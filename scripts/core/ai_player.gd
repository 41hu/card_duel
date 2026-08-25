# ai_player.gd — 人机对战 AI（局势感知打分制）
# 设计：每个合法动作算"效用分"（真实伤害×价值+策略档位修正+随机扰动），选最高分执行。
# 核心系统：
#   · 真实伤害：复用 combat.calculate_attack（武器/Buff/防具全算），斩杀判定准确
#   · 角色定位：基础标签 + 面板动态漂移，AI 知道自己该贴脸/中距离/自由位
#   · 记牌：从日志统计打出/响应消耗 + 数弃牌堆，推算某类攻击牌全局剩余
#   · 资源期：双方火力枯竭时转入攒资源模式（保留牌、打强化/天赐、不无脑出手）
# 难度四档：easy=粗打分+大扰动+装傻 / normal=定位+真实伤害+斩杀保命 / hard=全部+记牌资源期+读牌 /
# hell（内测）= 全部 + 全知（直接读对手手牌：响应预测/威胁评估精确化）+ 高复活率。
extends RefCounted

const DIFF_EASY = 0
const DIFF_NORMAL = 1
const DIFF_HARD = 2
const DIFF_HELL = 3

var match_ref
var difficulty: int = DIFF_NORMAL
# 记忆对手用过的响应卡类型（hard 难度读牌用，从日志解析填充）
var _opp_used_responses: Dictionary = {}
# 本回合是否已用过"骗响应"低价值攻击（每回合限一次，避免连续骗卡浪费输出）
var _bait_used: bool = false
var _bait_turn: int = -1
# 我方攻击被响应打断的统计（拟人化：同类型连续被挡 → 换招/骗响应）
var _blocked_attack_counts: Dictionary = {}
var _last_blocked_type: String = ""
var _scan_turn: int = -1
# 决策轨迹（对局日志复盘）：本回合攻击牌打分明细 + 最终决策摘要，返回前写入 action_log
var _atk_trace: Array = []
var _trace_ctx: Dictionary = {}

func _init(match, diff: int = DIFF_NORMAL):
	match_ref = match
	difficulty = diff

# ---------- 角色定位基础标签（新角色缺省时按面板自动判定） ----------
const _BASE_ROLES := {
	"fighter": "near", "berserker": "near", "assassin": "near", "paladin": "near",
	"sharpshooter": "range", "hunter": "range", "gunslinger": "range", "tracker": "range",
	"mage": "magic", "priest": "magic", "warlock": "magic", "miko": "magic",
}

func _role_types(role: String) -> Array:
	match role:
		"near": return ["near", "heavy"]
		"range": return ["range", "pierce"]
		"magic": return ["magic", "chant"]
	return ["near"]

# 当前定位：基础标签 + 面板漂移（成长卡把某面板叠高基础定位 2 点以上 → 漂移）
func _current_role(player_idx: int) -> String:
	var p = match_ref.get_player(player_idx)
	var base: String = _BASE_ROLES.get(p.char_id, "near")
	var best := "near"
	var best_v: int = p.near_power
	if p.range_power > best_v: best = "range"; best_v = p.range_power
	if p.magic_power > best_v: best = "magic"; best_v = p.magic_power
	var base_v: int = p.near_power if base == "near" else (p.range_power if base == "range" else p.magic_power)
	if best != base and best_v >= base_v + 2:
		return best
	return base

# ---------- 卡牌价值（弃牌/法师强化用；攻击类按真实伤害，不在此表） ----------
func _card_value(player_idx: int, type_id: String) -> int:
	var p = match_ref.get_player(player_idx)
	match type_id:
		"near", "heavy": return p.near_power + 2
		"range", "pierce":
			return (p.range_power + 2) * match_ref.char_skills.get_attack_hit_count(player_idx, type_id)
		"magic", "chant": return p.magic_power + 2
		"move": return 3
		"heal_3": return 4
		"heal_5": return 6
		"near_buf", "range_buf", "magic_buf": return 6
		"blessing": return 7  # 天赐免费抽2，资源价值高，不易被弃/不被当弃牌强化材料
		"item": return 5
		"attract", "deter": return 4
		"freeze": return 6
		"destroy": return 5
		"seize": return 5
		_: return 1

# ---------- 真实伤害（复用战斗公式：武器/Buff/防具全算；多段×段数） ----------
func _real_damage(player_idx: int, type_id: String) -> int:
	# 近战/重击必须贴脸（calculate_attack 不检查距离，出牌层才拦——AI 要自己模拟"能否打出"）
	if type_id in ["near", "heavy"] and match_ref.movement.get_distance() != 0:
		return 0
	var opp = 1 - player_idx
	var calc = match_ref.combat.calculate_attack(player_idx, opp, type_id)
	if calc.get("blocked", false):
		return 0
	var dmg = int(calc.get("damage", 0))
	if dmg <= 0: return 0
	# 法师强化 buff 加成（魔法/吟唱）：叠加层全部计入（打出即消耗，由 on_attack_cast 清除）
	if type_id in ["magic", "chant"]:
		dmg += match_ref.char_skills.mage_empower_value(player_idx)
	var hits = match_ref.char_skills.get_attack_hit_count(player_idx, type_id)
	# 圣骑士被动：每回合首次受伤-2（最低0）——只读模拟（直接调 on_taking_damage 会
	# 消耗真实 damage_reduction_used 状态导致实际攻击不减伤）；多段攻击只减免第一段
	var opp_p = match_ref.get_player(opp)
	if opp_p.char_id == "paladin" and not opp_p.damage_reduction_used:
		var total = 0
		for i in range(hits):
			total += (max(0, dmg - 2) if i == 0 else dmg)
		return total
	return dmg * hits

# 当前回合我能造成的最高真实伤害（斩杀判定用）
func _my_best_damage(player_idx: int) -> int:
	var role = _current_role(player_idx)
	var best = 0
	for t in _role_types(role):
		best = max(best, _real_damage(player_idx, t))
	return best

# 对手当前能造成的最高真实伤害（含对手武器/Buff，防斩判定用）
# 地狱全知：按对手手牌实际攻击牌计算（普通难度按定位理论最大值，可能高估）
func _opp_best_damage(player_idx: int) -> int:
	var opp = 1 - player_idx
	if difficulty >= DIFF_HELL:
		var best = 0
		for c in match_ref.card_systems[opp].hand:
			if c.get("type_id", "") in ["near", "heavy", "range", "pierce", "magic", "chant"]:
				best = max(best, _real_damage(opp, c.type_id))
		return best
	var role = _current_role(opp)
	var best = 0
	for t in _role_types(role):
		best = max(best, _real_damage(opp, t))
	return best

# ---------- 记牌系统 ----------
# 共享牌堆（默认）：全局某类牌剩余（牌堆+手牌循环中）= 初始 − 双方打出/响应消耗 − 共享弃牌堆
# 独立牌堆（PVE）：某玩家牌堆中剩余 = 初始 − 该玩家手牌 − 该玩家弃牌 − 该玩家日志打出/响应
func _global_left(player_idx: int, type_id: String) -> int:
	# 独立牌堆（自定义卡组）：直接数「牌堆剩余 + 手牌 + 弃牌」= 该卡实际可获取总数。
	# 不能用 CARD_COUNTS（默认 78 张基数）推算——40 张构筑里该卡可能只带 1-2 张，
	# 用默认基数会严重高估剩余（AI 记牌失准）。
	if match_ref.independent_decks:
		return _count_in_deck(player_idx, type_id) + _count_in_hand(player_idx, type_id) + _count_in_discard(player_idx, type_id)
	var left = Config.CARD_COUNTS.get(type_id, 0)
	left -= _played_from_log(-1, type_id)  # -1 = 统计双方
	left -= _count_in_discard(0, type_id)  # 共享弃牌堆
	return max(0, left)

func _count_in_deck(player_idx: int, type_id: String) -> int:
	var n = 0
	for c in match_ref.card_systems[player_idx].deck:
		if c.type_id == type_id: n += 1
	return n

func _count_in_hand(player_idx: int, type_id: String) -> int:
	var n = 0
	for c in match_ref.card_systems[player_idx].hand:
		if c.type_id == type_id: n += 1
	return n

func _played_from_log(player_idx: int, type_id: String) -> int:
	var n = 0
	var cname = Config.card_name(type_id)
	for e in match_ref.action_log:
		if player_idx >= 0 and e.get("player", -1) != player_idx: continue
		var msg: String = e.get("msg", "")
		# 攻击打出："XX打出近战"；响应消耗："用近战格挡/用远程牵制/用魔法闪避"
		if msg.contains("打出") and msg.contains(cname):
			n += 1
		elif msg.contains("用") and msg.contains(cname) and (msg.contains("格挡") or msg.contains("牵制") or msg.contains("闪避")):
			n += 1
	return n

func _count_in_discard(player_idx: int, type_id: String) -> int:
	var n = 0
	for c in match_ref.card_systems[player_idx].discard:
		if c.type_id == type_id: n += 1
	return n

