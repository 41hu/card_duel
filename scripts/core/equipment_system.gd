# equipment_system.gd — 装备系统（武器幻化、装备/丢弃、防具管理）
extends RefCounted

var match_ref

func _init(match):
	match_ref = match

func process_weapon_card(player_idx: int, weapon_type: String) -> Dictionary:
	var player = match_ref.get_player(player_idx)
	var used_ids = match_ref.used_weapon_ids
	var weapon = Config.get_random_weapon(weapon_type, used_ids)
	if weapon.is_empty():
		return {phase="done", msg="所有该类型武器已生成"}
	used_ids.append(weapon.id)
	return {phase="choose", weapon=weapon}

func equip_weapon(player_idx: int, weapon_id: String):
	var player = match_ref.get_player(player_idx)
	player.weapon = {id=weapon_id, data=Config.WEAPON_DB[weapon_id]}

func discard_weapon_offer(player_idx: int):
	pass

func equip_armor(player_idx: int, armor_type_id: String) -> Dictionary:
	var player = match_ref.get_player(player_idx)
	var dur = 3 + match_ref.char_skills.armor_durability_bonus(player_idx)
	if not player.armor.is_empty():
		match_ref.card_systems[player_idx].discard.append(player.armor.duplicate())
	player.armor = {id=armor_type_id, data=Config.ARMOR_DB[armor_type_id], durability=dur}
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
