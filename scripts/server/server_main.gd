# server_main.gd — 服务端主控（WebSocket + 房间管理 + 对局调度）
extends Node

const MatchStateClass = preload("res://scripts/core/match_state.gd")
const ModeData = preload("res://scripts/data/mode_data.gd")
const PORT = 17890

var _tcp_server: TCPServer = null
var _peers: Array = []
var _rooms: Array = []
var _next_room_id: int = 1000
var _timer_acc: float = 0.0

func log_msg(msg: String):
	var ts = Time.get_datetime_string_from_system()
	var line = "[%s] %s" % [ts, msg]
	print(line)

func _ready():
	log_msg("=== Card Duel 服务端启动 ===")
	_start_server()

func _start_server():
	_tcp_server = TCPServer.new()
	var err = _tcp_server.listen(PORT)
	if err != OK:
		log_msg("监听失败: %d" % err); return
	log_msg("WebSocket 监听端口 %d" % PORT)

func _process(_delta):
	if _tcp_server == null: return
	while _tcp_server.is_connection_available():
		var conn = _tcp_server.take_connection()
		if conn:
			var ws = WebSocketPeer.new()
			ws.accept_stream(conn)
			_peers.append({ws=ws, room_id="", player_index=-1, peer_name="Unknown", ready=false})
			log_msg("新连接: %d" % _peers.size())
	for i in range(_peers.size()-1, -1, -1):
		var peer = _peers[i]
		peer.ws.poll()
		var st = peer.ws.get_ready_state()
		match st:
			WebSocketPeer.STATE_OPEN:
				while peer.ws.get_available_packet_count() > 0:
					_handle_message(i, peer.ws.get_packet().get_string_from_utf8())
			WebSocketPeer.STATE_CLOSED:
				# 注意：不能 remove_at——移除会压缩数组，导致 room.peer_indices 里的
				# 索引错位（后续新连接补位后，消息发错人/发到死连接）。断开的 peer 保留
				# 并打 dead 标记，避免每帧重复触发断开处理（否则日志死循环）。
				if not peer.get("dead", false):
					peer.dead = true
					log_msg("断开: %s" % peer.peer_name)
					_on_peer_disconnected(i)
	_timer_acc += _delta
	if _timer_acc >= 1.0:
		_timer_acc = 0.0
		for room in _rooms:
			if room.match != null:
				room.match.check_timers()

func _handle_message(peer_idx: int, raw: String):
	var data = JSON.parse_string(raw)
	if data == null: return
	var t = data.get("t", "")
	log_msg("P%d << %s" % [_peers[peer_idx].player_index, t])
	match t:
		"create_room": _create_room(peer_idx, data)
		"join_room": _join_room(peer_idx, data)
		"ready": _on_ready(peer_idx)
		"bp_action": _on_bp_action(peer_idx, data)
		"play_card": _on_play_card(peer_idx, data)
		"end_turn": _on_end_turn(peer_idx)
		"respond": _on_response(peer_idx, data)
		"weapon_choice": _on_weapon_choice(peer_idx, data)
		"discard_one": _on_discard_one(peer_idx, data)
		"confirm_discard": _on_confirm_discard_msg(peer_idx, data)
		"use_skill": _on_use_skill(peer_idx, data)
		"reveal_hand": _on_reveal_hand(peer_idx)
		"fighter_choice": _on_fighter_choice(peer_idx, data)

func _create_room(peer_idx: int, data: Dictionary):
	var rid = str(_next_room_id); _next_room_id += 1
	var peer = _peers[peer_idx]
	# 模式映射：classic=2人标准 / rapid=2人快速 / ffa=4人混战（未来夺旗在此扩展）
	var mode = str(data.get("mode", "classic"))
	var md = ModeData.get_mode(mode)
	if md.is_empty() or not md.selectable:
		mode = "classic"
		md = ModeData.get_mode(mode)
	var upper = md.max_players if md.max_players > 0 else 2
	var max_p = clampi(int(data.get("max_players", upper)), 2, upper)
	var rapid = (mode == "rapid")
	var ready_arr: Array = []
	for i in range(max_p): ready_arr.append(false)
	peer.peer_name = data.get("player_name", "Player1"); peer.room_id = rid; peer.player_index = 0; peer.ready = false
	# config（自定义规则开关）暂存，规则生效逻辑后续接入 match_state
	_rooms.append({id=rid, peer_indices=[peer_idx], peer_names=[peer.peer_name], ready=ready_arr, stage="waiting", match=null, rapid_mode=rapid, mode=mode, max_players=max_p, config=data.get("config", {})})
	_send_to(peer_idx, {"t": "room_created", "room_id": rid, "mode": mode, "max_players": max_p})
	log_msg("房间%s创建（%s %d人）" % [rid, mode, max_p])