# 从日志解析响应历史（每回合刷新一次）：
# 1. 对手用过的响应类型（hard 读牌正式接入——remember_response 无调用点，改从日志解析）
# 2. 我方攻击被响应打断的统计（拟人化：连续被挡后换招/骗响应）
func _scan_response_log(player_idx: int):
	_opp_used_responses.clear()
	_blocked_attack_counts.clear()
	var resp_names := {"近战": "near", "远程": "range", "魔法": "magic"}
	var prev_was_response := false
	var prev_resp_player := -1
	for e in match_ref.action_log:
		var msg: String = e.get("msg", "")
		var ep: int = e.get("player", -1)
		var responded := false
		var resp_type := ""
		for cname in resp_names:
			if msg.contains("用" + cname) and (msg.contains("格挡") or msg.contains("牵制") or msg.contains("闪避")):
				responded = true
				resp_type = resp_names[cname]
				break
		if responded:
			if not _opp_used_responses.has(ep):
				_opp_used_responses[ep] = []
			_opp_used_responses[ep].append(resp_type)
			prev_was_response = true
			prev_resp_player = ep
		elif msg.contains("使用") and ((msg.contains("对") and msg.contains("造成")) or msg.contains("未造成伤害")):
			# 攻击结算行：紧跟响应日志 → 该次攻击被挡（防具挡下不算，prev_was_response 为 false）
			if prev_was_response and prev_resp_player == 1 - ep:
				var atype := _attack_type_from_msg(msg)
				if atype != "":
					_blocked_attack_counts[atype] = _blocked_attack_counts.get(atype, 0) + 1
					_last_blocked_type = atype
			prev_was_response = false
		else:
			prev_was_response = false

# 从攻击结算日志行解析攻击卡类型（"使用{卡名}对X造成/攻击未造成伤害"）
func _attack_type_from_msg(msg: String) -> String:
	for tid in ["near", "heavy", "range", "pierce", "magic", "chant"]:
		if msg.contains("使用") and msg.contains(Config.card_name(tid)):
			return tid
	return ""

# 手牌中"打得出的"攻击牌数量（资源期判定用）
# 近战型手牌全是远距离打不出的近战卡 → 攻击力 0 → 正确进入资源期攒资源
# （与人类"保留打不出的牌制造威慑 + 过回合抽卡"的资源期行为一致）
func _hand_attack_count(player_idx: int) -> int:
	var n = 0
	for c in match_ref.card_systems[player_idx].hand:
		if c.type_id in ["near", "heavy", "range", "pierce", "magic", "chant"]:
			if _real_damage(player_idx, c.type_id) > 0:
				n += 1
	return n

# 自己牌组攻击牌剩余总数（资源期判定用：牌堆中还剩几张攻击牌）
func _global_attack_left(player_idx: int) -> int:
	var total = 0
	for t in ["near", "heavy", "range", "pierce", "magic", "chant"]:
		total += _global_left(player_idx, t)
	return total

# 手牌是否持有近战/重击卡（法术型贴脸压制的前提——逼近后能立刻近战输出）
func _hand_has_melee(player_idx: int) -> bool:
	for c in match_ref.card_systems[player_idx].hand:
		if c.type_id in ["near", "heavy"]:
			return true
	return false

# 对手是否为法术型（主要输出来自魔法、近战弱）：魔法面板≥5 或 定位 magic
# 用途：猎人对法术型采用「贴脸近战压制 + 魔法卡保命」策略——魔法无视距离，风筝无意义
func _opp_is_magic_type(player_idx: int) -> bool:
	var opp = match_ref.get_player(1 - player_idx)
	if opp.magic_power >= 5:
		return true
	return _current_role(1 - player_idx) == "magic"

# 对手是否为牧师（回复型：回复卡+2、真言靠弃回复卡，回复卡 = 血库+真言素材双价值）
# 用途：猎人对牧师采用「打资源」策略——冻结断回血、摧毁/夺取抢回复卡（她打消耗战的核心）
func _opp_is_priest(player_idx: int) -> bool:
	return match_ref.get_player(1 - player_idx).char_id == "priest"

# ---------- 地狱全知（读对手真实手牌） ----------
# 对手手牌中某类型牌数量（难度不足时退化调用方逻辑，不直接使用）
func _opp_hand_count(opp_idx: int, type_id: String) -> int:
	var n = 0
	for c in match_ref.card_systems[opp_idx].hand:
		if c.get("type_id", "") == type_id:
			n += 1
	return n

# 对手手牌中攻击牌数量（地狱：响应后是否有后续威胁）
func _opp_hand_attack_count(opp_idx: int) -> int:
	var n = 0
	for c in match_ref.card_systems[opp_idx].hand:
		if c.get("type_id", "") in ["near", "heavy", "range", "pierce", "magic", "chant"]:
			n += 1
	return n

# 地狱：打出某类型攻击的响应风险（对手手牌精确判断）
# 魔法闪避可防所有攻击（0 伤害）风险最高；格挡（近战系）/牵制（远程系）次之
func _hell_response_risk(opp_idx: int, type_id: String) -> int:
	if _opp_hand_count(opp_idx, "magic") > 0:
		return 14
	if type_id in ["near", "heavy"] and _opp_hand_count(opp_idx, "near") > 0:
		return 8
	if type_id in ["range", "pierce", "magic", "chant"] and _opp_hand_count(opp_idx, "range") > 0:
		return 6
	return 0

# 对手贴脸伤害（近战/重击最大值）——远程型评估"贴脸安不安全"用
func _opp_near_threat(player_idx: int) -> int:
	var opp = 1 - player_idx
	# 地狱全知：对手手里没有近战/重击 → 贴脸威胁 0（普通难度按面板理论值估算）
	if difficulty >= DIFF_HELL:
		var best = 0
		for c in match_ref.card_systems[opp].hand:
			if c.get("type_id", "") in ["near", "heavy"]:
				best = max(best, _real_damage(opp, c.type_id))
		return best
	return max(_real_damage(opp, "near"), _real_damage(opp, "heavy"))

# 指定格是否有道具（陷阱/捕兽夹）——位移/暗影步踩中会受伤
func _item_at(pos: Vector2i) -> bool:
	for it in match_ref.items:
		if it.position == pos:
			return true
	return false

# 目标格对该角色的道具伤害风险（0=安全；>0=踩中会受的伤害，用于移动避障分级）
# 区分道具类型与角色免疫：捕兽夹对猎人免疫（安全），敌方鸟居神隐视为极高危
func _item_risk(player_idx: int, pos: Vector2i) -> int:
	var p = match_ref.get_player(player_idx)
	var risk = 0
	for it in match_ref.items:
		if it.position != pos: continue
		match it.item_type:
			"snare":
				if p.char_id != "hunter": risk += 4  # 夹子：猎人免疫，其他角色-4（2026-08-25 平衡：夹子3→4伤）
			"trap":
				risk += 3  # 普通陷阱：所有人-3
			"torii":
				if it.owner != player_idx: risk += 999  # 敌方鸟居：踩上神隐跳过回合，视为高危
	return risk

# 目标格是否有"我方放置的鸟居"（巫女踩上成长：+2HP 全属性+1；敌方踩上神隐）
func _my_torii_at(player_idx: int, pos: Vector2i) -> bool:
	for it in match_ref.items:
		if it.position == pos and it.item_type == "torii" and it.owner == player_idx:
			return true
	return false

# 目标格是否有"敌方放置的鸟居"（把敌人推入 → 神隐 combo）
func _opp_torii_at(player_idx: int, pos: Vector2i) -> bool:
	for it in match_ref.items:
		if it.position == pos and it.item_type == "torii" and it.owner != player_idx:
			return true
	return false

# 对手闪避威胁：hard 读牌——对手用过魔法闪避且手牌多（可能有闪避牌存量）
# 此时爆发牌大概率被闪避，应先骗响应消耗闪避再打主属性
# 地狱全知：直接看对手手牌有没有魔法闪避牌（精确）
func _opp_dodge_threat(player_idx: int) -> bool:
	if difficulty >= DIFF_HELL:
		return _opp_hand_count(1 - player_idx, "magic") > 0
	if difficulty < DIFF_HARD: return false
	var used = _opp_used_responses.get(1 - player_idx, [])
	var magic_used = 0
	for u in used:
		if u == "magic": magic_used += 1
	return magic_used >= 1 and match_ref.card_systems[1 - player_idx].hand.size() >= 2

# 对手贴脸威胁预判：对手近战型 + 距离近（≤3）+ 手牌多（可能攒着爆发牌）
# 近战角色"近身难"（抽不到移动卡）——对手可能憋 2-3 回合后一波贴脸爆发，AI 要提前防
func _near_threat_imminent(player_idx: int) -> bool:
	var opp = 1 - player_idx
	if _current_role(opp) != "near": return false
	var dist = match_ref.movement.get_distance()
	return dist <= 3 and match_ref.card_systems[opp].hand.size() >= 2

# 对方主要进攻类型：定位优先；hard 记牌修正——对手牌堆某类攻击牌剩余明显多于定位类时
# （对方抽到该类攻击牌的概率高），防御转向该类
func _opp_main_attack_type(player_idx: int) -> String:
	var opp = match_ref.get_player(1 - player_idx)
	var role = _current_role(1 - player_idx)
	# 面板修正：对手魔法面板 ≥ 其主攻面板 - 1 → 魔法威胁不可忽视（无视距离 + 可被强化卡抬升）。
	# 例：圣骑士(近4远2魔3) → 魔法防具优先（吟唱 4+3=7 / 魔法 4 是其主要伤害来源）
	if opp.magic_power >= opp.near_power - 1 and opp.magic_power >= opp.range_power - 1:
		return "magic"
	if difficulty < DIFF_HARD: return role
	var counts := {}
	for t in ["near", "range", "magic"]:
		counts[t] = 0
		for atk in _role_types(t):
			counts[t] += _global_left(1 - player_idx, atk)
	var role_count: int = counts.get(role, 0)
	for t in ["near", "range", "magic"]:
		if counts[t] > role_count + 3:
			return t
	return role

