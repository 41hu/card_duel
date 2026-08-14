# online_deck_test.gd — 联机自定义卡组协议测试（测试工具）
# Timer 驱动状态机，每 0.2 秒推进一次；关键步骤打印日志便于定位。
extends Node

const DeckData = preload("res://scripts/data/deck_data.gd")
const RESULT_PATH = "user://online_deck_test.txt"

var ws1: WebSocketPeer
var ws2: WebSocketPeer
var msgs1: Array = []
var msgs2: Array = []
var _deck: Array = []
var _state: int = 0
var _bp_phase: String = ""
var _bp_first: int = 0
var _deck1_sent: bool = false
var _deck2_sent: bool = false
var _ticks: int = 0

func _ready():
	ws1 = WebSocketPeer.new()
	ws2 = WebSocketPeer.new()
	ws1.connect_to_url("ws://127.0.0.1:17890")
	ws2.connect_to_url("ws://127.0.0.1:17890")
	_deck = DeckData.default_deck()
	var t = Timer.new()
	t.wait_time = 0.2
	t.timeout.connect(_tick)
	add_child(t)
	t.start()
	print("[DeckTest] 开始")

func _poll(ws: WebSocketPeer, msgs: Array):
	ws.poll()
	while ws.get_available_packet_count() > 0:
		var raw = ws.get_packet().get_string_from_utf8()
		var d = JSON.parse_string(raw)
		if d != null:
			msgs.append(d)

func _send(ws: WebSocketPeer, msg: Dictionary):
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	ws.put_packet(JSON.stringify(msg).to_utf8_buffer())

func _tick():
	_ticks += 1
	if _ticks % 2 != 0:  # 每 0.4 秒
		return
	_poll(ws1, msgs1)
	_poll(ws2, msgs2)
	if ws1.get_ready_state() != WebSocketPeer.STATE_OPEN or ws2.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	match _state:
		0:
			if msgs1.is_empty():
				print("[DeckTest] 创建房间")
				_send(ws1, {"t": "create_room", "player_name": "测试A", "mode": "custom_deck"})
				_state = 1
		1:
			var rc := _latest(msgs1, "room_created")
			if not rc.is_empty():
				print("[DeckTest] 加入房间 " + str(rc.room_id))
				_send(ws2, {"t": "join_room", "room_id": rc.room_id, "player_name": "测试B"})
				_state = 2
		2:
			if not _latest(msgs2, "room_joined").is_empty():
				print("[DeckTest] 双方准备")
				_send(ws1, {"t": "ready"})
				_send(ws2, {"t": "ready"})
				_state = 3
		3:
			# BP：读最新 bp_state（game_starting 内嵌或独立消息）
			var bp := _latest_bp()
			if bp.is_empty():
				return
			var phase = str(bp.get("phase", "done"))
			if "done" in phase:
				print("[DeckTest] BP done")
				_state = 4
				return
			if phase == _bp_phase:
				return
			_bp_phase = phase
			_bp_first = int(bp.get("bp_first", 0))
			var avail: Array = bp.get("available_chars", [])
			if avail.is_empty():
				return
			var act = "ban" if "ban" in phase else "pick"
			var is_first_phase = "first" in phase
			var acting = ws1 if ((_bp_first == 0) == is_first_phase) else ws2
			print("[DeckTest] BP %s %s first=%d acting=%s" % [phase, act, _bp_first, "P0" if acting == ws1 else "P1"])
			_send(acting, {"t": "bp_action", "action": act, "char_id": str(avail[0])})
		4:
			# deck_config → deck_ready
			var dc := _latest(msgs1, "deck_config")
			if not dc.is_empty() and not _deck1_sent:
				_deck1_sent = true
				print("[DeckTest] P0 上报卡组")
				_send(ws1, {"t": "deck_ready", "cards": _deck, "package": "B"})
			var dc2 := _latest(msgs2, "deck_config")
			if not dc2.is_empty() and not _deck2_sent:
				_deck2_sent = true
				print("[DeckTest] P1 上报卡组")
				_send(ws2, {"t": "deck_ready", "cards": _deck, "package": "B"})
			# 最终 game_starting(state)
			var gs := _latest_with_state(msgs1)
			if gs.is_empty():
				gs = _latest_with_state(msgs2)
			if not gs.is_empty():
				var st: Dictionary = gs.state
				var indep = st.get("independent_decks", false)
				var p1_total = int(st.players[0].deck_size) + int(st.players[0].hand_size)
				var p2_total = int(st.players[1].deck_size) + int(st.players[1].hand_size)
				var ok = indep and p1_total == 40 and p2_total == 40
				_write("PASS" if ok else "FAIL", "independent=%s p1=%d p2=%d" % [str(indep), p1_total, p2_total])
				print("[DeckTest] 完成 %s" % ("PASS" if ok else "FAIL"))
				queue_free()
				return
			if _ticks > 400:
				_write("TIMEOUT", "state=%d msgs1=%d msgs2=%d" % [_state, msgs1.size(), msgs2.size()])
				queue_free()

func _latest(msgs: Array, t: String) -> Dictionary:
	for i in range(msgs.size() - 1, -1, -1):
		if msgs[i].get("t", "") == t:
			return msgs[i]
	return {}

func _latest_bp() -> Dictionary:
	var out := {}
	for i in range(msgs1.size() - 1, -1, -1):
		var m = msgs1[i]
		if m.get("t", "") == "bp_state":
			out = m
			break
		if m.get("t", "") == "game_starting" and m.has("bp_state"):
			out = m.bp_state
			break
	return out

func _latest_with_state(msgs: Array) -> Dictionary:
	for i in range(msgs.size() - 1, -1, -1):
		var m = msgs[i]
		if m.get("t", "") == "game_starting" and m.has("state"):
			return m
	return {}

func _write(result: String, detail: String):
	var f = FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string("结果: %s\n%s\n" % [result, detail])
		f.close()
