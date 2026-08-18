# mode_select.gd — 模式选择界面
# 独立场景：横向滑动选模式 + 下半区可滚动配置区。
# 来源 source（main_menu 跳转前设置）：
#   "create" = 创建房间流程（选完连服务器创建房间得房间号）
#   "self"   = 本地自我对战（选完直接本地开打，无房间号）
extends Control

const Style = preload("res://scripts/theme/style_const.gd")
const ModeData = preload("res://scripts/data/mode_data.gd")

# 来源（static var 跨场景保留，main_menu 跳转前赋值）
static var source := "self"

@onready var back_btn: Button = $BackBtn
@onready var title: Label = $Title
@onready var cards_scroll: ScrollContainer = $CardsScroll
@onready var cards_box: HBoxContainer = $CardsScroll/CardsBox
@onready var config_scroll: ScrollContainer = $ConfigScroll
@onready var config_box: VBoxContainer = $ConfigScroll/ConfigBox
@onready var action_btn: Button = $ActionBtn
@onready var status_label: Label = $StatusLabel

signal _connect_resolved(ok: bool)

# 当前选中的模式 id 与配置
var _selected_mode: String = ""
# 当前配置默认值（该模式预设 + 全局默认，不含玩家改动）
var _config_defaults: Dictionary = {}
# 当前配置实际值（默认 + 玩家改动）
var _config_values: Dictionary = {}
# 房间人数（2 .. 模式上限）
var _player_count: int = 2
# 配置行显示 Label 引用（key -> Label），刷新数值用
var _int_labels: Dictionary = {}
var _bool_checks: Dictionary = {}
var _players_label: Label
var _feature_label: Label
# create 流程的输入框
var _server_input: LineEdit
var _name_input: LineEdit
# 连接中标志（防止重复/超时后继续）
var _pending_connect: bool = false
var _waiting_room: bool = false  # 已创建房间、正在等待对手（掉线时需恢复配置界面）

func _ready():
	Style.scale_node_fonts(self)
	_apply_safe_area()
	title.text = "选择对战模式"
	action_btn.text = "创建房间" if source == "create" else "开始对战"
	back_btn.pressed.connect(_on_back)
	action_btn.pressed.connect(_on_action)
	# 返回键：左上角按钮 + 手机/ESC 返回（scene_back 单次即回主菜单）
	BackHandler.scene_back = func() -> bool:
		_on_back()
		return true
	# 创建流程：网络信号
	Network.connected_to_server.connect(_on_connect_ok)
	Network.network_error.connect(_on_connect_err)
	Network.room_created.connect(_on_room_created)
	Network.game_starting.connect(_on_game_starting)
	Network.server_disconnected.connect(_on_disconnected)
	_build_mode_cards()
	_select_mode("classic")

# 全面屏/刘海屏安全区适配：横屏时刘海/摄像头在左右两侧，
# 模式卡片区、配置区（房间设置：服务器/名称/人数）、返回按钮都要避开，避免被遮挡
func _apply_safe_area():
	var sa = DisplayServer.get_display_safe_area()
	var win = DisplayServer.window_get_size()
	var vp = get_viewport_rect().size
	if vp.x <= 0 or vp.y <= 0: return
	var sx = win.x / vp.x if vp.x > 0 else 1.0
	var left = sa.position.x / sx
	var right = (win.x - sa.end.x) / sx
	if left > 0:
		cards_scroll.offset_left = left
		config_scroll.offset_left = left
		back_btn.offset_left += left
		back_btn.offset_right += left
	if right > 0:
		cards_scroll.offset_right = -right
		config_scroll.offset_right = -right

func _exit_tree():
	BackHandler.scene_back = Callable()
	if Network.connected_to_server.is_connected(_on_connect_ok):
		Network.connected_to_server.disconnect(_on_connect_ok)
	if Network.network_error.is_connected(_on_connect_err):
		Network.network_error.disconnect(_on_connect_err)
	if Network.room_created.is_connected(_on_room_created):
		Network.room_created.disconnect(_on_room_created)
	if Network.game_starting.is_connected(_on_game_starting):
		Network.game_starting.disconnect(_on_game_starting)
	if Network.server_disconnected.is_connected(_on_disconnected):
		Network.server_disconnected.disconnect(_on_disconnected)

func _on_back():
	Network.disconnect_from_server()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

