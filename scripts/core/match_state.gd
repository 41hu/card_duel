# ============================================================
# match_state.gd — 对局状态机（服务端权威，唯一真实数据源）
#
# 【架构】：服务端运行本文件实例，客户端只做UI渲染。
# 每个对局一个 MatchState 实例，server_room.gd 创建并管理。
# LocalGame autoload 创建 MatchState 实例用于本地自我对战。
#
# 【子系统】：
#   card_systems[i]  — CardSystem 牌堆管理（双方共享牌堆）
#   combat           — CombatSystem 伤害计算/响应/武器防具
#   movement         — MovementSystem 11格棋盘/距离/陷阱
#   equipment        — EquipmentSystem 武器幻化/防具管理
#   status           — StatusSystem Buff/DoT/冻结
#   bp               — BPSystem 禁选流程
#   char_skills      — CharacterSkills 角色技能钩子
#   card_effects     — CardEffects 卡牌效果注册表
#
# 【回合流程】（每回合4个阶段，严格顺序）：
#   _judgment_phase → _draw_phase → _action_phase → _discard_phase
#   判定(DoT/死亡)   摸牌(N张)    等待客户端操作   等待客户端弃牌
#   ↓ 调用 char_skills.on_turn_start
#   ↓ 调用 char_skills.on_opponent_turn_start
#
# 【消息协议】：客户端发送 JSON，服务端处理后广播状态
#   play_card    → process_action → _do_play_card → card_effects.execute
#   end_turn     → _discard_phase
#   respond      → process_response
#   weapon_choice→ confirm_weapon
#   discard_one / confirm_discard → 弃牌阶段操作
#   use_skill    → char_skills.use_skill
#
# 【状态广播】：get_full_state() 序列化所有可见状态为 Dictionary，
#   通过 state_changed 信号发送。网络模式下 server_main 做隐私过滤。
# ============================================================
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
var char_skills
var card_effects
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
	char_skills = preload("res://scripts/core/character_skills.gd").new(self)
	card_effects = preload("res://scripts/core/card_effects.gd").new(self)

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
		damage_bonus={},
		combo_attacks_this_turn=[],
		upgrades={},
		skill_counts={},
		pending_swordsman_skill=false,
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
	char_skills.on_opponent_turn_start(current_player)
	_draw_phase()

func _draw_phase():
	if phase == Config.Phase.GAME_OVER: return
	turn_phase = Config.TurnPhase.DRAW
	card_systems[current_player].draw_cards(char_skills.draw_count(current_player))
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
	char_skills.on_turn_start(current_player)
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
		"use_skill": return _handle_skill(player_idx, action_data.get("skill", ""), action_data)
		"swordsman_choice": return _handle_swordsman_choice(player_idx, action_data)
	return {success=false, msg="未知行动"}

func _do_play_card(player_idx: int, data: Dictionary) -> Dictionary:
	var card_uid = data.get("card_uid", -1)
	var extra = data.get("extra", {})
	# 支持从对方手牌出牌（extra.from_opponent=true）
	var from_idx = player_idx
	if extra.has("from_opponent") and extra.from_opponent:
		from_idx = 1 - player_idx
	var card_sys = card_systems[from_idx]
	if not card_sys.has_card(card_uid): return {success=false, msg="手牌中没有此卡"}
	var card = {}
	for c in card_sys.hand:
		if c.uid == card_uid: card = c.duplicate(); break
	for key in extra: card[key] = extra[key]
	# 支持"当作某牌打出"：extra中as_type覆盖原始type_id（预留功能）
	if extra.has("as_type"):
		if not Config.CARD_DB.has(extra.as_type):
			return {success=false, msg="无效卡牌类型"}
		card.type_id = extra.as_type
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
	var free_archer = char_skills.can_attack_free(player_idx, type_id)
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
		# 效果失败，返还已扣除的 AP
		if not free_archer and cd.ap != Config.APType.NONE:
			match cd.ap:
				Config.APType.ATTACK: player.ap_attack += cd.cost
				Config.APType.MOVE: player.ap_move += cd.cost
				Config.APType.FUNCTION: player.ap_function += cd.cost
		return result
	if free_archer: player.skill_used_this_turn = true
	state_changed.emit(get_full_state())
	return result

func _execute_card_effect(player_idx: int, card: Dictionary) -> Dictionary:
	return card_effects.execute(player_idx, card)
func _handle_skill(player_idx: int, skill: String, params: Dictionary = {}) -> Dictionary:
	var r = char_skills.use_skill(player_idx, skill, params)
	if r.get("success", false):
		state_changed.emit(get_full_state())
	return r

func _handle_swordsman_choice(player_idx: int, data: Dictionary) -> Dictionary:
	var p = players[player_idx]
	if not p.get("pending_swordsman_skill", false): return {success=false, msg="无可用技能"}
	if p.skill_used_this_turn: return {success=false, msg="本回合已使用过"}
	var choice = data.get("choice", "")
	if choice == "heal":
		p.hp = min(p.max_hp, p.hp + 2)
		add_log(player_idx, "剑士+2HP")
	elif choice == "draw":
		card_systems[player_idx].draw_cards(1)
		add_log(player_idx, "剑士抽1张")
	else:
		return {success=false, msg="无效选择"}
	p.skill_used_this_turn = true
	p.pending_swordsman_skill = false
	state_changed.emit(get_full_state())
	return {success=true}
