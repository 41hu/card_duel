# ai_player.gd — 人机对战 AI（局势感知打分制）
# 设计：每个合法动作算"效用分"（真实伤害×价值+策略档位修正+随机扰动），选最高分执行。
# 核心系统：
#   · 真实伤害：复用 combat.calculate_attack（武器/Buff/防具全算），斩杀判定准确
#   · 角色定位：基础标签 + 面板动态漂移，AI 知道自己该贴脸/中距离/自由位
#   · 记牌：从日志统计打出/响应消耗 + 数弃牌堆，推算某类攻击牌全局剩余
#   · 资源期：双方火力枯竭时转入攒资源模式（保留牌、打强化/天赐、不无脑出手）
# 难度三档：easy=粗打分+大扰动+装傻 / normal=定位+真实伤害+斩杀保命 / hard=全部+记牌资源期+读牌。
extends RefCounted

const DIFF_EASY = 0
const DIFF_NORMAL = 1
const DIFF_HARD = 2

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
	"swordsman": "near", "berserker": "near", "assassin": "near", "paladin": "near",
	"archer": "range", "hunter": "range", "gunslinger": "range", "tracker": "range",
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
		"blessing": return 4
		"trap": return 5
		"attract", "deter": return 4
		"freeze": return 6
		"destroy": return 5
		"seize": return 5
		_: return 1

# ---------- 真实伤害（复用战斗公式：武器/Buff/防具全算；多段×段数） ----------
func _real_damage(player_idx: int, type_id: String) -> int:
	var opp = 1 - player_idx
	var calc = match_ref.combat.calculate_attack(player_idx, opp, type_id)
	if calc.get("blocked", false):
		return 0
	var dmg = int(calc.get("damage", 0))
	if dmg <= 0: return 0
	return dmg * match_ref.char_skills.get_attack_hit_count(player_idx, type_id)

# 当前回合我能造成的最高真实伤害（斩杀判定用）
func _my_best_damage(player_idx: int) -> int:
	var role = _current_role(player_idx)
	var best = 0
	for t in _role_types(role):
		best = max(best, _real_damage(player_idx, t))
	return best

# 对手当前能造成的最高真实伤害（含对手武器/Buff，防斩判定用）
func _opp_best_damage(player_idx: int) -> int:
	var opp = 1 - player_idx
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

# 某方"可用"某类攻击牌的上限（全局剩余 − 对方手牌中该类：对方手里的我拿不到）
func _usable_left(player_idx: int, type_id: String) -> int:
	var left = _global_left(type_id)
	for c in match_ref.card_systems[1 - player_idx].hand:
		if c.type_id == type_id: left -= 1
	return max(0, left)

# 某方某定位的攻击潜力（hard 记牌用）：该类攻击牌还可能有几张
func _attack_potential(player_idx: int, role: String) -> int:
	var total = 0
	for t in _role_types(role):
		total += _usable_left(player_idx, t)
	return total

# 对手贴脸伤害（近战/重击最大值）——远程型评估"贴脸安不安全"用
func _opp_near_threat(player_idx: int) -> int:
	return max(_real_damage(1 - player_idx, "near"), _real_damage(1 - player_idx, "heavy"))