# ---------- 模式卡片 ----------
func _build_mode_cards():
	for c in cards_box.get_children():
		c.queue_free()
	for mode in ModeData.MODES:
		cards_box.add_child(_make_mode_card(mode))

func _make_mode_card(mode: Dictionary) -> Button:
	var btn := Button.new()
	btn.name = "Card_%s" % mode.id
	# flat=false 关键：flat=true 时 Godot 在 normal 状态不绘制样式盒，
	# 导致自定义的金色选中边框不显示（只看得见右上角角标）。样式盒已全量 override，无默认外观。
	btn.flat = false
	btn.custom_minimum_size = Vector2(Style.fs(460), Style.fs(300))
	# PASS：放行触摸拖动给 CardsScroll（横向滑动选模式）；Button 释放判定自带"拖出区域不触发"
	btn.mouse_filter = Control.MOUSE_FILTER_PASS
	btn.pressed.connect(_on_card_pressed.bind(mode.id))
	# 内容：名称 / 简介 / 规则要点 / 人数（VBox 铺满卡片，内边距）
	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = Style.fs(24)
	vb.offset_right = -Style.fs(24)
	vb.offset_top = Style.fs(20)
	vb.offset_bottom = -Style.fs(20)
	vb.add_theme_constant_override("separation", Style.fs(12))
	btn.add_child(vb)
	var name_lbl := Label.new()
	name_lbl.text = mode.name
	name_lbl.add_theme_font_size_override("font_size", Style.fs(40))
	name_lbl.add_theme_color_override("font_color", Style.MODE_TITLE)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(name_lbl)
	var desc_lbl := Label.new()
	desc_lbl.text = mode.desc
	desc_lbl.add_theme_font_size_override("font_size", Style.fs(26))
	desc_lbl.add_theme_color_override("font_color", Style.MODE_DESC)
	desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(desc_lbl)
	var feat_lbl := Label.new()
	feat_lbl.text = mode.features
	feat_lbl.add_theme_font_size_override("font_size", Style.fs(22))
	feat_lbl.add_theme_color_override("font_color", Style.MODE_FEATURE)
	feat_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	feat_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(feat_lbl)
	if mode.max_players > 0:
		var cnt_lbl := Label.new()
		cnt_lbl.text = "%d 人" % mode.max_players
		cnt_lbl.add_theme_font_size_override("font_size", Style.fs(24))
		cnt_lbl.add_theme_color_override("font_color", Style.CONFIG_LABEL)
		cnt_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(cnt_lbl)
	# 选中角标（右上角）：默认隐藏，选中时显示"✓ 已选择"
	var badge := Label.new()
	badge.name = "SelectedBadge"
	badge.text = "✓ 已选择"
	badge.visible = false
	badge.position = Vector2(Style.fs(316), 10)
	badge.add_theme_font_size_override("font_size", Style.fs(24))
	badge.add_theme_color_override("font_color", Style.MODE_SELECTED)
	btn.add_child(badge)
	_apply_card_style(btn, false, mode.selectable)
	return btn

func _apply_card_style(btn: Button, selected: bool, selectable: bool):
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(14)
	if not selectable:
		sb.bg_color = Style.MODE_CARD_BG.darkened(0.3)
		sb.border_color = Style.MODE_DISABLED
		sb.set_border_width_all(2)
	elif selected:
		# 选中态：金框相框效果——亮金粗边框 + 金色投影，背景暗化衬托金框更醒目
		sb.bg_color = Style.MODE_CARD_BG.darkened(0.08)
		sb.border_color = Style.WIN_GOLD
		sb.set_border_width_all(7)
		sb.shadow_color = Style.WIN_GOLD
		sb.shadow_size = 14
		sb.shadow_offset = Vector2(0, 2)
	else:
		sb.bg_color = Style.MODE_CARD_BG
		sb.border_color = Style.MODE_CARD_BORDER
		sb.set_border_width_all(2)
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", sb)
	btn.add_theme_stylebox_override("pressed", sb)
	btn.add_theme_stylebox_override("focus", sb)
	# 同步选中角标显隐
	var badge: Label = btn.get_node_or_null("SelectedBadge")
	if badge != null:
		badge.visible = selected

func _on_card_pressed(mode_id: String):
	if not ModeData.is_selectable(mode_id):
		_flash_status("该模式开发中，敬请期待", Style.MODE_DISABLED)
		return
	_select_mode(mode_id)

