# ai_player.gd — 人机对战 AI（规则打分制）
# 设计：每个合法动作算"效用分"（价值×角色系数×风险系数+随机扰动），选最高分执行。
# 难度三档控制"评估深度"：easy=粗打分+大扰动 / normal=完整打分 / hard=完整打分+读牌风险+陷阱连招。
# 后期提升智能 = 在打分函数里加评估项（新角色/新卡通过 _card_value 自动适配）。
extends RefCounted

const DIFF_EASY = 0
const DIFF_NORMAL = 1
const DIFF_HARD = 2

var match_ref
var difficulty: int = DIFF_NORMAL
# 记忆对手用过的响应卡类型（hard 难度读牌用）
var _opp_used_responses: Dictionary = {}

func _init(match, diff: int = DIFF_NORMAL):
	match_ref = match
	difficulty = diff

# ---------- 卡牌价值（按角色面板，新角色自动适配） ----------
func _card_value(player_idx: int, type_id: String) -> int:
	var p = match_ref.get_player(player_idx)
	match type_id:
		"near", "heavy": return p.near_power + 2
		"range", "pierce": return p.range_power + 2
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

# ---------- 攻击动作打分 ----------
# dmg: 期望伤害；风险：对手手牌多→可能有响应（hard 深度读牌）
func _attack_score(player_idx: int, dmg: int, opp_idx: int) -> int:
	var p = match_ref.get_player(player_idx)
	var opp = match_ref.get_player(opp_idx)
	var score = dmg * 3
	if opp.hp <= dmg:
		score += 60  # 斩杀优先
	# 对手手牌多 → 响应风险大（normal+）
	if difficulty >= DIFF_NORMAL:
		var opp_hand = match_ref.card_systems[opp_idx].hand.size()
		score -= opp_hand * 2
	# hard：读牌——对手用过的响应类型记忆
	if difficulty >= DIFF_HARD:
		var used = _opp_used_responses.get(opp_idx, [])
		if used.size() >= 2:
			score += 6  # 对手响应牌消耗多，攻击更安全
	# 自己血量低时保守
	if float(p.hp) / p.max_hp < 0.3:
		score -= 10
	return score

