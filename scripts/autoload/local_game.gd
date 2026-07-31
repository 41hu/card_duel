# local_game.gd — 本地自我对战（模拟 Network 信号，复用现有 UI）
extends Node

signal connected_to_server()
signal server_disconnected()
signal room_created(room_id: String)
signal room_joined(room_id: String, players: Array)
@warning_ignore("unused_signal")
signal game_starting(data: Dictionary)
signal state_updated(state: Dictionary)
signal bp_state_updated(bp_state: Dictionary)
signal weapon_prompt(weapon_data: Dictionary)
signal response_needed(attack_info: Dictionary)
signal game_ended(result: Dictionary)
signal hand_revealed(cards: Array)
signal network_error(msg: String)

const MatchStateClass = preload("res://scripts/core/match_state.gd")

var game: MatchStateClass
var _player_names = ["自己(P1)", "自己(P2)"]
var _timer_elapsed: float = 0.0
# 最近一局结果缓存（结算界面从缓存读取，避免信号时序问题）
var last_game_result: Dictionary = {}

func _process(delta):
	if game == null: return
	_timer_elapsed += delta
	if _timer_elapsed >= 1.0:
		_timer_elapsed = 0.0
		game.check_timers()

func start_local_game(p1_char: String, p2_char: String, bp_first: int = -1):
	game = MatchStateClass.new()
	game.state_changed.connect(_on_state)
	game.weapon_prompt.connect(_on_weapon)
	game.response_needed.connect(_on_response)
	game.game_ended.connect(_on_ended)
	game.init_match(p1_char, p2_char, bp_first)
	game._start_game()
	battle_state_cache = game.get_full_state()

func start_bp():
	game = MatchStateClass.new()
	game.bp.reset()
	bp_state_cache = game.bp.get_bp_state()
	bp_state_cache["t"] = "bp_state"

func _on_state(state: Dictionary):
	state["t"] = "game_state"
	state_updated.emit(state)

func _on_weapon(_player_idx: int, weapon: Dictionary):
	weapon_prompt.emit(weapon)

func _on_response(_defender_idx: int, attack_info: Dictionary):
	attack_info["t"] = "response_needed"
	response_needed.emit(attack_info)

func _on_ended(result: Dictionary):
	result["t"] = "game_over"
	game_ended.emit(result)

func create_room(_name: String = ""):
	connected_to_server.emit()
	room_created.emit("LOCAL")

func join_room(_rid: String, _name: String = ""):
	connected_to_server.emit()
	room_joined.emit("LOCAL", _player_names)

func ready_up(): pass

var bp_state_cache: Dictionary = {}
var battle_state_cache: Dictionary = {}
var player_index: int = 0

func send_bp_action(action: String, char_id: String):
	if not game: return
	var phase = game.bp.bp_phase
	var acting = -1
	if "first" in phase: acting = game.bp._bp_first
	elif "second" in phase: acting = 1 - game.bp._bp_first
	if acting < 0: return
	game.bp.execute_action(acting, action, char_id)
	if game.bp.is_done():
		var chars = game.bp.picked_chars
		var bf = game.bp._bp_first
		start_local_game(chars[0], chars[1], bf)
	else:
		var bs = game.bp.get_bp_state()
		bs["t"] = "bp_state"
		bp_state_updated.emit(bs)

func send_play_card(card_uid: int, extra: Dictionary = {}):
	if not game: return
	var r = game.process_action(game.current_player, {"action": "play_card", "card_uid": card_uid, "extra": extra})
	if not r.get("success", false): network_error.emit(r.get("msg", "操作失败"))

func send_response(respond: bool, card_uid: int = -1):
	if not game: return
	if respond:
		game.process_response(1 - game.current_player, true, card_uid)
	else:
		game.skip_response(1 - game.current_player)

func send_weapon_choice(accept: bool):
	if not game: return
	game.confirm_weapon(game.current_player, accept)

func send_end_turn():
	if not game: return
	game.process_action(game.current_player, {"action": "end_turn"})

func send_discard_one(card_uid: int):
	if not game: return
	game.discard_one(game.current_player, card_uid)

func send_confirm_discard(card_uids: Array = []):
	if not game: return
	game.confirm_discard(game.current_player, card_uids)

func _phase_name(state: Dictionary) -> String:
	match state.turn_phase:
		0: return "判定"
		1: return "摸牌"
		2: return "出牌"
		3: return "弃牌"
	return "?"

func send_use_skill(skill_name: String, extra: Dictionary = {}):
	if not game: return
	var data = {"action": "use_skill", "skill": skill_name}
	for key in extra: data[key] = extra[key]
	game.process_action(game.current_player, data)

func send_swordsman_choice(choice: String):
	if not game: return
	game.process_action(game.current_player, {"action": "swordsman_choice", "choice": choice})

func send_reveal_hand():
	if not game: return
	var hand = game.reveal_opponent_hand(game.current_player)
	hand_revealed.emit(hand)

func disconnect_from_server():
	game = null
	_timer_elapsed = 0.0
	server_disconnected.emit()

func get_connected() -> bool:
	return game != null
