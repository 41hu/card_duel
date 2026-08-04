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
# ignore_distance（魔力引导等技能）：重击无视距离限制打出
func calculate_attack(attacker_idx: int, defender_idx: int, card_type_id: String, ignore_distance: bool = false) -> Dictionary:
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
			var custom = match_ref.char_skills.get_attack_base_damage(attacker_idx, card_type_id, distance)
			if custom >= 0:
				# 角色公式覆盖（多段攻击角色，如快枪手）；后续武器/防具/Buff 修正照常
				base_damage = custom
				formula = str(custom)
			else:
				var eff_dist = distance
				var lb_bonus = 0
				if not attacker.weapon.is_empty() and attacker.weapon.id == "longbow":
					eff_dist = max(0, distance - 1)
					lb_bonus = 1  # 长弓：远程+1
				base_damage = max(0, attacker.range_power - eff_dist) + lb_bonus
				formula = "%d-%d+%d" % [attacker.range_power, eff_dist, lb_bonus]
		"magic":
			base_damage = attacker.magic_power
			formula = str(base_damage)
		"heavy":
			if distance != 0 and not ignore_distance:
				return {damage=0, blocked=true, msg="重击必须贴脸！"}
			base_damage = attacker.near_power + 3
			formula = "%d+3" % attacker.near_power
		"pierce":
			var custom2 = match_ref.char_skills.get_attack_base_damage(attacker_idx, card_type_id, distance)
			if custom2 >= 0:
				base_damage = custom2
				formula = str(custom2)
			else:
				var eff_dist2 = distance
				var lb_bonus2 = 0
				if not attacker.weapon.is_empty() and attacker.weapon.id == "longbow":
					eff_dist2 = max(0, distance - 1)
					lb_bonus2 = 1  # 长弓：远程+1
				# 规则：面板-距离≤0 时无法打出（穿心是唯一有此限制的攻击卡）
				if attacker.range_power - eff_dist2 <= 0:
					return {damage=0, blocked=true, msg="距离太远，穿心无法打出", reason="distance"}
				base_damage = max(0, attacker.range_power - eff_dist2) + 3 + lb_bonus2
				formula = "%d-%d+3+%d" % [attacker.range_power, eff_dist2, lb_bonus2]
		"chant":
			base_damage = attacker.magic_power + 3
			formula = "%d+3" % attacker.magic_power

	# 应用武器效果（伤害加成）
	var before_weapon = base_damage
	base_damage = _apply_weapon_damage_bonus(attacker, base_damage, damage_type)
	if base_damage != before_weapon and not attacker.weapon.is_empty():
		formula += "+%d" % (base_damage - before_weapon)

	# 应用Buff修正（狂战士等）
	var buff_mod = match_ref.status.get_attack_modifier(attacker_idx, damage_type)
	if buff_mod != 0:
		base_damage += buff_mod
		formula += ("+%d" if buff_mod > 0 else "%d") % buff_mod

	# 计算防具减伤（耐久消耗延迟到实际造成伤害时，闪避/免疫不消耗）
	var armor_result = _calc_armor(defender, damage_type, base_damage)
	if armor_result.blocked:
		armor_result.formula = "=0(防具免疫)"
		return armor_result

	var armor_dmg = armor_result.damage
	if armor_dmg != base_damage:
		formula += "/2"
	base_damage = armor_dmg

	return {damage=base_damage, blocked=false, msg="", damage_type=damage_type, formula=formula, armor_hit=armor_result.armor_hit}

# ---------- 武器伤害加成 ----------
func _apply_weapon_damage_bonus(attacker, base_damage: int, damage_type: int) -> int:
	if attacker.weapon.is_empty():
		return base_damage
	# 武器类型必须匹配伤害类型
	if not Config.weapon_matches_damage_type(attacker.weapon.data.type, damage_type):
		return base_damage
	var dmg = base_damage
	match attacker.weapon.id:
		"iron_cutter": dmg += 2
		"lunge":
			dmg += 1  # 突刺：近战+1
			if match_ref._moved_to_adjacent_this_turn:
				dmg += 3  # 通过移动牌位移到贴脸：额外+3
		"sage_book": dmg += 2
	return dmg

