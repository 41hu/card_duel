# ============================================================
# card_effects.gd — 卡牌效果注册表
#
# 【用法】：
#   加新卡：1) config.gd 的 CARD_DB 加一行
#           2) 本文件 _handlers 注册表加一行 -> 写效果函数
#
#   execute(player_idx, card) 根据 card.type_id 查表执行效果
#   每个效果函数签名为 func(player_idx, card) -> {success, msg}
# ============================================================
extends RefCounted

var _m
var _handlers: Dictionary


func _init(m):
	_m = m
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
	return _m._handle_attack_card(player_idx, card)

func _atk_move(player_idx: int, card: Dictionary):
	return _m._handle_move_card(player_idx, card)

func _atk_attract(player_idx: int, card: Dictionary):
	_m.movement.attract(player_idx)
	_m.card_systems[player_idx].play_card(card.uid)
	_m.add_log(player_idx, "吸引")
	_m._check_any_death()
	return {success=true}

func _atk_deter(player_idx: int, card: Dictionary):
	_m.movement.deter(player_idx)
	_m.card_systems[player_idx].play_card(card.uid)
	_m.add_log(player_idx, "威慑")
	_m._check_any_death()
	return {success=true}

func _atk_freeze(player_idx: int, card: Dictionary):
	# 冻结可被魔法闪避响应
	return _m._handle_respondable_card(player_idx, card, "freeze")

func _atk_destroy(player_idx: int, card: Dictionary):
	return _m._handle_destroy(player_idx, card)

func _atk_seize(player_idx: int, card: Dictionary):
	return _m._handle_seize(player_idx, card)

func _heal_3(player_idx: int, card: Dictionary):
	return _m._handle_heal(player_idx, card, 3)

func _heal_5(player_idx: int, card: Dictionary):
	return _m._handle_heal(player_idx, card, 5)

func _buff_near(player_idx: int, card: Dictionary):
	_m.players[player_idx].near_power += 1
	_m.card_systems[player_idx].play_card(card.uid)
	_m.add_log(player_idx, "近战+1")
	return {success=true}

func _buff_range(player_idx: int, card: Dictionary):
	_m.players[player_idx].range_power += 1
	_m.card_systems[player_idx].play_card(card.uid)
	_m.add_log(player_idx, "远程+1")
	return {success=true}

func _buff_magic(player_idx: int, card: Dictionary):
	_m.players[player_idx].magic_power += 1
	_m.card_systems[player_idx].play_card(card.uid)
	_m.add_log(player_idx, "魔法+1")
	return {success=true}

func _blessing(player_idx: int, card: Dictionary):
	_m.card_systems[player_idx].play_card(card.uid)
	_m.card_systems[player_idx].draw_cards(2)
	_m.add_log(player_idx, "天赐")
	return {success=true}

func _trap(player_idx: int, card: Dictionary):
	var p = _m.players[player_idx]
	var pos = card.get("trap_pos", p.position + (1 if player_idx == 1 else -1))
	# 一张通用道具卡：放什么道具由角色决定（默认陷阱，猎人=捕兽夹等）
	var item_type = _m.char_skills.get_item_type(player_idx)
	if _m.item_system.place_item(player_idx, item_type, pos):
		_m.card_systems[player_idx].play_card(card.uid)
		var it_name = _m.item_system.get_item_type(item_type).get("name", item_type)
		_m.add_log(player_idx, "%s于%d" % [it_name, pos])
		return {success=true}
	return {success=false, msg="无法放置"}

func _near_weapon(player_idx: int, card: Dictionary):
	return _m._handle_weapon_card(player_idx, card, "near")

func _range_weapon(player_idx: int, card: Dictionary):
	return _m._handle_weapon_card(player_idx, card, "range")

func _magic_weapon(player_idx: int, card: Dictionary):
	return _m._handle_weapon_card(player_idx, card, "magic")

func _near_armor(player_idx: int, card: Dictionary):
	_m.card_systems[player_idx].play_card(card.uid)
	_m.equipment.equip_armor(player_idx, "near_armor")
	_m.add_log(player_idx, "装备防具")
	return {success=true}

func _range_armor(player_idx: int, card: Dictionary):
	_m.card_systems[player_idx].play_card(card.uid)
	_m.equipment.equip_armor(player_idx, "range_armor")
	_m.add_log(player_idx, "装备防具")
	return {success=true}

func _magic_armor(player_idx: int, card: Dictionary):
	_m.card_systems[player_idx].play_card(card.uid)
	_m.equipment.equip_armor(player_idx, "magic_armor")
	_m.add_log(player_idx, "装备防具")
	return {success=true}