# ---------- 出牌阶段决策（返回 process_action 的 action 字典） ----------
# 注意：GDScript lambda 不能修改外层局部变量，候选比较全部用直接 if
func decide_action(player_idx: int) -> Dictionary:
	var p = match_ref.get_player(player_idx)
	var hand = match_ref.card_systems[player_idx].hand
	var opp_idx = 1 - player_idx
	var opp = match_ref.get_player(opp_idx)
	var distance = match_ref.movement.get_distance()
	var hp_ratio = float(p.hp) / p.max_hp

	var best_score: int = -99999
	var best_action: Dictionary = {}

	# 1. 攻击动作（按手牌类型计算伤害）
	for card in hand:
		if not card.has("type_id"): continue  # 防御：跳过异常卡（防牌堆污染残留）
		var tid = card.type_id
		var dmg = -1
		match tid:
			"near":
				if distance == 0: dmg = p.near_power
			"heavy":
				if distance == 0: dmg = p.near_power + 3
			"range":
				dmg = max(0, p.range_power - distance)
			"pierce":
				dmg = max(0, p.range_power - distance) + 3
			"magic":
				dmg = p.magic_power
			"chant":
				dmg = p.magic_power + 3
		if dmg > 0:
			var s = _attack_score(player_idx, dmg, opp_idx)
			if s > best_score:
				best_score = s
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 2. 回复（血少时）
	if hp_ratio < 0.65:
		for card in hand:
			var amt = -1
			match card.type_id:
				"heal_3": amt = 3
				"heal_5": amt = 5
			if amt > 0:
				var s = 20 + amt * 2
				if hp_ratio < 0.35: s += 30
				if s > best_score:
					best_score = s
					best_action = {"action": "play_card", "card_uid": card.uid}

	# 3. 强化卡（永久+1，早用早赚）
	for card in hand:
		if card.type_id in ["near_buf", "range_buf", "magic_buf"]:
			if 14 > best_score:
				best_score = 14
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 4. 免费卡（天赐抽2）
	for card in hand:
		if card.type_id == "blessing":
			if 12 > best_score:
				best_score = 12
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 5. 冻结（打断对手节奏）
	for card in hand:
		if card.type_id == "freeze":
			var s = 10 + (4 if opp.frozen_lockout == false else 0)
			if s > best_score:
				best_score = s
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 6. 摧毁 / 夺取（消耗对方资源）
	for card in hand:
		if card.type_id == "destroy":
			if 8 > best_score:
				best_score = 8
				best_action = {"action": "play_card", "card_uid": card.uid, "extra": {"destroy_target": "hand"}}
		if card.type_id == "seize":
			if 9 > best_score:
				best_score = 9
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 7. 陷阱：放在对手前方 1 格（对方移动/被推时踩中）
	for card in hand:
		if card.type_id == "trap":
			var trap_pos = opp.position + (1 if opp.position < p.position else -1)
			if trap_pos >= 0 and trap_pos <= 10 and trap_pos != p.position:
				if 7 > best_score:
					best_score = 7
					best_action = {"action": "play_card", "card_uid": card.uid, "extra": {"trap_pos": trap_pos}}

	# 8. 位移配合：有攻击卡但距离不够 → 移动靠近
	if distance > 0:
		var has_atk = false
		for card in hand:
			if card.type_id in ["near", "heavy", "range", "pierce", "magic", "chant"]:
				has_atk = true
				break
		if has_atk:
			for card in hand:
				if card.type_id == "move":
					var dir = 1 if opp.position > p.position else -1
					var s = 8 + (6 if distance <= 2 else 0)
					if s > best_score:
						best_score = s
						best_action = {"action": "play_card", "card_uid": card.uid, "extra": {"direction": dir, "steps": 1}}

	# 9. 吸引/威慑（调整距离：贴脸或拉开）
	for card in hand:
		if card.type_id in ["attract", "deter"]:
			if 5 > best_score:
				best_score = 5
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 10. 武器牌：直接装备（process_weapon_card 弹确认——AI 自动确认）
	for card in hand:
		if card.type_id in ["near_weapon", "range_weapon", "magic_weapon"]:
			if 11 > best_score:
				best_score = 11
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 11. 防具牌：直接装
	for card in hand:
		if card.type_id in ["near_armor", "range_armor", "magic_armor"]:
			if 10 > best_score:
				best_score = 10
				best_action = {"action": "play_card", "card_uid": card.uid}

	# 12. 主动技能（法师弃牌强化 / 刺客免费移动）
	var skills = match_ref._skill_list(player_idx)
	for sk in skills:
		match sk.id:
			"mage_discard":
				# 手牌有魔法攻击卡 + 可弃低价值卡 → 弃1张强化后魔法+2
				var has_magic_atk = false
				var discard_uid = -1
				var min_val = 999
				for card in hand:
					if card.type_id in ["magic", "chant"]:
						has_magic_atk = true
					elif card.type_id != "magic" and card.type_id != "chant":
						var v = _card_value(player_idx, card.type_id)
						if v < min_val:
							min_val = v
							discard_uid = card.uid
				if has_magic_atk and discard_uid >= 0:
					# 分数 = 强化后魔法伤害的期望（弃牌代价小补偿）
					var buffed = 0
					for card in hand:
						if card.type_id == "chant":
							buffed = max(buffed, p.magic_power + 5)
						elif card.type_id == "magic":
							buffed = max(buffed, p.magic_power + 2)
					var s = _attack_score(player_idx, buffed, opp_idx) + 2
					if s > best_score:
						best_score = s
						best_action = {"action": "use_skill", "skill": "mage_discard", "card_uid": discard_uid}
			"assassin_move":
				# 有近战攻击卡但距离不够 → 免费移动贴脸
				if distance > 0:
					var has_near = false
					for card in hand:
						if card.type_id in ["near", "heavy"]:
							has_near = true
							break
					if has_near:
						var dir = 1 if opp.position > p.position else -1
						if 9 > best_score:
							best_score = 9
							best_action = {"action": "use_skill", "skill": "assassin_move", "direction": dir}

	# 13. 随机扰动：分数接近时可能选次优（难度越高扰动越小）
	if best_action.is_empty():
		return {"action": "end_turn"}
	var jitter = 0
	match difficulty:
		DIFF_EASY: jitter = randi() % 30
		DIFF_NORMAL: jitter = randi() % 6 - 3
		DIFF_HARD: jitter = randi() % 3 - 1
	if best_score + jitter <= 0 and best_action.get("action", "") != "play_card":
		pass  # 保持
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
	# 闪避（魔法）价值最高：任意攻击可闪
	if magic_uid >= 0:
		return {respond=true, card_uid=magic_uid}
	# 格挡（近战）：仅近战/重击
	if near_uid >= 0 and attack_card in ["near", "heavy"]:
		return {respond=true, card_uid=near_uid}
	# 牵制（远程）：仅远程/穿心/魔法/吟唱
	if range_uid >= 0 and attack_card in ["range", "pierce", "magic", "chant"]:
		return {respond=true, card_uid=range_uid}
	return {respond=false, card_uid=-1}

# ---------- 弃牌决策（弃价值最低的） ----------
func decide_discard(player_idx: int, need: int) -> Array:
	var hand = match_ref.card_systems[player_idx].hand
	# 按价值升序排列，弃最低的
	var scored = []
	for card in hand:
		scored.append({"uid": card.uid, "value": _card_value(player_idx, card.type_id)})
	scored.sort_custom(func(a, b): return a.value < b.value)
	var to_discard = []
	for i in range(min(need, scored.size())):
		to_discard.append(scored[i].uid)
	return to_discard

# ---------- 武器确认（AI 直接装备） ----------
func decide_weapon() -> bool:
	return true

# ---------- 记录对手用过的响应（hard 读牌） ----------
func remember_response(player_idx: int, card_type: String):
	if difficulty < DIFF_HARD: return
	if not _opp_used_responses.has(player_idx):
		_opp_used_responses[player_idx] = []
	_opp_used_responses[player_idx].append(card_type)