func _join_room(peer_idx: int, data: Dictionary):
	var rid = data.get("room_id", ""); var peer = _peers[peer_idx]; var room = _find_room(rid)
	if room == null: _send_to(peer_idx, {"t":"error","msg":"房间不存在"}); return
	if room.peer_indices.size() >= room.max_players: _send_to(peer_idx, {"t":"error","msg":"房间已满"}); return
	var pidx = room.peer_indices.size()  # 动态分配玩家序号（2 人房 0/1，4 人房 0-3）
	peer.peer_name = data.get("player_name", "Player%d" % (pidx + 1)); peer.room_id = rid; peer.player_index = pidx; peer.ready = false
	room.peer_indices.append(peer_idx); room.peer_names.append(peer.peer_name)
	# 广播给所有房内玩家（含新加入者），保持人数/序号同步
	for p_idx in room.peer_indices:
		_send_to(p_idx, {"t":"room_joined","room_id":rid,"player_index":_peers[p_idx].player_index,"players":room.peer_names,"mode":room.mode})
	log_msg("P%d加入房间%s（%d/%d）" % [peer.player_index, rid, room.peer_indices.size(), room.max_players])

func _on_ready(peer_idx: int):
	var peer = _peers[peer_idx]; var room = _find_room(peer.room_id)
	if room == null: return
	room.ready[peer.player_index] = true
	_broadcast_to_room(room, {"t":"player_ready","player_index":peer.player_index,"name":peer.peer_name})
	var all_ready = true
	for r in room.ready:
		if not r: all_ready = false; break
	if not all_ready: return
	if room.max_players > 2:
		_start_ffa(room)  # 4 人混战：直接随机角色开局（不走 BP）
	else:
		_start_bp(room)

# 4 人混战开局：随机 4 个不同角色，直接开战（不走 BP）
func _start_ffa(room):
	room.stage = "game"
	room.match = MatchStateClass.new()
	room.match.rapid_mode = room.rapid_mode
	room.match.state_changed.connect(_on_match_state_changed.bind(room))
	room.match.weapon_prompt.connect(_on_weapon_prompt.bind(room))
	room.match.response_needed.connect(_on_response_needed.bind(room))
	room.match.game_ended.connect(_on_game_ended.bind(room))
	room.match.bp_state_changed.connect(_on_bp_timeout.bind(room))
	var chars = Config.CHARACTER_IDS.duplicate()
	chars.shuffle()
	var picked = chars.slice(0, room.peer_indices.size())
	room.match.init_match_multi(picked)
	room.match._start_game()
	var st = room.match.get_full_state()
	for p_idx in room.peer_indices:
		_send_to(p_idx, {"t": "game_starting", "ffa": true, "state": st})
	log_msg("4人混战开局 %s" % str(picked))

func _find_room(room_id: String):
	for room in _rooms:
		if room.id == room_id: return room
	return null

func _start_bp(room):
	room.stage = "bp"; room.match = MatchStateClass.new()
	room.match.state_changed.connect(_on_match_state_changed.bind(room))
	room.match.weapon_prompt.connect(_on_weapon_prompt.bind(room))
	room.match.response_needed.connect(_on_response_needed.bind(room))
	room.match.game_ended.connect(_on_game_ended.bind(room))
	room.match.bp_state_changed.connect(_on_bp_timeout.bind(room))
	var bp_state = room.match.bp.get_bp_state()
	for p_idx in room.peer_indices:
		_send_to(p_idx, {"t":"game_starting","bp_state":bp_state,"player_index":_peers[p_idx].player_index})
	log_msg("BP开始 房间%s" % room.id)