func _select_mode(mode_id: String):
	_selected_mode = mode_id
	status_label.text = ""  # 清除上一个模式的提示（如"该模式开发中"），避免切换后残留
	var mode = ModeData.get_mode(mode_id)
	_player_count = mode.max_players if mode.max_players > 0 else 2
	_config_defaults = ModeData.merge_config(mode_id)
	_config_values = _config_defaults.duplicate()
	# 刷新卡片选中态
	for i in range(ModeData.MODES.size()):
		var m = ModeData.MODES[i]
		var card = cards_box.get_child(i) if i < cards_box.get_child_count() else null
		if card != null:
			_apply_card_style(card, m.id == mode_id, m.selectable)
	_rebuild_config()

# ---------- 配置区 ----------
func _rebuild_config():
	for c in config_box.get_children():
		c.queue_free()
	_int_labels.clear()
	_bool_checks.clear()
	# 模式信息行（默认显示模式名，改规则后变「自定义模式」）
	_feature_label = _lbl("", Style.MODE_FEATURE, Style.fs(22))
	config_box.add_child(_feature_label)
	# create 流程：服务器地址 + 玩家名称
	if source == "create":
		config_box.add_child(_make_server_row())
		config_box.add_child(_make_name_row())
	# 房间人数
	config_box.add_child(_make_players_row())
	# 规则开关
	for schema in ModeData.CONFIG_SCHEMA:
		if schema.type == "bool":
			config_box.add_child(_make_bool_row(schema))
		else:
			config_box.add_child(_make_int_row(schema))
	_refresh_config_rows()
	_refresh_mode_label()

func _make_server_row() -> HBoxContainer:
	var row := _row()
	row.add_child(_row_label("服务器"))
	_server_input = LineEdit.new()
	_server_input.text = "ws://47.107.47.251:17890"
	_server_input.custom_minimum_size = Vector2(Style.fs(460), Style.fs(56))
	_server_input.add_theme_font_size_override("font_size", Style.fs(24))
	row.add_child(_server_input)
	var local_btn := _small_btn("本地")
	local_btn.pressed.connect(func(): _server_input.text = "ws://127.0.0.1:17890")
	row.add_child(local_btn)
	var cloud_btn := _small_btn("云端")
	if OS.has_feature("web"):
		cloud_btn.pressed.connect(func(): _server_input.text = "wss://shiyaohu.xyz/ws")
	else:
		cloud_btn.pressed.connect(func(): _server_input.text = "ws://47.107.47.251:17890")
	row.add_child(cloud_btn)
	return row

func _make_name_row() -> HBoxContainer:
	var row := _row()
	row.add_child(_row_label("玩家名称"))
	_name_input = LineEdit.new()
	_name_input.text = "Player1"
	_name_input.custom_minimum_size = Vector2(Style.fs(300), Style.fs(56))
	_name_input.add_theme_font_size_override("font_size", Style.fs(24))
	row.add_child(_name_input)
	return row

func _make_players_row() -> HBoxContainer:
	var row := _row()
	row.add_child(_row_label("房间人数"))
	var mode = ModeData.get_mode(_selected_mode)
	var upper = mode.max_players if mode.max_players > 0 else 2
	var min_btn := _small_btn("−")
	min_btn.pressed.connect(func():
		if _player_count > 2:
			_player_count -= 1
			_refresh_config_rows()
			_refresh_mode_label()
	)
	row.add_child(min_btn)
	_players_label = _lbl("%d 人" % _player_count, Style.CONFIG_VALUE, Style.fs(26))
	_players_label.custom_minimum_size = Vector2(Style.fs(110), 0)
	_players_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(_players_label)
	var plus_btn := _small_btn("+")
	plus_btn.pressed.connect(func():
		if _player_count < upper:
			_player_count += 1
			_refresh_config_rows()
			_refresh_mode_label()
	)
	row.add_child(plus_btn)
	if upper <= 2:
		min_btn.disabled = true
		plus_btn.disabled = true
	return row

