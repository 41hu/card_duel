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
const AIPlayerClass = preload("res://scripts/core/ai_player.gd")

var game: MatchStateClass
var _player_names = ["自己(P1)", "自己(P2)"]
var _timer_elapsed: float = 0.0
# 最近一局结果缓存（结算界面从缓存读取，避免信号时序问题）
var last_game_result: Dictionary = {}

# ---- 人机对战模式 ----
var ai_mode: bool = false
var ai_difficulty: int = 1
var ai_idx: int = 1
var _ai = null
var _ai_busy: bool = false
# AI 每步间隔（让玩家看清 AI 的出牌过程）
const AI_STEP_DELAY_MS = 700
var _ai_next_act_time: int = 0

func _process(delta):
	if game == null: return
	_timer_elapsed += delta
	if _timer_elapsed >= 1.0:
		_timer_elapsed = 0.0
		game.check_timers()
	# AI 帧驱动：轮到 AI 时按间隔逐步决策（玩家能看到出牌过程）
	if ai_mode and not _ai_busy and game != null and _ai != null:
		if game.phase == Config.Phase.PLAYER_TURN and game.current_player == ai_idx:
			if Time.get_ticks_msec() >= _ai_next_act_time:
				_ai_act_frame()
				_ai_next_act_time = Time.get_ticks_msec() + AI_STEP_DELAY_MS
	# AI BP 驱动：人机对战 BP 阶段轮到 AI 时自动随机禁选
	if ai_mode and game != null and game.phase == Config.Phase.BP_PHASE:
		if Time.get_ticks_msec() >= _ai_next_act_time:
			_ai_bp_act()
			_ai_next_act_time = Time.get_ticks_msec() + AI_STEP_DELAY_MS

func start_local_game(p1_char: String, p2_char: String, bp_first: int = -1):
	game = MatchStateClass.new()
	game.state_changed.connect(_on_state)
	game.weapon_prompt.connect(_on_weapon)
	game.response_needed.connect(_on_response)
	game.game_ended.connect(_on_ended)
	game.init_match(p1_char, p2_char, bp_first)
	game._start_game()
	battle_state_cache = game.get_full_state()

# 人机对战 BP：进入 BP 流程（人类在 BP 界面选角色，AI 自动禁选，新角色自动适配）
func start_ai_bp(difficulty: int):
	ai_mode = true
	ai_difficulty = difficulty
	ai_idx = 1  # 人类永远 P0，AI 是 P1
	game = MatchStateClass.new()
	game.bp_state_changed.connect(_on_bp_state_changed)
	game.bp.reset()
	bp_state_cache = game.bp.get_bp_state()
	bp_state_cache["t"] = "bp_state"
	# 第一步 AI 操作延迟到场景加载后（BP 界面就绪再行动）
	_ai_next_act_time = Time.get_ticks_msec() + AI_STEP_DELAY_MS + 300

# AI BP 自动操作：轮到 AI（非人类）时随机禁选一个可用角色
func _ai_bp_act():
	var phase = game.bp.bp_phase
	if "done" in phase: return
	var acting = -1
	if "first" in phase: acting = game.bp._bp_first
	elif "second" in phase: acting = 1 - game.bp._bp_first
	if acting != ai_idx: return
	var avail = game.bp.available_chars
	if avail.is_empty(): return
	var char_id = avail[randi() % avail.size()]
	game.bp.execute_action(acting, "ban" if "ban" in phase else "pick", char_id)
	if game.bp.is_done():
		_on_bp_state_changed(game.bp.get_bp_state())
	else:
		var bs = game.bp.get_bp_state()
		bs["t"] = "bp_state"
		bp_state_updated.emit(bs)

# 人机对战：不走 BP，直接开战（AI 随机先手，角色由入口传入）
func start_ai_game(p1_char: String, p2_char: String, difficulty: int):
	ai_mode = true
	ai_difficulty = difficulty
	ai_idx = 1  # 人类永远 P0，AI 是 P1
	game = MatchStateClass.new()
	game.state_changed.connect(_on_state)
	game.weapon_prompt.connect(_on_weapon)
	game.response_needed.connect(_on_response)
	game.game_ended.connect(_on_ended)
	game.init_match(p1_char, p2_char, randi() % 2)
	_ai = AIPlayerClass.new(game, difficulty)
	game._start_game()
	# AI 先手：不立即行动——等场景加载完成后由帧驱动逐步行动，
	# 否则 AI 会在场景切换期间连续出牌（用户看不到过程、日志被顶掉）
	_ai_next_act_time = Time.get_ticks_msec() + AI_STEP_DELAY_MS + 500
	battle_state_cache = game.get_full_state()

# AI 单步决策（由 _process 每帧驱动，一次只做一步，busy 标志防重入）
func _ai_act_frame():
	_ai_busy = true
	if game.waiting_for_discard:
		_ai_do_discard()
	else:
		var act = _ai.decide_action(ai_idx)
		var r = game.process_action(ai_idx, act)
		if not r.get("success", false):
			game.process_action(ai_idx, {"action": "end_turn"})
	_ai_busy = false

func _ai_do_discard():
	var need = 0
	var cs = game.card_systems[ai_idx]
	var limit = game.movement.get_hand_limit(ai_idx)
	need = max(0, cs.hand.size() - limit)
	if need == 0: need = 1  # 超上限0张也主动弃1张（简化）
	var uids = _ai.decide_discard(ai_idx, need)
	game.confirm_discard(ai_idx, uids)

# AI 防守响应（人类攻击 AI 时自动响应；后续回合流转由 _process 帧驱动接管）
func _ai_respond(attack_info: Dictionary):
	if not ai_mode or game == null or _ai == null: return
	var dec = _ai.decide_response(ai_idx, attack_info.get("card", ""))
	if dec.respond:
		game.process_response(ai_idx, true, dec.card_uid)
	else:
		game.skip_response(ai_idx)

func start_bp():
	game = MatchStateClass.new()
	game.bp_state_changed.connect(_on_bp_state_changed)
	game.bp.reset()
	bp_state_cache = game.bp.get_bp_state()
	bp_state_cache["t"] = "bp_state"

func _on_bp_state_changed(bs: Dictionary):
	# BP 超时自动操作后：完成则开战，否则刷新 UI
	if game.bp.is_done():
		var chars = game.bp.picked_chars
		var bf = game.bp._bp_first
		if ai_mode:
			# 人机：人类是 P0，BP 先手可能是 AI——按先手对齐角色
			var human_char = chars[0] if bf == 0 else chars[1]
			var ai_char = chars[1] if bf == 0 else chars[0]
			start_ai_game(human_char, ai_char, ai_difficulty)
		else:
			start_local_game(chars[0], chars[1], bf)
	else:
		bs["t"] = "bp_state"
		bp_state_updated.emit(bs)

func _on_state(state: Dictionary):
	state["t"] = "game_state"
	state_updated.emit(state)

func _on_weapon(player_idx: int, weapon: Dictionary):
	if ai_mode and player_idx == ai_idx:
		game.confirm_weapon(player_idx, true)  # AI 获得武器直接装备
		return
	weapon_prompt.emit(weapon)

func _on_response(defender_idx: int, attack_info: Dictionary):
	attack_info["t"] = "response_needed"
	if ai_mode and defender_idx == ai_idx:
		_ai_respond(attack_info)  # AI 被攻击：自动响应
		return
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
