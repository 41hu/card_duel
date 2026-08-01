# equipment_system.gd — 装备系统（武器幻化、装备/丢弃、防具管理）
extends RefCounted

var match_ref

func _init(match):
	match_ref = match

func process_weapon_card(_player_idx: int, weapon_type: String) -> Dictionary:
	var used_ids = match_ref.used_weapon_ids
	var weapon = Config.get_random_weapon(weapon_type, used_ids)
	if weapon.is_empty():
		return {phase="done", msg="所有该类型武器已生成"}
	used_ids.append(weapon.id)
	return {phase="choose", weapon=weapon}

func equip_weapon(player_idx: int, weapon_id: String):
	var player = match_ref.get_player(player_idx)
	var reject = match_ref.char_skills.can_equip(player_idx, "weapon")
	if reject != "": return
	# 旧武器回池
	if not player.weapon.is_empty():
		match_ref.used_weapon_ids.erase(player.weapon.id)
	player.weapon = {id=weapon_id, data=Config.WEAPON_DB[weapon_id]}

func discard_weapon_offer(weapon_id: String):
	# 放弃幻化武器，放回池子
	match_ref.used_weapon_ids.erase(weapon_id)

func equip_armor(player_idx: int, armor_type_id: String) -> Dictionary:
	var reject = match_ref.char_skills.can_equip(player_idx, "armor")
	if reject != "": return {success=false, msg=reject}
	var player = match_ref.get_player(player_idx)
	var dur = 3
	# 旧防具直接消失（防具卡打出时已进弃牌堆；若把 {id,data} 结构塞进弃牌堆会污染牌堆）
	player.armor = {id=armor_type_id, data=Config.ARMOR_DB[armor_type_id], durability=dur, max_durability=dur}
	return {success=true, msg="装备了" + Config.ARMOR_DB[armor_type_id].name}

func swap_armor(player_idx: int, armor_type_id: String) -> Dictionary:
	return equip_armor(player_idx, armor_type_id)

func destroy_equipment(player_idx: int, equip_type: String) -> String:
	var player = match_ref.get_player(player_idx)
	match equip_type:
		"weapon":
			if player.weapon.is_empty(): return "对方没有武器"
			var old = player.weapon
			match_ref.used_weapon_ids.erase(old.id)
			player.weapon = {}
			return "摧毁了" + old.data.name + "(已回池)"
		"armor":
			if player.armor.is_empty(): return "对方没有防具"
			var old = player.armor
			player.armor = {}
			return "摧毁了" + old.data.name
	return "无效选择"
