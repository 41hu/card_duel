# match_state.gd — 对局状态机（服务端权威，整合所有子系统）
extends RefCounted

const CombatSys = preload("res://scripts/core/combat_system.gd")
const MovementSys = preload("res://scripts/core/movement_system.gd")
const EquipmentSys = preload("res://scripts/core/equipment_system.gd")
const StatusSys = preload("res://scripts/core/status_system.gd")
const BPSys = preload("res://scripts/core/bp_system.gd")
const CardSys = preload("res://scripts/core/card_system.gd")

var card_systems: Array = []
var combat
var movement
var equipment
var status
var bp

var players: Array = []
var phase: int = Config.Phase.MAIN_MENU
var turn_phase: int = Config.TurnPhase.JUDGMENT
var current_player: int = 0
var turn_number: int = 0
var first_player: int = 0
var used_weapon_ids: Array = []
var traps: Array = []
var action_log: Array = []
var waiting_for_weapon_choice: int = -1
var pending_weapon_id: String = ""
var response_pending: bool = false
var attacker_last_damage: int = 0
var attacker_last_type: int = 0
var pending_attack_card: String = ""
var pending_attack_uid: int = -1
var game_result: Dictionary = {}
var waiting_for_discard: bool = false
var discard_count: int = 0

signal state_changed(data: Dictionary)
signal weapon_prompt(player_idx: int, weapon: Dictionary)
signal response_needed(defender_idx: int, attack_info: Dictionary)
signal game_ended(result: Dictionary)

func _init():
	combat = CombatSys.new(self)
	movement = MovementSys.new(self)
	equipment = EquipmentSys.new(self)
	status = StatusSys.new(self)
	bp = BPSys.new(self)

func init_match(p1_char_id: String, p2_char_id: String):
	var p1_char = Config.CHARACTER_DB[p1_char_id]
	var p2_char = Config.CHARACTER_DB[p2_char_id]
	players = [
		_create_player(0, p1_char_id, p1_char),
		_create_player(1, p2_char_id, p2_char),
	]
	var shared_deck = Config.build_initial_deck()
	shared_deck.shuffle()
	var shared_discard = []
	card_systems = [
		CardSys.new(shared_deck, shared_discard),
		CardSys.new(shared_deck, shared_discard),
	]
	used_weapon_ids.clear()
	traps.clear()
	action_log.clear()
	turn_number = 0
	waiting_for_weapon_choice = -1
	response_pending = false
	waiting_for_discard = false
	discard_count = 0
	game_result = {}
	first_player = randi() % 2
	current_player = first_player
	phase = Config.Phase.BP_PHASE
	bp.reset()
	for i in range(2):
		card_systems[i].draw_cards(4)

func _create_player(idx: int, char_id: String, char_data: Dictionary) -> Dictionary:
	return {
		index=idx, char_id=char_id,
		hp=char_data.hp, max_hp=char_data.hp,
		near_power=char_data.near, range_power=char_data.range, magic_power=char_data.magic,
		position=(3 if idx == 0 else 7),
		weapon={}, armor={}, buffs=[], dots=[],
		frozen=false, frozen_lockout=false, frozen_move=false,
		damage_reduction_used=false, skill_used_this_turn=false, free_move_used=false,
		combo_attacks_this_turn=[],
	}

func get_player(idx: int): return players[idx]
func get_traps() -> Array: return traps

func do_bp_action(player_idx: int, action: String, char_id: String) -> bool:
	var ok = bp.execute_action(player_idx, action, char_id)
	if ok and bp.is_done():
		var chars = bp.picked_chars
		init_match(chars[0], chars[1])
		_start_game()
	return ok

func _start_game():
	phase = Config.Phase.PLAYER_TURN
	turn_phase = Config.TurnPhase.JUDGMENT
	turn_number = 1
	current_player = first_player
	_judgment_phase()

func _judgment_phase():
	if phase == Config.Phase.GAME_OVER: return
	turn_phase = Config.TurnPhase.JUDGMENT
	var player = players[current_player]
	if player.dots.size() > 0:
		var dd = combat.apply_dot_damage(current_player)
		if dd > 0:
			player.hp -= dd
			add_log(current_player, "DoT造成%d点伤害" % dd)
			if player.hp <= 0:
				_handle_death(current_player)
				if phase == Config.Phase.GAME_OVER: return
	status.on_turn_start(current_player)
	_draw_phase()