# BP 倒计时超时自动操作后：广播并推进流程
# 注意参数顺序：信号 emit(bp_state) + bind(room) → 回调实际收到 (bp_state, room)
func _on_bp_timeout(_bs: Dictionary, room):
	_broadcast_bp_state(room)
	if room.match.bp.is_done():
		var chars = room.match.bp.get_start_chars()
		var bf = room.match.bp._bp_first
		room.match.rapid_mode = room.rapid_mode  # 快速模式（房间创建时指定）
		room.match.init_match(chars[0], chars[1], bf)
		room.match._start_game()
		room.stage = "game"
		log_msg("BP超时完成 P1=%s P2=%s" % [chars[0], chars[1]])

func _on_bp_action(peer_idx: int, data: Dictionary):
	var peer = _peers[peer_idx]; var room = _find_room(peer.room_id)
	if room == null or room.match == null: return
	var ok = room.match.bp.execute_action(peer.player_index, data.get("action",""), data.get("char_id",""))
	if not ok: _send_to(peer_idx, {"t":"error","msg":"无效BP操作"}); return
	log_msg("P%d BP操作 %s %s" % [peer.player_index, data.get("action",""), data.get("char_id","")])
	_broadcast_bp_state(room)
	if room.match.bp.is_done():
		var chars = room.match.bp.get_start_chars()
		var bf = room.match.bp._bp_first
		room.match.rapid_mode = room.rapid_mode  # 快速模式（房间创建时指定）
		room.match.init_match(chars[0], chars[1], bf)
		room.match._start_game()
		room.stage = "game"
		log_msg("BP完成 P1=%s P2=%s" % [chars[0], chars[1]])

func _broadcast_bp_state(room):
	var bp_state = room.match.bp.get_bp_state(); bp_state["t"]="bp_state"
	for p_idx in room.peer_indices: _send_to(p_idx, bp_state)

func _on_play_card(peer_idx: int, data: Dictionary):
	var peer = _peers[peer_idx]; var room = _find_room(peer.room_id)
	if room == null or room.match == null: return
	data["action"] = "play_card"
	var result = room.match.process_action(peer.player_index, data)
	if not result.get("success", false) and result.get("phase") != "weapon_choose":
		_send_to(peer_idx, {"t":"error","msg":result.get("msg","失败")})

func _on_end_turn(peer_idx: int):
	var peer = _peers[peer_idx]; var room = _find_room(peer.room_id)
	if room == null or room.match == null: return
	room.match.process_action(peer.player_index, {"action":"end_turn"})

func _on_response(peer_idx: int, data: Dictionary):
	var peer = _peers[peer_idx]; var room = _find_room(peer.room_id)
	if room == null or room.match == null: return
	if data.get("respond", false):
		room.match.process_response(peer.player_index, true, data.get("card_uid", -1))
	else: room.match.skip_response(peer.player_index)

func _on_weapon_choice(peer_idx: int, data: Dictionary):
	var peer = _peers[peer_idx]; var room = _find_room(peer.room_id)
	if room == null or room.match == null: return
	room.match.confirm_weapon(peer.player_index, data.get("accept", true))

func _on_discard_one(peer_idx: int, data: Dictionary):
	var peer = _peers[peer_idx]; var room = _find_room(peer.room_id)
	if room == null or room.match == null: return
	room.match.discard_one(peer.player_index, data.get("card_uid", -1))

func _on_reveal_hand(peer_idx: int):
	var peer = _peers[peer_idx]; var room = _find_room(peer.room_id)
	if room == null or room.match == null: return
	var hand = room.match.reveal_opponent_hand(peer.player_index)
	_send_to(peer_idx, {"t": "hand_revealed", "cards": hand})

func _on_use_skill(peer_idx: int, data: Dictionary):
	var peer = _peers[peer_idx]; var room = _find_room(peer.room_id)
	if room == null or room.match == null: return
	# 安全：下划线前缀是本地调试技能（发牌/立即结束），联网玩家禁止调用
	var skill = data.get("skill", "")
	if skill.begins_with("_"):
		return
	data["action"] = "use_skill"
	room.match.process_action(peer.player_index, data)

func _on_fighter_choice(peer_idx: int, data: Dictionary):
	var peer = _peers[peer_idx]; var room = _find_room(peer.room_id)
	if room == null or room.match == null: return
	room.match.process_action(peer.player_index, {"action": "fighter_choice", "choice": data.get("choice", "")})