# 远程型贴脸是否安全：贴脸换血不亏（我贴脸最高伤害 ≥ 对手贴脸伤害），或血量显著占优
func _range_melee_safe(player_idx: int) -> bool:
	var p = match_ref.get_player(player_idx)
	var opp = match_ref.get_player(1 - player_idx)
	var threat = _opp_near_threat(player_idx)
	if threat <= 0: return true
	var my_best = 0
	for t in ["range", "pierce", "near", "heavy"]:
		my_best = max(my_best, _real_damage(player_idx, t))
	if my_best >= threat: return true
	return float(p.hp) / max(p.max_hp, 1) >= float(opp.hp) / max(opp.max_hp, 1) + 0.15

# ---------- 攻击动作打分 ----------
func _attack_score(player_idx: int, dmg: int, opp_idx: int, stance: Dictionary) -> int:
	var p = match_ref.get_player(player_idx)
	var opp = match_ref.get_player(opp_idx)
	var score = dmg * 4
	if dmg >= opp.hp:
		score += 80  # 斩杀优先（真实伤害判定）
	# 对手手牌多 → 响应风险（对手响应牌占比约 1/3，惩罚按期望而非手牌数放大）
	if difficulty >= DIFF_NORMAL:
		score -= match_ref.card_systems[opp_idx].hand.size()
	# 开局试探期（拟人化）：人类前两回合以布局+试探为主，不无脑全力输出——
	# 高伤害爆发牌（≥6）开局照打（如快枪手穿心双发），小伤害攻击降分（留牌等时机）
	if match_ref.turn_number <= 2:
		if dmg >= 6:
			score += 6
		else:
			score -= 4
	# hard：读牌——对手用过的响应类型记忆
	if difficulty >= DIFF_HARD:
		var used = _opp_used_responses.get(opp_idx, [])
		if used.size() >= 2:
			score += 6  # 对手响应牌消耗多，攻击更安全
		# 对手用过闪避且手牌多 → 爆发牌大概率被闪避，降低攻击预期（应先用骗卡消耗闪避）
		if _opp_dodge_threat(player_idx):
			score -= 8
	# 危险/保命档：血量劣势时进攻收敛（避免送死对拼；斩杀判定兜底）
	var s_stance = stance.get("stance", "")
	if s_stance == "flee":
		score -= 6
	elif s_stance == "danger":
		score -= 10  # 危险档更谨慎：对手两刀斩杀范围内不冒险换血
	# 资源期：火力枯竭时低价值攻击不打（攒牌等重洗）
	if stance.get("stance", "") == "resource":
		score -= 30
	# 距离修正（按定位）
	if difficulty >= DIFF_NORMAL:
		var dist = match_ref.movement.get_distance()
		var role = _current_role(player_idx)
		if role == "range":
			# 远程伤害随距离衰减 → 贴脸伤害最高。安全时可贴脸打远程，危险时保持距离
			var safe = _range_melee_safe(player_idx)
			if dist <= 1 and not safe:
				score -= 10  # 距离 1 也在对手贴脸范围内，危险时不冒险换血
			elif dist == 0 and safe:
				score += 4
		elif role == "near" and dist > 0:
			score -= 6  # 近战型远距离只有远程卡时攻击打折（更应贴脸）
	# 自己血量低时略收敛（回血由回复分支接管，进攻不全面冻结）
	if float(p.hp) / p.max_hp < 0.3:
		score -= 6
	return score

# ---------- 局势评估（读双方数值/状态 → 档位） ----------
func _evaluate_stance(player_idx: int) -> Dictionary:
	var p = match_ref.get_player(player_idx)
	var opp = match_ref.get_player(1 - player_idx)
	var my_role = _current_role(player_idx)
	var opp_role = _current_role(1 - player_idx)
	var my_dmg = _my_best_damage(player_idx)
	var opp_dmg = _opp_best_damage(player_idx)
	var stance = "normal"
	# 斩杀：我能这回合打死对手
	if my_dmg >= opp.hp and opp.hp > 0:
		stance = "kill"
	# 保命：对手可能斩杀我（进入斩杀线）
	elif opp_dmg >= p.hp:
		stance = "flee"
	# 危险：对手伤害威胁大且我血量不高 → 提前防守（回血/留闪避/不冒险对拼）
	# 避免被真人"秒杀"：血量进入对手 2 刀斩杀范围时就开始保命，而不是等最后一回合
	elif opp_dmg >= p.hp * 0.5 and float(p.hp) / p.max_hp < 0.7:
		stance = "danger"
	# 资源期（hard 记牌）：真的没进攻能力——我手牌攻击牌 ≤1 且全局攻击牌剩余枯竭
	# （只看手牌+牌堆总数，避免过早进入资源期；手里有攻击牌就不是资源期）
	elif difficulty >= DIFF_HARD and _hand_attack_count(player_idx) <= 1 and _global_attack_left(player_idx) <= 6:
		stance = "resource"
	# 压制：我 HP 明显高于对手
	elif float(p.hp) / max(p.max_hp, 1) >= float(opp.hp) / max(opp.max_hp, 1) + 0.2:
		stance = "pressure"
	return {"stance": stance, "my_role": my_role, "opp_role": opp_role, "my_dmg": my_dmg, "opp_dmg": opp_dmg}