func _make_int_row(schema: Dictionary) -> HBoxContainer:
	var row := _row()
	row.add_child(_row_label(schema.label))
	var min_btn := _small_btn("−")
	min_btn.pressed.connect(func(): _int_step(schema, -1))
	row.add_child(min_btn)
	var val_lbl := _lbl("", Style.CONFIG_VALUE, Style.fs(26))
	val_lbl.custom_minimum_size = Vector2(Style.fs(110), 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(val_lbl)
	_int_labels[schema.key] = val_lbl
	var plus_btn := _small_btn("+")
	plus_btn.pressed.connect(func(): _int_step(schema, 1))
	row.add_child(plus_btn)
	return row

func _make_bool_row(schema: Dictionary) -> HBoxContainer:
	var row := _row()
	row.add_child(_row_label(schema.label))
	var cb := CheckButton.new()
	cb.add_theme_font_size_override("font_size", Style.fs(24))
	cb.add_theme_color_override("font_color", Color(0.9, 0.92, 0.95))
	cb.button_pressed = bool(_config_values.get(schema.key, false))
	cb.text = "开" if cb.button_pressed else "关"
	cb.toggled.connect(func(on: bool):
		_config_values[schema.key] = on
		cb.text = "开" if on else "关"
		_refresh_mode_label()
	)
	row.add_child(cb)
	_bool_checks[schema.key] = cb
	return row

func _row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Style.fs(14))
	row.custom_minimum_size = Vector2(0, Style.fs(56))
	return row

func _row_label(text: String) -> Label:
	var l := _lbl(text, Style.CONFIG_LABEL, Style.fs(26))
	l.custom_minimum_size = Vector2(Style.fs(200), 0)
	return l

