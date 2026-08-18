# server_main.gd — 服务端主控（WebSocket + 房间管理 + 对局调度）
extends Node

const MatchStateClass = preload("res://scripts/core/match_state.gd")
const ModeData = preload("res://scripts/data/mode_data.gd")
const DeckData = preload("res://scripts/data/deck_data.gd")
const PORT = 17890
const DECK_TIME = 90  # 自定义卡组配置超时（秒），超时自动使用默认卡组

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
			# 发送缓冲区默认仅 64KB：长对局结算 game_over 消息（含对局记录/战报/统计）
			# 会超限 → put_packet 返回 ERR_OUT_OF_MEMORY → 客户端收不到结算，卡在战斗界面
			ws.outbound_buffer_size = 16 * 1024 * 1024
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
			# 自定义卡组配置超时：未上报的玩家自动使用默认卡组
			if room.stage == "deck" and Time.get_ticks_msec() >= int(room.get("deck_deadline", 0)):
				for i in range(room.decks.size()):
					if room.decks[i].is_empty():
						room.decks[i] = DeckData.default_deck()
						log_msg("P%d 配置超时，使用默认卡组" % i)
				_try_start_deck(room)

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
		"wind_bow_move": _on_wind_bow_move(peer_idx, data)
		"deck_ready": _on_deck_ready(peer_idx, data)

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
	if room.peer_indices.size() >= room.max_players:
		# 满员时区分「对局已开始」与「人满」，避免误导（对局已开始无法再加入）
		if room.stage != "waiting":
			_send_to(peer_idx, {"t":"error","msg":"对局已开始，无法加入"})
		else:
			_send_to(peer_idx, {"t":"error","msg":"房间已满"})
		return
	var pidx = room.peer_indices.size()  # 动态分配玩家序号（2 人房 0/1，4 人房 0-3）
	if room.ready.size() <= pidx:
		room.ready.append(false)  # 有人退出压缩过 ready 数组，补位时扩展保持下标对齐
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
	# 防重复 ready 重开 BP/对局（重复触发会重置 match 状态），以及人数未满时继续等人补位
	if room.stage != "waiting": return
	if room.peer_indices.size() < room.max_players: return
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
	room.match.wind_bow_prompt.connect(_on_wind_bow_prompt.bind(room))
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
	room.match.wind_bow_prompt.connect(_on_wind_bow_prompt.bind(room))
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
		_after_bp(room)

func _on_bp_action(peer_idx: int, data: Dictionary):
	var peer = _peers[peer_idx]; var room = _find_room(peer.room_id)
	if room == null or room.match == null: return
	var ok = room.match.bp.execute_action(peer.player_index, data.get("action",""), data.get("char_id",""))
	if not ok: _send_to(peer_idx, {"t":"error","msg":"无效BP操作"}); return
	log_msg("P%d BP操作 %s %s" % [peer.player_index, data.get("action",""), data.get("char_id","")])
	_broadcast_bp_state(room)
	if room.match.bp.is_done():
		_after_bp(room)

# BP 完成统一入口：经典/快速直接开战；自定义卡组进入「等卡组」阶段
func _after_bp(room):
	var chars = room.match.bp.get_start_chars()
	var bf = room.match.bp._bp_first
	if room.mode == "custom_deck":
		# 自定义卡组：等双方 deck_ready（客户端跳配置环节选卡组），90 秒超时自动默认
		room.stage = "deck"
		room.decks = [[], []]  # 与 deck_ready 赋值的数组类型一致
		room.weapon_pools = [{}, {}]  # 武器幻化池随卡组上报
		room.deck_locked = [false, false]  # 上报一次即锁定（准备阶段不可再调整，防重复上报覆盖）
		room.bp_chars = chars
		room.bp_first = bf
		room.deck_deadline = Time.get_ticks_msec() + DECK_TIME * 1000
		_broadcast_to_room(room, {"t": "deck_config", "chars": chars, "first": bf})
		log_msg("BP完成，等待双方卡组 P1=%s P2=%s" % [chars[0], chars[1]])
		return
	room.match.rapid_mode = room.rapid_mode  # 快速模式（房间创建时指定）
	room.match.init_match(chars[0], chars[1], bf)
	room.match._start_game()
	room.stage = "game"
	log_msg("BP完成 P1=%s P2=%s" % [chars[0], chars[1]])

