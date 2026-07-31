# ============================================================
# combat_system.gd — 战斗系统
# 核心函数: calculate_attack / process_response / apply_on_hit_effects
# 攻击结算: 伤害→响应窗口→响应效果→扣HP→命中特效→死亡判定
# ============================================================
extends RefCounted

var match_ref  # Weak reference to MatchState for accessing player data

func _init(match):
	match_ref = match

# ---------- 主入口：计算攻击伤害 ----------
# 返回 {damage, blocked, msg, formula}
func calculate_attack(attacker_idx: int, defender_idx: int, card_type_id: String) -> Dictionary:
	var attacker = match_ref.get_player(attacker_idx)
	var defender = match_ref.get_player(defender_idx)
	var distance = match_ref.movement.get_distance()
	var base_damage = 0
	var damage_type = Config.get_damage_type(card_type_id)
	var formula = ""

	# 计算基础伤害
	match card_type_id:
		"near":
			base_damage = attacker.near_power
			formula = str(base_damage)
		"range":
			var eff_dist = distance
			if not attacker.weapon.is_empty() and attacker.weapon.id == "longbow":
				eff_dist = max(0, distance - 1)
			base_damage = max(0, attacker.range_power - eff_dist)
			formula = "%d-%d" % [attacker.range_power, eff_dist]
		"magic":
			base_damage = attacker.magic_power
			formula = str(base_damage)
		"heavy":
			if distance != 0:
				return {damage=0, blocked=true, msg="重击必须贴脸！"}
			base_damage = attacker.near_power + 3
			formula = "%d+3" % attacker.near_power
		"pierce":
			var eff_dist2 = distance
			if not attacker.weapon.is_empty() and attacker.weapon.id == "longbow":
				eff_dist2 = max(0, distance - 1)
			base_damage = max(0, attacker.range_power - eff_dist2) + 3
			formula = "%d-%d+3" % [attacker.range_power, eff_dist2]
		"chant":
			base_damage = attacker.magic_power + 3
			formula = "%d+3" % attacker.magic_power

	# 应用武器效果（伤害加成）
	var before_weapon = base_damage
	base_damage = _apply_weapon_damage_bonus(attacker, base_damage, damage_type)
	if base_damage != before_weapon and not attacker.weapon.is_empty():
		formula += "+%d" % (base_damage - before_weapon)

	# 应用Buff修正（狂战士等）
	var buff_mod = match_ref.status.get_attack_modifier(attacker_idx)
	if buff_mod != 0:
		base_damage += buff_mod
		formula += ("+%d" if buff_mod > 0 else "%d") % buff_mod

	# 检查防具
	var armor_result = _check_armor(defender, damage_type, base_damage)
	if armor_result.completely_blocked:
		armor_result.formula = "=0(防具免疫)"
		return armor_result

	var armor_dmg = armor_result.damage
	if armor_dmg != base_damage:
		formula += "/2"
	base_damage = armor_dmg

	return {damage=base_damage, blocked=false, msg="", damage_type=damage_type, formula=formula}

# ---------- 武器伤害加成 ----------
func _apply_weapon_damage_bonus(attacker, base_damage: int, damage_type: int) -> int:
	if attacker.weapon.is_empty():
		return base_damage
	# 武器类型必须匹配伤害类型
	if not Config.weapon_matches_damage_type(attacker.weapon.data.type, damage_type):
		return base_damage
	var dmg = base_damage
	match attacker.weapon.id:
		"flame_sword": dmg += 2
		"lunge": dmg += 1
		"sage_book": dmg += 2
		"resonance":
			if attacker.combo_attacks_this_turn.size() > 1:
				dmg += 2
	return dmg

# ---------- 防具检查 ----------
func _check_armor(defender, damage_type: int, damage: int) -> Dictionary:
	if defender.armor.is_empty():
		return {completely_blocked=false, damage=damage, msg=""}

	var armor_id = defender.armor.id
	var armor_type = Config.ARMOR_DB[armor_id].type
	var durability = defender.armor.durability

	# 检查防具类型是否匹配
	var matches = false
	match armor_type:
		"physical":
			matches = (damage_type == Config.DamageType.PHYSICAL)
		"ranged":
			matches = (damage_type == Config.DamageType.RANGED)
		"magical":
			matches = (damage_type == Config.DamageType.MAGICAL)

	if not matches:
		return {completely_blocked=false, damage=damage, msg=""}

	# 第1次：完全免疫
	if durability == defender.armor.get("max_durability", 3):
		defender.armor.durability -= 1
		return {completely_blocked=true, damage=0, msg="防具完全免疫了伤害！"}

	# 第2、3次：减半
	defender.armor.durability -= 1
	var reduced = floori(damage / 2.0)
	if defender.armor.durability <= 0:
		defender.armor = {}
	return {completely_blocked=false, damage=reduced, msg="防具减免了一半伤害"}