# 指定格是否有道具（陷阱/捕兽夹）——位移/暗影步踩中会受伤
func _item_at(pos: int) -> bool:
	for it in match_ref.items:
		if it.get("position", -1) == pos:
			return true
	return false

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
	var score = dmg * 3
	if dmg >= opp.hp:
		score += 80  # 斩杀优先（真实伤害判定）
	# 对手手牌多 → 响应风险大（normal+）
	if difficulty >= DIFF_NORMAL:
		score -= match_ref.card_systems[opp_idx].hand.size() * 2
	# hard：读牌——对手用过的响应类型记忆
	if difficulty >= DIFF_HARD:
		var used = _opp_used_responses.get(opp_idx, [])
		if used.size() >= 2:
			score += 6  # 对手响应牌消耗多，攻击更安全
	# 保命档：我血量低且对手威胁大 → 压低进攻欲望
	if stance.get("stance", "") == "flee":
		score -= 20
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
			if dist == 0 and not safe:
				score -= 10
			elif dist == 0 and safe:
				score += 4
		elif role == "near" and dist > 0:
			score -= 6  # 近战型远距离只有远程卡时攻击打折（更应贴脸）
	# 自己血量低时保守
	if float(p.hp) / p.max_hp < 0.3:
		score -= 10
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
	# 保命：对手可能斩杀我
	elif opp_dmg >= p.hp:
		stance = "flee"
	# 资源期（hard 记牌）：双方火力都枯竭
	elif difficulty >= DIFF_HARD and _attack_potential(player_idx, my_role) <= 1 and _attack_potential(1 - player_idx, opp_role) <= 1:
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
				if my_role == "range" and tid in ["range", "pierce"] and distance <= 1:
					continue  # 远程型：贴脸时远程卡留着，拉开距离再打
			# 保留响应牌：非斩杀时，不打最后一张可响应卡
			if tid in ["near", "range", "magic"] and resp_count <= 1:
				continue
		var s = _attack_score(player_idx, dmg, opp_idx, stance)
		# 骗响应连招（normal+，每回合限一次）：手牌有主属性爆发（定位卡高伤害）时，
		# 低价值攻击（非定位、非唯一保命牌）先手消耗对手响应牌，主属性随后爆发——
		# 对手不响应则骗响应卡本身也耗血，响应则消耗其响应牌（hard 记牌可读）。
		if is_norm and not can_kill and not _bait_used and _my_best_damage(player_idx) > 0:
			var is_main_card = tid in _role_types(my_role)
			var is_last_resp = tid in ["near", "range", "magic"] and resp_count <= 1
			if not is_main_card and not is_last_resp and dmg * 2 < _my_best_damage(player_idx) \
					and match_ref.card_systems[opp_idx].hand.size() >= 2:
				# 骗响应收益：主属性爆发伤害的估算（含对手不响应时骗卡本身的消耗）
				s += min(18, _my_best_damage(player_idx) * 2 + 6)
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
				d_target = {"destroy_target": "hand"}
			# 对手无牌无装备 → s=0 不打（避免卡消耗无效果）
			if s > best_score:
				best_score = s
				best_action = {"action": "play_card", "card_uid": card.uid, "extra": d_target}
		if card.type_id == "seize":
			var s = 9 + min(6, match_ref.card_systems[opp_idx].hand.size() * 2)  # 对手手牌越多夺牌收益越大
			if s > best_score:
				best_score = s
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 7. 陷阱：预判放置；功能点感知
	#   压制时放对手前方（封锁对方移动/被推踩中）；保命时放自己前方（防贴脸）
	for card in hand:
		if p.ap_function < 1: break
		if card.type_id == "trap":
			var s = 6
			var trap_pos = -1
			if stance.get("stance", "") == "flee":
				trap_pos = p.position + (1 if p.position < opp.position else -1)  # 自己朝对手侧一格
			else:
				trap_pos = opp.position + (1 if opp.position < p.position else -1)  # 对手前方
			if trap_pos >= 0 and trap_pos <= 10 and trap_pos != p.position and trap_pos != opp.position:
				if stance.get("stance", "") == "flee": s = 14
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
						s = 12  # 对手贴脸威胁大 → 后撤
					elif distance < 2 and safe:
						s = 2  # 安全 → 贴脸打远程（伤害最高），不急着撤
					elif distance > 4: s = 8  # 太远 → 靠近到输出距离
					elif distance > 3: s = 4  # 偏远 → 靠近一点
					else: s = 2
				elif my_role == "magic":
					s = 4
				if stance_s == "flee": s = max(s, 16)  # 防斩：拉开距离
				if stance_s == "resource": s -= 4
			else:
				s = 8 + (6 if distance <= 2 else 0)
			# 贴脸时允许后撤（远程型/保命拉开距离）；其余需 distance > 0
			var can_move = distance > 0 or ((my_role == "range" or stance_s == "flee") and distance == 0)
			if can_move and s > 0 and s > best_score:
				# 保命/远程危险时朝反方向后撤，否则朝对手（安全时贴脸打远程伤害最高）
				var mdir = dir
				if my_role == "range" and distance < 2:
					if not _range_melee_safe(player_idx): mdir = -dir
				if stance_s == "flee" and distance <= 2: mdir = -dir
				best_score = s
				best_action = {"action": "play_card", "card_uid": card.uid, "extra": {"direction": mdir, "steps": 1}}

	# 9. 吸引/威慑（调整距离）：近战型用吸引拉近，远程型用威慑推开；功能点感知
	for card in hand:
		if p.ap_function < 1: break
		if card.type_id in ["attract", "deter"]:
			var s = 4
			if is_norm:
				if card.type_id == "attract" and my_role == "near" and distance > 0: s = 12
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
					var buffed = 0
					for card in hand:
						if card.type_id == "chant":
							buffed = max(buffed, p.magic_power + 5)
						elif card.type_id == "magic":
							buffed = max(buffed, p.magic_power + 2)
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
