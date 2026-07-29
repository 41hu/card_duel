# network.gd — 网络通信层（Autoload，客户端WebSocket）
extends Node

signal connected_to_server()
signal server_disconnected()
signal room_created(room_id: String)
signal room_joined(room_id: String, players: Array)
signal game_starting(data: Dictionary)
signal state_updated(state: Dictionary)
signal bp_state_updated(bp_state: Dictionary)
signal weapon_prompt(weapon_data: Dictionary)
signal response_needed(attack_info: Dictionary)
signal game_ended(result: Dictionary)
signal network_error(msg: String)

var _socket: WebSocketPeer = null
var _active: bool = false
var _player_name: String = "Player"
var room_id: String = ""
var player_index: int = -1
var bp_state_cache: Dictionary = {}
var battle_state_cache: Dictionary = {}

func _ready():
	print("[Network] Autoload 已加载")

func _process(_delta):
	if _socket == null:
		return

	_socket.poll()
	var st = _socket.get_ready_state()

	match st:
		WebSocketPeer.STATE_OPEN:
			if not _active:
				_active = true
				print("[Network] WebSocket 已连接")
				connected_to_server.emit()
			while _socket.get_available_packet_count() > 0:
				var raw = _socket.get_packet().get_string_from_utf8()
				_handle_packet(raw)

		WebSocketPeer.STATE_CLOSED:
			if _active:
				_active = false
				print("[Network] 连接关闭")
				server_disconnected.emit()
				_close()

func connect_to_server(url: String = ""):
	if url == "":
		url = "ws://127.0.0.1:17890"
	if not url.begins_with("ws"):
		url = "ws://" + url.replace("http://", "")

	print("[Network] 正在连接 %s" % url)
	_socket = WebSocketPeer.new()
	var err = _socket.connect_to_url(url)
	if err != OK:
		print("[Network] connect_to_url 失败: %d" % err)
		network_error.emit("连接失败: %d" % err)
		_close()
		return

func disconnect_from_server():
	if _socket != null:
		_socket.close()
	_close()

func _close():
	_socket = null
	_active = false
	room_id = ""
	player_index = -1

func get_connected() -> bool:
	return _active

func send(msg: Dictionary):
	if not _active or _socket == null:
		print("[Network] send 失败: 未连接")
		return
	var json_str = JSON.stringify(msg)
	_socket.put_packet(json_str.to_utf8_buffer())

func create_room(player_name: String = "Player1"):
	_player_name = player_name
	send({"t": "create_room", "player_name": player_name})

func join_room(rid: String, player_name: String = "Player2"):
	_player_name = player_name
	room_id = rid
	send({"t": "join_room", "room_id": rid, "player_name": player_name})

func ready_up():
	send({"t": "ready"})

func send_bp_action(action: String, char_id: String):
	send({"t": "bp_action", "action": action, "char_id": char_id})

func send_play_card(card_uid: int, extra: Dictionary = {}):
	send({"t": "play_card", "card_uid": card_uid, "extra": extra})

func send_response(respond: bool, card_uid: int = -1):
	send({"t": "respond", "respond": respond, "card_uid": card_uid})

func send_weapon_choice(accept: bool):
	send({"t": "weapon_choice", "accept": accept})

func send_end_turn():
	send({"t": "end_turn"})

func send_discard_one(card_uid: int):
	send({"t": "discard_one", "card_uid": card_uid})

func send_confirm_discard(card_uids: Array = []):
	send({"t": "confirm_discard", "card_uids": card_uids})

func send_use_skill(skill_name: String, extra: Dictionary = {}):
	var msg = {"t": "use_skill", "skill": skill_name}
	for key in extra: msg[key] = extra[key]
	send(msg)

func _handle_packet(raw: String):
	var data = JSON.parse_string(raw)
	if data == null:
		return
	var msg_type = data.get("t", "")

	match msg_type:
		"room_created":
			room_id = data.room_id
			player_index = 0
			room_created.emit(data.room_id)
		"room_joined":
			player_index = data.player_index
			room_joined.emit(data.room_id, data.players)
		"game_starting":
			game_starting.emit(data)
		"bp_state":
			bp_state_updated.emit(data)
		"game_state":
			if data.has("phase"):
				state_updated.emit(data)
		"weapon_prompt":
			weapon_prompt.emit(data.weapon)
		"response_needed":
			response_needed.emit(data)
		"game_over":
			game_ended.emit(data)
		"error":
			network_error.emit(data.get("msg", "未知错误"))
		"player_ready":
			pass