# ---------- 出牌阶段决策（返回 process_action 的 action 字典） ----------
func decide_action(player_idx: int) -> Dictionary:
	var p = match_ref.get_player(player_idx)
	var hand = match_ref.card_systems[player_idx].hand
	var opp_idx = 1 - player_idx
	var opp = match_ref.get_player(opp_idx)
	var distance = match_ref.movement.get_distance()
	var hp_ratio = float(p.hp) / p.max_hp
	var stance = _evaluate_stance(player_idx)
	var my_role = stance.get("my_role", "near")
	var opp_role = stance.get("opp_role", "near")
	var is_hard = difficulty >= DIFF_HARD
	var is_norm = difficulty >= DIFF_NORMAL
	var is_hell = difficulty >= DIFF_HELL

	var best_score: int = -99999
	var best_action: Dictionary = {}
	_atk_trace.clear()
	_trace_ctx = {
		"stance": stance.get("stance", "?"), "dist": distance,
		"hand": hand.size(), "limit": match_ref.movement.get_hand_limit(player_idx),
		"my_dmg": stance.get("my_dmg", 0), "opp_dmg": stance.get("opp_dmg", 0),
		"hp": p.hp, "max_hp": p.max_hp, "opp_hp": opp.hp,
	}

	# 回合级状态重置（骗响应每回合限一次 + 每回合刷新日志解析）
	if match_ref.turn_number != _bait_turn:
		_bait_turn = match_ref.turn_number
		_bait_used = false
	if match_ref.turn_number != _scan_turn:
		_scan_turn = match_ref.turn_number
		_scan_response_log(player_idx)

	# 防守保留：手里至少保留 1 张响应牌（近战=格挡/远程=牵制/魔法=闪避），
	# 斩杀（能击倒对手）时例外，全力进攻。
	var resp_count = 0
	for card in hand:
		if card.type_id in ["near", "range", "magic"]:
			resp_count += 1
	var can_kill = _my_best_damage(player_idx) >= opp.hp and opp.hp > 0

	# 1. 攻击动作（真实伤害；AP 感知——攻击点不够的卡不选，避免打出失败浪费回合）
	for card in hand:
		if not card.has("type_id"): continue  # 防御：跳过异常卡（防牌堆污染残留）
		var tid = card.type_id
		if not tid in ["near", "heavy", "range", "pierce", "magic", "chant"]:
			continue
		# 猎人专属：魔法卡纯保命（闪避响应），不主动打出——猎人魔 2 数值太低，
		# 打出去 2 点伤害远不如留作闪避保命（用户确认：保命价值 > 输出价值）
		if p.char_id == "hunter" and tid == "magic":
			_atk_trace.append({"tid": tid, "dmg": -1, "score": -999, "skip": "魔法保命(猎人)"})
			continue
		var atk_cost = match_ref.char_skills.get_attack_cost(player_idx, tid)
		if atk_cost < 0: atk_cost = Config.CARD_DB.get(tid, {}).get("cost", 1)
		if p.ap_attack < atk_cost: continue  # 攻击点不足（快枪手远程耗 2 等）
		var dmg = _real_damage(player_idx, tid)
		if dmg <= 0:
			_atk_trace.append({"tid": tid, "dmg": 0, "score": -999, "skip": "0伤(防具免疫/距离)"})
			continue
		# 定位保留：非斩杀时，定位类攻击卡在"时机未到"（距离不合适）时保留在手，等进入理想距离爆发
		if is_norm and not can_kill:
			var is_role_card = tid in _role_types(my_role)
			if is_role_card:
				if my_role == "near" and distance > 0:
					continue  # 近战型：没贴脸时近战卡留着
				if my_role == "range" and tid in ["range", "pierce"] and distance == 0 \
						and not _range_melee_safe(player_idx):
					# 远程型：贴脸（距离0）换血亏 → 留着拉开再打；距离 1 是白嫖输出不拦
					# 濒死豁免：我方血量 ≤35% 或处于危险/保命档（对手能斩杀我）时，
					# "怕换血"不成立——反正快死了，贴脸搏命输出优先（实测：8HP 猎人贴脸
					# 穿心 8 伤不打 → 被斗士 9 伤带走，错过击杀窗口）
					var lethal_soon = float(p.hp) / p.max_hp <= 0.35 \
							or stance.get("stance", "") in ["flee", "danger"]
					if lethal_soon:
						pass  # 搏命照打
					else:
						_atk_trace.append({"tid": tid, "dmg": dmg, "score": -999, "skip": "贴脸换血亏"})
						continue
			# 保留响应牌：非斩杀时，不打最后一张可响应卡。
			# 修正：血量健康（>50%）且未处于危险/保命档时**不强留**——输出优先，
			# 否则猎人手里唯一远程被锁死 → 打不出主输出 → 只能打无意义功能牌（用户实测反馈）
			var low_hp = float(p.hp) / p.max_hp <= 0.5
			var in_danger = stance.get("stance", "") in ["flee", "danger"]
			if tid in ["near", "range", "magic"] and resp_count <= 1 and (low_hp or in_danger):
				_atk_trace.append({"tid": tid, "dmg": dmg, "score": -999, "skip": "保留响应牌(残血/危险)"})
				continue
			# 危险/保命/贴脸威胁：魔法闪避牌强制保留（防被真人斩杀一波带走）
			if tid == "magic" and (stance.get("stance", "") in ["danger", "flee"]
					or (is_norm and _near_threat_imminent(player_idx) and distance <= 2)):
				continue
			# 自己唯一魔法卡 + 对手闪避威胁：保留（打了会被闪避，还白送闪避牌）
			if tid == "magic" and _opp_dodge_threat(player_idx):
				var my_magic = 0
				for c in hand:
					if c.type_id == "magic": my_magic += 1
				if my_magic <= 1:
					continue
		var s = _attack_score(player_idx, dmg, opp_idx, stance)
		# 法术型对策：近战/重击面板占优（法术型近 2 格挡弱）且逼迫消耗其闪避 → 加分；
		# 远程/穿心对法术型易被闪避（她们手牌魔法卡多 = 闪避多）→ 降分
		if _opp_is_magic_type(player_idx):
			if tid in ["near", "heavy"]: s += 6
			elif tid in ["range", "pierce"]: s -= 4
		_atk_trace.append({"tid": tid, "dmg": dmg, "score": s, "skip": ""})
		# 地狱全知：对手手牌精确响应风险惩罚（闪避/格挡/牵制可防则攻击预期下降）
		if is_hell:
			s -= _hell_response_risk(opp_idx, tid)
		# 拟人化换招（normal+）：同类型攻击连续被响应(≥2次) → 大幅降分换招；
		# 最近被打断的是其他类型 → 换类型打更可能命中，加分
		if is_norm:
			if _blocked_attack_counts.get(tid, 0) >= 2:
				s -= 25
			elif _last_blocked_type != "" and tid != _last_blocked_type:
				s += 6
		# 骗响应连招（normal+，每回合限一次）：手牌有主属性爆发（定位卡高伤害）时，
		# 低价值攻击（非定位、非唯一保命牌）先手消耗对手响应牌，主属性随后爆发——
		# 对手不响应则骗响应卡本身也耗血，响应则消耗其响应牌（hard 记牌可读）。
		if is_norm and not can_kill and not _bait_used and _my_best_damage(player_idx) > 0:
			var is_main_card = tid in _role_types(my_role)
			var is_last_resp = tid in ["near", "range", "magic"] and resp_count <= 1
			# 法术型对手手牌魔法比例天然高（闪避存量高）→ 直接视为闪避威胁，骗卡收益大
			var dodge_threat = _opp_dodge_threat(player_idx) or _opp_is_magic_type(player_idx)
			# 地狱全知：对手手牌无任何响应牌 → 骗响应无意义，直接主属性爆发
			var hell_no_resp = is_hell and (_opp_hand_count(opp_idx, "magic") + _opp_hand_count(opp_idx, "near") + _opp_hand_count(opp_idx, "range")) == 0
			# 骗响应：常规要求伤害明显低于主属性；对手闪避威胁大时放宽（接近主属性的也能当骗卡）
			if not hell_no_resp and not is_main_card and not is_last_resp and match_ref.card_systems[opp_idx].hand.size() >= 2 \
					and (dmg * 2 < _my_best_damage(player_idx) or dodge_threat):
				var bonus = min(18, _my_best_damage(player_idx) * 2 + 6)
				if dodge_threat: bonus += 10
				if _opp_is_magic_type(player_idx): bonus += 6  # 法术型闪避牌多，骗卡收益大
				s += bonus
				_bait_used = true  # 本回合只骗一次，之后直接主属性爆发
		if s > best_score:
			best_score = s
			best_action = {"action": "play_card", "card_uid": card.uid}

	# 2. 回复（血少时；保命档大幅提高；功能点感知）
	if hp_ratio < 0.65:
		for card in hand:
			if p.ap_function < 1: break
			var amt = -1
			match card.type_id:
				"heal_3": amt = 3
				"heal_5": amt = 5
			if amt > 0:
				var s = 20 + amt * 2
				if hp_ratio < 0.35: s += 30
				if stance.get("stance", "") == "flee": s += 40  # 防斩：回血救命
				if stance.get("stance", "") == "danger": s += 25  # 危险档提前回血，防止进入斩杀线
				if s > best_score:
					best_score = s
					best_action = {"action": "play_card", "card_uid": card.uid}

	# 3. 强化卡（时机：本回合有该类型攻击配合 / 资源期攒面板 / 无事可做时打掉而非弃掉；功能点感知）
	for card in hand:
		if p.ap_function < 1: break
		var tid = card.type_id
		if tid in ["near_buf", "range_buf", "magic_buf"]:
			var s = 8  # 基础分：永久+1 不亏，无事可做时打掉比留在手里被弃好
			var buf_role = "near" if tid == "near_buf" else ("range" if tid == "range_buf" else "magic")
			# 本回合能立刻用强化后的面板攻击 → 高分（功能点与攻击点独立，可组合）
			var has_atk_of_role = false
			for c in hand:
				if c.type_id in _role_types(buf_role):
					has_atk_of_role = true
					break
			if has_atk_of_role:
				s = 18 + (10 if buf_role == my_role else 0)  # 定位匹配的强化更值
			if stance.get("stance", "") == "resource":
				s = 22  # 资源期攒面板（永久+1 循环叠加）
			if s > best_score:
				best_score = s
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 4. 免费卡（天赐抽2）：手牌少或资源期；功能点感知
	for card in hand:
		if p.ap_function < 1: break
		if card.type_id == "blessing":
			var s = 8
			if hand.size() <= 3: s = 16
			if stance.get("stance", "") == "resource": s = 18
			if s > best_score:
				best_score = s
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 5. 冻结（打断对手节奏）；对手威胁大（手牌多/即将斩杀）时高分；功能点感知
	for card in hand:
		if p.ap_function < 1: break
		if card.type_id == "freeze":
			var s = 8
			if opp.frozen_lockout == 0:
				if match_ref.card_systems[opp_idx].hand.size() >= 4 or stance.get("stance", "") == "flee":
					s = 26  # 对手手牌多（即将爆发）或我要被斩杀 → 冻住打断（拟人化：优先于普通攻击）
				else:
					s = 12
				# 牧师专项：冻结跳过其出牌阶段 = 断一回合回血/真言（对回复型消耗战价值极高）
				if _opp_is_priest(player_idx):
					s = max(s, 20)
			if s > best_score:
				best_score = s
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 6. 摧毁 / 夺取（消耗对方资源；对手手牌多时夺取更值；功能点感知——邪术师 2 点可打两张）
	for card in hand:
		if p.ap_function < 1: break
		if card.type_id == "destroy":
			var s = 0
			var d_target = {}
			# 敌方鸟居（神隐威胁：踩上跳过回合）→ 拆鸟居最高优先（巫女专属；所有难度都拆，
			# 场上道具是公开信息不依赖全知——此前仅地狱会拆，普通难度漏拆）
			for it in match_ref.items:
				if it.item_type == "torii" and it.owner == opp_idx:
					s = 16
					d_target = {"destroy_target": "trap", "trap_pos": match_ref.movement.geometry.to_dict(it.position)}
					break
			# 满耐久防具完全免疫我方主攻 → 拆防具是解输出死锁的关键（优先级高于拆武器）。
			# 例：猎人穿心被狂战士满耐久远程防具全挡 → 不拆防具则整局 0 输出（用户实测日志验证）
			var armor_blocks_main := false
			if not opp.armor.is_empty() and opp.armor.id != "demon_armor" \
					and int(opp.armor.get("durability", 0)) >= int(opp.armor.get("max_durability", 3)):
				var my_main = _current_role(player_idx)
				var atype: String = opp.armor.id
				armor_blocks_main = (atype == "near_armor" and my_main == "near") \
						or (atype == "range_armor" and my_main == "range") \
						or (atype == "magic_armor" and my_main == "magic")
			# 牧师专项：拆手牌（盲丢可能丢到回复卡 = 她的血库+真言素材，双重收益）优先级最高，
			# 高于拆武器/防具——牧师打消耗战的核心是回复卡，打掉一张少回 5-7 血
			if d_target.is_empty() and _opp_is_priest(player_idx) \
					and match_ref.card_systems[opp_idx].hand.size() > 0:
				s = 14
				d_target = {"destroy_target": "hand"}
			elif d_target.is_empty() and armor_blocks_main:
				s = 18  # 免疫我主攻的满耐久防具：拆掉恢复输出
				d_target = {"destroy_target": "equip", "equip_type": "armor"}
			elif d_target.is_empty() and not opp.weapon.is_empty():
				s = 14  # 拆武器（对方输出核心）最值
				d_target = {"destroy_target": "equip", "equip_type": "weapon"}
			elif d_target.is_empty() and not opp.armor.is_empty() and opp.armor.id != "demon_armor":
				s = 12  # 拆防具次之（活铠免疫摧毁，不选——服务端会拒绝白耗卡）
				d_target = {"destroy_target": "equip", "equip_type": "armor"}
			elif d_target.is_empty() and match_ref.card_systems[opp_idx].hand.size() > 0:
				s = 8 + min(4, match_ref.card_systems[opp_idx].hand.size() * 2)  # 拆手牌（对手牌越多越值）
				# 地狱全知：对手手牌攻击牌多 → 拆手牌价值暴涨（废掉其输出/响应资源）
				if is_hell:
					var opp_atk = _opp_hand_attack_count(opp_idx)
					if opp_atk >= 2: s = max(s, 16)
					elif opp_atk == 1: s = max(s, 10)
				d_target = {"destroy_target": "hand"}
			# 对手无牌无装备 → s=0 不打（避免卡消耗无效果）
			if s > best_score:
				best_score = s
				best_action = {"action": "play_card", "card_uid": card.uid, "extra": d_target}
		if card.type_id == "seize":
			var s = 9 + min(6, match_ref.card_systems[opp_idx].hand.size() * 2)  # 对手手牌越多夺牌收益越大
			# 地狱全知：对手手牌有攻击牌 → 夺取可能抢走其核心输出，价值上调
			if is_hell and _opp_hand_attack_count(opp_idx) >= 1:
				s += 5
			# 牧师专项：盲抽可能抢走回复卡（血库+真言素材），价值上调
			if _opp_is_priest(player_idx):
				s += 6
			if s > best_score:
				best_score = s
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 7. 陷阱：预判放置；功能点感知
	#   对手近战型且可能贴脸（距离近+手牌多，憋爆发）→ 防守陷阱优先（放自己前方防贴脸）
	#   压制时放对手前方（封锁对方移动/被推踩中）；保命时放自己前方（防贴脸）
	var near_threat = _near_threat_imminent(player_idx)
	for card in hand:
		if p.ap_function < 1: break
		if card.type_id == "item":
			var s = 6
			if match_ref.turn_number <= 2:
				s += 5  # 开局布防习惯（拟人化）：人类前两回合就布置陷阱占位
			var geo = match_ref.movement.geometry
			var is_torii = match_ref.char_skills.get_item_type(player_idx) == "torii"
			var trap_pos: Vector2i = Vector2i.ZERO
			if is_torii:
				# 巫女鸟居：放自己前方一格——既是自增益点（踩上成长），也是防守地雷（敌人贴脸被推入神隐）
				trap_pos = geo.step(p.position, geo.direction_between(p.position, opp.position))
				s = 10
				if near_threat or stance.get("stance", "") in ["flee", "danger"]:
					s += 5  # 贴脸威胁/保命 → 防守地雷价值高
			elif stance.get("stance", "") == "flee" or near_threat:
				trap_pos = geo.step(p.position, geo.direction_between(p.position, opp.position))  # 自己朝对手侧一格（防贴脸）
			else:
				trap_pos = geo.step(opp.position, geo.direction_between(opp.position, p.position))  # 对手前方封锁
			if geo.is_valid(trap_pos) and trap_pos != p.position and trap_pos != opp.position:
				if not is_torii:
					if stance.get("stance", "") == "flee": s = 14
					elif near_threat: s = 13  # 对手可能贴脸爆发 → 防守陷阱优先（即使有攻击动作）
					elif is_hard and opp_role == "near": s = 12  # 对手近战型 → 封锁逼近路线更值
				if s > best_score:
					best_score = s
					best_action = {"action": "play_card", "card_uid": card.uid, "extra": {"trap_pos": geo.to_dict(trap_pos)}}

	# 7.5 猎人夹子区 combo：夹子区成型（同格 ≥2）且手牌有吸引/威慑 → 主动把对手送进夹子区
	if p.char_id == "hunter":
		var hc = _hunter_combo(player_idx, opp_idx, p, hand, distance, stance)
		if hc.get("score", 0) > best_score:
			best_score = hc.get("score", 0)
			best_action = hc.get("action", {})

	# 8. 位移：按定位控制距离（位移点感知）
	#   近战型：逼近贴脸；远程型：保持中距离(2~4)；保命：远离
	for card in hand:
		if p.ap_move < 1: break
		if card.type_id == "move":
			var s = 0
			var geo = match_ref.movement.geometry
			var dir: Vector2i = geo.direction_between(p.position, opp.position)
			var stance_s = stance.get("stance", "")
			if is_norm:
				if my_role == "near" and distance > 0:
					# 拟人化：手里有能打出的近战牌才积极逼近；无牌时远距离占位、近距离等牌
					var has_melee_now = false
					for c in hand:
						if c.type_id in ["near", "heavy"] and _real_damage(player_idx, c.type_id) > 0:
							has_melee_now = true
							break
					if has_melee_now or stance.get("stance", "") == "kill":
						s = 12 + (6 if distance <= 2 else 0)  # 贴脸逼近（有牌/可斩杀）
					elif distance > 3:
						s = 8  # 远距离无牌 → 缓慢占位
					else:
						s = 2  # 近距离无牌 → 等牌（人类不会白走）
				elif my_role == "range":
					if _opp_is_magic_type(player_idx) and _hand_has_melee(player_idx):
						# 法术型对策：魔法无视距离、风筝无意义 → 主动贴脸用近战/重击压制（面板占优）
						if distance > 1:
							s = 12 + (8 if distance <= 3 else 0)  # 逼近（3 格内优先）
						elif distance == 0:
							s = 3  # 已贴脸：保持（近战输出）
						else:
							s = 2  # 距离 1：再进一步贴脸
					else:
						# 远程伤害随距离衰减：安全时贴脸打远程（伤害最高），危险时保持距离
						var safe = _range_melee_safe(player_idx)
						if distance < 2 and not safe:
							s = 14  # 对手贴脸威胁大 → 后撤（优先于攻击/同分动作）
							if _near_threat_imminent(player_idx):
								s = 18  # 对手近战型可能贴脸爆发 → 坚决拉开（拟人化）
						elif distance < 2 and safe:
							s = 2  # 安全 → 贴脸打远程（伤害最高），不急着撤
						elif distance > 4: s = 8  # 太远 → 靠近到输出距离
						elif distance > 3: s = 4  # 偏远 → 靠近一点
						else: s = 2
						# 对手近战型可能贴脸爆发（憋牌）→ 提前拉开；权衡板边：后撤目标格上限 <4 不拉
						# （保持手牌资源：退板边 = 手牌上限被砍 = 抽牌超限狂弃 = 恶性循环）
						if _near_threat_imminent(player_idx) and distance <= 3:
							var back_limit = geo.hand_limit(player_idx, geo.step(p.position, -dir))
							if back_limit >= 4:
								s = max(s, 10)
						if _near_threat_imminent(player_idx) and distance <= 2:
								var back_limit2 = geo.hand_limit(player_idx, geo.step(p.position, -dir))
								if back_limit2 >= 4:
									s = 10
				if stance_s == "flee": s = max(s, 16)  # 防斩：拉开距离
				if stance_s == "danger": s = max(s, 12)  # 危险档：贴脸时拉开（防止被斩杀）
				if stance_s == "resource": s -= 4
			else:
				s = 8 + (6 if distance <= 2 else 0)
			# 贴脸时允许后撤（远程型/危险/保命拉开距离）；其余需 distance > 0
			var can_move = distance > 0 or ((my_role == "range" or stance_s == "flee" or stance_s == "danger") and distance == 0)
			if can_move and s > 0 and s > best_score:
				# 保命/远程危险/贴脸威胁预判时朝反方向后撤，否则朝对手（安全时贴脸打远程伤害最高）
				var mdir = dir
				if _opp_is_magic_type(player_idx) and _hand_has_melee(player_idx):
					mdir = dir  # 法术型：始终逼近贴脸（近战压制；魔法无视距离，后撤无意义）
				elif my_role == "range" and distance < 2:
					if not _range_melee_safe(player_idx): mdir = -dir
				if _near_threat_imminent(player_idx) and my_role in ["range", "magic"] and distance <= 3:
					# 提前拉开：有手牌空间才后撤（风筝）。
					# 无空间时：手里有近战/重击且距离≤2（上前可贴脸输出，物理穿透防具）→ 上前；
					# 否则原地不动（不送死上前，也不浪费移动卡）——修正"想撤撤不了、想上上不了"站桩
					var back_limit = geo.hand_limit(player_idx, geo.step(p.position, -dir))
					if back_limit >= 4:
						mdir = -dir
					else:
						var has_melee := false
						for c in hand:
							if c.type_id in ["near", "heavy"]:
								has_melee = true
								break
						if has_melee and distance <= 2:
							mdir = dir
						else:
							s = -999  # 原地保持（不移动），避免无意义走位
				if (stance_s == "flee" or stance_s == "danger") and distance <= 2 \
						and not _opp_is_magic_type(player_idx):
					mdir = -dir  # 保命拉开（对法术型不拉：魔法无视距离，后撤救不了）
				# 板边惩罚：朝自己板边移动会降低手牌上限（操作空间减少）→ 减分；
				# 朝中场移动保持上限 → 加分（鼓励维持操作空间）
				var target_pos = geo.step(p.position, mdir)
				var new_limit = geo.hand_limit(player_idx, target_pos)
				var cur_limit = match_ref.movement.get_hand_limit(player_idx)
				s += (new_limit - cur_limit) * 5
				# 后撤到低手牌上限位置：除非贴脸危急（保命优先），否则大幅减分（防退板边）
				if mdir == -dir and new_limit < 4 and not (distance == 0 and stance_s in ["flee", "danger"]):
					s -= 25
				# 避陷阱：目标格有道具（陷阱/捕兽夹）→ 按收益减分
				#   逼近后能立刻贴脸攻击 → 踩陷阱换爆发可接受（小减分）
				#   纯走位踩陷阱（无输出收益）→ 大减分避开
				#   保命时移动优先，踩也认
				# 自己的鸟居：踩上成长（+2HP 全属性+1 永久）——巫女核心收益
				if _my_torii_at(player_idx, target_pos):
					s += 12
				elif stance_s != "flee":
					# 道具风险分级：夹子对猎人免疫（安全），敌方陷阱/鸟居按风险减分
					var risk = _item_risk(player_idx, target_pos)
					if risk > 0:
						var new_dist = geo.distance(target_pos, opp.position)
						var gains_attack = false
						if new_dist == 0:
							for c in hand:
								if c.type_id in ["near", "heavy"]:
									gains_attack = true
									break
						# 后撤摆脱贴脸威胁（远程型危险贴脸）也算收益，踩陷阱换安全可接受
						var gains_safety = (my_role == "range" and mdir == -dir and distance <= 2)
						s -= 4 if (gains_attack or gains_safety) else min(14, risk * 4)
				if s > best_score:
					best_score = s
					best_action = {"action": "play_card", "card_uid": card.uid, "extra": {"direction": geo.to_dict(mdir), "steps": 1}}

	# 9. 吸引/威慑（调整距离）：近战型用吸引拉近，远程型用威慑推开；功能点感知
	# 注意：吸引在距离 1 时触发"对方贴脸、自己后退"分支——自己会后退，对近战型是负收益，
	#     仅当距离 ≥2（真正拉近 1 格）且自己后退空间充足、换血不劣势时才用
	for card in hand:
		if p.ap_function < 1: break
		if card.type_id in ["attract", "deter"]:
			# 濒死/危险档禁用吸引：把对手拉近 = 送死（防"无动作凑分打吸引"把自己拉进斩杀线）
			if card.type_id == "attract" and stance.get("stance", "") in ["flee", "danger"]:
				continue
			# 基础分 0：威慑/吸引只在有明确收益时打（保距/拉近/推入夹子/神隐），
			# 不再无脑凑分打——无配合的威慑/吸引 = 白耗功能点（用户实测反馈）
			var s = 0
			if is_norm:
				if card.type_id == "attract" and my_role == "near":
					# 后退空间：吸引贴脸分支我会朝远离对方方向退 1 格
					var back_room = match_ref.movement.geometry.edge_distance(player_idx, p.position)
					var not_disadvantage = hp_ratio >= float(opp.hp) / max(opp.max_hp, 1) - 0.1
					if distance >= 2 and back_room >= 2 and not_disadvantage:
						s = 12  # 真拉近 1 格贴脸（不触发自己后退）
				if card.type_id == "deter" and my_role == "range" and distance < 2: s = 12
				if card.type_id == "deter" and stance.get("stance", "") == "flee": s = 12
				# 推入神隐 combo：威慑/吸引的落点有我方鸟居 → 敌人踩上跳过回合（价值极高）
				var geo = match_ref.movement.geometry
				var toward: Vector2i = geo.direction_between(opp.position, p.position)
				if card.type_id == "deter": toward = -toward  # 威慑推远、吸引拉近
				var land = geo.clamp_position(geo.step(opp.position, toward))
				if land != p.position:
					if _my_torii_at(player_idx, land):
						s += 20
					# 推/拉进夹子区 combo：落点有我方捕兽夹/陷阱 → 对手踩上 -3（单夹也值得）
					for it in match_ref.items:
						if it.position == land and it.owner == player_idx \
								and it.item_type in ["snare", "trap"]:
							s += 12
							break
				if s > best_score:
					best_score = s
					best_action = {"action": "play_card", "card_uid": card.uid}

	# 10. 武器牌：只装备适配自身定位的武器（类型不匹配装了无加成，还会覆盖旧武器）；功能点感知
	for card in hand:
		if p.ap_function < 1: break
		if card.type_id in ["near_weapon", "range_weapon", "magic_weapon"]:
			var wtype = "near" if card.type_id == "near_weapon" else ("range" if card.type_id == "range_weapon" else "magic")
			if wtype == my_role:
				var s = 20  # 定位匹配 → 装备提升输出（拟人化：人类装完武器当回合就用，装备优先）
				if s > best_score:
					best_score = s
					best_action = {"action": "play_card", "card_uid": card.uid}
			# 不匹配 → 不打（留手里当弃牌，避免占武器位）

	# 11. 防具牌：按对方主要进攻手段选择（对方定位 + 牌堆剩余攻击牌修正）；
	#     已有防具时不换更差的（装备新防具会覆盖旧防具）；功能点感知
	var opp_main_atk = _opp_main_attack_type(player_idx)
	for card in hand:
		if p.ap_function < 1: break
		if card.type_id in ["near_armor", "range_armor", "magic_armor"]:
			# 饲甲人：护甲卡=修复活铠（耐久不满才有价值，满耐久打出纯浪费）
			if p.char_id == "armor_feeder":
				if not p.armor.is_empty() and p.armor.id == "demon_armor" \
						and int(p.armor.durability) < int(p.armor.get("max_durability", 2)):
					var s_repair = 8 if int(p.armor.durability) == 0 else 5  # 0耐久修复收益更高（免献祭+恢复减半）
					if s_repair > best_score:
						best_score = s_repair
						best_action = {"action": "play_card", "card_uid": card.uid}
				continue
			var atype = "near" if card.type_id == "near_armor" else ("range" if card.type_id == "range_armor" else "magic")
			var s = 0
			if atype == opp_main_atk:
				s = 16  # 针对对方主要进攻手段（3 耐久完全免疫首击，价值高）
			elif p.armor.is_empty():
				s = 8  # 无防具时随便装一个（有总比没有好）
				if match_ref.turn_number <= 2:
					s += 4  # 开局布防习惯（拟人化）：早期穿防具
			# 已有防具且新防具不针对 → 不换（避免覆盖针对防具）
			if s > best_score:
				best_score = s
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 12. 主动技能（法师弃牌强化 / 刺客免费移动 / 猎人埋伏）
	var skills = match_ref._skill_list(player_idx)
	for sk in skills:
		match sk.id:
			"mage_discard":
				# 濒死/危险档不用弃牌强化：强化后的魔法攻击会被"保命留闪避"保留打不出，
				# 弃攻击牌换的强化白费（负收益）
				if stance.get("stance", "") in ["flee", "danger"]:
					continue
				var has_magic_atk = false
				var discard_uid = -1
				var min_val = 999
				for card in hand:
					if card.type_id in ["magic", "chant"]:
						has_magic_atk = true
					elif card.type_id != "magic" and card.type_id != "chant" and not card.type_id in ["near", "range"]:
						# 弃牌跳过响应牌（near/range/magic 保防御能力），只弃低价值功能牌
						var v = _card_value(player_idx, card.type_id)
						if v < min_val:
							min_val = v
							discard_uid = card.uid
				if has_magic_atk and discard_uid >= 0:
					# 放技能后伤害 = 当前真实伤害（含已有叠加层）+ 新层2
					var buffed = 0
					for card in hand:
						if card.type_id in ["magic", "chant"]:
							buffed = max(buffed, _real_damage(player_idx, card.type_id))
					buffed += 2
					var s = _attack_score(player_idx, buffed, opp_idx, stance) + 2
					if s > best_score:
						best_score = s
						best_action = {"action": "use_skill", "skill": "mage_discard", "card_uid": discard_uid}
			"priest_chant":
				# 真言：弃回复卡换等值伤害（无视护甲、只能闪避）；血量过半才用（保回复续航）
				if match_ref.players[player_idx].hp * 2 >= match_ref.players[player_idx].max_hp:
					for card in hand:
						if card.type_id in ["heal_3", "heal_5"]:
							var dmg = 3 if card.type_id == "heal_3" else 5
							var s = _attack_score(player_idx, dmg, opp_idx, stance)
							if s > best_score:
								best_score = s
								best_action = {"action": "use_skill", "skill": "priest_chant", "card_uid": card.uid, "target": opp_idx}
			"mage_phantom":
				# 幻影：危险/濒死档且无其他更好行动时，弃魔法卡换闪避保命
				if stance.get("stance", "") in ["danger", "flee"]:
					for card in hand:
						if card.type_id in ["magic", "chant"]:
							var s = 8 if card.type_id == "chant" else 6
							if s > best_score:
								best_score = s
								best_action = {"action": "use_skill", "skill": "mage_phantom", "card_uid": card.uid}
			"assassin_move":
				if distance > 0:
					var has_near = false
					for card in hand:
						if card.type_id in ["near", "heavy"]:
							has_near = true
							break
					var geo = match_ref.movement.geometry
					var dir: Vector2i = geo.direction_between(p.position, opp.position)
					var s = 0
					if has_near:
						s = 9
						if is_norm and my_role == "near": s = 13  # 近战型暗影步贴脸
					else:
						# 拟人化：无近战牌时不无脑逼近——距离远占位，距离近等牌
						if distance > 2:
							s = 6
						else:
							s = 1
					# 目标格有道具风险（夹子对猎人免疫，陷阱/鸟居按风险）→ 暗影步踩中受伤，高风险低用
					var step_pos = geo.step(p.position, dir)
					var step_risk = _item_risk(player_idx, step_pos)
					if step_risk > 0:
						s -= min(12, step_risk * 3)
						if stance.get("stance", "") == "flee": s -= 6
					if s > best_score:
						best_score = s
						best_action = {"action": "use_skill", "skill": "assassin_move", "direction": geo.to_dict(dir)}
			"wardsmith_infuse":
				# 注魔：护甲满耐久 + 手牌有攻击卡 → 当前护甲类型不针对对方主要攻击时换甲
				if not p.armor.is_empty() and p.armor.get("durability", 0) >= p.armor.get("max_durability", 4):
					var want = _opp_main_attack_type(player_idx)
					var want_armor = {"near": "near_armor", "range": "range_armor", "magic": "magic_armor"}.get(want, "")
					if want_armor != "" and p.armor.id != want_armor:
						var infuse_uid = -1
						for card in hand:
							if card.type_id in ["near", "range", "magic", "heavy", "pierce", "chant"]:
								infuse_uid = card.uid
								break
						if infuse_uid >= 0:
							# 优先消耗「非输出」的攻击卡（低价值近战/与自己主攻不匹配的），火力充足才换甲
							var s = 10
							if stance.get("stance", "") in ["flee", "danger"]: s = 14  # 危险时换对甲价值高
							if s > best_score:
								best_score = s
								best_action = {"action": "use_skill", "skill": "wardsmith_infuse", "card_uid": infuse_uid}
			"wardsmith_repair":
				# 修复：护甲破损 + 手牌有匹配强化卡 + 1攻击点 → 弃卡修复2耐久（满耐久可完全免疫对方一次攻击）
				if not p.armor.is_empty() and p.armor.get("durability", 0) < p.armor.get("max_durability", 3):
					var expect_type = {"near_armor": "heavy", "range_armor": "pierce", "magic_armor": "chant"}.get(p.armor.id, "")
					var repair_uid = -1
					for card in hand:
						if card.type_id == expect_type:
							repair_uid = card.uid
							break
					if repair_uid >= 0 and p.ap_attack >= 1:
						# 护甲能防住对方主要攻击才值得修；保命档破损也修（总比碎了裸奔好）
						var atype = "near" if p.armor.id == "near_armor" else ("range" if p.armor.id == "range_armor" else "magic")
						var s = 0
						if atype == _opp_main_attack_type(player_idx): s = 16
						elif stance.get("stance", "") in ["flee", "danger"]: s = 12
						if s > best_score:
							best_score = s
							best_action = {"action": "use_skill", "skill": "wardsmith_repair", "card_uid": repair_uid}
			"hunter_ambush":
				# 埋伏 playbook：夹子防守布防/贴脸脱身/板边封锁 + 卡组感知 + 资源门槛
				var hb = _hunter_ambush_playbook(player_idx, opp_idx, p, hand, distance, stance)
				if hb.get("score", -1) > best_score:
					best_score = hb.get("score", -1)
					best_action = hb.get("action", {})

	# 13. 负分动作不执行（无有效动作就结束，不浪费牌/不送低价值攻击）
	if best_action.is_empty() or best_score <= 0:
		_log_ai_decision(player_idx, {"action": "end_turn"}, best_score)
		return {"action": "end_turn"}
	# 分数接近时可能选次优（难度越高扰动越小）
	var jitter = 0
	match difficulty:
		DIFF_EASY: jitter = randi() % 30
		DIFF_NORMAL: jitter = randi() % 6 - 3
		DIFF_HARD: jitter = randi() % 3 - 1
	best_score += jitter
	if best_score <= 0:
		_log_ai_decision(player_idx, {"action": "end_turn"}, best_score)
		return {"action": "end_turn"}
	_log_ai_decision(player_idx, best_action, best_score)
	return best_action

