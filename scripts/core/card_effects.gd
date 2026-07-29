# card_effects.gd — 卡牌效果系统（加新卡只需改 config + 本文件注册表）
extends RefCounted

var match

func _init(m):
	match = m
	_handlers = {
		"near": _atk, "range": _atk, "magic": _atk,
		"heavy": _atk, "pierce": _atk, "chant": _atk,
		"move": _atk_move,
		"attract": _atk_attract, "deter": _atk_deter,
		"freeze": _atk_freeze,
		"destroy": _atk_destroy, "seize": _atk_seize,
		"heal_3": _heal_3, "heal_5": _heal_5,
		"near_buf": _buff_near, "range_buf": _buff_range, "magic_buf": _buff_magic,
		"blessing": _blessing, "trap": _trap,
		"near_weapon": _near_weapon, "range_weapon": _range_weapon, "magic_weapon": _magic_weapon,
		"near_armor": _near_armor, "range_armor": _range_armor, "magic_armor": _magic_armor,
	}

func execute(player_idx: int, card: Dictionary) -> Dictionary:
	var h = _handlers.get(card.type_id, null)
	if h: return h.call(player_idx, card)
	return {success=false, msg="未知卡牌"}

# 攻击卡
func _atk(player_idx: int, card: Dictionary):
	return match._handle_attack_card(player_idx, card)

func _atk_move(player_idx: int, card: Dictionary):
	return match._handle_move_card(player_idx, card)

func _atk_attract(player_idx: int, card: Dictionary):
	match.movement.attract(player_idx)
	match.card_systems[player_idx].play_card(card.uid)
	match.add_log(player_idx, "吸引")
	return {success=true}

func _atk_deter(player_idx: int, card: Dictionary):
	match.movement.deter(player_idx)
	match.card_systems[player_idx].play_card(card.uid)
	match.add_log(player_idx, "威慑")
	return {success=true}

func _atk_freeze(player_idx: int, card: Dictionary):
	var ok = match.status.freeze_player(1 - player_idx)
	match.card_systems[player_idx].play_card(card.uid)
	match.add_log(player_idx, "冻结" if ok else "冻结失败")
	return {success=ok}

func _atk_destroy(player_idx: int, card: Dictionary):
	return match._handle_destroy(player_idx, card)

func _atk_seize(player_idx: int, card: Dictionary):
	return match._handle_seize(player_idx, card)

func _heal_3(player_idx: int, card: Dictionary):
	return match._handle_heal(player_idx, card, 3)

func _heal_5(player_idx: int, card: Dictionary):
	return match._handle_heal(player_idx, card, 5)

func _buff_near(player_idx: int, card: Dictionary):
	match.players[player_idx].near_power += 1
	match.card_systems[player_idx].play_card(card.uid)
	match.add_log(player_idx, "近战+1")
	return {success=true}

func _buff_range(player_idx: int, card: Dictionary):
	match.players[player_idx].range_power += 1
	match.card_systems[player_idx].play_card(card.uid)
	match.add_log(player_idx, "远程+1")
	return {success=true}

func _buff_magic(player_idx: int, card: Dictionary):
	match.players[player_idx].magic_power += 1
	match.card_systems[player_idx].play_card(card.uid)
	match.add_log(player_idx, "魔法+1")
	return {success=true}

func _blessing(player_idx: int, card: Dictionary):
	match.card_systems[player_idx].play_card(card.uid)
	match.card_systems[player_idx].draw_cards(2)
	match.add_log(player_idx, "天赐")
	return {success=true}

func _trap(player_idx: int, card: Dictionary):
	var p = match.players[player_idx]
	var pos = card.get("trap_pos", p.position + (1 if player_idx == 1 else -1))
	if match.movement.place_trap(player_idx, pos):
		match.card_systems[player_idx].play_card(card.uid)
		match.add_log(player_idx, "陷阱于%d" % pos)
		return {success=true}
	return {success=false, msg="无法放置"}

func _near_weapon(player_idx: int, card: Dictionary):
	return match._handle_weapon_card(player_idx, card, "near")

func _range_weapon(player_idx: int, card: Dictionary):
	return match._handle_weapon_card(player_idx, card, "range")

func _magic_weapon(player_idx: int, card: Dictionary):
	return match._handle_weapon_card(player_idx, card, "magic")

func _near_armor(player_idx: int, card: Dictionary):
	match.card_systems[player_idx].play_card(card.uid)
	match.equipment.equip_armor(player_idx, "near_armor")
	match.add_log(player_idx, "装备防具")
	return {success=true}

func _range_armor(player_idx: int, card: Dictionary):
	match.card_systems[player_idx].play_card(card.uid)
	match.equipment.equip_armor(player_idx, "range_armor")
	match.add_log(player_idx, "装备防具")
	return {success=true}

func _magic_armor(player_idx: int, card: Dictionary):
	match.card_systems[player_idx].play_card(card.uid)
	match.equipment.equip_armor(player_idx, "magic_armor")
	match.add_log(player_idx, "装备防具")
	return {success=true}

var _handlers: Dictionary
