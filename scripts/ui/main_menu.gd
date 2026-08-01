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
	$MainPanel/MultiBtn.pressed.connect(_on_multi_battle)
	$MainPanel/SelfBtn.pressed.connect(_on_self_play)
	$MainPanel/AiBtn.pressed.connect(_on_ai_battle)
	$MainPanel/WikiBtn.pressed.connect(func():
		get_tree().change_scene_to_file("res://scenes/wiki_scene.tscn")
	)
	$MainPanel/QuitBtn.pressed.connect(func(): get_tree().quit())
	_add_server_shortcut(c_server, "本地")
	_add_server_shortcut(c_server, "云端")
	_add_server_shortcut(j_server, "本地")
	_add_server_shortcut(j_server, "云端")
	_check_update()
	version_label = Label.new()
	version_label.name = "VersionLabel"
	version_label.text = "v" + _get_version()
	version_label.add_theme_font_size_override("font_size", 20)
	version_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	# 安全区适配：全面屏/刘海屏上避免被裁切
	var sa = DisplayServer.get_display_safe_area()
	var win = DisplayServer.window_get_size()
	var vp = get_viewport_rect().size
	var sx = (win.x / vp.x) if vp.x > 0 else 1.0
	var sy = (win.y / vp.y) if vp.y > 0 else 1.0
	version_label.position = Vector2(sa.position.x / sx + 12, sa.position.y / sy + 12)
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
	var v = preload("res://scripts/version.gd")
	return v.VERSION

# ---- 版本更新检查 ----
var _update_http: HTTPRequest
var _latest_version: String = ""

const UPDATE_SERVER = "http://47.107.47.251:17891"

func _check_update():
	if OS.get_name() != "Android": return
	_update_http = HTTPRequest.new()
	add_child(_update_http)
	_update_http.timeout = 15
	_update_http.request_completed.connect(_on_update_check_done)
	var err = _update_http.request(UPDATE_SERVER + "/version.json")
	if err != OK: _update_http.queue_free()

func _on_update_check_done(result: int, _code: int, _headers: PackedStringArray, body: PackedByteArray):
	_update_http.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS: return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if data == null or not data.has("version"): return
	_latest_version = str(data.get("version", "")).trim_prefix("v")
	var local_ver = _get_version()
	if _version_greater(_latest_version, local_ver):
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
	c.name = "UpdatePopup"
	c.z_index = 20
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new()
	bg.name = "UpdateBg"
	bg.color = Color(0, 0, 0, 0.7)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(bg)
	var vb = VBoxContainer.new()
	vb.name = "UpdateBox"
	vb.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vb.size = Vector2(520, 320)
	vb.position = vb.position - Vector2(260, 160)
	c.add_child(vb)
	var t = Label.new()
	t.name = "UpdateTitle"
	t.text = "发现新版本 v%s\n当前 v%s" % [_latest_version, _get_version()]
	t.add_theme_font_size_override("font_size", 30)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(t)
	var dl_btn = Button.new()
	dl_btn.name = "DownloadBtn"
	dl_btn.text = "下载更新"
	# 打开浏览器下载 APK：下载到公共目录、系统自动弹安装提示（应用内下载在 Android 上无法安装）
	dl_btn.pressed.connect(func():
		OS.shell_open(UPDATE_SERVER + "/CardDuel.apk")
		c.queue_free()
	)
	dl_btn.custom_minimum_size = Vector2(260, 90)
	dl_btn.add_theme_font_size_override("font_size", 30)
	vb.add_child(dl_btn)
	var later_btn = Button.new()
	later_btn.name = "LaterBtn"
	later_btn.text = "稍后"
	later_btn.pressed.connect(func(): c.queue_free())
	later_btn.custom_minimum_size = Vector2(260, 90)
	later_btn.add_theme_font_size_override("font_size", 30)
	vb.add_child(later_btn)
	add_child(c)

func _add_server_shortcut(input: LineEdit, label: String):
	var btn = Button.new()
	btn.name = "Shortcut_%s" % label
	btn.text = label
	btn.size = Vector2(120, 70)
	var offset = _shortcut_offsets.get(input, 0)
	btn.position = Vector2(input.position.x + input.size.x + 10 + offset, input.position.y)
	_shortcut_offsets[input] = offset + 130
	btn.add_theme_font_size_override("font_size", 26)
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
	# 房间已创建：隐藏创建/返回按钮，准备按钮显示在按钮区（避免与输入框重叠）
	c_create_btn.visible = false
	c_back_btn.visible = false
	var btn = _make_ready_btn(create_panel, 560)
	btn.pressed.connect(func(): Network.ready_up(); btn.disabled = true; btn.text = "已准备")