func _draw_phase():
	if phase == Config.Phase.GAME_OVER: return
	turn_phase = Config.TurnPhase.DRAW
	card_systems[current_player].draw_cards(2)
	add_log(current_player, "抽了2张牌")
	_action_phase()

func _action_phase():
	if phase == Config.Phase.GAME_OVER: return
	turn_phase = Config.TurnPhase.ACTION
	var player = players[current_player]
	if player.frozen:
		add_log(current_player, "被冻结，跳过出牌阶段")
		status.clear_freeze(current_player)
		_discard_phase()
		return
	player.skill_used_this_turn = false
	player.free_move_used = false
	player.combo_attacks_this_turn = []
	player.damage_reduction_used = false
	player.ap_attack = 2
	player.ap_move = 1
	player.ap_function = 1
	if player.char_id == "warlock": player.ap_function += 1
	state_changed.emit(get_full_state())

func process_action(player_idx: int, action_data: Dictionary) -> Dictionary:
	if player_idx != current_player: return {success=false, msg="不是你的回合"}
	if waiting_for_discard:
		var act = action_data.get("action", "")
		if act == "discard_one": return {success=discard_one(player_idx, action_data.get("card_uid", -1))}
		if act == "confirm_discard": confirm_discard(player_idx, action_data.get("card_uids", [])); return {success=true}
		return {success=false, msg="弃牌阶段请先弃牌或确认结束"}
	if phase != Config.Phase.PLAYER_TURN or turn_phase != Config.TurnPhase.ACTION:
		return {success=false, msg="当前不在出牌阶段"}
	var action = action_data.get("action", "")
	match action:
		"play_card": return _do_play_card(player_idx, action_data)
		"end_turn": _discard_phase(); return {success=true, msg="结束出牌"}
	return {success=false, msg="未知行动"}

func _do_play_card(player_idx: int, data: Dictionary) -> Dictionary:
	var card_uid = data.get("card_uid", -1)
	var extra = data.get("extra", {})
	var card_sys = card_systems[player_idx]
	if not card_sys.has_card(card_uid): return {success=false, msg="手牌中没有此卡"}
	var card = {}
	for c in card_sys.hand:
		if c.uid == card_uid: card = c.duplicate(); break
	for key in extra: card[key] = extra[key]
	var type_id = card.type_id
	var player = players[player_idx]
	var cd = Config.CARD_DB[type_id]
	var ap_ok = false
	match cd.ap:
		Config.APType.ATTACK: ap_ok = (player.ap_attack >= cd.cost)
		Config.APType.MOVE: ap_ok = (player.ap_move >= cd.cost)
		Config.APType.FUNCTION: ap_ok = (player.ap_function >= cd.cost)
		Config.APType.NONE: ap_ok = true
	if not ap_ok: return {success=false, msg="行动点不足"}
	var free_archer = false
	if player.char_id == "archer" and type_id == "range" and not player.skill_used_this_turn:
		free_archer = true
	if type_id == "blessing":
		if player.free_move_used: return {success=false, msg="本回合已使用过天赐"}
		player.free_move_used = true
	if not free_archer and cd.ap != Config.APType.NONE:
		match cd.ap:
			Config.APType.ATTACK: player.ap_attack -= cd.cost
			Config.APType.MOVE: player.ap_move -= cd.cost
			Config.APType.FUNCTION: player.ap_function -= cd.cost
	var result = _execute_card_effect(player_idx, card)
	if not result.get("success", false) and result.get("phase") != "choose":
		return result
	if free_archer: player.skill_used_this_turn = true
	state_changed.emit(get_full_state())
	return result

