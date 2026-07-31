# main_menu.gd — 主菜单界面
extends Control

const Style = preload("res://scripts/theme/style_const.gd")

@onready var main_panel = $MainPanel
@onready var create_panel = $CreatePanel
@onready var join_panel = $JoinPanel
@onready var c_server = $CreatePanel/CServerInput
@onready var c_name = $CreatePanel/CNameInput
@onready var c_create_btn = $CreatePanel/CCreateBtn
@onready var c_back_btn = $CreatePanel/CBackBtn
@onready var c_room_label = $CreatePanel/CRoomLabel
@onready var j_server = $JoinPanel/JServerInput
@onready var j_room = $JoinPanel/JRoomInput
@onready var j_name = $JoinPanel/JNameInput
@onready var j_join_btn = $JoinPanel/JJoinBtn
@onready var j_back_btn = $JoinPanel/JBackBtn
@onready var status_label = $StatusLabel
@onready var version_label: Label

func _ready():
	$MainPanel/CreateBtn.pressed.connect(_show_create)
	$MainPanel/JoinBtn.pressed.connect(_show_join)
	$MainPanel/SelfBtn.pressed.connect(_on_self_play)
	_add_server_shortcut(c_server, "本地")
	_add_server_shortcut(c_server, "云端")
	_add_server_shortcut(j_server, "本地")
	_add_server_shortcut(j_server, "云端")
	_check_update()
	version_label = Label.new()
	version_label.text = "v" + _get_version()
	version_label.add_theme_font_size_override("font_size", 20)
	version_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	version_label.position = Vector2(12, 12)
	add_child(version_label)
	c_back_btn.pressed.connect(_show_main)
	j_back_btn.pressed.connect(_show_main)
	c_create_btn.pressed.connect(_on_create)
	j_join_btn.pressed.connect(_on_join)
	Network.connected_to_server.connect(_on_connected)
	Network.server_disconnected.connect(_on_disconnected)
	Network.room_created.connect(_on_room_created)
	Network.room_joined.connect(_on_room_joined)
	Network.game_starting.connect(_on_game_starting)
	Network.network_error.connect(_on_error)

var _shortcut_offsets: Dictionary = {}

func _get_version() -> String:
	var f = FileAccess.open("res://version.txt", FileAccess.READ)
	if f:
		return f.get_line().strip_edges()
	return "0.0.0"

# ---- 版本更新检查 ----
var _update_http: HTTPRequest
var _download_http: HTTPRequest
var _latest_version: String = ""
var _download_url: String = ""

func _check_update():
	if OS.get_name() != "Android": return
	_update_http = HTTPRequest.new()
	add_child(_update_http)
	_update_http.request_completed.connect(_on_update_check_done)
	var err = _update_http.request("https://api.github.com/repos/41hu/card_duel/releases/latest")
	if err != OK: _update_http.queue_free()

func _on_update_check_done(result: int, _code: int, _headers: PackedStringArray, body: PackedByteArray):
	_update_http.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS: return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if data == null or not data.has("tag_name"): return
	_latest_version = str(data.get("tag_name", "")).trim_prefix("v")
	var local_ver = _get_version()
	if _version_greater(_latest_version, local_ver):
		# 找 apk 下载地址
		var assets = data.get("assets", [])
		for a in assets:
			if str(a.get("name", "")).ends_with(".apk"):
				_download_url = a.get("browser_download_url", "")
				break
		if _download_url != "":
			_show_update_popup()

func _version_greater(a: String, b: String) -> bool:
	var av = a.split(".")
	var bv = b.split(".")
	for i in range(3):
		var ai = int(av[i]) if i < av.size() else 0
		var bi = int(bv[i]) if i < bv.size() else 0
		if ai > bi: return true
		if ai < bi: return false
	return false