func _on_confirm_discard_msg(peer_idx: int, data: Dictionary):
	var peer = _peers[peer_idx]; var room = _find_room(peer.room_id)
	if room == null or room.match == null: return
	room.match.confirm_discard(peer.player_index, data.get("card_uids", []))

func _on_match_state_changed(state: Dictionary, room):
	state["t"] = "game_state"
	for p_idx in room.peer_indices:
		var ps = state.duplicate(true)
		for pl in ps.players:
			if pl.index != _peers[p_idx].player_index: pl.hand = []
		_send_to(p_idx, ps)

func _on_weapon_prompt(player_idx: int, weapon: Dictionary, room):
	for p_idx in room.peer_indices:
		if _peers[p_idx].player_index == player_idx:
			_send_to(p_idx, {"t":"weapon_prompt","weapon":weapon})

func _on_response_needed(defender_idx: int, attack_info: Dictionary, room):
	for p_idx in room.peer_indices:
		if _peers[p_idx].player_index == defender_idx:
			attack_info["t"] = "response_needed"
			_send_to(p_idx, attack_info)

func _on_game_ended(result: Dictionary, room):
	room.stage = "ended"; result["t"]="game_over"
	# 结算页显示玩家输入的名字（peer_names[i] 与 players[i] 索引对齐）
	if room.peer_names.size() >= 2:
		result["names"] = room.peer_names.duplicate()
	_broadcast_to_room(room, result)

func _send_to(peer_idx: int, msg: Dictionary):
	var peer = _peers[peer_idx]
	peer.ws.put_packet(JSON.stringify(msg).to_utf8_buffer())

func _broadcast_to_room(room, msg: Dictionary):
	for p_idx in room.peer_indices: _send_to(p_idx, msg)

func _on_peer_disconnected(peer_idx: int):
	var peer = _peers[peer_idx]; var room = _find_room(peer.room_id)
	if room != null:
		if room.stage == "ended":
			# 对局已正常结束：退出不再发断线结算（否则赢家退出会用"对手断线"覆盖正常结算，
			# 导致获胜者被改成输家）
			_rooms.erase(room)
			return
		# 4 人混战：对局中断线 → 该玩家淘汰，对局继续（最后存活者胜）
		if room.max_players > 2 and room.stage == "game" and room.match != null:
			var idx = peer.player_index
			if idx >= 0 and idx < room.match.players.size() \
					and not room.match.players[idx].get("eliminated", false):
				room.match.players[idx].eliminated = true
				room.match.players[idx].hp = 0
				log_msg("P%d断线淘汰 房间%s" % [idx, room.id])
				room.match._check_multi_winner()
				if room.match.phase != Config.Phase.GAME_OVER:
					room.match.state_changed.emit(room.match.get_full_state())
			return
		# 4 人混战：等待/准备阶段断线 → 移除该玩家，房间继续等人
		if room.max_players > 2 and room.stage != "game":
			var idx = peer.player_index
			room.peer_indices.erase(peer_idx)
			if idx >= 0 and idx < room.peer_names.size():
				room.peer_names.remove_at(idx)
				room.ready[idx] = false
			peer.room_id = ""; peer.player_index = -1; peer.ready = false
			if room.peer_indices.is_empty():
				_rooms.erase(room)
				return
			for p_idx in room.peer_indices:
				_send_to(p_idx, {"t":"room_joined","room_id":room.id,"player_index":_peers[p_idx].player_index,"players":room.peer_names,"mode":room.mode})
			log_msg("P%d离开房间%s（剩%d人）" % [idx, room.id, room.peer_indices.size()])
			return
		# 存活方获胜：发送完整结算数据（与正常对局结束一致），结算界面可查看统计/称号
		for p_idx in room.peer_indices:
			if p_idx != peer_idx:
				var winner = _peers[p_idx].player_index
				var result = {
					"t": "game_over",
					"winner": winner,
					"loser": peer.player_index,
					"reason": "opponent_disconnected",
					"stats": room.match.stats.duplicate(),
					"names": room.peer_names.duplicate() if room.peer_names.size() >= 2 else [
						Config.char_name(room.match.players[0].char_id), Config.char_name(room.match.players[1].char_id)],
					"titles": room.match._calc_titles(winner),
					"battle_record": room.match.battle_record.duplicate(),
					"action_log": room.match.action_log.duplicate(),
				}
				_send_to(p_idx, result)
		_rooms.erase(room)