# ---------- 决策轨迹（对局日志复盘用） ----------
# 在 action_log 写一条"[AI决策]"行：选中动作 + 分数 + 关键上下文 + 攻击牌候选对比。
# 复盘时能直接看出"为什么打这张不打那张"（如远程被保留逻辑跳过、魔法被保命拦截）。
func _log_ai_decision(player_idx: int, action: Dictionary, score: int):
	var parts: Array = []
	for t in _atk_trace:
		if t.get("skip", "") != "":
			parts.append("%s[%s]" % [t.get("tid", "?"), t.get("skip", "")])
		else:
			parts.append("%s=%d(%d伤)" % [t.get("tid", "?"), t.get("score", 0), t.get("dmg", 0)])
	var c = _trace_ctx
	match_ref.add_log(player_idx, "[AI决策] 选:%s(分%d) 态势:%s 距%d 手%d/%d 我方%d伤 敌%d伤 | 攻击: %s" % [
		_action_desc(action, player_idx), score,
		c.get("stance", "?"), c.get("dist", -1), c.get("hand", 0), c.get("limit", 0),
		c.get("my_dmg", 0), c.get("opp_dmg", 0),
		"、".join(parts) if not parts.is_empty() else "无"])

func _action_desc(action: Dictionary, player_idx: int) -> String:
	var a: String = action.get("action", "")
	match a:
		"play_card":
			for card in match_ref.card_systems[player_idx].hand:
				if card.uid == action.get("card_uid", -1):
					return "打出%s" % Config.card_name(card.type_id)
			return "打出?"
		"use_skill": return "技能:%s" % action.get("skill", "?")
		"end_turn": return "结束回合"
		_: return a