func _lbl(text: String, color: Color, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _small_btn(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(Style.fs(56), Style.fs(56))
	b.add_theme_font_size_override("font_size", Style.fs(26))
	return b

# int 行加减：带 default_label 的项在「默认值」与 [min,max] 之间切换，其余正常加减
func _int_step(schema: Dictionary, delta: int):
	var key = schema.key
	var v = int(_config_values.get(key, 0))
	var d = int(_config_defaults.get(key, 0))
	var has_label = schema.has("default_label") and str(schema.default_label) != ""
	if delta > 0:
		if has_label and v == d and d < schema.min:
			_config_values[key] = schema.min
		else:
			_config_values[key] = min(v + 1, schema.max)
	else:
		if has_label and v == schema.min:
			_config_values[key] = d
		else:
			_config_values[key] = max(v - 1, schema.min)
	_refresh_config_rows()
	_refresh_mode_label()

func _int_display(schema: Dictionary) -> String:
	var key = schema.key
	var v = int(_config_values.get(key, 0))
	var d = int(_config_defaults.get(key, 0))
	if schema.has("default_label") and str(schema.default_label) != "" and v == d:
		return str(schema.default_label)
	return str(v)

func _refresh_config_rows():
	if _players_label != null:
		_players_label.text = "%d 人" % _player_count
	for schema in ModeData.CONFIG_SCHEMA:
		if schema.type == "int" and _int_labels.has(schema.key):
			_int_labels[schema.key].text = _int_display(schema)
		elif schema.type == "bool" and _bool_checks.has(schema.key):
			_bool_checks[schema.key].button_pressed = bool(_config_values.get(schema.key, false))

# 当前配置是否偏离选中模式默认（房间人数或任一规则被改动即视为「自定义」）
func _is_customized() -> bool:
	var mode = ModeData.get_mode(_selected_mode)
	var default_count = mode.max_players if mode.max_players > 0 else 2
	if _player_count != default_count:
		return true
	for key in _config_values:
		if _config_values[key] != _config_defaults.get(key):
			return true
	return false

# 更新模式信息行：默认显示「模式名 · 规则要点」，改动后显示「自定义模式（基于模式名）」
func _refresh_mode_label():
	if _feature_label == null:
		return
	var mode = ModeData.get_mode(_selected_mode)
	if _is_customized():
		_feature_label.text = "自定义模式（基于%s）· %s" % [mode.name, mode.features]
		_feature_label.add_theme_color_override("font_color", Style.MODE_SELECTED)
	else:
		_feature_label.text = "%s · %s" % [mode.name, mode.features]
		_feature_label.add_theme_color_override("font_color", Style.MODE_FEATURE)

# ---------- 主操作 ----------
func _on_action():
	if _selected_mode == "" or not ModeData.is_selectable(_selected_mode):
		_flash_status("请选择模式", Style.ERROR_RED)
		return
	if source == "create":
		_do_create_room()
	else:
		_do_start_local()

func _final_config() -> Dictionary:
	return _config_values.duplicate()

func _do_create_room():
	action_btn.disabled = true
	# 已连接（如输错房间号重试场景）：跳过连接流程直接创建，避免 await 信号挂起
	if Network.get_connected():
		status_label.text = "已连接，创建房间..."
		var pname = _name_input.text.strip_edges()
		if pname == "":
			pname = "Player1"
		Network.create_room(pname, _selected_mode, _player_count, _final_config())
		return
	status_label.text = "正在连接..."
	_pending_connect = true
	var tw := get_tree().create_timer(12.0)
	tw.timeout.connect(func():
		if _pending_connect:
			_pending_connect = false
			_connect_resolved.emit(false)
	)
	Network.connect_to_server(_server_input.text.strip_edges())
	var ok: bool = await _connect_resolved
	if not ok:
		action_btn.disabled = false
		if status_label.text == "正在连接...":
			_flash_status("连接失败或超时，请检查网络", Style.ERROR_RED)
		return
	status_label.text = "已连接，创建房间..."
	var pname = _name_input.text.strip_edges()
	if pname == "":
		pname = "Player1"
	Network.create_room(pname, _selected_mode, _player_count, _final_config())

func _do_start_local():
	var mode = _selected_mode
	if mode == "ffa":
		LocalGame.rapid_mode = false
		LocalGame.start_local_game_multi(_random_chars(4))
		get_tree().change_scene_to_file("res://scenes/battle_scene.tscn")
	elif mode == "custom_deck":
		# 自定义卡组：BP 选完角色后进入「配置卡组」环节（deck_pick 场景），再开战
		LocalGame.rapid_mode = false
		LocalGame.deck_mode = true
		LocalGame.start_bp()
		get_tree().change_scene_to_file("res://scenes/bp_scene.tscn")
	else:
		LocalGame.rapid_mode = (mode == "rapid")
		LocalGame.start_bp()
		get_tree().change_scene_to_file("res://scenes/bp_scene.tscn")

func _random_chars(n: int) -> Array:
	var ids = Config.CHARACTER_IDS.duplicate()
	ids.shuffle()
	return ids.slice(0, n)

# ---------- 网络回调 ----------
func _on_connect_ok():
	if _pending_connect:
		_pending_connect = false
		_connect_resolved.emit(true)

func _on_connect_err(msg: String):
	if _pending_connect:
		_pending_connect = false
		_connect_resolved.emit(false)
	else:
		# 非连接阶段的错误（如服务端通知「对手已离开房间」）：显示并恢复界面
		if _waiting_room:
			_restore_from_waiting(msg)
		else:
			status_label.text = msg

func _on_room_created(room_id: String, _mode: String):
	_waiting_room = true
	status_label.text = "房间号: %s  （%s）\n等待对手加入..." % [room_id, ModeData.get_mode(_selected_mode).name]
	status_label.add_theme_color_override("font_color", Style.ME_GREEN)
	# 隐藏配置/卡片，显示准备按钮
	for c in config_box.get_children():
		c.visible = false
	action_btn.text = "准备开始"
	action_btn.disabled = false
	action_btn.pressed.disconnect(_on_action)
	action_btn.pressed.connect(_on_ready)

func _on_ready():
	action_btn.disabled = true
	action_btn.text = "已准备"
	Network.ready_up()

func _on_game_starting(data: Dictionary):
	if data.get("ffa", false):
		status_label.text = "4人混战开始！"
		Network.battle_state_cache = data.get("state", {})
		get_tree().change_scene_to_file("res://scenes/battle_scene.tscn")
	else:
		status_label.text = "进入BP..."
		Network.bp_state_cache = data.get("bp_state", {})
		get_tree().change_scene_to_file("res://scenes/bp_scene.tscn")

func _on_disconnected():
	if not is_instance_valid(self) or status_label == null:
		return
	if _waiting_room:
		_restore_from_waiting("连接断开")
	else:
		status_label.text = "已断开连接"

# 等待房间时掉线/对手离开：恢复配置界面（否则界面僵死在等待态）
func _restore_from_waiting(msg: String):
	_waiting_room = false
	status_label.text = msg
	status_label.add_theme_color_override("font_color", Style.ERROR_RED)
	for c in config_box.get_children():
		c.visible = true
	action_btn.text = "开始对战"
	action_btn.disabled = false
	if action_btn.pressed.is_connected(_on_ready):
		action_btn.pressed.disconnect(_on_ready)
	action_btn.pressed.connect(_on_action)

# ---------- 工具 ----------
func _flash_status(text: String, color: Color):
	status_label.text = text
	status_label.add_theme_color_override("font_color", color)