func _use_card(player_idx: int, card: Dictionary):
	card_systems[player_idx].play_card(card.uid)

func _handle_respondable_card(player_idx: int, card: Dictionary, kind: String) -> Dictionary:
	var opp = 1 - player_idx
	pending_attack_card = kind
	pending_attack_uid = card.uid
	attacker_last_damage = 1
	phase = Config.Phase.RESPONSE_WINDOW
	response_pending = true
	response_needed.emit(opp, {attacker=player_idx, card=kind, damage=0, distance=0})
	return {success=true, phase="response"}

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
	attacker_last_damage += char_skills.on_attack_cast(player_idx, type_id)
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
				"block": final_damage = floori(final_damage / 2.0)
				"restrain": final_damage = max(0, final_damage - rr.value)
				"dodge": final_damage = 0
			add_log(defender_idx, "卡牌响应")
		else:
			if respond: add_log(defender_idx, "无法响应")
	card_systems[attacker_idx].play_card(pending_attack_uid)
	# 冻结卡：被闪避则失败，否则生效
	if pending_attack_card == "freeze":
		if final_damage == 0:
			add_log(attacker_idx, "冻结被闪避")
		else:
			status.freeze_player(defender_idx)
			add_log(attacker_idx, "冻结")
		state_changed.emit(get_full_state())
		return
	if final_damage > 0:
		# 技能减伤（圣骑士等）：在扣血前调用
		final_damage = char_skills.on_taking_damage(defender_idx, attacker_idx, final_damage)
		players[defender_idx].hp -= final_damage
		add_log(attacker_idx, "造成%d伤害" % final_damage)
		combat.apply_on_hit_effects(attacker_idx, defender_idx, final_damage, attacker_last_type)
		char_skills.on_attack_hit(attacker_idx, defender_idx, final_damage, attacker_last_type)
	if players[defender_idx].hp <= 0: _handle_death(defender_idx)
	if phase == Config.Phase.GAME_OVER: return
	turn_phase = Config.TurnPhase.ACTION
	state_changed.emit(get_full_state())

func skip_response(defender_idx: int): process_response(defender_idx, false)

func _handle_move_card(player_idx: int, card: Dictionary) -> Dictionary:
	var direction = card.get("direction", 0)
	var steps = card.get("steps", 1)
	if direction != -1 and direction != 1: return {success=false, msg="无效移动方向"}
	if not char_skills.move_distances(player_idx).has(steps):
		return {success=false, msg="不支持%d步移动" % steps}
	if status.get_move_modifier(player_idx) < 0:
		return {success=false, msg="本回合无法移动"}
	for _s in range(steps):
		if not movement.move_player(player_idx, direction): break
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
	if et != "weapon" and et != "armor": return {success=false, msg="无效装备类型"}
	var msg = equipment.destroy_equipment(opp, et); _use_card(player_idx, card); add_log(player_idx, msg); return {success=true}

func _handle_seize(player_idx: int, card: Dictionary) -> Dictionary:
	var opp = 1 - player_idx
	var taken = card_systems[opp].random_take(); _use_card(player_idx, card)
	if taken.is_empty(): add_log(player_idx, "夺取空"); return {success=true}
	card_systems[player_idx].add_to_hand(taken); add_log(player_idx, "夺取1张"); return {success=true}

func _handle_heal(player_idx: int, card: Dictionary, amount: int) -> Dictionary:
	var player = players[player_idx]
	amount = char_skills.on_heal(player_idx, amount)
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
	else: equipment.discard_weapon_offer(pending_weapon_id); add_log(player_idx, "放弃武器")
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
	char_skills.on_turn_end(current_player)
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
	amount = char_skills.on_heal(player_idx, amount)
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

# 偷对手一张牌到自己手牌（返回uid，-1表示失败）
func steal_card(player_idx: int, target_uid: int) -> int:
	var opp = 1 - player_idx
	if not card_systems[opp].has_card(target_uid): return -1
	var card = card_systems[opp].play_card(target_uid)
	if card.is_empty(): return -1
	card_systems[player_idx].add_to_hand(card)
	add_log(player_idx, "取走对方1张牌")
	return card.uid

# 归还一张牌给对手
func return_card(player_idx: int, card_uid: int) -> bool:
	var opp = 1 - player_idx
	if not card_systems[player_idx].has_card(card_uid): return false
	var card = card_systems[player_idx].play_card(card_uid)
	if card.is_empty(): return false
	card_systems[opp].add_to_hand(card)
	return true

# 查看对手手牌（返回 type_id 列表，不含 uid）
func reveal_opponent_hand(asking_player_idx: int) -> Array:
	var opp = 1 - asking_player_idx
	return card_systems[opp].get_hand_type_ids()

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
			active_skill=char_skills.has_active_skill(i),
			pending_swordsman_skill=p.get("pending_swordsman_skill", false),
		})
	if full: state.bp_state = bp.get_bp_state()
	return state