func _execute_card_effect(player_idx: int, card: Dictionary) -> Dictionary:
	var type_id = card.type_id
	var player = players[player_idx]
	var opp = 1 - player_idx
	if type_id in ["near", "range", "magic", "heavy", "pierce", "chant"]:
		return _handle_attack_card(player_idx, card)
	match type_id:
		"move": return _handle_move_card(player_idx, card)
		"attract": movement.attract(player_idx); _use_card(player_idx, card); add_log(player_idx, "吸引"); return {success=true}
		"deter": movement.deter(player_idx); _use_card(player_idx, card); add_log(player_idx, "威慑"); return {success=true}
		"freeze":
			var ok = status.freeze_player(opp)
			_use_card(player_idx, card)
			add_log(player_idx, "冻结" if ok else "冻结失败")
			return {success=ok}
		"destroy": return _handle_destroy(player_idx, card)
		"seize": return _handle_seize(player_idx, card)
		"heal_3": return _handle_heal(player_idx, card, 3)
		"heal_5": return _handle_heal(player_idx, card, 5)
		"near_buf": player.near_power += 1; _use_card(player_idx, card); add_log(player_idx, "近战+1"); return {success=true}
		"range_buf": player.range_power += 1; _use_card(player_idx, card); add_log(player_idx, "远程+1"); return {success=true}
		"magic_buf": player.magic_power += 1; _use_card(player_idx, card); add_log(player_idx, "魔法+1"); return {success=true}
		"blessing": card_systems[player_idx].play_card(card.uid); card_systems[player_idx].draw_cards(2); add_log(player_idx, "天赐"); return {success=true}
		"trap":
			var pos = card.get("trap_pos", player.position + (1 if player_idx == 1 else -1))
			if movement.place_trap(player_idx, pos): _use_card(player_idx, card); add_log(player_idx, "陷阱于%d" % pos); return {success=true}
			return {success=false, msg="该格无法放置"}
		"near_weapon": return _handle_weapon_card(player_idx, card, "near")
		"range_weapon": return _handle_weapon_card(player_idx, card, "range")
		"magic_weapon": return _handle_weapon_card(player_idx, card, "magic")
		_: if type_id in ["near_armor", "range_armor", "magic_armor"]:
			_use_card(player_idx, card); equipment.equip_armor(player_idx, type_id); add_log(player_idx, "装备防具"); return {success=true}
	return {success=false, msg="未知卡牌"}

func _use_card(player_idx: int, card: Dictionary):
	card_systems[player_idx].play_card(card.uid)

func _handle_attack_card(player_idx: int, card: Dictionary) -> Dictionary:
	var type_id = card.type_id
	var opp = 1 - player_idx
	var distance = movement.get_distance()
	if type_id in ["near", "heavy"] and distance != 0:
		return {success=false, msg="必须贴脸"}
	var player = players[player_idx]
	player.combo_attacks_this_turn.append(type_id)
	pending_attack_card = type_id
	pending_attack_uid = card.uid
	attacker_last_damage = 0
	attacker_last_type = Config.get_damage_type(type_id)
	var calc = combat.calculate_attack(player_idx, opp, type_id)
	attacker_last_damage = calc.damage
	if attacker_last_damage <= 0:
		match Config.get_card_ap_type(type_id):
			Config.APType.ATTACK: player.ap_attack += Config.get_card_ap_cost(type_id)
		return {success=false, msg="无法造成伤害"}
	phase = Config.Phase.RESPONSE_WINDOW
	response_pending = true
	response_needed.emit(opp, {attacker=player_idx, card=type_id, damage=calc.damage, distance=distance})
	return {success=true, phase="response", damage=calc.damage}

func process_response(defender_idx: int, respond: bool, card_uid: int = -1):
	if not response_pending: return
	var attacker_idx = 1 - defender_idx
	response_pending = false
	phase = Config.Phase.PLAYER_TURN
	var final_damage = attacker_last_damage
	if respond and card_uid >= 0:
		var rr = combat.process_response(attacker_idx, defender_idx, pending_attack_card, card_uid)
		if rr.success:
			match rr.effect:
				"block": final_damage = int(final_damage / 2)
				"restrain": final_damage = max(0, final_damage - rr.value)
				"dodge": final_damage = 0
			add_log(defender_idx, "卡牌响应")
		else:
			if respond: add_log(defender_idx, "无法响应")
	card_systems[attacker_idx].play_card(pending_attack_uid)
	if final_damage > 0:
		players[defender_idx].hp -= final_damage
		add_log(attacker_idx, "造成%d伤害" % final_damage)
		combat.apply_on_hit_effects(attacker_idx, defender_idx, final_damage, attacker_last_type)
		var attacker = players[attacker_idx]
		if attacker.char_id == "swordsman" and not attacker.skill_used_this_turn:
			if attacker_last_type == Config.DamageType.PHYSICAL:
				attacker.skill_used_this_turn = true
				attacker.hp = min(attacker.max_hp, attacker.hp + 2)
				add_log(attacker_idx, "剑士+2HP")
		if players[defender_idx].char_id == "berserker":
			status.add_buff(defender_idx, "attack_up", 1, 2)
			add_log(defender_idx, "狂战士+1近战")
	if players[defender_idx].hp <= 0: _handle_death(defender_idx)
	if phase == Config.Phase.GAME_OVER: return
	turn_phase = Config.TurnPhase.ACTION
	state_changed.emit(get_full_state())

