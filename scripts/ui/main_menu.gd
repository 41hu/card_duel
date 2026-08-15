# main_menu.gd — 主菜单界面
extends Control

const Style = preload("res://scripts/theme/style_const.gd")
const ModeData = preload("res://scripts/data/mode_data.gd")
const ModeSelectScript = preload("res://scripts/ui/mode_select.gd")

@onready var main_panel = $MainPanel
@onready var join_panel = $JoinPanel
@onready var j_server = $JoinPanel/JServerInput
@onready var j_room = $JoinPanel/JRoomInput
@onready var j_name = $JoinPanel/JNameInput
@onready var j_join_btn = $JoinPanel/JJoinBtn
@onready var j_back_btn = $JoinPanel/JBackBtn
@onready var status_label = $StatusLabel
@onready var version_label: Label

func _ready():
	Style.scale_node_fonts(self)  # 移动端字号适配（tscn 写死的字号）
	$MainPanel/MultiBtn.pressed.connect(_on_multi_battle)
	$MainPanel/SelfBtn.pressed.connect(_on_self_play)
	$MainPanel/AiBtn.pressed.connect(_on_ai_battle)
	$MainPanel/WikiBtn.pressed.connect(func():
		get_tree().change_scene_to_file("res://scenes/wiki_scene.tscn")
	)
	$MainPanel/QuitBtn.pressed.connect(func(): get_tree().quit())
	if OS.has_feature("web"):
		$MainPanel/QuitBtn.visible = false
	# 新手教程入口：左下角独立按钮（不与主按钮堆一起）
	var tbtn := Button.new()
	tbtn.text = "新手教程"
	tbtn.add_theme_font_size_override("font_size", Style.fs(26))
	tbtn.anchor_top = 1.0; tbtn.anchor_bottom = 1.0
	tbtn.offset_left = 24
	tbtn.offset_top = -Style.fs(104); tbtn.offset_bottom = -24
	tbtn.size = Vector2(Style.fs(180), Style.fs(80))
	tbtn.pressed.connect(_start_tutorial)
	add_child(tbtn)
	# 卡组管理入口：新手教程按钮上方（预设每角色卡组，开局配置环节使用）
	var dbtn := Button.new()
	dbtn.text = "卡组管理"
	dbtn.add_theme_font_size_override("font_size", Style.fs(26))
	dbtn.anchor_top = 1.0; dbtn.anchor_bottom = 1.0
	dbtn.offset_left = 24
	dbtn.offset_top = -Style.fs(196); dbtn.offset_bottom = -Style.fs(116)
	dbtn.size = Vector2(Style.fs(180), Style.fs(80))
	dbtn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/deck_edit.tscn"))
	add_child(dbtn)
	_add_server_shortcut(j_server, "本地")
	_add_server_shortcut(j_server, "云端")
	_check_update()
	version_label = Label.new()
	version_label.name = "VersionLabel"
	version_label.text = "v" + _get_version()
	version_label.add_theme_font_size_override("font_size", Style.fs(20))
	version_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	# 安全区适配：全面屏/刘海屏上避免被裁切
	var sa = DisplayServer.get_display_safe_area()
	var win = DisplayServer.window_get_size()
	var vp = get_viewport_rect().size
	var sx = (win.x / vp.x) if vp.x > 0 else 1.0
	var sy = (win.y / vp.y) if vp.y > 0 else 1.0
	version_label.position = Vector2(sa.position.x / sx + 12, sa.position.y / sy + 12)
	add_child(version_label)
	# 返回按钮：断开连接（若已连服务器）并回主面板
	j_back_btn.pressed.connect(func(): Network.disconnect_from_server(); _show_main())
	# 手机返回键：加入房间面板可见时回主面板（不退出游戏）
	BackHandler.main_menu_back = func() -> bool:
		if join_panel.visible:
			Network.disconnect_from_server()
			_show_main()
			return true
		return false
	j_join_btn.pressed.connect(_on_join)
	Network.connected_to_server.connect(_on_connected)
	Network.server_disconnected.connect(_on_disconnected)
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
	t.add_theme_font_size_override("font_size", Style.fs(30))
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
	dl_btn.add_theme_font_size_override("font_size", Style.fs(30))
	vb.add_child(dl_btn)
	var later_btn = Button.new()
	later_btn.name = "LaterBtn"
	later_btn.text = "稍后"
	later_btn.pressed.connect(func(): c.queue_free())
	later_btn.custom_minimum_size = Vector2(260, 90)
	later_btn.add_theme_font_size_override("font_size", Style.fs(30))
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
	btn.add_theme_font_size_override("font_size", Style.fs(26))
	if label == "本地":
		btn.pressed.connect(func(): input.text = "ws://127.0.0.1:17890")
	else:
		# 网页版必须走 wss 反代（HTTPS 页面禁止明文 ws）；APK 直连 17890
		if OS.has_feature("web"):
			btn.pressed.connect(func(): input.text = "wss://shiyaohu.xyz/ws")
		else:
			btn.pressed.connect(func(): input.text = "ws://47.107.47.251:17890")
	input.get_parent().add_child(btn)