# ---------- 响应决策（防守） ----------
func decide_response(defender_idx: int, attack_card: String) -> Dictionary:
	# easy：50% 概率不响应（装傻）
	if difficulty == DIFF_EASY and randi() % 100 < 50:
		return {respond=false, card_uid=-1}
	var hand = match_ref.card_systems[defender_idx].hand
	var magic_uid = -1
	var near_uid = -1
	var range_uid = -1
	for card in hand:
		match card.type_id:
			"magic": magic_uid = card.uid
			"near": near_uid = card.uid
			"range": range_uid = card.uid
	var p = match_ref.get_player(defender_idx)
	# 本次攻击伤害（真实，含多段单段）：小伤害且自己血量安全 → 省牌不响应（normal+）
	var atk_dmg = int(match_ref.attacker_last_damage)
	var hp_safe = float(p.hp) / max(p.max_hp, 1) > 0.6
	if difficulty >= DIFF_NORMAL and atk_dmg <= 2 and hp_safe:
		return {respond=false, card_uid=-1}
	# 地狱全知：攻击者手牌已无攻击牌（本次是最后威胁）→ 非斩杀伤害全部省牌
	if difficulty >= DIFF_HELL and _opp_hand_attack_count(1 - defender_idx) == 0 and atk_dmg < p.hp:
		return {respond=false, card_uid=-1}
	# 伤害分级（拟人化）：闪避留给大伤害/致死伤害，中等伤害优先格挡/牵制省魔法卡
	var big_hit = atk_dmg >= p.hp or atk_dmg >= 6 or atk_dmg >= int(p.hp * 0.4)
	# 低档响应：格挡（近战系）/ 牵制（远程/魔法系，减伤 = 远程面板 - 距离，连弩+2）
	var cheap_uid = -1
	if near_uid >= 0 and attack_card in ["near", "heavy"]:
		cheap_uid = near_uid
	elif range_uid >= 0 and attack_card in ["range", "pierce", "magic", "chant"]:
		var dist = match_ref.movement.get_distance()
		var restrain_value = max(0, p.range_power - dist)
		if not p.weapon.is_empty() and p.weapon.id == "repeater":
			restrain_value += 2
		if restrain_value > 0:
			cheap_uid = range_uid
	if magic_uid >= 0:
		var magic_count = 0
		for c in hand:
			if c.type_id == "magic": magic_count += 1
		if big_hit:
			return {respond=true, card_uid=magic_uid}  # 大伤害 → 闪避（人类习惯）
		if cheap_uid >= 0:
			return {respond=true, card_uid=cheap_uid}  # 中等伤害 → 低档响应省闪避
		# 中等伤害无低档响应：hard 且魔法卡不多 → 省牌；否则闪避
		if difficulty >= DIFF_HARD and magic_count <= 1:
			return {respond=false, card_uid=-1}
		return {respond=true, card_uid=magic_uid}
	if cheap_uid >= 0:
		return {respond=true, card_uid=cheap_uid}
	return {respond=false, card_uid=-1}