func skip_response(defender_idx: int): process_response(defender_idx, false)

func _handle_move_card(player_idx: int, card: Dictionary) -> Dictionary:
	var direction = card.get("direction", 0)
	if direction == 0: return {success=false, msg="请选择移动方向"}
	if not movement.move_player(player_idx, direction): return {success=false, msg="无法移动"}
	_use_card(player_idx, card)
	add_log(player_idx, "移动到%d" % players[player_idx].position)
	var td = movement.check_trap_trigger(player_idx)
	if td > 0:
		players[player_idx].hp -= td; add_log(player_idx, "陷阱-%d" % td)
		if players[player_idx].hp <= 0: _handle_death(player_idx)
	return {success=true}

func _handle_destroy(player_idx: int, card: Dictionary) -> Dictionary:
	var opp = 1 - player_idx
	var target = card.get("destroy_target", "hand")
	if target == "hand":
		card_systems[opp].random_discard(1); _use_card(player_idx, card); add_log(player_idx, "摧毁手牌"); return {success=true}
	if target == "trap":
		if traps.size() > 0: traps.pop_back(); _use_card(player_idx, card); add_log(player_idx, "摧毁陷阱"); return {success=true}
		return {success=false, msg="场上没有陷阱"}
	var et = card.get("equip_type", "weapon")
	var msg = equipment.destroy_equipment(opp, et); _use_card(player_idx, card); add_log(player_idx, msg); return {success=true}

func _handle_seize(player_idx: int, card: Dictionary) -> Dictionary:
	var opp = 1 - player_idx
	var taken = card_systems[opp].random_take(); _use_card(player_idx, card)
	if taken.is_empty(): add_log(player_idx, "夺取空"); return {success=true}
	card_systems[player_idx].add_to_hand(taken); add_log(player_idx, "夺取1张"); return {success=true}

func _handle_heal(player_idx: int, card: Dictionary, amount: int) -> Dictionary:
	var player = players[player_idx]
	if player.char_id == "priest": amount += 2
	player.hp = min(player.max_hp, player.hp + amount); _use_card(player_idx, card)
	add_log(player_idx, "+%dHP" % amount); return {success=true}

func _handle_weapon_card(player_idx: int, card: Dictionary, weapon_type: String) -> Dictionary:
	var result = equipment.process_weapon_card(player_idx, weapon_type)
	if result.phase == "done": return result
	_use_card(player_idx, card)
	waiting_for_weapon_choice = player_idx; pending_weapon_id = result.weapon.id
	weapon_prompt.emit(player_idx, result.weapon)
	return {success=true, phase="weapon_choose", weapon=result.weapon}

func confirm_weapon(player_idx: int, accept: bool):
	if waiting_for_weapon_choice != player_idx: return
	waiting_for_weapon_choice = -1
	if accept: equipment.equip_weapon(player_idx, pending_weapon_id); add_log(player_idx, "装备武器")
	else: add_log(player_idx, "放弃武器")
	pending_weapon_id = ""; state_changed.emit(get_full_state())

func _discard_phase():
	if phase == Config.Phase.GAME_OVER: return
	turn_phase = Config.TurnPhase.DISCARD
	waiting_for_discard = true
	state_changed.emit(get_full_state())