# ---------- 防具计算（只算减伤，不消耗耐久；耐久由 consume_armor 在实际伤害时扣） ----------
# 返回 {blocked, damage, armor_hit, msg}；armor_hit=true 表示防具本次生效（应消耗耐久）
func _calc_armor(defender, damage_type: int, damage: int) -> Dictionary:
	if defender.armor.is_empty() or damage <= 0:
		return {blocked=false, damage=damage, armor_hit=false, msg=""}

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
		return {blocked=false, damage=damage, armor_hit=false, msg=""}

	# 第1次（满耐久）：完全免疫
	if durability == defender.armor.get("max_durability", 3):
		return {blocked=true, damage=0, armor_hit=true, msg="防具完全免疫了伤害！"}

	# 第2、3次：减半
	return {blocked=false, damage=floori(damage / 2.0), armor_hit=true, msg="防具减免了一半伤害"}

# 防具耐久消耗（实际受到伤害或免疫生效时调用；被闪避/0伤害攻击不消耗）
func consume_armor(defender_idx: int):
	var defender = match_ref.get_player(defender_idx)
	if defender.armor.is_empty(): return
	defender.armor.durability -= 1
	if defender.armor.durability <= 0:
		defender.armor = {}  # 碎裂

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
			if not defender.weapon.is_empty() and defender.weapon.id == "repeater":
				value += 2  # 连弩：牵制额外扣除2点
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
		match_ref.add_log(attacker_idx, "霜咬: 对方下回合无法移动")

	# 嗜血：近战≥3伤害回2HP（走 on_heal 钩子，邪术师回血效果-1 覆盖）
	if weapon_id == "bloodthirst" and damage >= 3:
		var before = attacker.hp
		var heal_amt = match_ref.char_skills.on_heal(attacker_idx, 2)
		attacker.hp = min(attacker.max_hp, attacker.hp + heal_amt)
		match_ref.stats[attacker_idx]["heal_total"] += attacker.hp - before  # 武器回血计入统计
		match_ref.add_log(attacker_idx, "嗜血: +%dHP" % (attacker.hp - before))

	# 鹰眼：远程命中后查看对方手牌
	if weapon_id == "hawkeye":
		match_ref._reveal_to = attacker_idx
		match_ref._reveal_from = defender_idx
		match_ref.add_log(attacker_idx, "鹰眼: 查看对方手牌")

	# 毒牙：远程命中后给予2层中毒（每回合-1HP，层数每回合-1，可叠加）
	if weapon_id == "toxic_fang":
		match_ref.status.add_poison(defender_idx, 2, attacker_idx)
		match_ref.add_log(attacker_idx, "毒牙: 对方中毒2层")

	# 灼烧：魔法命中后灼烧2回合每回合-2HP，再次命中刷新时长
	if weapon_id == "scorch":
		match_ref.status.add_burn(defender_idx, attacker_idx)
		match_ref.add_log(attacker_idx, "灼烧: 对方灼烧2回合")

	# 时滞：魔法命中后对方下回合攻击行动点-1
	if weapon_id == "time_lag":
		match_ref.status.add_buff(defender_idx, "ap_attack_down", -1, 1)
		match_ref.add_log(attacker_idx, "时滞: 对方下回合攻击行动点-1")

	# 共鸣：法术命中后减少对方护甲耐久2点
	if weapon_id == "resonance" and not defender.armor.is_empty():
		defender.armor.durability -= 2
		if defender.armor.durability <= 0:
			defender.armor = {}  # 碎裂
		match_ref.add_log(attacker_idx, "共鸣: 对方护甲耐久-2")

# ---------- 处置DoT伤害 ----------
# 灼烧: 每回合-2HP，duration-1，到0移除
# 中毒: 每回合-1HP，duration-1，到0移除
func apply_dot_damage(player_idx: int) -> Dictionary:
	var player = match_ref.get_player(player_idx)
	var total_damage = 0
	var details = []
	var dot_stats = []  # [{source, damage}] 用于伤害来源统计

	for i in range(player.dots.size() - 1, -1, -1):
		var dot = player.dots[i]
		if dot.type == "burn":
			total_damage += dot.damage
			details.append("灼烧-%d" % dot.damage)
			dot_stats.append({"source": dot.get("source", -1), "damage": dot.damage})
		elif dot.type == "poison":
			total_damage += dot.damage
			details.append("中毒-%d" % dot.damage)
			dot_stats.append({"source": dot.get("source", -1), "damage": dot.damage})
		dot.duration -= 1
		if dot.duration <= 0:
			player.dots.remove_at(i)

	return {damage=total_damage, details=details, dot_stats=dot_stats}