# 自定义卡组：玩家配置完卡组后上报；双方就绪则服务端校验开战（防作弊）
func _on_deck_ready(peer_idx: int, data: Dictionary):
	var peer = _peers[peer_idx]; var room = _find_room(peer.room_id)
	if room == null or room.stage != "deck": return
	# 已上报过（准备阶段锁定）：拒绝再次调整，防止重复上报覆盖已确认卡组
	if room.deck_locked.size() > peer.player_index and room.deck_locked[peer.player_index]:
		_send_to(peer_idx, {"t": "error", "msg": "卡组已确认锁定，无法再次调整"})
		return
	var cards: Array = data.get("cards", [])
	var pkg = str(data.get("package", DeckData.DEFAULT_PACKAGE))
	var v = DeckData.validate_deck(cards, pkg)
	if not v.ok:
		_send_to(peer_idx, {"t": "error", "msg": "卡组不合法：" + v.msg})
		log_msg("P%d 非法卡组被拒：%s" % [peer.player_index, v.msg])
		return
	room.decks[peer.player_index] = cards
	room.deck_locked[peer.player_index] = true  # 进入准备阶段：锁定本次卡组
	# 武器幻化池：非法/缺失 → 默认池（不因此拒绝整个卡组，宽容处理）
	room.weapon_pools[peer.player_index] = DeckData.normalize_weapon_pool(data.get("weapon_pool", {}))
	log_msg("P%d 卡组就绪（%d张，套餐%s，武器池%s）" % [peer.player_index, cards.size(), pkg,
		"自定义" if data.has("weapon_pool") else "默认"])
	_try_start_deck(room)

# 双方卡组就绪则开战（deck_ready 上报与超时兜底共用）
func _try_start_deck(room):
	if room.decks[0].is_empty() or room.decks[1].is_empty():
		return
	var chars = room.bp_chars
	var bf = room.bp_first
	room.match.rapid_mode = room.rapid_mode
	room.match.init_match(chars[0], chars[1], bf, [room.decks[0], room.decks[1]], true, room.weapon_pools)
	room.match._start_game()
	room.stage = "game"
	var st = room.match.get_full_state()
	for p_idx in room.peer_indices:
		_send_to(p_idx, {"t": "game_starting", "state": st})
	log_msg("自定义卡组开战 P1=%s P2=%s" % [chars[0], chars[1]])

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

# 风神弓：攻击者选择控制方向（process_action 内校验待决状态与归属）
func _on_wind_bow_move(peer_idx: int, data: Dictionary):
	var peer = _peers[peer_idx]; var room = _find_room(peer.room_id)
	if room == null or room.match == null: return
	var result = room.match.process_action(peer.player_index, data)
	if not result.get("success", false):
		_send_to(peer_idx, {"t":"error","msg":result.get("msg","失败")})

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

# 风神弓：控制权在攻击者，把提示发给攻击者（客户端弹方向选择）
func _on_wind_bow_prompt(attacker_idx: int, target_idx: int, room):
	for p_idx in room.peer_indices:
		if _peers[p_idx].player_index == attacker_idx:
			_send_to(p_idx, {"t":"wind_bow_prompt","target":target_idx})
			return

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
	if peer.get("dead", false): return  # 断线 peer 保留槽位（索引对齐），但不再发送
	var data = JSON.stringify(msg)
	var err = peer.ws.put_packet(data.to_utf8_buffer())
	if err != OK:
		log_msg("发送失败 P%d %s: %d (消息%d字节)" % [peer.player_index, msg.get("t", "?"), err, data.to_utf8_buffer().size()])