# ---------- 响应处理 ----------
func process_response(_attacker_idx: int, defender_idx: int, attack_card: String, response_card_uid: int) -> Dictionary:
	var defender = match_ref.get_player(defender_idx)
	var defender_cs = match_ref.card_systems[defender_idx]

	# 按 uid 找卡，并验证类型
	var hand = defender_cs.hand
	var resp_card = {}
	for c in hand:
		if c.uid == response_card_uid:
			resp_card = c
			break
	if resp_card.is_empty():
		return {success=false, msg="手牌中无此卡"}

	# 根据卡牌类型确定响应效果（而非攻击类型决定）
	var card_id = resp_card.type_id
	print("[Combat] 响应 card_id=", card_id, " attack=", attack_card)
	var effect = ""
	var value = 0

	if card_id in ["near"]:
		# 近战卡只能格挡近战/重击
		if attack_card in ["near", "heavy"]:
			effect = "block"
		else:
			return {success=false, msg="近战卡只能响应近战攻击"}
	elif card_id in ["range"]:
		# 远程卡可牵制远程/穿心，也可牵制魔法/吟唱
		if attack_card in ["range", "pierce", "magic", "chant"]:
			effect = "restrain"
			value = max(0, defender.range_power - match_ref.movement.get_distance())
		else:
			return {success=false, msg="远程卡不能响应该攻击"}
	elif card_id in ["magic"]:
		# 魔法卡可闪避任意攻击
		effect = "dodge"
	else:
		return {success=false, msg="此卡不能用于响应"}

	# 消耗响应卡
	defender_cs.play_card(response_card_uid)

	match effect:
		"block": return {success=true, effect="block", response_card=card_id}
		"restrain": return {success=true, effect="restrain", value=value, response_card=card_id}
		"dodge": return {success=true, effect="dodge", response_card=card_id}
	return {success=false}

# ---------- 计算长弓的距离衰减修正 ----------
func get_longbow_distance_penalty(attacker) -> int:
	if attacker.weapon.is_empty():
		return 0
	if attacker.weapon.id == "longbow":
		return 1  # 距离衰减-1 → 实际 - (distance - 1)
	return 0

# ---------- 造成伤害后的武器特效 ----------
func apply_on_hit_effects(attacker_idx: int, defender_idx: int, damage: int, damage_type: int):
	var attacker = match_ref.get_player(attacker_idx)
	var defender = match_ref.get_player(defender_idx)

	if attacker.weapon.is_empty():
		return
	# 武器类型必须匹配伤害类型
	if not Config.weapon_matches_damage_type(attacker.weapon.data.type, damage_type):
		return

	var weapon_id = attacker.weapon.id

	# 霜咬：近战命中后对方下回合位移=0
	if weapon_id == "frost_bite":
		defender.frozen_move = true

	# 嗜血：近战≥3伤害回2HP
	if weapon_id == "bloodthirst" and damage >= 3:
		attacker.hp = min(attacker.max_hp, attacker.hp + 2)

	# 鹰眼：远程命中后查看对方手牌
	if weapon_id == "hawkeye":
		match_ref._reveal_to = attacker_idx
		match_ref._reveal_from = defender_idx

	# 毒牙：远程命中后给予2层中毒（每回合-1HP，层数每回合-1，可叠加）
	if weapon_id == "toxic_fang":
		match_ref.status.add_poison(defender_idx, 2)

	# 灼烧：魔法命中后灼烧2回合每回合-2HP，再次命中刷新时长
	if weapon_id == "scorch":
		match_ref.status.add_burn(defender_idx)

	# 时滞：魔法命中后对方下回合攻击-1
	if weapon_id == "time_lag":
		match_ref.status.add_buff(defender_idx, "attack_down", -1, 1)

	# 共鸣：在 _apply_weapon_damage_bonus 中处理（本回合已出过其他攻击则+2）

# ---------- 处置DoT伤害 ----------
# 灼烧: 每回合-2HP，duration-1，到0移除
# 中毒: 每回合-1HP，duration-1，到0移除
func apply_dot_damage(player_idx: int) -> Dictionary:
	var player = match_ref.get_player(player_idx)
	var total_damage = 0
	var details = []

	for i in range(player.dots.size() - 1, -1, -1):
		var dot = player.dots[i]
		if dot.type == "burn":
			total_damage += dot.damage
			details.append("灼烧-%d" % dot.damage)
		elif dot.type == "poison":
			total_damage += dot.damage
			details.append("中毒-%d" % dot.damage)
		dot.duration -= 1
		if dot.duration <= 0:
			player.dots.remove_at(i)

	return {damage=total_damage, details=details}