func discard_one(player_idx: int, card_uid: int):
	if not waiting_for_discard or player_idx != current_player: return false
	if not card_systems[current_player].has_card(card_uid): return false
	card_systems[current_player].discard_card(card_uid)
	add_log(current_player, "弃1张")
	state_changed.emit(get_full_state())
	return true

func confirm_discard(player_idx: int, card_uids: Array = []):
	if not waiting_for_discard or player_idx != current_player: return
	for uid in card_uids:
		card_systems[current_player].discard_card(uid)
	state_changed.emit(get_full_state())
	var limit = movement.get_hand_limit(current_player)
	if card_systems[current_player].hand.size() > limit: return
	waiting_for_discard = false
	_finish_discard()

func _finish_discard():
	var player = players[current_player]
	if player.char_id == "warlock" and player.ap_function >= 1:
		card_systems[current_player].draw_cards(1); add_log(current_player, "术士+1抽")
	status.on_turn_end(current_player)
	_advance_to_next_player()

func _advance_to_next_player():
	if phase == Config.Phase.GAME_OVER: return
	current_player = 1 - current_player
	if current_player == first_player: turn_number += 1
	_judgment_phase()
	state_changed.emit(get_full_state())

func _handle_death(player_idx: int):
	add_log(player_idx, "HP归零，复活...")
	phase = Config.Phase.RESURRECTING
	card_systems[player_idx].discard_all()
	var drawn = card_systems[player_idx].draw_cards(4)
	if drawn.is_empty(): _check_permanent_death(player_idx); return
	for c in drawn:
		if c.type_id == "blessing":
			card_systems[player_idx].play_card(c.uid); card_systems[player_idx].draw_cards(2); break
	while card_systems[player_idx].has_heal_card() and players[player_idx].hp <= 0:
		_use_heal_in_resurrection(player_idx)
	if players[player_idx].hp > 0:
		add_log(player_idx, "复活成功")
		players[player_idx].frozen = false; players[player_idx].frozen_lockout = false
		phase = Config.Phase.PLAYER_TURN; response_pending = false
		state_changed.emit(get_full_state())
	else: _check_permanent_death(player_idx)

func _use_heal_in_resurrection(player_idx: int):
	var card = card_systems[player_idx].use_heal_card()
	if card.is_empty(): return
	var amount = 3 if card.type_id == "heal_3" else 5
	if players[player_idx].char_id == "priest": amount += 2
	players[player_idx].hp = min(players[player_idx].max_hp, players[player_idx].hp + amount)

func _check_permanent_death(player_idx: int):
	if players[player_idx].hp <= 0:
		phase = Config.Phase.GAME_OVER
		game_result = {winner=1-player_idx, loser=player_idx, reason="permanent_death"}
		add_log(player_idx, "淘汰")
		state_changed.emit(get_full_state())
		game_ended.emit(game_result)

func add_log(player_idx: int, msg: String):
	action_log.append({turn=turn_number, player=player_idx, player_name=Config.char_name(players[player_idx].char_id), msg=msg})

func get_full_state(full: bool = false) -> Dictionary:
	var state = {
		phase=phase, turn_phase=turn_phase, current_player=current_player,
		turn_number=turn_number, first_player=first_player,
		response_pending=response_pending, pending_attack_card=pending_attack_card,
		waiting_for_discard=waiting_for_discard, discard_count=discard_count,
		players=[], traps=traps.duplicate(), action_log=action_log.duplicate(),
		distance=movement.get_distance(),
	}
	for i in range(2):
		var p = players[i]; var cs = card_systems[i]
		state.players.append({
			index=i, char_id=p.char_id, char_name=Config.char_name(p.char_id),
			hp=p.hp, max_hp=p.max_hp,
			near_power=p.near_power, range_power=p.range_power, magic_power=p.magic_power,
			position=p.position, weapon=p.weapon, armor=p.armor,
			buffs=p.buffs.duplicate(), dots=p.dots.duplicate(), frozen=p.frozen,
			ap_attack=p.get("ap_attack",0), ap_move=p.get("ap_move",0), ap_function=p.get("ap_function",0),
			hand_size=cs.hand.size(), deck_size=cs.deck.size(),
			hand=cs.hand.duplicate(), hand_limit=movement.get_hand_limit(i),
		})
	if full: state.bp_state = bp.get_bp_state()
	return state