# ---------- 弃牌决策（弃价值最低的；保护响应牌/定位牌） ----------
func decide_discard(player_idx: int, need: int) -> Array:
	var hand = match_ref.card_systems[player_idx].hand
	var role = _current_role(player_idx)
	var scored = []
	for card in hand:
		var v = _card_value(player_idx, card.type_id)
		# 响应牌不易弃（保持防御能力）
		if card.type_id in ["near", "range", "magic"]:
			v += 4
		# 定位牌不易弃（主要输出手段）
		if card.type_id in _role_types(role):
			v += 3
		# 攻击牌保值：可打出的攻击牌是输出核心，超限弃牌时优先保攻击
		if card.type_id in ["near", "heavy", "range", "pierce", "magic", "chant"]:
			v += 2
		# 强化卡保值：永久+1 在适当时机打出比被弃掉划算
		if card.type_id in ["near_buf", "range_buf", "magic_buf"]:
			v += 2
		# 猎人专属：远程/穿心（输出+埋伏双价值）与魔法（保命闪避）保值更高，不易被弃
		if match_ref.players[player_idx].char_id == "hunter":
			if card.type_id in ["range", "pierce"]: v += 4
			elif card.type_id == "magic": v += 3
		scored.append({"uid": card.uid, "value": v})
	scored.sort_custom(func(a, b): return a.value < b.value)
	var to_discard = []
	for i in range(min(need, scored.size())):
		to_discard.append(scored[i].uid)
	return to_discard

