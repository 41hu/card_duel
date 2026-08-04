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
# 记忆对手用过的响应卡类型（hard 难度读牌用）
var _opp_used_responses: Dictionary = {}
# 本回合是否已用过"骗响应"低价值攻击（每回合限一次，避免连续骗卡浪费输出）
var _bait_used: bool = false
var _bait_turn: int = -1

func _init(match, diff: int = DIFF_NORMAL):
	match_ref = match
	difficulty = diff

# ---------- 角色定位基础标签（新角色缺省时按面板自动判定） ----------
const _BASE_ROLES := {
	"fighter": "near", "berserker": "near", "assassin": "near", "paladin": "near",
	"sharpshooter": "range", "hunter": "range", "gunslinger": "range", "tracker": "range",
	"mage": "magic", "priest": "magic", "warlock": "magic",
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
		"trap": return 5
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

# ---------- 记牌系统（双方共享牌堆，初始构成 CARD_COUNTS 已知） ----------
# 全局某类牌剩余（仍可能在牌堆或任一手牌中）= 初始 − 日志打出/响应消耗 − 弃牌堆
func _global_left(type_id: String) -> int:
	var left = Config.CARD_COUNTS.get(type_id, 0)
	left -= _played_from_log(type_id)
	left -= _count_in_discard(type_id)
	return max(0, left)

func _played_from_log(type_id: String) -> int:
	var n = 0
	var cname = Config.card_name(type_id)
	for e in match_ref.action_log:
		var msg: String = e.get("msg", "")
		# 攻击打出："XX打出近战"；响应消耗："用近战格挡/用远程牵制/用魔法闪避"
		if msg.contains("打出") and msg.contains(cname):
			n += 1
		elif msg.contains("用") and msg.contains(cname) and (msg.contains("格挡") or msg.contains("牵制") or msg.contains("闪避")):
			n += 1
	return n

func _count_in_discard(type_id: String) -> int:
	var n = 0
	for c in match_ref.card_systems[0].discard:
		if c.type_id == type_id: n += 1
	return n

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

# 全局攻击牌剩余总数（资源期判定用：牌堆+双方手牌中还有几张攻击牌）
func _global_attack_left() -> int:
	var total = 0
	for t in ["near", "heavy", "range", "pierce", "magic", "chant"]:
		total += _global_left(t)
	return total

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
func _item_at(pos: int) -> bool:
	for it in match_ref.items:
		if it.get("position", -1) == pos:
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

# 对方主要进攻类型：定位优先；hard 记牌修正——牌堆某类攻击牌剩余明显多于定位类时
# （对方抽到该类攻击牌的概率高），防御转向该类
func _opp_main_attack_type(player_idx: int) -> String:
	var role = _current_role(1 - player_idx)
	if difficulty < DIFF_HARD: return role
	var counts := {}
	for t in ["near", "range", "magic"]:
		counts[t] = 0
		for atk in _role_types(t):
			counts[t] += _global_left(atk)
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
	# 开局拼换血：前两回合进攻优先，抢优势保持压制（避免开局过度保守）
	if match_ref.turn_number <= 2 and float(p.hp) / p.max_hp > 0.7:
		score += 8
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
	elif difficulty >= DIFF_HARD and _hand_attack_count(player_idx) <= 1 and _global_attack_left() <= 6:
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

	# 回合级状态重置（骗响应每回合限一次）
	if match_ref.turn_number != _bait_turn:
		_bait_turn = match_ref.turn_number
		_bait_used = false

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
		var atk_cost = match_ref.char_skills.get_attack_cost(player_idx, tid)
		if atk_cost < 0: atk_cost = Config.CARD_DB.get(tid, {}).get("cost", 1)
		if p.ap_attack < atk_cost: continue  # 攻击点不足（快枪手远程耗 2 等）
		var dmg = _real_damage(player_idx, tid)
		if dmg <= 0: continue
		# 定位保留：非斩杀时，定位类攻击卡在"时机未到"（距离不合适）时保留在手，等进入理想距离爆发
		if is_norm and not can_kill:
			var is_role_card = tid in _role_types(my_role)
			if is_role_card:
				if my_role == "near" and distance > 0:
					continue  # 近战型：没贴脸时近战卡留着
				if my_role == "range" and tid in ["range", "pierce"] and distance <= 1 \
						and not _range_melee_safe(player_idx):
					continue  # 远程型：贴脸换血亏 → 留着拉开再打；安全时贴脸打远程（伤害最高）
			# 保留响应牌：非斩杀时，不打最后一张可响应卡
			if tid in ["near", "range", "magic"] and resp_count <= 1:
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
		# 地狱全知：对手手牌精确响应风险惩罚（闪避/格挡/牵制可防则攻击预期下降）
		if is_hell:
			s -= _hell_response_risk(opp_idx, tid)
		# 骗响应连招（normal+，每回合限一次）：手牌有主属性爆发（定位卡高伤害）时，
		# 低价值攻击（非定位、非唯一保命牌）先手消耗对手响应牌，主属性随后爆发——
		# 对手不响应则骗响应卡本身也耗血，响应则消耗其响应牌（hard 记牌可读）。
		if is_norm and not can_kill and not _bait_used and _my_best_damage(player_idx) > 0:
			var is_main_card = tid in _role_types(my_role)
			var is_last_resp = tid in ["near", "range", "magic"] and resp_count <= 1
			var dodge_threat = _opp_dodge_threat(player_idx)
			# 地狱全知：对手手牌无任何响应牌 → 骗响应无意义，直接主属性爆发
			var hell_no_resp = is_hell and (_opp_hand_count(opp_idx, "magic") + _opp_hand_count(opp_idx, "near") + _opp_hand_count(opp_idx, "range")) == 0
			# 骗响应：常规要求伤害明显低于主属性；对手闪避威胁大时放宽（接近主属性的也能当骗卡）
			if not hell_no_resp and not is_main_card and not is_last_resp and match_ref.card_systems[opp_idx].hand.size() >= 2 \
					and (dmg * 2 < _my_best_damage(player_idx) or dodge_threat):
				var bonus = min(18, _my_best_damage(player_idx) * 2 + 6)
				if dodge_threat: bonus += 10  # 对手闪避存量高 → 骗卡消耗闪避的收益大
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
					s = 20  # 对手手牌多（即将爆发）或我要被斩杀 → 冻住打断
				else:
					s = 12
			if s > best_score:
				best_score = s
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 6. 摧毁 / 夺取（消耗对方资源；对手手牌多时夺取更值；功能点感知——邪术师 2 点可打两张）
	for card in hand:
		if p.ap_function < 1: break
		if card.type_id == "destroy":
			var s = 0
			var d_target = {}
			if not opp.weapon.is_empty():
				s = 14  # 拆武器（对方输出核心）最值
				d_target = {"destroy_target": "equip", "equip_type": "weapon"}
			elif not opp.armor.is_empty():
				s = 12  # 拆防具次之
				d_target = {"destroy_target": "equip", "equip_type": "armor"}
			elif match_ref.card_systems[opp_idx].hand.size() > 0:
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
			if s > best_score:
				best_score = s
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 7. 陷阱：预判放置；功能点感知
	#   对手近战型且可能贴脸（距离近+手牌多，憋爆发）→ 防守陷阱优先（放自己前方防贴脸）
	#   压制时放对手前方（封锁对方移动/被推踩中）；保命时放自己前方（防贴脸）
	var near_threat = _near_threat_imminent(player_idx)
	for card in hand:
		if p.ap_function < 1: break
		if card.type_id == "trap":
			var s = 6
			var trap_pos = -1
			if stance.get("stance", "") == "flee" or near_threat:
				trap_pos = p.position + (1 if p.position < opp.position else -1)  # 自己朝对手侧一格（防贴脸）
			else:
				trap_pos = opp.position + (1 if opp.position < p.position else -1)  # 对手前方封锁
			if trap_pos >= 0 and trap_pos <= 10 and trap_pos != p.position and trap_pos != opp.position:
				if stance.get("stance", "") == "flee": s = 14
				elif near_threat: s = 13  # 对手可能贴脸爆发 → 防守陷阱优先（即使有攻击动作）
				elif is_hard and opp_role == "near": s = 12  # 对手近战型 → 封锁逼近路线更值
				if s > best_score:
					best_score = s
					best_action = {"action": "play_card", "card_uid": card.uid, "extra": {"trap_pos": trap_pos}}

	# 8. 位移：按定位控制距离（位移点感知）
	#   近战型：逼近贴脸；远程型：保持中距离(2~4)；保命：远离
	for card in hand:
		if p.ap_move < 1: break
		if card.type_id == "move":
			var s = 0
			var dir = 1 if opp.position > p.position else -1
			var stance_s = stance.get("stance", "")
			if is_norm:
				if my_role == "near" and distance > 0:
					s = 12 + (6 if distance <= 2 else 0)  # 贴脸逼近
				elif my_role == "range":
					# 远程伤害随距离衰减：安全时贴脸打远程（伤害最高），危险时保持距离
					var safe = _range_melee_safe(player_idx)
					if distance < 2 and not safe:
						s = 14  # 对手贴脸威胁大 → 后撤（优先于攻击/同分动作）
					elif distance < 2 and safe:
						s = 2  # 安全 → 贴脸打远程（伤害最高），不急着撤
					elif distance > 4: s = 8  # 太远 → 靠近到输出距离
					elif distance > 3: s = 4  # 偏远 → 靠近一点
					else: s = 2
					# 对手近战型可能贴脸爆发（憋牌）→ 提前拉开；权衡板边：后撤目标格上限 <=2 不拉
					if _near_threat_imminent(player_idx) and distance <= 3:
						var back_pos = p.position - dir
						var back_limit = (back_pos if player_idx == 0 else 10 - back_pos) + 1
						if back_limit >= 3:
							s = max(s, 10)
					if _near_threat_imminent(player_idx) and distance <= 2:
							var back_pos2 = p.position - dir
							var back_limit2 = (back_pos2 if player_idx == 0 else 10 - back_pos2) + 1
							if back_limit2 >= 3:
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
				if my_role == "range" and distance < 2:
					if not _range_melee_safe(player_idx): mdir = -dir
				if _near_threat_imminent(player_idx) and my_role in ["range", "magic"] and distance <= 3:
					mdir = -dir  # 提前拉开方向（远离对手）
				if (stance_s == "flee" or stance_s == "danger") and distance <= 2: mdir = -dir
				# 板边惩罚：朝自己板边移动会降低手牌上限（操作空间减少）→ 减分；
				# 朝中场移动保持上限 → 加分（鼓励维持操作空间）
				var target_pos = p.position + mdir
				var new_limit = (target_pos if player_idx == 0 else 10 - target_pos) + 1
				var cur_limit = match_ref.movement.get_hand_limit(player_idx)
				s += (new_limit - cur_limit) * 3
				# 避陷阱：目标格有道具（陷阱/捕兽夹）→ 按收益减分
				#   逼近后能立刻贴脸攻击 → 踩陷阱换爆发可接受（小减分）
				#   纯走位踩陷阱（无输出收益）→ 大减分避开
				#   保命时移动优先，踩也认
				if _item_at(p.position + mdir) and stance_s != "flee":
					var new_dist = abs((p.position + mdir) - opp.position) - 1
					var gains_attack = false
					if new_dist == 0:
						for c in hand:
							if c.type_id in ["near", "heavy"]:
								gains_attack = true
								break
					# 后撤摆脱贴脸威胁（远程型危险贴脸）也算收益，踩陷阱换安全可接受
					var gains_safety = (my_role == "range" and mdir == -dir and distance <= 2)
					s -= 4 if (gains_attack or gains_safety) else 14
				if s > best_score:
					best_score = s
					best_action = {"action": "play_card", "card_uid": card.uid, "extra": {"direction": mdir, "steps": 1}}

	# 9. 吸引/威慑（调整距离）：近战型用吸引拉近，远程型用威慑推开；功能点感知
	# 注意：吸引在距离 1 时触发"对方贴脸、自己后退"分支——自己会后退，对近战型是负收益，
	#     仅当距离 ≥2（真正拉近 1 格）且自己后退空间充足、换血不劣势时才用
	for card in hand:
		if p.ap_function < 1: break
		if card.type_id in ["attract", "deter"]:
			var s = 4
			if is_norm:
				if card.type_id == "attract" and my_role == "near":
					# 后退空间：吸引贴脸分支我会朝远离对方方向退 1 格
					var back_room = (10 - p.position) if p.position > opp.position else p.position
					var not_disadvantage = hp_ratio >= float(opp.hp) / max(opp.max_hp, 1) - 0.1
					if distance >= 2 and back_room >= 2 and not_disadvantage:
						s = 12  # 真拉近 1 格贴脸（不触发自己后退）
				if card.type_id == "deter" and my_role == "range" and distance < 2: s = 12
				if card.type_id == "deter" and stance.get("stance", "") == "flee": s = 12
			if s > best_score:
				best_score = s
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 10. 武器牌：只装备适配自身定位的武器（类型不匹配装了无加成，还会覆盖旧武器）；功能点感知
	for card in hand:
		if p.ap_function < 1: break
		if card.type_id in ["near_weapon", "range_weapon", "magic_weapon"]:
			var wtype = "near" if card.type_id == "near_weapon" else ("range" if card.type_id == "range_weapon" else "magic")
			if wtype == my_role:
				var s = 16  # 定位匹配 → 装备提升输出
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
			var atype = "near" if card.type_id == "near_armor" else ("range" if card.type_id == "range_armor" else "magic")
			var s = 0
			if atype == opp_main_atk:
				s = 16  # 针对对方主要进攻手段（3 耐久完全免疫首击，价值高）
			elif p.armor.is_empty():
				s = 8  # 无防具时随便装一个（有总比没有好）
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
			"assassin_move":
				if distance > 0:
					var has_near = false
					for card in hand:
						if card.type_id in ["near", "heavy"]:
							has_near = true
							break
					if has_near:
						var dir = 1 if opp.position > p.position else -1
						var s = 9
						if is_norm and my_role == "near": s = 13  # 近战型暗影步贴脸
						# 目标格有陷阱 → 暗影步会踩中受伤，高风险低用（保命档更不该踩）
						var step_pos = p.position + dir
						if _item_at(step_pos):
							s -= 8
							if stance.get("stance", "") == "flee": s -= 6
						if s > best_score:
							best_score = s
							best_action = {"action": "use_skill", "skill": "assassin_move", "direction": dir}
			"wardsmith_imbue":
				# 护甲注魔（改版）：不耗卡，直接选护甲装备（铸甲师 4 耐久强生存）；
				# 按对方主要进攻手段选对应护甲（与防具牌同逻辑）；价值高于防具牌（免费且4耐久，
				# 防具牌仅3耐久还要耗卡）→ 无防具时注魔优先，避免浪费核心技能；
				# 危险/保命档价值更高
				if p.armor.is_empty():
					var imbue_atype = _opp_main_attack_type(player_idx)
					var imbue_armor = {"near": "near_armor", "range": "range_armor", "magic": "magic_armor"}.get(imbue_atype, "near_armor")
					var s = 20
					if stance.get("stance", "") in ["flee", "danger"]: s = 22  # 危险时防御优先
					if s > best_score:
						best_score = s
						best_action = {"action": "use_skill", "skill": "wardsmith_imbue", "armor_type": imbue_armor}
			"wardsmith_repair":
				# 修复：护甲破损 + 手牌有匹配强化卡 + 2攻击点 → 弃卡修复1耐久（满耐久可完全免疫对方一次攻击）
				if not p.armor.is_empty() and p.armor.get("durability", 0) < p.armor.get("max_durability", 3):
					var expect_type = {"near_armor": "heavy", "range_armor": "pierce", "magic_armor": "chant"}.get(p.armor.id, "")
					var repair_uid = -1
					for card in hand:
						if card.type_id == expect_type:
							repair_uid = card.uid
							break
					if repair_uid >= 0 and p.ap_attack >= 2:
						# 护甲能防住对方主要攻击才值得修；保命档破损也修（总比碎了裸奔好）
						var atype = "near" if p.armor.id == "near_armor" else ("range" if p.armor.id == "range_armor" else "magic")
						var s = 0
						if atype == _opp_main_attack_type(player_idx): s = 14
						elif stance.get("stance", "") in ["flee", "danger"]: s = 10
						if s > best_score:
							best_score = s
							best_action = {"action": "use_skill", "skill": "wardsmith_repair", "card_uid": repair_uid}
			"hunter_ambush":
				if p.ap_attack >= 1:
					var ambush_uid = -1
					var rng_count = 0
					for card in hand:
						if card.type_id in ["range", "pierce"]:
							rng_count += 1
							if ambush_uid < 0: ambush_uid = card.uid
					if ambush_uid >= 0:
						var hpos = opp.position + (1 if opp.position < p.position else -1)
						if hpos >= 0 and hpos <= 10 and hpos != p.position and hpos != opp.position:
							# 价值判断：埋伏消耗 1 张远程输出牌，火力充足才划算
							var s = 0
							var deck_left = _global_left("range") + _global_left("pierce")
							if rng_count >= 2 or deck_left >= 4:
								s = 9  # 远程火力充足 → 转一张不心疼
							elif rng_count == 1 and deck_left >= 2:
								s = 5  # 勉强：转一张还有牌堆补充
							# 否则 s=0：只剩一张远程牌且牌堆枯竭 → 保留输出
							if stance.get("stance", "") == "flee" and s > 0:
								s = max(s, 12)  # 保命：防守陷阱价值高
							if s > best_score:
								best_score = s
								best_action = {"action": "use_skill", "skill": "hunter_ambush", "card_uid": ambush_uid, "pos": hpos}

	# 13. 负分动作不执行（无有效动作就结束，不浪费牌/不送低价值攻击）
	if best_action.is_empty() or best_score <= 0:
		return {"action": "end_turn"}
	# 分数接近时可能选次优（难度越高扰动越小）
	var jitter = 0
	match difficulty:
		DIFF_EASY: jitter = randi() % 30
		DIFF_NORMAL: jitter = randi() % 6 - 3
		DIFF_HARD: jitter = randi() % 3 - 1
	best_score += jitter
	if best_score <= 0:
		return {"action": "end_turn"}
	return best_action

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
	# 闪避（魔法）价值最高：任意攻击可闪；但魔法卡同时也是自己的攻击输出，省着用
	if magic_uid >= 0:
		# hard：自己攻击性魔法卡不多时，大伤害才闪（省输出）
		var magic_count = 0
		for c in hand:
			if c.type_id == "magic": magic_count += 1
		if difficulty >= DIFF_HARD and magic_count <= 1 and atk_dmg <= 3:
			pass  # 省魔法卡，落到格挡/牵制
		else:
			return {respond=true, card_uid=magic_uid}
	# 格挡（近战）：仅近战/重击
	if near_uid >= 0 and attack_card in ["near", "heavy"]:
		return {respond=true, card_uid=near_uid}
	# 牵制（远程）：仅远程/穿心/魔法/吟唱；减伤 = 自身远程面板 - 距离（连弩+2）
	if range_uid >= 0 and attack_card in ["range", "pierce", "magic", "chant"]:
		var dist = match_ref.movement.get_distance()
		var restrain_value = max(0, p.range_power - dist)
		if not p.weapon.is_empty() and p.weapon.id == "repeater":
			restrain_value += 2
		if restrain_value > 0:
			return {respond=true, card_uid=range_uid}
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

# ---------- 记录对手用过的响应（hard 读牌） ----------
func remember_response(player_idx: int, card_type: String):
	if difficulty < DIFF_HARD: return
	if not _opp_used_responses.has(player_idx):
		_opp_used_responses[player_idx] = []
	_opp_used_responses[player_idx].append(card_type)