func _show_update_popup():
	var c = Control.new()
	c.z_index = 20
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.7)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(bg)
	var vb = VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vb.size = Vector2(400, 220)
	vb.position = vb.position - Vector2(200, 110)
	c.add_child(vb)
	var t = Label.new()
	t.text = "发现新版本 v%s\n当前 v%s" % [_latest_version, _get_version()]
	t.add_theme_font_size_override("font_size", 22)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(t)
	var dl_btn = Button.new()
	dl_btn.text = "下载更新"
	dl_btn.pressed.connect(func(): _download_update(c))
	dl_btn.custom_minimum_size = Vector2(200, 50)
	dl_btn.add_theme_font_size_override("font_size", 24)
	vb.add_child(dl_btn)
	var later_btn = Button.new()
	later_btn.text = "稍后"
	later_btn.pressed.connect(func(): c.queue_free())
	later_btn.custom_minimum_size = Vector2(200, 50)
	later_btn.add_theme_font_size_override("font_size", 24)
	vb.add_child(later_btn)
	add_child(c)

func _download_update(popup: Control):
	var path = OS.get_user_data_dir() + "/CardDuel_update.apk"
	_download_http = HTTPRequest.new()
	add_child(_download_http)
	_download_http.download_file = path
	_download_http.request_completed.connect(func(res, _c, _h, _b):
		if res == HTTPRequest.RESULT_SUCCESS:
			OS.shell_open("file://" + path)
		_download_http.queue_free()
		popup.queue_free()
	)
	_download_http.request(_download_url)

func _add_server_shortcut(input: LineEdit, label: String):
	var btn = Button.new()
	btn.text = label
	btn.size = Vector2(60, 35)
	var offset = _shortcut_offsets.get(input, 0)
	btn.position = Vector2(input.position.x + input.size.x + 5 + offset, input.position.y)
	_shortcut_offsets[input] = offset + 65
	btn.add_theme_font_size_override("font_size", 17)
	if label == "本地":
		btn.pressed.connect(func(): input.text = "ws://127.0.0.1:17890")
	else:
		btn.pressed.connect(func(): input.text = "ws://47.107.47.251:17890")
	input.get_parent().add_child(btn)

func _show_create():
	main_panel.visible = false
	create_panel.visible = true
	join_panel.visible = false

func _show_join():
	main_panel.visible = false
	create_panel.visible = false
	join_panel.visible = true

func _show_main():
	main_panel.visible = true
	create_panel.visible = false
	join_panel.visible = false

func _on_create():
	status_label.text = "正在连接..."
	Network.connect_to_server(c_server.text.strip_edges())
	await Network.connected_to_server
	var pname = c_name.text.strip_edges()
	if pname == "": pname = "Player1"
	Network.create_room(pname)

func _on_join():
	var rid = j_room.text.strip_edges()
	if rid == "": status_label.text = "请输入房间号"; return
	status_label.text = "正在连接..."
	Network.connect_to_server(j_server.text.strip_edges())
	await Network.connected_to_server
	var pname = j_name.text.strip_edges()
	if pname == "": pname = "Player2"
	Network.join_room(rid, pname)

func _on_connected(): status_label.text = "已连接"
func _on_disconnected(): status_label.text = "断开连接"

func _on_room_created(room_id: String):
	c_room_label.text = "房间号: %s" % room_id
	status_label.text = "等待对手加入..."
	var btn = _make_ready_btn(create_panel, 360)
	btn.pressed.connect(func(): Network.ready_up(); btn.disabled = true; btn.text = "已准备")

func _on_room_joined(room_id: String, _players: Array):
	status_label.text = "已加入房间 %s" % room_id
	var btn = _make_ready_btn(join_panel, 390)
	btn.pressed.connect(func(): Network.ready_up(); btn.disabled = true; btn.text = "已准备")

func _make_ready_btn(parent: Control, y: float) -> Button:
	for c in parent.get_children():
		if c is Button and "准备" in c.text: c.queue_free()
	var btn = Button.new()
	btn.text = "准备开始"
	btn.position = Vector2(100, y)
	btn.size = Vector2(200, 45)
	btn.add_theme_color_override("font_color", Style.READY_YELLOW)
	parent.add_child(btn)
	return btn

func _on_game_starting(data: Dictionary):
	status_label.text = "进入BP..."
	Network.bp_state_cache = data.get("bp_state", {})
	get_tree().change_scene_to_file("res://scenes/bp_scene.tscn")

func _on_self_play():
	LocalGame.start_bp()
	get_tree().change_scene_to_file("res://scenes/bp_scene.tscn")

func _on_error(msg: String):
	status_label.text = "错误: " + msg
	status_label.add_theme_color_override("font_color", Style.ERROR_RED)