func _on_room_joined(room_id: String, _players: Array):
	status_label.text = "已加入房间 %s" % room_id
	# 房间已加入：隐藏加入/返回按钮，准备按钮显示在按钮区
	j_join_btn.visible = false
	j_back_btn.visible = false
	var btn = _make_ready_btn(join_panel, 560)
	btn.pressed.connect(func(): Network.ready_up(); btn.disabled = true; btn.text = "已准备")

func _make_ready_btn(parent: Control, y: float) -> Button:
	for c in parent.get_children():
		if c is Button and "准备" in c.text: c.queue_free()
	var btn = Button.new()
	btn.text = "准备开始"
	btn.position = Vector2(100, y)
	btn.size = Vector2(320, 100)
	btn.add_theme_font_size_override("font_size", 32)
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

# ---- 多人对战（选择创建或加入） ----
func _on_multi_battle():
	var c = _make_popup("多人对战")
	var vb = c.get_child(1)
	var create = _popup_btn("创建房间")
	create.pressed.connect(func(): c.queue_free(); _show_create())
	vb.add_child(create)
	var join = _popup_btn("加入房间")
	join.pressed.connect(func(): c.queue_free(); _show_join())
	vb.add_child(join)
	var back = _popup_btn("返回")
	back.pressed.connect(func(): c.queue_free())
	vb.add_child(back)
	add_child(c)

# ---- 人机对战 ----
func _on_ai_battle():
	_show_ai_difficulty()

func _show_ai_difficulty():
	var c = _make_popup("选择 AI 难度")
	var vb = c.get_child(1)
	var easy = _popup_btn("简单")
	easy.pressed.connect(func(): c.queue_free(); _show_ai_char(0))
	vb.add_child(easy)
	var normal = _popup_btn("普通")
	normal.pressed.connect(func(): c.queue_free(); _show_ai_char(1))
	vb.add_child(normal)
	var hard = _popup_btn("困难")
	hard.pressed.connect(func(): c.queue_free(); _show_ai_char(2))
	vb.add_child(hard)
	var back = _popup_btn("返回")
	back.pressed.connect(func(): c.queue_free())
	vb.add_child(back)
	add_child(c)

func _show_ai_char(diff: int):
	var c = _make_popup("选择你的角色")
	var vb = c.get_child(1)
	for char_id in Config.CHARACTER_IDS:
		var b = _popup_btn(Config.char_name(char_id))
		# 用 bind 显式绑定参数（不依赖 lambda 默认参数语义，杜绝闭包绑定错位）
		b.pressed.connect(_on_ai_char_picked.bind(diff, char_id))
		vb.add_child(b)
	var back = _popup_btn("返回")
	back.pressed.connect(func(): c.queue_free())
	vb.add_child(back)
	add_child(c)

func _on_ai_char_picked(diff: int, char_id: String):
	var popup = get_node_or_null("AiPopup")
	if popup: popup.queue_free()
	_start_ai_battle(diff, char_id)

func _start_ai_battle(diff: int, my_char: String):
	var pool = Config.CHARACTER_IDS.duplicate()
	pool.erase(my_char)
	var ai_char = pool[randi() % pool.size()]
	LocalGame.start_ai_game(my_char, ai_char, diff)
	get_tree().change_scene_to_file("res://scenes/battle_scene.tscn")

# 弹窗辅助：半透明遮罩 + 居中滚动容器，返回 Control（第 2 个子节点是内容 VBox）
func _make_popup(title_text: String) -> Control:
	var c = Control.new()
	c.name = "AiPopup"
	c.z_index = 20
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.7)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(bg)
	var vb = VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vb.size = Vector2(560, 480)
	vb.position = vb.position - Vector2(280, 240)
	vb.add_theme_constant_override("separation", 10)
	c.add_child(vb)
	var t = Label.new()
	t.text = title_text
	t.add_theme_font_size_override("font_size", 32)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(t)
	return c

func _popup_btn(text: String) -> Button:
	var b = Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(280, 80)
	b.add_theme_font_size_override("font_size", 28)
	return b

func _on_error(msg: String):
	status_label.text = "错误: " + msg
	status_label.add_theme_color_override("font_color", Style.ERROR_RED)