func _broadcast_to_room(room, msg: Dictionary):
	for p_idx in room.peer_indices:
		if _peers[p_idx].get("dead", false): continue  # 4人房断线者仍占槽位，跳过无效发送
		_send_to(p_idx, msg)

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
					# 断线者正轮到出牌时立即换人，否则对局软锁到出牌超时（60s）
					if room.match.current_player == idx \
							and room.match.phase == Config.Phase.PLAYER_TURN:
						room.match._advance_to_next_player()
					else:
						room.match.state_changed.emit(room.match.get_full_state())
			return
		# 4 人混战：等待/准备阶段断线 → 移除该玩家并重排存活者 player_index，
		# 房间继续等人补位（下标与 player_index 保持一致，防止新玩家撞号/幽灵位）
		if room.max_players > 2 and room.stage != "game":
			var idx = peer.player_index
			room.peer_indices.erase(peer_idx)
			if idx >= 0 and idx < room.peer_names.size():
				room.peer_names.remove_at(idx)
				room.ready.remove_at(idx)  # 压缩数组：下标即 player_index 的不变量
			peer.room_id = ""; peer.player_index = -1; peer.ready = false
			if room.peer_indices.is_empty():
				_rooms.erase(room)
				return
			# 重排存活者 player_index 并广播（客户端以 room_joined 里的 player_index 为准）
			for i in range(room.peer_indices.size()):
				_peers[room.peer_indices[i]].player_index = i
			for p_idx in room.peer_indices:
				_send_to(p_idx, {"t":"room_joined","room_id":room.id,"player_index":_peers[p_idx].player_index,"players":room.peer_names,"mode":room.mode})
			log_msg("P%d离开房间%s（剩%d人，索引已重排）" % [idx, room.id, room.peer_indices.size()])
			return
		# BP/配置卡组阶段断线（2人房，流程已启动但未开局，match.players 为空）：
		# 存活方直接获胜结算（对手逃跑），否则客户端会卡在 BP/配置页一直等对手
		if room.max_players <= 2 and room.stage in ["bp", "deck"]:
			for p_idx in room.peer_indices:
				if p_idx != peer_idx:
					var winner = _peers[p_idx].player_index
					_send_to(p_idx, {
						"t": "game_over",
						"winner": winner,
						"loser": peer.player_index,
						"reason": "opponent_disconnected",
						"stats": [],
						"names": room.peer_names.duplicate(),
						"titles": [],
						"battle_record": [],
						"action_log": [],
					})
					log_msg("配置阶段P%d断开，P%d获胜 房间%s解散" % [peer.player_index, winner, room.id])
			_rooms.erase(room)
			return
		# 等待阶段断线（对局未开始，match 为 null）：通知存活方对手已离开（否则客户端卡在等待界面）
		if room.match == null or room.match.players.is_empty():
			for p_idx in room.peer_indices:
				if p_idx != peer_idx:
					_send_to(p_idx, {"t":"error","msg":"对手已离开房间"})
			_rooms.erase(room)
			log_msg("对局未开始P%d断开，房间%s解散" % [peer.player_index, room.id])
			return
		# 存活方获胜：发送完整结算数据（与正常对局结束一致），结算界面可查看统计/称号
		for p_idx in room.peer_indices:
			if p_idx != peer_idx:
				var winner = _peers[p_idx].player_index
				var endp: Array = []
				for p in room.match.players:
					endp.append({char_id=p.char_id, name=Config.char_name(p.char_id),
						hp=p.hp, max_hp=p.max_hp, near=p.near_power, range=p.range_power, magic=p.magic_power})
				var result = {
					"t": "game_over",
					"winner": winner,
					"loser": peer.player_index,
					"reason": "opponent_disconnected",
					"stats": room.match.stats.duplicate(),
					"names": room.peer_names.duplicate() if room.peer_names.size() >= 2 else [
						Config.char_name(room.match.players[0].char_id), Config.char_name(room.match.players[1].char_id)],
					"titles": room.match._calc_titles(winner, true),
					"titles_loser": [],  # 对手断线：不给败者称号
					"end_players": endp,
					"battle_record": room.match.battle_record.duplicate(),
					"action_log": room.match.action_log.duplicate(),
				}
				_send_to(p_idx, result)
		_rooms.erase(room)