# ---------- 武器确认（类型适配自身定位才装备） ----------
func decide_weapon(player_idx: int, weapon: Dictionary) -> bool:
	if weapon.is_empty(): return true
	var wtype: String = weapon.get("data", {}).get("type", "")
	if wtype == "": return true
	return wtype == _current_role(player_idx)

# 同格捕兽夹数量（猎人夹子叠放阈值判断用）
func _snare_count_at(pos: Vector2i) -> int:
	var n = 0
	for it in match_ref.items:
		if it.position == pos and it.item_type == "snare": n += 1
	return n

# 猎人埋伏 playbook（完整版）：位置策略（防守/封锁/脱身）+ 叠放阈值分散 + 穿心双位 + 卡组感知
# 返回 {score, action}；score<=0 表示不值得埋伏（留给通用层其他动作）
func _hunter_ambush_playbook(player_idx: int, opp_idx: int, p, hand: Array, distance: int, stance: Dictionary) -> Dictionary:
	# 手牌远程牌（埋伏消耗一张 range/pierce）
	var rng_hand = 0
	var ambush_uid = -1
	var is_pierce = false
	for c in hand:
		if c.type_id in ["range", "pierce"]:
			rng_hand += 1
			if ambush_uid < 0:
				ambush_uid = c.uid
				is_pierce = (c.type_id == "pierce")
	if ambush_uid < 0:
		return {"score": -1, "action": {}}
	# 穿心输出优先：距离 ≤3 时穿心直接打（远程结算 5-8 点，稳赚不亏），不转夹子；
	# 距离 >3 才考虑双夹（此时穿心伤害 ≤4，夹子控场价值更高）
	if is_pierce and distance <= 3:
		return {"score": -1, "action": {}}
	var deck_left = _global_left(player_idx, "range") + _global_left(player_idx, "pierce")
	# 每局限次：我方夹子（含道具卡放置）≥5 后不再埋伏（防夹子过量、输出断档）
	var my_snares := 0
	for it in match_ref.items:
		if it.item_type == "snare" and it.owner == player_idx:
			my_snares += 1
	if my_snares >= 5:
		return {"score": -1, "action": {}}
	# 卡组感知：统计自己的牌堆（自定义卡组时 = 玩家构筑）卡型构成，分流打法风格
	var tactic_cards = 0
	var attack_cards = 0
	for c in match_ref.card_systems[player_idx].deck:
		if c.type_id in ["item", "attract", "deter", "move"]: tactic_cards += 1
		elif c.type_id in Config.ATTACK_CARD_TYPES: attack_cards += 1
	var tactic_style = tactic_cards >= 6 and tactic_cards >= attack_cards  # 战术流卡组：布夹收益加成
	var geo = match_ref.movement.geometry
	var opp = match_ref.get_player(opp_idx)
	var opp_role: String = stance.get("opp_role", "near")
	var s = 0
	# 条件分（决定埋伏意愿）
	if distance <= 2 and opp_role == "near":
		s += 12  # 近战对手即将贴脸（≤2 格）→ 防守布防（距离 3 不布：保持输出距离，防整局常驻触发）
	if distance <= 1:
		s += 6  # 已贴脸 → 脱身夹子
	if geo.edge_distance(opp_idx, opp.position) <= 1:
		s += 8  # 对手靠板边 → 封锁退路
	if tactic_style:
		s += 4  # 战术流：多布夹是卡组设计意图
	if _near_threat_imminent(player_idx) and opp_role == "near":
		s += 8  # 对手近战憋爆发（距离≤3+手牌多）→ 提前布防
	# 资源底线（开局放宽，中后期严格）：手里必须留 1 张远程可打（输出不能断）；
	# 牌堆远程 <4 → 留输出不埋伏
	if match_ref.turn_number > 2 and (rng_hand <= 1 or deck_left < 4):
		s = 0
	# 保命档：防守夹子价值显著提高
	if stance.get("stance", "") in ["flee", "danger"] and s > 0:
		s = max(s, 14)
	if s <= 0:
		return {"score": -1, "action": {}}
	# 选位：候选位（防守/封锁/脱身）按优先级，同格夹子 ≥3（叠放阈值）降权转分散
	var cands: Array = []
	var dir_to_opp = geo.direction_between(p.position, opp.position)
	cands.append({"pos": geo.step(p.position, dir_to_opp), "prio": 12})
	cands.append({"pos": geo.step(opp.position, geo.direction_between(opp.position, p.position)), "prio": 8})
	cands.append({"pos": geo.step(p.position, -dir_to_opp), "prio": 6})
	var valid: Array = []
	for cnd in cands:
		var pos: Vector2i = cnd.pos
		if not geo.is_valid(pos) or pos == p.position or pos == opp.position:
			continue
		if _snare_count_at(pos) >= 3:
			cnd.prio -= 20  # 叠满阈值：不再叠（除非无其他合法位，仍有候选兜底）
		valid.append(cnd)
	valid.sort_custom(func(a, b): return a.prio > b.prio)
	var picked: Array = []
	for cnd in valid:
		if picked.is_empty() or (is_pierce and picked.size() < 2 and cnd.pos != picked[0]):
			picked.append(cnd.pos)
		if picked.size() >= (2 if is_pierce else 1):
			break
	if picked.is_empty():
		return {"score": -1, "action": {}}
	var action := {"action": "use_skill", "skill": "hunter_ambush", "card_uid": ambush_uid, "pos": geo.to_dict(picked[0])}
	if is_pierce and picked.size() > 1:
		action["pos2"] = geo.to_dict(picked[1])  # 穿心第二夹：次选位（不再落到 (0,0)）
	return {"score": s, "action": action}

# 猎人夹子区 combo：夹子 ≥2 的格成型后，用吸引/威慑把对手主动送进夹子区（B2 进攻性）
func _hunter_combo(player_idx: int, opp_idx: int, p, hand: Array, distance: int, stance: Dictionary) -> Dictionary:
	var geo = match_ref.movement.geometry
	var opp = match_ref.get_player(opp_idx)
	var attract_uid = -1
	var deter_uid = -1
	for c in hand:
		if c.type_id == "attract" and attract_uid < 0: attract_uid = c.uid
		elif c.type_id == "deter" and deter_uid < 0: deter_uid = c.uid
	if attract_uid < 0 and deter_uid < 0:
		return {"score": 0, "action": {}}
	# 找夹子区：同格夹子 ≥2（优先离自己近的）
	var zone: Vector2i = Vector2i(-999, -999)
	var best_d = 999999
	for it in match_ref.items:
		if it.item_type != "snare": continue
		var n = _snare_count_at(it.position)
		if n >= 2:
			var d = geo.distance(p.position, it.position)
			if d < best_d:
				best_d = d
				zone = it.position
	if zone.x == -999:
		return {"score": 0, "action": {}}
	# 吸引 combo：夹子区 = 对手朝自己方向 1 格（吸引后对手落在夹子区），且对手距离 ≥2
	var attract_zone = geo.step(opp.position, geo.direction_between(opp.position, p.position))
	if attract_uid >= 0 and distance >= 2 and zone == attract_zone:
		return {"score": 16, "action": {"action": "play_card", "card_uid": attract_uid, "target": opp_idx}}
	# 威慑 combo：夹子区 = 对手身后（远离自己方向 1 格），威慑推入
	var deter_zone = geo.step(opp.position, -geo.direction_between(opp.position, p.position))
	if deter_uid >= 0 and zone == deter_zone:
		return {"score": 16, "action": {"action": "play_card", "card_uid": deter_uid, "target": opp_idx}}
	return {"score": 0, "action": {}}

# 风神弓：AI 选择控制对方移动的方向（简单策略：近战拉近、远程/法术推远）
func decide_wind_bow(attacker_idx: int, target_idx: int) -> Vector2i:
	var match = match_ref
	var role = _current_role(attacker_idx)
	var my_pos = match.players[attacker_idx].position
	var t_pos = match.players[target_idx].position
	if role == "near":
		# 近战：拉近对方（朝自己方向）
		return match.movement.geometry.direction_between(t_pos, my_pos)
	# 远程/法术：推远对方（远离自己）
	return match.movement.geometry.direction_between(my_pos, t_pos)

# ---------- 记录对手用过的响应（hard 读牌） ----------
func remember_response(player_idx: int, card_type: String):
	if difficulty < DIFF_HARD: return
	if not _opp_used_responses.has(player_idx):
		_opp_used_responses[player_idx] = []
	_opp_used_responses[player_idx].append(card_type)