func _show_join():
	main_panel.visible = false
	join_panel.visible = true

func _show_main():
	main_panel.visible = true
	join_panel.visible = false

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
func _on_disconnected():
	status_label.text = "断开连接"
	# 恢复加入面板：掉线后加入按钮复位、清除残留的准备按钮
	j_join_btn.visible = true
	for c in join_panel.get_children():
		if c is Button and "准备" in c.text:
			c.queue_free()

func _on_room_joined(room_id: String, _players: Array, mode: String):
	var mode_name = ModeData.get_mode(mode).get("name", "标准模式")
	status_label.text = "已加入房间 %s（%s）" % [room_id, mode_name]
	# 房间已加入：隐藏加入按钮，保留返回按钮（等待时可返回主界面，断开连接）
	j_join_btn.visible = false
	var btn = _make_ready_btn(join_panel, 560)
	btn.pressed.connect(func(): Network.ready_up(); btn.disabled = true; btn.text = "已准备")

func _make_ready_btn(parent: Control, y: float) -> Button:
	for c in parent.get_children():
		if c is Button and "准备" in c.text: c.queue_free()
	var btn = Button.new()
	btn.text = "准备开始"
	# 右侧按钮区（原加入按钮位置），左侧保留返回按钮不重叠
	btn.position = Vector2(400, y)
	btn.size = Vector2(320, 100)
	btn.add_theme_font_size_override("font_size", Style.fs(32))
	btn.add_theme_color_override("font_color", Style.READY_YELLOW)
	parent.add_child(btn)
	return btn

func _on_game_starting(data: Dictionary):
	if data.get("ffa", false):
		# 4 人混战：跳过 BP 直接进对战（初始 state 由服务器附带，独立场景布局）
		status_label.text = "4人混战开始！"
		Network.battle_state_cache = data.get("state", {})
		get_tree().change_scene_to_file("res://scenes/battle_scene.tscn")
		return
	status_label.text = "进入BP..."
	Network.bp_state_cache = data.get("bp_state", {})
	get_tree().change_scene_to_file("res://scenes/bp_scene.tscn")

# ---- 模式选择（创建房间 / 自我对战统一入口） ----
func _goto_mode_select(src: String):
	ModeSelectScript.source = src
	get_tree().change_scene_to_file("res://scenes/mode_select.tscn")

func _on_self_play():
	_goto_mode_select("self")

# ---- 多人对战（选择创建或加入） ----
func _on_multi_battle():
	var c = _make_popup("多人对战")
	var vb = c.get_child(1)
	var create = _popup_btn("创建房间")
	create.pressed.connect(func(): c.queue_free(); _goto_mode_select("create"))
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
	var fast = _popup_check("快速模式（无限出牌 · 冻结连续 · 天赐不限）")
	vb.add_child(fast)
	var easy = _popup_btn("简单")
	easy.pressed.connect(func(): c.queue_free(); LocalGame.rapid_mode = fast.button_pressed; _start_ai_bp(0))
	vb.add_child(easy)
	var normal = _popup_btn("普通")
	normal.pressed.connect(func(): c.queue_free(); LocalGame.rapid_mode = fast.button_pressed; _start_ai_bp(1))
	vb.add_child(normal)
	var hard = _popup_btn("困难")
	hard.pressed.connect(func(): c.queue_free(); LocalGame.rapid_mode = fast.button_pressed; _start_ai_bp(2))
	vb.add_child(hard)
	var hell = _popup_btn("地狱（内测）")
	hell.pressed.connect(func(): c.queue_free(); LocalGame.rapid_mode = fast.button_pressed; _start_ai_bp(3))
	vb.add_child(hell)
	var back = _popup_btn("返回")
	back.pressed.connect(func(): c.queue_free())
	vb.add_child(back)
	add_child(c)

# 弹窗开关（快速模式等）：勾选样式与弹窗按钮统一
func _popup_check(text: String) -> CheckButton:
	var cb := CheckButton.new()
	cb.text = text
	cb.add_theme_font_size_override("font_size", Style.fs(26))
	cb.add_theme_color_override("font_color", Color(0.9, 0.92, 0.95))
	return cb

# 新手教程：进入教程对局（TutorialManager 控制 9 步流程）
func _start_tutorial():
	LocalGame.start_tutorial()
	get_tree().change_scene_to_file("res://scenes/battle_scene.tscn")

# 人机对战：进入 BP 界面选角色（AI 自动禁选，新角色自动适配）
func _start_ai_bp(diff: int):
	LocalGame.start_ai_bp(diff)
	get_tree().change_scene_to_file("res://scenes/bp_scene.tscn")

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
	t.add_theme_font_size_override("font_size", Style.fs(32))
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(t)
	return c

func _popup_btn(text: String) -> Button:
	var b = Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(280, 80)
	b.add_theme_font_size_override("font_size", Style.fs(28))
	return b

func _on_error(msg: String):
	status_label.text = "错误: " + msg
	status_label.add_theme_color_override("font_color", Style.ERROR_RED)

func _exit_tree():
	# 场景卸载时清空回调，避免 BackHandler 调用已释放的 Callable
	BackHandler.main_menu_back = Callable()
