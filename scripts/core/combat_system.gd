# combat_system.gd — 战斗系统（伤害计算、响应处理、武器/防具效果）
extends RefCounted

var match_ref  # Weak reference to MatchState for accessing player data

func _init(match):
	match_ref = match

# ---------- 主入口：计算攻击伤害 ----------
# 返回 {damage, blocked, msg}
func calculate_attack(attacker_idx: int, defender_idx: int, card_type_id: String) -> Dictionary:
	var attacker = match_ref.get_player(attacker_idx)
	var defender = match_ref.get_player(defender_idx)
	var distance = match_ref.movement.get_distance()
	var base_damage = 0
	var damage_type = Config.get_damage_type(card_type_id)

	# 计算基础伤害
	match card_type_id:
		"near":
			base_damage = attacker.near_power
		"range":
			var eff_dist = distance
			if not attacker.weapon.is_empty() and attacker.weapon.id == "longbow":
				eff_dist = max(0, distance - 1)
			base_damage = max(0, attacker.range_power - eff_dist)
		"magic":
			base_damage = attacker.magic_power
		"heavy":
			# 必须贴脸
			if distance != 0:
				return {damage=0, blocked=true, msg="重击必须贴脸！"}
			base_damage = attacker.near_power + 3
		"pierce":
			var eff_dist2 = distance
			if not attacker.weapon.is_empty() and attacker.weapon.id == "longbow":
				eff_dist2 = max(0, distance - 1)
			base_damage = max(0, attacker.range_power - eff_dist2) + 3
		"chant":
			base_damage = attacker.magic_power + 3

	# 应用武器效果（伤害加成）
	base_damage = _apply_weapon_damage_bonus(attacker, base_damage)

	# 检查防具
	var armor_result = _check_armor(defender, damage_type, base_damage)
	if armor_result.completely_blocked:
		return armor_result

	base_damage = armor_result.damage

	return {damage=base_damage, blocked=false, msg="", damage_type=damage_type}

# ---------- 武器伤害加成 ----------
func _apply_weapon_damage_bonus(attacker, base_damage: int) -> int:
	var dmg = base_damage
	if attacker.weapon.is_empty():
		return dmg
	var weapon_id = attacker.weapon.id
	match weapon_id:
		"flame_sword":
			dmg += 2
		"lunge":
			dmg += 1
		"sage_book":
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
	if durability == 3:
		defender.armor.durability -= 1
		return {completely_blocked=true, damage=0, msg="防具完全免疫了伤害！"}

	# 第2、3次：减半
	defender.armor.durability -= 1
	var reduced = int(damage / 2)
	if defender.armor.durability <= 0:
		defender.armor = {}
	return {completely_blocked=false, damage=reduced, msg="防具减免了一半伤害"}

# ---------- 响应处理 ----------
func process_response(attacker_idx: int, defender_idx: int, attack_card: String, response_card_uid: int) -> Dictionary:
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
			value = defender.range_power - match_ref.movement.get_distance()
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
		"block": return {success=true, effect="block"}
		"restrain": return {success=true, effect="restrain", value=value}
		"dodge": return {success=true, effect="dodge"}
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

	var weapon_id = attacker.weapon.id

	# 霜咬：命中后对方下回合位移=0
	if weapon_id == "frost_bite":
		defender.frozen_move = true

	# 嗜血：近战≥3伤害回2HP
	if weapon_id == "bloodthirst" and damage_type == Config.DamageType.PHYSICAL and damage >= 3:
		attacker.hp = min(attacker.max_hp, attacker.hp + 2)

	# 鹰眼：命中后查看对方手牌 (由服务端处理)
	if weapon_id == "hawkeye":
		pass  # 服务端在回复中附带对方手牌信息

	# 毒牙：中毒-2×2回合
	if weapon_id == "toxic_fang":
		match_ref.status.add_dot(defender_idx, "poison", 2, 2)

	# 灼烧：可叠加-1HP/回合
	if weapon_id == "scorch":
		match_ref.status.add_dot(defender_idx, "burn", 1, -1)  # -1表示无限持续

	# 时滞：命中后对方下回合攻击-1
	if weapon_id == "time_lag":
		match_ref.status.add_buff(defender_idx, "attack_down", -1, 1)

	# 共鸣：在 _handle_magic_attack 中已处理

# ---------- 处置DoT伤害 ----------
func apply_dot_damage(player_idx: int) -> int:
	var player = match_ref.get_player(player_idx)
	var total_damage = 0

	for dot in player.dots:
		total_damage += dot.damage
		if dot.duration > 0:
			dot.duration -= 1

	# 清理过期DoT
	player.dots = player.dots.filter(func(d): return d.duration != 0)
	return total_damage
