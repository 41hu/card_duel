# battle_ui.gd — 对战界面
extends Control

const Style = preload("res://scripts/theme/style_const.gd")
const CardWidget = preload("res://scripts/ui/components/card_widget.gd")
const MapGeometry = preload("res://scripts/core/map_geometry.gd")
const InfoPanel = preload("res://scripts/ui/components/info_panel.gd")
const ItemSys = preload("res://scripts/core/item_system.gd")
const DragScroll = preload("res://scripts/ui/components/drag_scroll.gd")

@onready var phase_label = $PhaseLabel
@onready var hand_area = $HandScroll/HandArea
@onready var end_turn_btn = $EndTurnBtn
@onready var confirm_btn = $ConfirmBtn
@onready var cancel_btn = $CancelBtn
@onready var status_label = $StatusLabel
@onready var board = $Board
@onready var action_log = $ActionLog

var _game_state: Dictionary = {}
var _player_index: int = -1
var _is_my_turn: bool = false
var _selected_uid: int = -1
var _selected_type: String = ""
var _hunter_pos1: Dictionary = {}  # 猎人埋伏（穿心）：第 1 个放置位置（{x,y}），空=未选
var _discard_selected: Array = []
@onready var card_info = $CardInfo
@onready var skill_row = $SkillRow
var _last_hp: Array = [-1, -1]
var _last_turn: int = -1
var _turn_notice: Label
var _turn_notice_tween: Tween

func _turn_owner_text() -> String:
	var current := int(_game_state.get("current_player", -1))
	for player in _game_state.get("players", []):
		if int(player.index) == current:
			return "你的回合" if current == _player_index else "P%d %s的回合" % [current + 1, player.get("char_name", "")]
	return "等待回合"

func _show_turn_notice():
	if _turn_notice == null:
		_turn_notice = Label.new()
		_turn_notice.name = "TurnNotice"
		_turn_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_turn_notice.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
		_turn_notice.anchor_left = 0.22
		_turn_notice.anchor_right = 0.66
		_turn_notice.offset_top = 106
		_turn_notice.offset_bottom = 190
		_turn_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_turn_notice.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_turn_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_turn_notice.add_theme_font_size_override("font_size", 34)
		_turn_notice.z_index = 20
		var background := StyleBoxFlat.new()
		background.bg_color = Color(0.06, 0.08, 0.12, 0.94)
		background.border_color = Color(0.5, 0.8, 1)
		background.border_width_bottom = 3
		_turn_notice.add_theme_stylebox_override("normal", background)
		add_child(_turn_notice)
	if _turn_notice_tween != null: _turn_notice_tween.kill()
	_turn_notice.text = "第 %d 回合 · %s" % [_game_state.get("turn_number", 1), _turn_owner_text()]
	_turn_notice.add_theme_color_override("font_color", Color(0.5, 0.85, 1) if int(_game_state.current_player) == _player_index else Color(1, 0.75, 0.5))
	_turn_notice.modulate.a = 1
	_turn_notice.show()
	_turn_notice_tween = create_tween()
	_turn_notice_tween.tween_interval(1.6)
	_turn_notice_tween.tween_property(_turn_notice, "modulate:a", 0.0, 0.3)
	_turn_notice_tween.tween_callback(_turn_notice.hide)
var _last_player: int = -1
var _board_hex: bool = false  # 棋盘当前是否六边形模式（多人局）
# 数据驱动玩家面板：自己面板（左下）+ 对手面板（右侧竖排，数量随玩家数动态增减）
# 彻底消除 me_info/opp_info 二元假设，2 人 / 4 人 / 未来 N 人统一走同一套渲染
var _self_panel: PanelContainer = null
var _opp_panels: Array = []
var _opp_indices: Array = []  # 与 _opp_panels 平行：每个面板对应的玩家 index（HP 闪烁/安全区定位用）
var _opp_scroll: ScrollContainer
var _opp_box: VBoxContainer
var _transient_popups: Array = []
var _transport: Node
var _cheat_on: bool = false
var _timer_left: int = -1
var _resp_popup: Control
var tutorial = null  # 教程控制器（新手教程模式时非空）
var _wpn_popup: Control
var _staged_extra: Dictionary = {}
var _pick_mode := ""
var _submitting := false
var _selected_cell := Vector2i(-999, -999)

func _n():
	if LocalGame.game != null: return LocalGame
	return Network

# ---------- 数据驱动：玩家查找（消除 players[0]/[1] 二元假设） ----------
# 从给定列表（默认 _game_state.players）找自己；找不到返回空字典。
# 关键：不再假设只有 2 个玩家，多人局（4 人）任意 index 都能正确命中。
func _find_self(pls: Array = []) -> Dictionary:
	if pls.is_empty():
		pls = _game_state.get("players", [])
	for p in pls:
		if p.get("index", -1) == _player_index:
			return p
	return {}

# 从给定列表找第一个对手（2 人局=唯一对手；多人局取第一个，用于单目标场景）
func _find_opponent(pls: Array = []) -> Dictionary:
	if pls.is_empty():
		pls = _game_state.get("players", [])
	for p in pls:
		if p.get("index", -1) != _player_index:
			return p
	return {}

func _ready():
	phase_label.offset_left = -590
	phase_label.offset_right = 380
	phase_label.add_theme_font_size_override("font_size", 32)
	phase_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Style.scale_node_fonts(self)  # 移动端字号适配（tscn 写死的字号）
	board.cell_clicked.connect(_on_board_cell_clicked)
	board.cell_long_pressed.connect(_on_cell_long_pressed)  # 长按查看地格道具
	board.cell_released.connect(_on_cell_released)  # 松手隐藏道具悬浮框
	_create_self_panel()
	_opp_scroll = DragScroll.new()
	_opp_scroll.name = "OpponentScroll"
	_opp_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_opp_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_opp_scroll.anchor_left = 1.0
	_opp_scroll.offset_top = 110
	_opp_scroll.offset_bottom = -340
	add_child(_opp_scroll)
	_opp_box = VBoxContainer.new()
	_opp_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_opp_box.add_theme_constant_override("separation", 8)
	_opp_scroll.add_child(_opp_box)
	_build_popups()
	_build_skill_focus()
	_transport = _n()
	BackHandler.scene_back = _handle_back
	resized.connect(_apply_safe_area)
	card_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card_info.offset_left = -440; card_info.offset_right = 440
	card_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 日志加宽后左缘与棋盘第 0/1 格有重叠：PASS 让点按穿透到棋盘，
	# 拖动仍由 ScrollContainer 先处理（发生滚动时 accept，否则继续下传）
	action_log.mouse_filter = Control.MOUSE_FILTER_PASS
	end_turn_btn.pressed.connect(_on_end_turn)
	confirm_btn.pressed.connect(_on_confirm_card)
	cancel_btn.pressed.connect(_on_cancel_select)
	hand_area.card_clicked.connect(_on_card_clicked)
	hand_area.card_details.connect(_on_card_details)
	hand_area.empty_clicked.connect(_on_cancel_select)
	$Bg.gui_input.connect(_on_background_input)
	_n().state_updated.connect(_on_state_updated)
	_n().response_needed.connect(_on_response_needed)
	_n().hand_revealed.connect(_on_hand_revealed)
	_n().weapon_prompt.connect(_on_weapon_prompt)
	_n().wind_bow_prompt.connect(_on_wind_bow_prompt)
	_n().game_ended.connect(_on_game_ended)
	_n().network_error.connect(_on_error)
	Network.server_disconnected.connect(_on_server_disconnected)
	var cached = _n().battle_state_cache
	if not cached.is_empty():
		_on_state_updated(cached)
		_n().battle_state_cache = {}
	_apply_safe_area()
	_setup_debug_button()
	# 新手教程模式：创建教程控制器（步骤引导/脚本对手/操作限制）
	if LocalGame.tutorial_mode:
		var tm = load("res://scripts/ui/tutorial_manager.gd").new()
		tm.battle = self
		tm.g = LocalGame.game
		add_child(tm)
		tutorial = tm

func _exit_tree():
	if BackHandler.scene_back == _handle_back: BackHandler.scene_back = Callable()
	# 与其它场景风格对齐：显式断开全部信号，防未来节点复用累积重复连接
	var n = _transport
	if not is_instance_valid(n): return
	if n.state_updated.is_connected(_on_state_updated):
		n.state_updated.disconnect(_on_state_updated)
	if n.response_needed.is_connected(_on_response_needed):
		n.response_needed.disconnect(_on_response_needed)
	if n.hand_revealed.is_connected(_on_hand_revealed):
		n.hand_revealed.disconnect(_on_hand_revealed)
	if n.weapon_prompt.is_connected(_on_weapon_prompt):
		n.weapon_prompt.disconnect(_on_weapon_prompt)
	if n.wind_bow_prompt.is_connected(_on_wind_bow_prompt):
		n.wind_bow_prompt.disconnect(_on_wind_bow_prompt)
	if n.game_ended.is_connected(_on_game_ended):
		n.game_ended.disconnect(_on_game_ended)
	if n.network_error.is_connected(_on_error):
		n.network_error.disconnect(_on_error)
	if Network.server_disconnected.is_connected(_on_server_disconnected):
		Network.server_disconnected.disconnect(_on_server_disconnected)
	# 教程控制器随场景释放（其引导横幅/跳过按钮已挂在本节点下）

func _handle_back() -> bool:
	for i in range(_transient_popups.size() - 1, -1, -1):
		var popup = _transient_popups[i]
		if not is_instance_valid(popup) or popup.is_queued_for_deletion() or not popup.visible: continue
		if popup.name == "SwordsmanPopup": return false
		popup.hide()
		popup.queue_free()
		if popup.name == "WindBowPopup": _n().send_wind_bow_move({}, true)
		return true
	if _selected_uid != -1:
		_on_cancel_select()
		return true
	return false

# 自己面板（左下角，动态创建，替代原场景 MeInfo 固定节点）
func _create_self_panel():
	var pc: PanelContainer = InfoPanel.new()
	pc.anchor_left = 0.0
	pc.anchor_top = 1.0
	pc.anchor_bottom = 1.0
	pc.offset_left = 16
	pc.offset_top = -220
	pc.offset_right = 594
	pc.offset_bottom = -20
	pc.grow_vertical = Control.GROW_DIRECTION_BEGIN
	pc.status_clicked.connect(_on_status_clicked)
	add_child(pc)
	_self_panel = pc

# 调试菜单按钮（仅编辑器运行时显示，导出到真机不显示）：快速结束对局/发牌
func _setup_debug_button():
	if not OS.has_feature("editor"): return
	var dbg = Button.new()
	dbg.name = "DebugBtn"
	dbg.text = "调试"
	dbg.position = Vector2(12, 12)
	dbg.size = Vector2(140, 70)
	dbg.add_theme_font_size_override("font_size", Style.fs(26))
	dbg.pressed.connect(_show_debug_menu)
	add_child(dbg)

func _show_debug_menu():
	var c = Control.new()
	c.name = "DebugMenu"
	c.z_index = 15
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new()
	bg.name = "DebugBg"
	bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(bg)
	var vb = _popup_box(c, 480, 420)
	vb.name = "DebugBox"
	vb.add_child(_lbl("调试菜单"))
	var win = _mkbtn("立即胜利")
	win.name = "DebugWinBtn"
	win.pressed.connect(func():
		c.queue_free()
		_n().send_use_skill("_debug_end", {"win": true})
	)
	vb.add_child(win)
	var lose = _mkbtn("立即失败")
	lose.name = "DebugLoseBtn"
	lose.pressed.connect(func():
		c.queue_free()
		_n().send_use_skill("_debug_end", {"win": false})
	)
	vb.add_child(lose)
	var deal = _mkbtn("随机发5张牌")
	deal.name = "DebugDealBtn"
	deal.pressed.connect(func():
		c.queue_free()
		var keys = Config.CARD_DB.keys()
		for i in range(5):
			_n().send_use_skill("_cheat", {"type_id": keys[randi() % keys.size()]})
	)
	vb.add_child(deal)
	var close = _mkbtn("关闭")
	close.name = "DebugCloseBtn"
	close.pressed.connect(func(): c.queue_free())
	vb.add_child(close)
	add_child(c)

# 全面屏/刘海屏安全区适配：横屏时刘海在左右两侧，给角落信息留出边距。
# 注意：对手面板是运行时动态创建的（人数变化会重建），安全区偏移存成成员变量，
# _make_opp_panel 创建时直接带上——只在 _apply_safe_area 里遍历一次会导致
# 联机局（首次渲染时面板尚未创建）新建面板不带安全区，被刘海裁切。
# 偏移量 clamp 到 [32, 100]：下限 32 覆盖全面屏圆角（横屏时右上/右下角圆角会切贴边面板，
# 即使刘海在左、safe area 右值为 0 也要内缩）；上限 100 防部分设备 safe area 报告异常值把面板推飞。
var _safe_right: float = 32.0
var _safe_bottom: float = 0.0  # 底部不安全区（self_panel 每次刷新按此上移，防手势条/圆角裁切）

func _apply_safe_area():
	var sa = DisplayServer.get_display_safe_area()
	var win = DisplayServer.window_get_size()
	var vp = get_viewport_rect().size
	if vp.x <= 0 or vp.y <= 0 or _self_panel == null: return
	if win.x <= 0 or win.y <= 0: win = Vector2i(vp)
	if not OS.has_feature("android") and not OS.has_feature("ios"):
		sa = Rect2i(Vector2i.ZERO, win)
	var sx = win.x / vp.x
	var sy = win.y / vp.y
	var left = sa.position.x / sx
	var right = (win.x - sa.end.x) / sx
	var _top = sa.position.y / sy
	var bottom = (win.y - sa.end.y) / sy
	# 敌方面板统一按右侧不安全区 clamp 内缩（最小 32 避开圆角，上限 100 防异常值）
	_safe_right = clampf(right, 32.0, 100.0)
	_safe_bottom = clampf(bottom, 0.0, 100.0)
	# 我方面板（左下）：左缘与底缘始终内缩——clamp 下限 32 覆盖全面屏圆角/刘海，
	# 避免 buff/装备行贴边被裁切（与敌方面板对称处理；刘海时再多 12 间距）
	var safe_left = clampf(left, 32.0, 100.0) + 12.0
	_self_panel.offset_left = safe_left
	action_log.offset_left = safe_left
	action_log.offset_right = safe_left + 312
	skill_row.offset_left = -400 - _safe_right
	skill_row.offset_right = -_safe_right
	skill_row.offset_top = -320 - _safe_bottom
	skill_row.offset_bottom = -230 - _safe_bottom
	end_turn_btn.offset_left = -400 - _safe_right
	end_turn_btn.offset_right = -_safe_right
	end_turn_btn.offset_top = -130 - _safe_bottom
	end_turn_btn.offset_bottom = -20 - _safe_bottom
	_opp_scroll.offset_left = -560 - _safe_right
	_opp_scroll.offset_right = -_safe_right
	_opp_scroll.offset_bottom = -432 - _safe_bottom
	$HandScroll.anchor_left = 0.0
	$HandScroll.anchor_right = 0.0
	$HandScroll.offset_left = 610
	$HandScroll.offset_right = vp.x - 416 - _safe_right
	$HandScroll.offset_top = -412 - _safe_bottom
	$HandScroll.offset_bottom = -20 - _safe_bottom
	for button in [confirm_btn, cancel_btn]:
		button.add_theme_font_size_override("font_size", 30)
		button.anchor_left = 1.0
		button.anchor_right = 1.0
		button.offset_top = -212 - _safe_bottom
		button.offset_bottom = -142 - _safe_bottom
	confirm_btn.offset_left = -400 - _safe_right
	confirm_btn.offset_right = -116 - _safe_right
	cancel_btn.offset_left = -104 - _safe_right
	cancel_btn.offset_right = -_safe_right
	status_label.anchor_left = 1.0
	status_label.anchor_right = 1.0
	status_label.offset_left = -400 - _safe_right
	status_label.offset_right = -_safe_right
	status_label.offset_top = -416 - _safe_bottom
	status_label.offset_bottom = -328 - _safe_bottom
	status_label.add_theme_font_size_override("font_size", 22)
	_layout_self_panel.call_deferred()
	_layout_skill_focus()

func _layout_self_panel():
	if not is_inside_tree() or _self_panel == null: return
	var self_w = 594.0 - _self_panel.offset_left
	var height = maxf(160.0, _self_panel.content_height(self_w))
	_self_panel.offset_top = -height - 20.0 - _safe_bottom
	_self_panel.offset_bottom = -20.0 - _safe_bottom
	action_log.anchor_bottom = 1.0
	action_log.offset_bottom = _self_panel.offset_top - 12.0

func _input(event):
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _handle_back(): get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		if _handle_back(): get_viewport().set_input_as_handled()
		return
	if not OS.has_feature("editor"): return  # F12 作弊仅在编辑器运行时有效
	if not event is InputEventKey or not event.pressed: return
	if event.keycode == KEY_F12: _cheat_on = not _cheat_on; return
	if not _cheat_on or not _is_my_turn: return
	var cheat = {KEY_F1: "near", KEY_F2: "range", KEY_F3: "magic", KEY_F4: "heavy", KEY_F5: "range_weapon", KEY_F6: "magic_weapon", KEY_F7: "move", KEY_F8: "blessing", KEY_F9: "heal_3", KEY_F10: "near_weapon"}
	if event.keycode in cheat:
		_n().send_use_skill("_cheat", {"type_id": cheat[event.keycode]})

# 状态槽/角色名/装备点击（移动端无 hover）：详情显示到状态栏，3 秒自动消失
func _on_status_clicked(text: String):
	if text.is_empty(): return
	var old = get_node_or_null("StatusDetailPopup")
	if old != null:
		remove_child(old)
		old.queue_free()
	var c = Control.new()
	c.name = "StatusDetailPopup"
	c.z_index = 12
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new()
	bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(bg)
	var vb = _popup_box(c, 960, 680)
	vb.add_child(_lbl(text))
	var close = _mkbtn("关闭")
	close.pressed.connect(c.queue_free)
	vb.add_child(close)
	add_child(c)

func _on_cancel_select():
	var was_skill_pick := not _skill_pick.is_empty()
	if not _skill_pick.is_empty(): _restore_material_cards()
	_skill_pick = ""
	_skill_params.clear()
	_hide_skill_focus()
	hand_area.set_skill_selection(false)
	status_label.remove_theme_color_override("font_color")
	if was_skill_pick: _refresh_skill_row(_find_self())
	_pick_mode = ""
	_staged_extra.clear()
	_selected_cell = Vector2i(-999, -999)
	board.set_targets([])
	hand_area.clear_focus()
	_selected_uid = -1
	_selected_type = ""  # 清类型：残留会导致点棋盘误发 play_card（"手牌中没有此卡"）
	_discard_selected.clear()
	confirm_btn.visible = false
	cancel_btn.visible = false
	card_info.text = ""
	_hunter_pos1.clear()
	_skip_root_choice = false
	_status_msg_timer = 0.0
	status_label.text = ""
	_refresh_highlight()
	if _is_my_turn and _game_state.get("waiting_for_discard", false):
		for card in hand_area.cards: card.set_discard_mark(false)
		_show_discard_focus(_find_self())

func _build_popups():
	_resp_popup = _make_resp_popup()
	_wpn_popup = _make_wpn_popup()

func _make_resp_popup() -> Control:
	var c = Control.new()
	c.visible = false; c.z_index = 10; c.name = "RespPopupRoot"
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new()
	bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(bg)
	add_child(c)
	return c

func _show_resp_popup(atk_card: String, dmg: int = 0):
	var root = _resp_popup
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in root.get_children():
		root.remove_child(child)
		child.queue_free()
	var panel := PanelContainer.new()
	panel.position = Vector2(610, 130)
	panel.size = Vector2(maxf(500, size.x - 1250), 180)
	root.add_child(panel)
	var content := VBoxContainer.new()
	panel.add_child(content)
	var attack_name := "真言" if atk_card == "priest_chant" else Config.card_name(atk_card)
	var segment := ""
	if int(_game_state.get("pending_attack_segments", 1)) > 1:
		segment = " 第%d/%d段" % [_game_state.get("pending_attack_segment", 1), _game_state.pending_attack_segments]
	content.add_child(_lbl("响应：%s%s%s" % [attack_name, segment, " 伤害%d" % dmg if dmg > 0 else ""]))
	if tutorial == null or not tutorial.force_response():
		var skip = _mkbtn("不响应")
		skip.pressed.connect(func(): _submit_response(false))
		content.add_child(skip)
	root.visible = true
func _make_wpn_popup() -> Control:
	var c = Control.new()
	c.name = "WpnPopupRoot"
	c.visible = false; c.z_index = 10
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new()
	bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(bg)
	add_child(c)
	var box = _box(c, 200, 160, 640, 320)
	var t = _lbl("获得武器！")
	t.name = "WpnTitle"
	box.add_child(t)
	var d = _lbl("")
	d.name = "WpnDesc"
	d.add_theme_color_override("font_color", Style.HAND_TITLE)
	box.add_child(d)
	var hb = HBoxContainer.new()
	box.add_child(hb)
	var eb = _mkbtn("装备")
	eb.pressed.connect(func(): c.visible = false; _n().send_weapon_choice(true))
	hb.add_child(eb)
	var db = _mkbtn("丢弃")
	db.pressed.connect(func(): c.visible = false; _n().send_weapon_choice(false))
	hb.add_child(db)
	return c

func _box(parent: Control, _x: float, _y: float, w: float, h: float) -> VBoxContainer:
	# _x/_y 已废弃（原实现未使用），统一走滚动弹窗框架
	return _popup_box(parent, w, h)

func _popup_box(parent: Control, w: float, h: float) -> VBoxContainer:
	if parent.name not in ["RespPopupRoot", "WpnPopupRoot"]:
		_transient_popups.append(parent)
	# 居中滚动弹窗：内容超出时滚动，最大占屏幕 92%，适配手机小屏
	var vp = get_viewport_rect().size
	w = min(w, vp.x * 0.92)
	h = min(h, vp.y * 0.92)
	var sc = DragScroll.new()
	sc.name = "PopupScroll"
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.08, 0.1, 0.14, 0.98)
	panel.set_content_margin_all(16)
	panel.set_corner_radius_all(8)
	sc.add_theme_stylebox_override("panel", panel)
	sc.layout_mode = 1
	sc.anchor_left = 0.5; sc.anchor_right = 0.5
	sc.anchor_top = 0.5; sc.anchor_bottom = 0.5
	sc.offset_left = -w / 2.0; sc.offset_right = w / 2.0
	sc.offset_top = -h / 2.0; sc.offset_bottom = h / 2.0
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.get_v_scroll_bar().custom_minimum_size = Vector2(24, 0)
	parent.add_child(sc)
	var vb = VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(vb)
	return vb

func _flash(node: Control):
	var tw = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_property(node, "scale", Vector2(1.15, 1.15), 0.15)
	tw.tween_property(node, "scale", Vector2.ONE, 0.3)

func _lbl(txt: String) -> Label:
	var l = Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.text = txt
	l.add_theme_color_override("font_color", Style.LOG_TEXT)
	l.add_theme_font_size_override("font_size", Style.fs(28))
	return l

func _mkbtn(txt: String) -> Button:
	var b = Button.new()
	b.text = txt
	b.custom_minimum_size = Vector2(220, 100)
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.add_theme_font_size_override("font_size", Style.fs(32))
	return b

func _on_state_updated(state: Dictionary):
	_submitting = false
	hand_area.locked = false
	var previous = _game_state
	_game_state = state
	if _n() == LocalGame:
		if LocalGame.tutorial_mode:
			# 教程：固定玩家 P0 视角（对手回合不泄露手牌）
			_player_index = 0
			_is_my_turn = (state.current_player == 0 and state.phase == Config.Phase.PLAYER_TURN)
		elif LocalGame.ai_mode:
			# 人机对战：人类固定 P0 视角（否则 AI 回合会泄露 AI 手牌）
			_player_index = 0
			_is_my_turn = (state.current_player == 0 and state.phase == Config.Phase.PLAYER_TURN)
		else:
			# 自我对战：轮流操作，视角跟随当前回合玩家
			if state.get("response_pending", false):
				_player_index = int(state.get("pending_target", 1 - state.current_player))
			else:
				_player_index = state.current_player
			_is_my_turn = (state.phase == Config.Phase.PLAYER_TURN)
	else:
		_player_index = _n().player_index
		_is_my_turn = (state.current_player == _player_index) and (state.phase == Config.Phase.PLAYER_TURN)
	var context_changed = previous.get("current_player", -1) != state.current_player \
		or previous.get("turn_number", -1) != state.turn_number \
		or previous.get("phase", -1) != state.phase \
		or previous.get("waiting_for_discard", false) != state.get("waiting_for_discard", false)
	var hand_changed = previous.get("players", []) != state.get("players", [])
	if not _is_my_turn or context_changed or hand_changed:
		_on_cancel_select()
	_sync_popups(context_changed or hand_changed)
	_hide_item_popup()
	_refresh_all(state)
	_restore_card_controls()
	if state.get("revealed_to", -1) == _player_index:
		_on_hand_revealed(state.get("revealed_hand", []), int(state.get("revealed_from", -1)))

func _is_response_target() -> bool:
	return _game_state.get("response_pending", false) and int(_game_state.get("pending_target", -1)) == _player_index

func _sync_popups(context_changed: bool):
	_resp_popup.visible = _is_response_target()
	if _game_state.has("waiting_for_weapon_choice") and int(_game_state.waiting_for_weapon_choice) != _player_index:
		_wpn_popup.visible = false
	var kept: Array = []
	for popup in _transient_popups:
		if not is_instance_valid(popup) or popup.is_queued_for_deletion(): continue
		var close = context_changed
		if popup.name == "WindBowPopup":
			close = not _game_state.get("wind_bow_pending", false) or _game_state.current_player != _player_index
		elif popup.name == "SwordsmanPopup":
			close = not _is_my_turn or not _find_self().get("pending_fighter_skill", false) or _game_state.get("waiting_for_discard", false)
		elif popup.name in ["RevealedHandPopup", "StatusDetailPopup"]:
			close = true
		if close:
			popup.hide()
			popup.queue_free()
		else:
			kept.append(popup)
	_transient_popups = kept

func _update_timer_label():
	if _timer_left < 0:
		return
	var tp = ["判定", "摸牌", "出牌", "弃牌"]
	var tn = tp[_game_state.get("turn_phase", 0)] if _game_state.get("turn_phase", 0) < tp.size() else "?"
	var who = _turn_owner_text()
	phase_label.text = "T%d | %s | %s | %ds" % [_game_state.turn_number, tn, who, _timer_left]

func _process(delta):
	# 状态详情（点击角色名/装备/状态槽）自动消失
	if _status_msg_timer > 0:
		_status_msg_timer -= delta
		if _status_msg_timer <= 0:
			_status_msg_timer = 0
			status_label.text = ""
	if _timer_left <= 0:
		return
	_timer_elapsed += delta
	if _timer_elapsed >= 1.0:
		_timer_elapsed -= 1.0
		_timer_left -= 1
		if _timer_left < 0: _timer_left = -1
		_update_timer_label()

var _timer_elapsed: float = 0.0
var _status_msg_timer: float = 0.0
var _end_confirm_at: int = 0  # 结束出牌防误触：进入确认态的时间戳（0=未确认）

func _refresh_all(state: Dictionary):
	card_info.text = ""
	var pls = state.players
	if pls.size() < 2:
		return
	# 多人局：棋盘切换六边形模式（模式不变时 BoardRenderer 内部跳过重建）
	var want_hex = pls.size() > 2
	if want_hex != _board_hex:
		_board_hex = want_hex
		board.set_geometry_mode(MapGeometry.MODE_HEX if want_hex else MapGeometry.MODE_LINEAR)
	# 分区式布局：棋盘居中于中列（左战报 300、右对手面板 460 之间，中心 x≈900）。
	# 每次刷新都应用（不能只在模式切换时，否则首次进入 2 人局保持 tscn 旧尺寸 1440×760）
	# 2 人局线性棋盘 1100×160（11 格×100）；4 人局六边形棋盘 900×640
	if want_hex:
		board.offset_left = -510; board.offset_right = 390
		board.offset_top = -380; board.offset_bottom = 150
	else:
		# 2 人局棋盘 1020 宽（原 1100 缩 80）：给右侧对手面板（460+safe）腾空间，防棋盘右缘与面板重叠
		board.offset_left = -560; board.offset_right = 350
		board.offset_top = -140; board.offset_bottom = 20
	# HP 闪烁记录数组按玩家数扩展（4 人局原 2 元素会越界）
	while _last_hp.size() < pls.size():
		_last_hp.append(-1)
	# 数据驱动玩家面板：自己面板 + 所有对手面板（数量随玩家数动态，2/4/N 人统一）
	var me = _find_self(pls)
	_self_panel.refresh(me, "自己", Color(0.5, 0.8, 1))
	# 面板高度跟随内容（buff 状态槽多时变高，完整显示不被裁切），封顶 300 保证不挡技能按钮
	# （技能按钮 SkillRow 顶部 y≈760，面板底部 -20 → 高度 ≤300 不重叠）。
	# 用 content_height(面板宽)（基础行 + 状态行按槽数×每行槽数估行数）且 +20 抵消 offset_bottom=-20，
	# 保证设定高 ≥ 内容高 → PanelContainer 不强制扩展（扩展会把面板底推出屏幕裁切）
	_layout_self_panel.call_deferred()
	_refresh_opp_panels(pls)
	for p in pls:
		if p.hp != _last_hp[p.index]:
			var panel = _panel_for(int(p.index))
			if panel != null:
				panel.flash_hp(p.hp > _last_hp[p.index])
			_last_hp[p.index] = p.hp
	var tp = ["判定", "摸牌", "出牌", "弃牌"]
	var tn = tp[state.get("turn_phase", 0)] if state.get("turn_phase", 0) < tp.size() else "?"
	var who = _turn_owner_text()
	# 从服务端同步计时器
	var timer = state.get("action_time_left", -1)
	if timer <= 0: timer = state.get("discard_time_left", -1)
	_timer_left = timer if timer > 0 else -1
	_timer_elapsed = 0.0
	if _timer_left > 0:
		_update_timer_label()
	else:
		phase_label.text = "T%d | %s | %s" % [state.turn_number, tn, who]
	if state.turn_number != _last_turn or state.current_player != _last_player:
		_last_turn = state.turn_number; _last_player = state.current_player
		_flash(phase_label)
		_show_turn_notice()

	board.update(pls, state.get("items", []), _player_index)

	var responding: Array = []
	if _is_response_target():
		var attack := str(state.get("pending_attack_card", ""))
		responding = ["magic"]
		if attack in ["range", "pierce", "magic", "chant"]: responding.append("range")
		if attack in ["near", "heavy"]: responding.append("near")
	hand_area.sync_hand(me.get("hand", []), me, responding, _discard_selected,
		_is_response_target() or (state.get("waiting_for_discard", false) and _is_my_turn))
	hand_area.select(_selected_uid)
	action_log.show_logs(state.get("action_log", []), 8, _player_index)

	if _is_response_target():
		_show_resp_popup(state.get("pending_attack_card", ""), int(state.get("pending_attack_damage", 0)))

	var in_discard = state.get("waiting_for_discard", false)
	for card in hand_area.cards: card.set_discard_phase(in_discard and _is_my_turn)
	_refresh_skill_row(me)
	if in_discard and _is_my_turn:
		var need = me.get("hand", []).size() - me.get("hand_limit", 5)
		var txt = "确认弃牌(%d张)" % _discard_selected.size()
		end_turn_btn.text = txt; end_turn_btn.visible = true
		_status_msg_timer = 0  # 弃牌提示常驻，不被详情自动消失误清
		if need > 0:
			status_label.text = "还需弃%d张（手牌上限%d）" % [need, me.get("hand_limit", 5)]
		else:
			status_label.text = "手牌未超上限，可主动多弃（选%d张）" % _discard_selected.size()
		confirm_btn.visible = false
		_show_discard_focus(me)
	else:
		if _discard_focus:
			_hide_skill_focus()
		_discard_selected.clear()
		_end_confirm_at = 0  # 状态刷新（出牌等操作）取消结束确认态
		end_turn_btn.text = "结束出牌"
		end_turn_btn.remove_theme_color_override("font_color")
		end_turn_btn.visible = _is_my_turn
		confirm_btn.visible = false
		cancel_btn.visible = false
		_status_msg_timer = 0
		status_label.text = ""
		if _is_my_turn and me.get("pending_fighter_skill", false):
			_show_fighter_popup()

func _on_card_clicked(card_uid: int, type_id: String):
	if _submitting or hand_area.get_card(card_uid) == null: return
	type_id = hand_area.get_card(card_uid).type_id
	if not _skill_pick.is_empty():
		_select_skill_material(card_uid, type_id)
		return
	if tutorial != null and not _is_response_target() and not tutorial.allow_card_click(card_uid, type_id):
		status_label.text = "当前步骤请按引导操作"
		return
	if _is_my_turn and _game_state.get("waiting_for_discard", false):
		if card_uid in _discard_selected: _discard_selected.erase(card_uid)
		else: _discard_selected.append(card_uid)
		_refresh_all(_game_state)
		return
	if _selected_uid == card_uid:
		_on_cancel_select()
		return
	_on_cancel_select()
	_selected_uid = card_uid
	_selected_type = type_id
	hand_area.select(card_uid)
	cancel_btn.show()
	if _is_response_target():
		_pick_mode = "response"
		confirm_btn.text = "确认响应"
		confirm_btn.visible = hand_area.get_card(card_uid)._respondable
		confirm_btn.disabled = false
		status_label.text = _response_description(type_id)
		return
	if not _is_my_turn or int(_game_state.get("waiting_for_weapon_choice", -1)) == _player_index or _game_state.get("wind_bow_pending", false):
		return
	confirm_btn.show()
	confirm_btn.disabled = false
	confirm_btn.text = "确认使用"
	var reason: String = hand_area.get_card(card_uid).blocked_reason
	if not reason.is_empty():
		confirm_btn.disabled = true
		status_label.text = reason
		return
	if type_id in ["near", "heavy"] and _has_removable_seed():
		confirm_btn.text = "选择用途"
		return
	if type_id == "move":
		_pick_mode = "move"
	elif type_id == "item":
		_pick_mode = "item"
	elif _is_targeted_card(type_id) and type_id != "destroy":
		_pick_mode = "target"
	if not _pick_mode.is_empty():
		confirm_btn.disabled = true
		confirm_btn.text = "选择目标"
		var targets := _card_targets()
		board.set_targets(targets)
		if targets.is_empty(): status_label.text = "当前没有可选目标"
		if _pick_mode == "target" and targets.size() == 1: _stage_board_target(targets[0])
	elif _is_armor_override(type_id):
		confirm_btn.text = "装备"
	elif type_id == "destroy":
		confirm_btn.text = "选择用途"

func _card_targets() -> Array:
	var geo = MapGeometry.new()
	geo.set_mode(MapGeometry.MODE_HEX if _board_hex else MapGeometry.MODE_LINEAR)
	var me := _find_self()
	var origin: Vector2i = geo.from_dict(me.get("position", {}))
	var result: Array = []
	if _pick_mode == "move":
		if me.get("frozen_move", false): return result
		var dirs: Array = MapGeometry.HEX_DIRS if _board_hex else [Vector2i(-1, 0), Vector2i(1, 0)]
		for direction in dirs:
			if tutorial != null and not _board_hex and not direction.x in tutorial.allowed_move_dirs(): continue
			if geo.is_valid(origin + direction): result.append(origin + direction)
	elif _pick_mode == "item":
		for x in range(-MapGeometry.HEX_RADIUS if _board_hex else 0, MapGeometry.HEX_RADIUS + 1 if _board_hex else MapGeometry.WIDTH):
			for y in range(-MapGeometry.HEX_RADIUS if _board_hex else 0, MapGeometry.HEX_RADIUS + 1 if _board_hex else 1):
				var pos := Vector2i(x, y)
				if not geo.is_valid(pos): continue
				if tutorial != null:
					var allowed = tutorial.allowed_trap_positions()
					if not allowed.is_empty() and not pos in allowed: continue
				if me.get("char_id", "") == "vine_ent":
					var seed := false
					for item in _game_state.get("items", []):
						if item.get("item_type", "") == "vine_seed" and geo.from_dict(item.position) == pos: seed = true
					if not seed: continue
				result.append(pos)
	else:
		for p in _game_state.players:
			if p.index == _player_index or p.get("eliminated", false): continue
			var valid_target := true
			for data in me.get("hand", []):
				if int(data.uid) == _selected_uid and _selected_type in ["near", "heavy", "range", "pierce", "magic", "chant"]:
					valid_target = not data.has("valid_attack_targets") or p.index in data.valid_attack_targets
			if not valid_target: continue
			var pos: Vector2i = geo.from_dict(p.position)
			if _selected_type in ["near", "heavy"] and geo.distance(origin, pos) != 0: continue
			if _selected_type in ["range", "pierce", "magic", "chant"] and _has_buff(p, "rogue_stealth"): continue
			result.append(pos)
	return result

func _stage_board_target(pos: Vector2i):
	if not pos in _card_targets(): return
	var geo = MapGeometry.new()
	_staged_extra.clear()
	_selected_cell = pos
	if _pick_mode == "move":
		var direction: Vector2i = pos - geo.from_dict(_find_self().position)
		_staged_extra = {"steps": 1, "direction": geo.to_dict(direction)}
		confirm_btn.text = "确认移动"
	elif _pick_mode == "item":
		_staged_extra = {"trap_pos": geo.to_dict(pos)}
		confirm_btn.text = "确认放置"
	else:
		for p in _game_state.players:
			if geo.from_dict(p.position) == pos and p.index != _player_index:
				_staged_extra = {"target": int(p.index)}
				status_label.text = "目标：P%d %s" % [p.index + 1, p.get("char_name", "")]
				if not p.get("armor", {}).is_empty():
					status_label.text += " · %s %d/%d" % [p.armor.data.name, p.armor.durability, p.armor.get("max_durability", 3)]
		confirm_btn.text = "确认使用"
	confirm_btn.disabled = _staged_extra.is_empty()
	board.set_targets(_card_targets(), pos)

func _on_card_details(uid: int, type_id: String):
	var card = hand_area.get_card(uid)
	if card == null: return
	var description := "%s\n基础消耗：%s %s\n\n%s" % [card._name_label.text, card._ap_label.text, Config.get_card_ap_cost(type_id), card._description.text]
	if not card.blocked_reason.is_empty(): description += "\n\n" + card.blocked_reason
	if _is_response_target(): description += "\n\n" + _response_description(type_id)
	_on_status_clicked(description)

func _response_description(type_id: String) -> String:
	var card_types: Array = ["magic"]
	var attack := str(_game_state.get("pending_attack_card", ""))
	if attack in ["near", "heavy"]: card_types.append("near")
	if attack in ["range", "pierce", "magic", "chant"]: card_types.append("range")
	if not type_id in card_types: return "此牌不能响应当前攻击"
	if type_id == "magic": return "闪避：免疫此次伤害或冻结，不消耗行动点"
	if type_id == "near": return "格挡：伤害减半，不消耗行动点"
	var me := _find_self()
	var reduction := maxi(0, int(me.get("range_power", 0)) - int(_game_state.get("distance", 0)))
	if me.get("weapon", {}).get("id", "") == "repeater": reduction += 2
	return "牵制：减免%d伤害，不消耗行动点" % reduction

func _restore_card_controls():
	if not _skill_pick.is_empty():
		_refresh_skill_pick()
		return
	if _selected_uid == -1: return
	var card = hand_area.get_card(_selected_uid)
	if card == null: return
	cancel_btn.show()
	if _pick_mode == "response":
		confirm_btn.visible = _is_response_target() and card._respondable
		confirm_btn.disabled = false
	elif _is_my_turn and int(_game_state.get("waiting_for_weapon_choice", -1)) != _player_index and not _game_state.get("wind_bow_pending", false):
		confirm_btn.show()
		confirm_btn.disabled = not _pick_mode.is_empty() and _staged_extra.is_empty()
		if not _staged_extra.is_empty(): _stage_board_target(_selected_cell)

func _on_background_input(event: InputEvent):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_on_cancel_select()


func _on_confirm_card():
	if not _skill_pick.is_empty():
		if _submitting or not _is_my_turn or not _skill_ready(): return
		var skill := _skill_pick
		var params := _skill_params.duplicate(true)
		params["card_uid"] = _selected_uid
		_submitting = true
		hand_area.locked = true
		_on_cancel_select()
		_n().send_use_skill(skill, params)
		return
	if _selected_uid == -1:
		return
	if _submitting: return
	if _pick_mode == "response":
		var response = hand_area.get_card(_selected_uid)
		if not _is_response_target() or response == null or not response._respondable: return
		_submit_response(true, _selected_uid)
		return
	if not _is_my_turn: return
	if not _pick_mode.is_empty():
		if _staged_extra.is_empty(): return
		var uid := _selected_uid
		var extra := _staged_extra.duplicate(true)
		var tid := _selected_type
		if tid == "seize":
			for p in _game_state.players:
				if p.index == extra.get("target", -1) and _has_buff(p, "exposed") and not p.get("hand", []).is_empty():
					_on_cancel_select()
					_show_exposed_hand_pick(uid, tid, int(p.index), extra)
					return
		_submit_card(uid, extra)
		return
	# 除根二选一跳过标志（选择"攻击"后不再弹二选一）
	var skip_root = _skip_root_choice
	_skip_root_choice = false
	if _selected_type in ["move", "destroy"]:
		match _selected_type:
			"move": _popup_move(_selected_uid)
			"destroy": _popup_destroy(_selected_uid)
		_selected_uid = -1
		confirm_btn.visible = false
	elif _selected_type == "seize" and _game_state.players.size() <= 2:
		# 夺取（2人局）：目标暴露时弹手牌选择
		var opp2 = _find_opponent()
		if _has_buff(opp2, "exposed") and not opp2.get("hand", []).is_empty():
			_show_exposed_hand_pick(_selected_uid, "seize", opp2.get("index", 1 - _player_index), {})
		else:
			_submit_card(_selected_uid)
		_selected_uid = -1
		confirm_btn.visible = false
	elif _selected_type == "item":
		_popup_item(_selected_uid)  # 进入棋盘选格模式（保留 _selected_uid 供点击后发送）
		confirm_btn.visible = false
	elif _selected_type in ["near", "heavy"] and not skip_root and _has_removable_seed():
		# 附近有蔓生种子：二选一（正常攻击 / 除根）
		_show_attack_or_root(_selected_uid, _selected_type)
		_selected_uid = -1
		confirm_btn.visible = false
	else:
		if _has_matching_armor(_selected_type):
			_show_armor_confirm(_selected_uid, _selected_type)
			_selected_uid = -1
		elif _is_armor_override(_selected_type):
			_show_armor_override_confirm(_selected_uid)
			_selected_uid = -1
		elif _is_targeted_card(_selected_type) and _game_state.players.size() > 2:
			_show_target_pick(_selected_uid, _selected_type)
			_selected_uid = -1
		else:
			_submit_card(_selected_uid)
			_selected_uid = -1
	confirm_btn.visible = false
	cancel_btn.visible = false
	_refresh_highlight()

# 数据驱动对手面板：右侧竖排，数量随对手数动态（2 人局 1 个，4 人局 3 个）
func _refresh_opp_panels(pls: Array):
	var opps := []
	for p in pls:
		if p.get("index", -1) != _player_index:
			opps.append(p)
	var need = opps.size()
	while _opp_panels.size() < need:
		_opp_panels.append(_make_opp_panel())
		_opp_indices.append(-1)
	while _opp_panels.size() > need:
		_opp_panels.pop_back().queue_free()
		_opp_indices.pop_back()
	for i in range(need):
		_opp_indices[i] = int(opps[i].index)
		_update_opp_panel(_opp_panels[i], opps[i])

# 指定玩家索引 → 其面板（自己 → 左下；对手 → 右侧竖排对应项）；找不到返回 null
func _panel_for(index: int) -> PanelContainer:
	if index == _player_index:
		return _self_panel
	var pos = _opp_indices.find(index)
	if pos >= 0 and pos < _opp_panels.size():
		return _opp_panels[pos]
	return null

func _make_opp_panel() -> PanelContainer:
	var pc: PanelContainer = InfoPanel.new()
	# 安全区内缩与宽度/高度由 _refresh_opp_panels 统一设置（按人数/屏幕高）
	pc.status_clicked.connect(_on_status_clicked)
	_opp_box.add_child(pc)
	return pc

func _update_opp_panel(pc: PanelContainer, p: Dictionary):
	var tag = "P%d" % [p.index + 1]
	if p.get("eliminated", false):
		tag += "（已淘汰）"
	pc.refresh(p, tag, Color(1, 0.7, 0.5))

# 指向性卡（多人局需要选择目标）：攻击/吸引/威慑/冻结/摧毁/夺取
func _is_targeted_card(type_id: String) -> bool:
	return type_id in ["near", "heavy", "range", "pierce", "magic", "chant",
		"attract", "deter", "freeze", "destroy", "seize"]

# 多人局：指向卡弹出目标选择（列所有存活对手：名字/HP/位置）
# extra：目标外的附加参数（如摧毁手牌/装备的 destroy_target 等）
func _show_target_pick(card_uid: int, type_id: String, extra: Dictionary = {}):
	var c = Control.new()
	c.name = "TargetPick"
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 560, 460)
	vb.add_child(_lbl("选择「%s」的目标：" % Config.card_name(type_id)))
	var any = false
	for p in _game_state.players:
		if p.index == _player_index or p.get("eliminated", false): continue
		any = true
		var pos = p.get("position", {})
		var pos_str = "%d,%d" % [pos.get("x", 0), pos.get("y", 0)]
		var b = _mkbtn("P%d %s  HP:%d/%d  格(%s)" % [p.index + 1, p.get("char_name", "?"), p.get("hp", 0), p.get("max_hp", 1), pos_str])
		b.pressed.connect(func(pid = p.index):
			c.queue_free()
			var send_extra = {"target": pid}
			for k in extra: send_extra[k] = extra[k]
			# 夺取/摧毁-盲丢：目标暴露时先弹手牌选择
			var want_pick = (type_id == "seize") or (type_id == "destroy" and send_extra.get("destroy_target", "") == "hand")
			if want_pick and _has_buff(p, "exposed") and not p.get("hand", []).is_empty():
				_show_exposed_hand_pick(card_uid, type_id, pid, send_extra)
				return
			_submit_card(card_uid, send_extra)
		)
		vb.add_child(b)
	if not any:
		vb.add_child(_lbl("没有可攻击的目标"))
	var close = _mkbtn("取消")
	close.pressed.connect(func(): c.queue_free())
	vb.add_child(close)
	add_child(c)

# 已有防具时再装备防具卡：弹确认（旧防具会被直接覆盖消失）；饲甲人活铠不可覆盖（护甲卡=修复）
func _is_armor_override(type_id: String) -> bool:
	if not type_id.ends_with("_armor"): return false
	var me = _find_self()
	if me.get("char_id", "") == "armor_feeder": return false
	return not me.get("armor", {}).is_empty()

func _show_armor_override_confirm(card_uid: int):
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 640, 400)
	var me = _find_self()
	var old_name = me.get("armor", {}).get("data", {}).get("name", "防具")
	vb.add_child(_lbl("已装备防具「%s」\n新防具会覆盖旧防具（旧防具直接消失），确定装备？" % old_name))
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_theme_constant_override("separation", 24)
	var ok = _mkbtn("确定装备")
	ok.pressed.connect(func():
		c.queue_free()
		_submit_card(card_uid)
	)
	hb.add_child(ok)
	var no = _mkbtn("取消")
	no.pressed.connect(func(): c.queue_free())
	hb.add_child(no)
	vb.add_child(hb)
	add_child(c)

func _has_matching_armor(attack_type: String) -> bool:
	var armor_needed = {"near": "physical", "heavy": "physical", "range": "ranged", "pierce": "ranged", "magic": "magical", "chant": "magical"}
	var need = armor_needed.get(attack_type, "")
	if need == "": return false
	for p in _game_state.players:
		if p.index != _player_index and not p.armor.is_empty():
			if p.armor.data.type == "all": return true  # 活铠全类型
			return p.armor.data.type == need
	return false

func _show_armor_confirm(card_uid: int, _attack_type: String):
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 700, 340)
	var armor_name = ""
	var is_full_durability = false
	for p in _game_state.players:
		if p.index != _player_index and not p.armor.is_empty():
			armor_name = p.armor.data.name
			# 活铠（饲甲人魔甲）无完全免疫：满耐久也只提示减免一半
			is_full_durability = p.armor.get("id", "") != "demon_armor" \
					and p.armor.durability >= p.armor.get("max_durability", 3)
			break
	vb.add_child(_lbl("对方装备了%s" % armor_name))
	# 按耐久区分提示：满耐久才完全免疫，其余是减免一半
	vb.add_child(_lbl("此次攻击将被完全免疫" if is_full_durability else "此次攻击将被减免一半"))
	vb.add_child(_lbl("确定要打出吗？"))
	var hb = HBoxContainer.new(); vb.add_child(hb)
	var ok = _mkbtn("确定")
	ok.pressed.connect(func(): c.queue_free(); _submit_card(card_uid))
	hb.add_child(ok)
	var no = _mkbtn("取消")
	no.pressed.connect(func(): c.queue_free())
	hb.add_child(no)
	add_child(c)

func _refresh_highlight():
	hand_area.select(_selected_uid)

# ---------- 地格道具详情悬浮框（长按查看） ----------
var _item_popup: Label = null

func _on_cell_long_pressed(cell_pos: Vector2i):
	_show_item_popup(cell_pos)

func _on_cell_released(_cell_pos: Vector2i):
	_hide_item_popup()

func _show_item_popup(cell_pos: Vector2i):
	# 统计该格道具（按结算优先级=伤害类在前/收益类在后，即 item_system 注册表顺序）
	var counts := {}
	for it in _game_state.get("items", []):
		var p = it.get("position", {})
		var itp = Vector2i(int(p.get("x", 0)), int(p.get("y", 0)))
		if itp == cell_pos:
			var tid = str(it.get("item_type", "?"))
			counts[tid] = int(counts.get(tid, 0)) + 1
	if counts.is_empty():
		return
	var isys = ItemSys.new(null)  # 临时实例：仅查道具注册表（名称/排序）
	var parts: Array = []
	for tid in isys.get_type_order():
		if counts.has(str(tid)):
			var dname = str(isys.get_item_type(str(tid)).get("name", tid))
			# 蔓生种子悬浮框显示缩写"蔓"（卡面仍显示全名"蔓生种子"）
			if str(tid) == "vine_seed": dname = "蔓"
			parts.append("%s:%d" % [dname, counts[str(tid)]])
	if parts.is_empty():
		return
	if _item_popup == null:
		_item_popup = Label.new()
		_item_popup.name = "ItemPopup"
		_item_popup.z_index = 25
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.05, 0.05, 0.08, 0.92)
		sb.border_color = Color(1, 0.85, 0.3, 0.95)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(10)
		sb.content_margin_left = 16.0
		sb.content_margin_right = 16.0
		sb.content_margin_top = 8.0
		sb.content_margin_bottom = 8.0
		_item_popup.add_theme_stylebox_override("normal", sb)
		_item_popup.add_theme_font_size_override("font_size", Style.fs(24))
		_item_popup.add_theme_color_override("font_color", Color(1, 0.9, 0.6))
		add_child(_item_popup)
	_item_popup.text = " | ".join(parts)
	_item_popup.reset_size()
	# 定位：地格中心上方；屏幕边缘翻转/夹紧防溢出
	var center = board.cell_global_center(cell_pos)
	var px = center.x - _item_popup.size.x / 2.0
	var py = center.y - _item_popup.size.y - 70.0
	if py < 8.0:
		py = center.y + 70.0  # 上方放不下：翻转到下方
	px = clampf(px, 8.0, size.x - _item_popup.size.x - 8.0)
	py = clampf(py, 8.0, size.y - _item_popup.size.y - 8.0)
	_item_popup.position = Vector2(px, py)
	_item_popup.visible = true

func _hide_item_popup():
	if _item_popup != null:
		_item_popup.visible = false

func _on_board_cell_clicked(cell_pos: Vector2i):
	if not _skill_pick.is_empty():
		_stage_skill_target(cell_pos)
		return
	if _selected_uid == -1: return
	if _submitting: return
	if _pick_mode in ["target", "move", "item"]:
		_stage_board_target(cell_pos)
		return
	# 教程限制：当前步骤只允许特定格子放夹子（穿心/陷阱），保证教学流程可控
	if tutorial != null and _selected_type in ["hunter_ambush", "item"]:
		var allowed = tutorial.allowed_trap_positions()
		if not allowed.is_empty() and not cell_pos in allowed:
			status_label.text = "夹子只能放在教学指定的格子"
			return
	var pos_dict := {"x": cell_pos.x, "y": cell_pos.y}
	if _selected_type == "hunter_ambush" and _is_my_turn:
		# 穿心：已选第 1 个位置，本次为第 2 个 → 发送放置
		if not _hunter_pos1.is_empty():
			_n().send_use_skill("hunter_ambush", {"card_uid": _selected_uid, "pos": _hunter_pos1, "pos2": pos_dict})
			_hunter_pos1 = {}
			_selected_uid = -1
			_selected_type = ""
			confirm_btn.visible = false
			cancel_btn.visible = false
			card_info.text = ""
			status_label.text = ""
			return
		# 判断所选卡是否为穿心（穿心需连续选 2 个放置位置）
		var me = _find_self()
		var is_pierce = false
		for card in me.get("hand", []):
			# _game_state 是 JSON 化状态，uid 是 float，需 int 强转后比较
			if int(card.uid) == _selected_uid and card.type_id == "pierce":
				is_pierce = true
				break
		if is_pierce:
			_hunter_pos1 = pos_dict
			status_label.text = "选择第2个捕兽夹位置"
			return
		_n().send_use_skill("hunter_ambush", {"card_uid": _selected_uid, "pos": pos_dict})
		_selected_uid = -1
		_selected_type = ""
		confirm_btn.visible = false
		cancel_btn.visible = false
		card_info.text = ""
		status_label.text = ""
		return
	if _selected_type == "destroy_trap" and _is_my_turn:
		_submit_card(_selected_uid, {"destroy_target": "trap", "trap_pos": pos_dict})
		_selected_uid = -1
		_selected_type = ""
		confirm_btn.visible = false
		cancel_btn.visible = false
		card_info.text = ""
		status_label.text = ""
		return
	if _selected_type == "vine_remove" and _is_my_turn:
		# 除根：点击地格选择要除根的蔓生种子（与摧毁-拆除道具同交互）
		_n().send_vine_remove(_selected_uid, pos_dict)
		_selected_uid = -1
		_selected_type = ""
		confirm_btn.visible = false
		cancel_btn.visible = false
		card_info.text = ""
		status_label.text = ""
		return
	if _selected_type == "vine_spread" and _is_my_turn:
		# 蔓延：点击地格新种蔓生种子
		_n().send_use_skill("vine_spread", {"card_uid": _selected_uid, "pos": pos_dict})
		_selected_uid = -1
		_selected_type = ""
		confirm_btn.visible = false
		cancel_btn.visible = false
		card_info.text = ""
		status_label.text = ""
		return
	if _selected_type != "item" or not _is_my_turn:
		return
	_submit_card(_selected_uid, {"trap_pos": pos_dict})
	_selected_uid = -1
	_selected_type = ""
	confirm_btn.visible = false
	cancel_btn.visible = false

func _popup_move(card_uid: int):
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 620, 360)
	vb.add_child(_lbl("移动方向"))
	# 哨兵 -1 = 技能调用（暗影步）；调试发牌卡 uid 为负数（-1000 递减），必须走 play_card
	# 教程：限制可选移动方向（线性：左右；六边形教程不涉及）
	var dirs = [1, -1]
	if tutorial != null:
		dirs = tutorial.allowed_move_dirs()
	if _board_hex:
		# 六边形：米字格布局（3×3，方向按视觉位置摆放，中间是取消）
		#  西北  [北]  东北
		#  西   [取消] 东
		#  西南  [南]  东南
		# 注意：六边形没有正北/正南方向（尖顶朝上只有 6 个邻居），
		# 上中/下中放灰掉的占位按钮保持米字格视觉对齐
		var grid = GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 16)
		grid.add_theme_constant_override("v_separation", 10)
		vb.add_child(grid)
		# 行优先填入（与米字格位置一一对应）；占位项点击无效
		var cells = [
			["西北", Vector2i(0, -1), false],
			["北", Vector2i.ZERO, true],
			["东北", Vector2i(1, -1), false],
			["西", Vector2i(-1, 0), false],
			["取消", Vector2i.ZERO, true],
			["东", Vector2i(1, 0), false],
			["西南", Vector2i(-1, 1), false],
			["南", Vector2i.ZERO, true],
			["东南", Vector2i(0, 1), false],
		]
		for cell in cells:
			var text: String = cell[0]
			var dir: Vector2i = cell[1]
			var placeholder: bool = cell[2]
			if text == "取消":
				var cb = _mkbtn("取消")
				cb.pressed.connect(func(): c.queue_free())
				grid.add_child(cb)
				continue
			if placeholder:
				var d = _mkbtn(text)
				d.disabled = true
				grid.add_child(d)
				continue
			var b = _mkbtn("%s1格" % text)
			b.pressed.connect(func(dd=dir):
				c.queue_free()
				_send_move(card_uid, dd)
			)
			grid.add_child(b)
	else:
		var hb = HBoxContainer.new()
		vb.add_child(hb)
		var lb = _mkbtn("左1格")
		lb.visible = -1 in dirs
		lb.pressed.connect(func(): c.queue_free(); _send_move(card_uid, Vector2i(-1, 0)))
		hb.add_child(lb)
		var rb = _mkbtn("右1格")
		rb.visible = 1 in dirs
		rb.pressed.connect(func(): c.queue_free(); _send_move(card_uid, Vector2i(1, 0)))
		hb.add_child(rb)
	var cb = _mkbtn("取消")
	cb.pressed.connect(func(): c.queue_free())
	vb.add_child(cb)
	add_child(c)

# 移动/暗影步方向发送统一出口（card_uid == -1 表示暗影步技能）
func _send_move(card_uid: int, dir: Vector2i):
	if card_uid == -1:
		_n().send_use_skill("assassin_move", {"direction": {"x": dir.x, "y": dir.y}})
	else:
		_submit_card(card_uid, {"direction": {"x": dir.x, "y": dir.y}, "steps": 1})

func _popup_destroy(card_uid: int):
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 700, 440)
	vb.add_child(_lbl("摧毁: 选择目标"))
	var multi = _game_state.players.size() > 2  # 多人局：选完摧毁类型再选目标
	var pls = _game_state.players
	var opp = _find_opponent(pls)
	var hb = _mkbtn("盲丢对方1手牌")
	hb.pressed.connect(func():
		c.queue_free()
		if multi:
			_show_target_pick(card_uid, "destroy", {"destroy_target": "hand"})
		elif _has_buff(opp, "exposed") and not opp.get("hand", []).is_empty():
			_show_exposed_hand_pick(card_uid, "destroy", opp.get("index", 1 - _player_index), {"destroy_target": "hand"})
		else:
			_submit_card(card_uid, {"destroy_target": "hand"})
	)
	vb.add_child(hb)
	# 多人局：武器/防具按钮始终显示（点选目标后由核心校验目标是否有对应装备）
	if multi or not opp.weapon.is_empty():
		var wb = _mkbtn("摧毁对方武器" + ((": " + opp.weapon.data.name) if not opp.weapon.is_empty() else ""))
		wb.pressed.connect(func():
			c.queue_free()
			if multi:
				_show_target_pick(card_uid, "destroy", {"destroy_target": "equip", "equip_type": "weapon"})
			else:
				_submit_card(card_uid, {"destroy_target": "equip", "equip_type": "weapon"})
		)
		vb.add_child(wb)
	if multi or not opp.armor.is_empty():
		# 活铠（饲甲人魔甲）免疫摧毁：2人局按钮直接标注免疫，点击不消耗卡只提示
		var immune = (not multi) and (not opp.armor.is_empty()) and opp.armor.get("id", "") == "demon_armor"
		var ab = _mkbtn("对方防具: 活铠（免疫摧毁）" if immune else ("摧毁对方防具" + ((": " + opp.armor.data.name) if not opp.armor.is_empty() else "")))
		ab.pressed.connect(func():
			c.queue_free()
			if immune:
				status_label.text = "活铠免疫摧毁"
				return
			if multi:
				_show_target_pick(card_uid, "destroy", {"destroy_target": "equip", "equip_type": "armor"})
			else:
				_submit_card(card_uid, {"destroy_target": "equip", "equip_type": "armor"})
		)
		vb.add_child(ab)
	var traps_list = _game_state.get("items", [])
	if traps_list.size() > 0:
		var tb = _mkbtn("摧毁道具：点击棋盘指定格子(%d个)" % traps_list.size())
		tb.pressed.connect(func(): c.queue_free(); _enter_destroy_trap(card_uid))
		vb.add_child(tb)
	add_child(c)

# 摧毁陷阱：进入棋盘选格模式（复用放陷阱的格子点击交互）
func _enter_destroy_trap(card_uid: int):
	_selected_uid = card_uid
	_selected_type = "destroy_trap"
	cancel_btn.visible = true
	card_info.text = "点击棋盘上有道具的格子进行摧毁"
	status_label.text = "点击棋盘上有道具的格子进行摧毁"

func _popup_item(card_uid: int):
	var me0 = _find_self()
	# 蔓生树妖：道具卡只能叠加（点击已有蔓生种子的地格升到2层=缠绕）；其余角色正常放置
	if me0.get("char_id", "") == "vine_ent":
		status_label.text = "点击已有蔓生种子的地格叠加（2层=缠绕）"
	else:
		status_label.text = "已选道具,点击棋盘格子放置"
	_selected_uid = card_uid
	_selected_type = "item"

func _on_response_needed(data: Dictionary):
	# 教程接管响应：对手自动不响应 / 复活步骤自动跳过
	if tutorial != null and tutorial.handle_response_needed():
		return
	if not _is_response_target(): return
	var atk = data.get("card", "")
	# 真言为技能攻击：显示中文名（card_name 对无卡池条目返回英文 id）
	var atk_display = "真言" if atk == "priest_chant" else Config.card_name(str(atk))
	status_label.text = "对方发动%s攻击！" % atk_display
	_show_resp_popup(atk, int(data.get("damage", 0)))

func _on_weapon_prompt(weapon: Dictionary):
	var wd = weapon.get("data", {})
	_wpn_popup.find_child("WpnTitle", true, false).text = "获得武器: " + wd.get("name", "?")
	_wpn_popup.find_child("WpnDesc", true, false).text = wd.get("desc", "")
	_wpn_popup.visible = true

# 风神弓：穿心命中后选择控制对方移动的方向（取消 = 放弃控制）
func _on_wind_bow_prompt(_target_idx: int):
	var c = Control.new()
	c.name = "WindBowPopup"
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 620, 420)
	vb.add_child(_lbl("风神弓：控制对方移动1格"))
	var send_dir := func(dir: Vector2i):
		c.queue_free()
		_n().send_wind_bow_move({"x": dir.x, "y": dir.y})
	if _board_hex:
		# 六边形：米字格布局（与移动弹窗一致）
		var grid = GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 16)
		grid.add_theme_constant_override("v_separation", 10)
		vb.add_child(grid)
		var cells = [
			["西北", Vector2i(0, -1), false],
			["北", Vector2i.ZERO, true],
			["东北", Vector2i(1, -1), false],
			["西", Vector2i(-1, 0), false],
			["取消", Vector2i.ZERO, true],
			["东", Vector2i(1, 0), false],
			["西南", Vector2i(-1, 1), false],
			["南", Vector2i.ZERO, true],
			["东南", Vector2i(0, 1), false],
		]
		for cell in cells:
			var text: String = cell[0]
			var dir: Vector2i = cell[1]
			var placeholder: bool = cell[2]
			if text == "取消":
				var cb = _mkbtn("取消")
				cb.pressed.connect(func(): c.queue_free(); _n().send_wind_bow_move({}, true))
				grid.add_child(cb)
				continue
			if placeholder:
				var d = _mkbtn(text)
				d.disabled = true
				grid.add_child(d)
				continue
			var b = _mkbtn("%s1格" % text)
			b.pressed.connect(func(dd=dir): send_dir.call(dd))
			grid.add_child(b)
	else:
		var hb = HBoxContainer.new()
		vb.add_child(hb)
		var lb = _mkbtn("左1格")
		lb.pressed.connect(func(): send_dir.call(Vector2i(-1, 0)))
		hb.add_child(lb)
		var rb = _mkbtn("右1格")
		rb.pressed.connect(func(): send_dir.call(Vector2i(1, 0)))
		hb.add_child(rb)
	var cb2 = _mkbtn("取消（放弃控制）")
	cb2.pressed.connect(func(): c.queue_free(); _n().send_wind_bow_move({}, true))
	vb.add_child(cb2)
	add_child(c)

func _on_game_ended(r: Dictionary):
	if LocalGame.tutorial_mode:
		return  # 教程：反杀后由教程控制器继续（切猎人段），不跳结算页
	_n().last_game_result = r
	get_tree().change_scene_to_file("res://scenes/settlement.tscn")

func _on_error(msg: String):
	_submitting = false
	hand_area.locked = false
	_on_cancel_select()
	status_label.text = "错误: " + msg

func _submit_card(uid: int, extra: Dictionary = {}):
	if _submitting: return
	_submitting = true
	hand_area.locked = true
	_on_cancel_select()
	_n().send_play_card(uid, extra)

func _submit_response(respond: bool, uid: int = -1):
	if _submitting or not _is_response_target(): return
	_submitting = true
	hand_area.locked = true
	_on_cancel_select()
	_resp_popup.hide()
	_n().send_response(respond, uid)

func _on_server_disconnected():
	status_label.text = "连接断开，1秒后返回主菜单..."
	await get_tree().create_timer(1.0).timeout
	if is_instance_valid(self):
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

const MATERIAL_SKILLS = {
	"mage_discard": "魔法强化：弃1张手牌",
	"mage_phantom": "幻影：弃1张魔法或吟唱卡",
	"priest_chant": "真言：弃1张回复卡",
	"spellblade_channel": "魔力引导：魔法/吟唱转近战",
	"wardsmith_infuse": "注魔：消耗1张攻击卡",
	"wardsmith_repair": "修复：消耗匹配强化卡",
	"hunter_ambush": "埋伏：消耗远程/穿心",
	"vine_spread": "蔓延：弃1张攻击卡",
	"rogue_give": "济贫：送出1张手牌",
}
var _skill_pick := ""
var _skill_params: Dictionary = {}
var _skill_scrim: ColorRect
var _skill_description: RichTextLabel
var _skill_focus_layers: Dictionary = {}
var _skill_log_visible := true
var _discard_focus := false

func _show_discard_focus(me: Dictionary):
	if _skill_scrim == null: return
	if not _skill_scrim.visible: _skill_log_visible = action_log.visible
	_discard_focus = true
	action_log.hide()
	if _turn_notice != null: _turn_notice.hide()
	_skill_scrim.show()
	_skill_description.show()
	_skill_description.bbcode_enabled = true
	var count: int = me.get("hand", []).size()
	var limit := int(me.get("hand_limit", 5))
	var chosen := _discard_selected.size()
	var remaining := maxi(0, count - limit - chosen)
	var requirement := "还需选择 %d 张" % remaining if remaining > 0 else "已满足手牌上限"
	if count <= limit and chosen == 0: requirement = "无需弃牌，可直接结束回合"
	_skill_description.text = "[font_size=42][color=#c49aff]弃牌阶段[/color][/font_size]\n\n[color=#c49aff]%s[/color]\n已选 %d 张 · 弃后剩余 %d 张 · 手牌上限 %d 张" % [requirement, chosen, count - chosen, limit]
	for control in _skill_focus_layers: control.z_index = int(_skill_focus_layers[control])
	for control in [_self_panel, _opp_scroll, $HandScroll, end_turn_btn, status_label]: control.z_index = 5
	status_label.add_theme_color_override("font_color", Color("c49aff"))
	status_label.text = "弃牌阶段 · 已选%d张\n%s" % [chosen, requirement]
	end_turn_btn.text = "确认弃牌(%d张)" % chosen if chosen > 0 else "不弃牌，结束回合"
	if remaining > 0: end_turn_btn.text = "确认弃牌(%d张)" % chosen
	end_turn_btn.add_theme_color_override("font_color", Color("c49aff"))
	cancel_btn.hide()
	_layout_skill_focus()

func _build_skill_focus():
	_skill_scrim = ColorRect.new()
	_skill_scrim.name = "SkillFocusScrim"
	_skill_scrim.color = Color(0.08, 0.08, 0.09, 0.82)
	_skill_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skill_scrim.z_index = 3
	_skill_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_skill_scrim.hide()
	add_child(_skill_scrim)
	_skill_description = RichTextLabel.new()
	_skill_description.name = "SkillFocusDescription"
	_skill_description.z_index = 4
	_skill_description.add_theme_font_size_override("normal_font_size", 26)
	_skill_description.add_theme_color_override("default_color", Color("e0e5ed"))
	_skill_description.hide()
	add_child(_skill_description)
	for control in [_self_panel, _opp_scroll, $HandScroll, skill_row, confirm_btn, cancel_btn, status_label, board, end_turn_btn]:
		_skill_focus_layers[control] = control.z_index

func _layout_skill_focus():
	if _skill_description == null: return
	var vp := get_viewport_rect().size
	_skill_description.position = Vector2(_self_panel.offset_left, 80)
	var width := 312.0 if _board_hex else maxf(312.0, vp.x - 690.0 - _safe_right)
	var height := maxf(100.0, vp.y + _self_panel.offset_top - 110.0) if _board_hex else 300.0
	_skill_description.size = Vector2(width, height)

func _show_skill_focus():
	if _skill_scrim == null: return
	if not _skill_scrim.visible: _skill_log_visible = action_log.visible
	action_log.hide()
	if _turn_notice != null: _turn_notice.hide()
	_skill_scrim.show()
	_skill_description.show()
	_skill_description.bbcode_enabled = false
	var desc: String = Config.CHARACTER_DB.get(_find_self().get("char_id", ""), {}).get("skill_desc", "")
	for skill in _find_self().get("active_skills", []):
		if skill.id == _skill_pick and not str(skill.get("desc", "")).is_empty(): desc = skill.desc
	_skill_description.text = Style.wj(MATERIAL_SKILLS[_skill_pick]) + "\n\n" + Style.wj(desc)
	for control in _skill_focus_layers:
		control.z_index = 5
	end_turn_btn.z_index = int(_skill_focus_layers[end_turn_btn])
	board.z_index = 5 if not _skill_targets().is_empty() else int(_skill_focus_layers[board])
	_layout_skill_focus()

func _hide_skill_focus():
	if _skill_scrim == null: return
	if _discard_focus:
		_discard_focus = false
		status_label.remove_theme_color_override("font_color")
		end_turn_btn.remove_theme_color_override("font_color")
	if _skill_scrim.visible: action_log.visible = _skill_log_visible
	_skill_scrim.hide()
	_skill_description.hide()
	_skill_description.text = ""
	for control in _skill_focus_layers:
		control.z_index = int(_skill_focus_layers[control])

func _begin_skill_pick(skill: String):
	_skill_pick = skill
	_refresh_skill_row(_find_self())
	_refresh_skill_pick()

func _material_allowed(type_id: String) -> bool:
	match _skill_pick:
		"mage_discard", "rogue_give": return true
		"mage_phantom", "spellblade_channel": return type_id in ["magic", "chant"]
		"priest_chant": return type_id in ["heal_3", "heal_5"]
		"hunter_ambush": return type_id in ["range", "pierce"]
		"wardsmith_repair":
			return type_id == {"near_armor": "heavy", "range_armor": "pierce", "magic_armor": "chant"}.get(_find_self().get("armor", {}).get("id", ""), "")
	return type_id in ["near", "heavy", "range", "pierce", "magic", "chant"]

func _restore_material_cards():
	if hand_area == null: return
	for data in _find_self().get("hand", []):
		var card = hand_area.get_card(int(data.uid))
		if card == null: continue
		card.set_skill_material(false)
		card.set_skill_unavailable(false)
		card.blocked_reason = str(data.get("blocked_reason", ""))
		if not data.has("blocked_reason") and not data.get("ap_affordable", true): card.blocked_reason = "行动点不足"
		card.set_unaffordable(not card.blocked_reason.is_empty())

func _select_skill_material(uid: int, type_id: String):
	if not _is_my_turn or not _material_allowed(type_id): return
	if tutorial != null and not tutorial.allow_card_click(uid, type_id): return
	_skill_params.clear()
	_selected_cell = Vector2i(-999, -999)
	_selected_uid = -1 if uid == _selected_uid else uid
	_selected_type = type_id if _selected_uid != -1 else ""
	hand_area.select(_selected_uid)
	if _selected_uid != -1 and _skill_pick in ["rogue_give", "priest_chant", "spellblade_channel"]:
		var targets := _skill_targets()
		if targets.size() == 1:
			_stage_skill_target(targets[0])
	_refresh_skill_pick()

func _skill_targets() -> Array:
	var out: Array = []
	if _selected_uid == -1: return out
	var geo = MapGeometry.new()
	geo.set_mode(MapGeometry.MODE_HEX if _board_hex else MapGeometry.MODE_LINEAR)
	if _skill_pick in ["rogue_give", "priest_chant", "spellblade_channel"]:
		for p in _game_state.get("players", []):
			if p.index != _player_index and not p.get("eliminated", false):
				out.append(geo.from_dict(p.position))
	elif _skill_pick in ["vine_spread", "hunter_ambush"]:
		for x in range(-MapGeometry.HEX_RADIUS if _board_hex else 0, MapGeometry.HEX_RADIUS + 1 if _board_hex else MapGeometry.WIDTH):
			for y in range(-MapGeometry.HEX_RADIUS if _board_hex else 0, MapGeometry.HEX_RADIUS + 1 if _board_hex else 1):
				var pos := Vector2i(x, y)
				if not geo.is_valid(pos): continue
				if _skill_pick == "vine_spread":
					var occupied := false
					var adjacent := false
					for item in _game_state.get("items", []):
						if item.get("item_type", "") != "vine_seed": continue
						var seed: Vector2i = geo.from_dict(item.position)
						if seed == pos: occupied = true
						elif geo.is_adjacent(seed, pos): adjacent = true
					if occupied or not adjacent: continue
				else:
					var occupied := false
					for p in _game_state.players:
						if not p.get("eliminated", false) and geo.from_dict(p.position) == pos: occupied = true
					if occupied: continue
					if tutorial != null:
						var allowed = tutorial.allowed_trap_positions()
						if not allowed.is_empty() and not pos in allowed: continue
				out.append(pos)
	return out

func _stage_skill_target(pos: Vector2i):
	if _submitting or not _is_my_turn or not pos in _skill_targets(): return
	_selected_cell = pos
	var geo = MapGeometry.new()
	if _skill_pick in ["rogue_give", "priest_chant", "spellblade_channel"]:
		for p in _game_state.players:
			if geo.from_dict(p.position) == pos: _skill_params["target"] = int(p.index)
	elif _skill_pick == "hunter_ambush" and _selected_type == "pierce" and _skill_params.has("pos") and not _skill_params.has("pos2"):
		_skill_params["pos2"] = geo.to_dict(pos)
	else:
		_skill_params = {"pos": geo.to_dict(pos)}
	_refresh_skill_pick()

func _skill_ready() -> bool:
	if _selected_uid == -1: return false
	if _skill_pick in ["rogue_give", "priest_chant", "spellblade_channel"]: return _skill_params.has("target")
	if _skill_pick == "vine_spread": return _skill_params.has("pos")
	if _skill_pick == "hunter_ambush": return _skill_params.has("pos") and (_selected_type != "pierce" or _skill_params.has("pos2"))
	return true

func _refresh_skill_pick():
	_show_skill_focus()
	hand_area.set_skill_selection(true)
	status_label.add_theme_color_override("font_color", CardWidget.SKILL_COLOR)
	for card in hand_area.cards:
		card.set_skill_material(_material_allowed(card.type_id))
		card.set_skill_unavailable(not _material_allowed(card.type_id))
		card.blocked_reason = "" if _material_allowed(card.type_id) else "不符合技能材料要求"
		card.set_unaffordable(not card.blocked_reason.is_empty())
	cancel_btn.show()
	confirm_btn.show()
	confirm_btn.text = "确认技能"
	confirm_btn.disabled = not _skill_ready()
	status_label.text = MATERIAL_SKILLS[_skill_pick] + ("\n已选0/1" if _selected_uid == -1 else "\n已选1/1")
	if _selected_uid != -1:
		status_label.text += " · " + Config.card_name(_selected_type)
		if _skill_pick == "mage_phantom": status_label.text += " → %d层幻影" % (2 if _selected_type == "chant" else 1)
		if _skill_pick == "priest_chant": status_label.text += " → %d伤害" % (5 if _selected_type == "heal_5" else 3)
		if _skill_pick == "wardsmith_infuse": status_label.text += " → " + {"near": "近战防具", "heavy": "近战防具", "range": "远程防具", "pierce": "远程防具", "magic": "法术防具", "chant": "法术防具"}.get(_selected_type, "")
		if _skill_params.has("target"): status_label.text += " → P%d" % (int(_skill_params.target) + 1)
		elif _skill_pick in ["rogue_give", "priest_chant", "spellblade_channel"]: status_label.text += "\n请选择目标"
		if _skill_pick in ["vine_spread", "hunter_ambush"] and not _skill_params.has("pos"): status_label.text += "\n请选择高亮地格"
		if _skill_pick == "wardsmith_repair": status_label.text += "\n1攻击点，耐久+2"
		if _skill_params.has("pos"): status_label.text += " · 位置(%d,%d)" % [_skill_params.pos.x, _skill_params.pos.y]
		if _skill_pick == "hunter_ambush" and _selected_type == "pierce": status_label.text += " · 位置%d/2" % (2 if _skill_params.has("pos2") else (1 if _skill_params.has("pos") else 0))
	board.set_targets(_skill_targets(), _selected_cell)

func _exec_skill(sk_id: String):
	if _submitting: return
	if sk_id == _skill_pick: return
	for skill in _find_self().get("active_skills", []):
		if skill.id == sk_id:
			var reason := _skill_disabled_reason(skill)
			if not reason.is_empty():
				_on_status_clicked(reason)
				return
	_on_cancel_select()
	if tutorial != null and not tutorial.allow_skill(sk_id):
		status_label.text = "当前步骤请按引导操作"
		return
	if sk_id in MATERIAL_SKILLS: _begin_skill_pick(sk_id)
	elif sk_id == "assassin_move": _popup_move(-1)
	else: _n().send_use_skill(sk_id)

func _has_buff(p: Dictionary, buff_type: String) -> bool:
	for b in p.get("buffs", []):
		if b.get("type", "") == buff_type: return true
	return false

# 目标暴露：弹对方手牌选择（选择后发送 chosen_uid）
func _show_exposed_hand_pick(card_uid: int, type_id: String, target_idx: int, extra: Dictionary):
	var target = null
	for p in _game_state.players:
		if p.index == target_idx: target = p; break
	var c = Control.new()
	c.name = "ExposedHandPick"
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 640, 460)
	var act = "夺取" if type_id == "seize" else "丢弃"
	vb.add_child(_lbl("%s目标「%s」已暴露：选择要%s的手牌" % [Config.card_name(type_id),
		target.get("char_name", "?"), act]))
	var has_any = false
	for cd in target.get("hand", []):
		has_any = true
		var b = _mkbtn(Config.card_name(str(cd.type_id)))
		b.pressed.connect(func(uid = int(cd.uid)):
			c.queue_free()
			var send_extra = {"chosen_uid": uid}
			for k in extra: send_extra[k] = extra[k]
			_submit_card(card_uid, send_extra)
		)
		vb.add_child(b)
	if not has_any:
		vb.add_child(_lbl("对方没有手牌"))
	var cl = _mkbtn("取消")
	cl.pressed.connect(func(): c.queue_free())
	vb.add_child(cl)
	add_child(c)

# ---- 蔓生树妖：除根与播种交互 ----
var _skip_root_choice: bool = false

# 附近（所在格+相邻格）是否有可除根的蔓生种子
func _has_removable_seed() -> bool:
	var me = _find_self()
	if me.is_empty(): return false
	var geo = MapGeometry.new()
	geo.set_mode(MapGeometry.MODE_HEX if _board_hex else MapGeometry.MODE_LINEAR)
	var my_pos = geo.from_dict(me.get("position", {}))
	for it in _game_state.get("items", []):
		if it.get("item_type", "") != "vine_seed": continue
		if geo.distance(my_pos, geo.from_dict(it.get("position", {}))) <= 0:
			return true
	return false

# 近战/重击打出时二选一：正常攻击 / 除根
func _show_attack_or_root(card_uid: int, type_id: String):
	var c = Control.new()
	c.name = "AttackOrRoot"
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 620, 360)
	vb.add_child(_lbl("附近有蔓生种子，选择操作："))
	var atk = _mkbtn("攻击（正常打出）")
	var card_data: Dictionary = {}
	for data in _find_self().get("hand", []):
		if int(data.uid) == card_uid: card_data = data; break
	atk.disabled = not bool(card_data.get("ap_affordable", true)) or (card_data.has("valid_attack_targets") and card_data.valid_attack_targets.is_empty())
	if atk.disabled: atk.text = "攻击（行动点不足或没有近身目标）"
	atk.pressed.connect(func():
		c.queue_free()
		_skip_root_choice = true
		_selected_uid = card_uid
		_selected_type = type_id
		confirm_btn.visible = true
		cancel_btn.visible = true
		_on_confirm_card()
	)
	vb.add_child(atk)
	var root = _mkbtn("除根（清除种子，耗1攻击点）")
	root.text = "除根（清除种子，耗%d攻击点）" % int(card_data.get("root_cost", 1))
	root.disabled = not bool(card_data.get("root_available", true))
	root.pressed.connect(func():
		c.queue_free()
		_enter_root_pick(card_uid)
	)
	vb.add_child(root)
	var cl = _mkbtn("取消")
	cl.pressed.connect(func(): c.queue_free())
	vb.add_child(cl)
	add_child(c)

# 除根：进入棋盘选格模式（点击地格道具进行摧毁，与"摧毁-拆除道具"同交互）
func _enter_root_pick(card_uid: int):
	_selected_uid = card_uid
	_selected_type = "vine_remove"
	confirm_btn.visible = false
	cancel_btn.visible = true
	status_label.text = "点击要除根的蔓生种子所在格"

# 技能按钮行：每个主动技能一个按钮直接使用（多技能角色并排显示，3+ 技能自动加宽）
func _skill_disabled_reason(skill: Dictionary) -> String:
	if not _is_my_turn: return "尚未轮到你的出牌阶段"
	if _game_state.get("waiting_for_discard", false): return "弃牌阶段不能使用技能"
	if _game_state.get("response_pending", false): return "请先完成响应"
	if int(_game_state.get("waiting_for_weapon_choice", -1)) >= 0 or _game_state.get("wind_bow_pending", false): return "请先完成当前选择"
	return str(skill.get("blocked_reason", "" if skill.get("available", true) else "暂时不可用"))

func _refresh_skill_row(me: Dictionary):
	for c in skill_row.get_children():
		skill_row.remove_child(c)  # 立即移除（queue_free 延迟删除，同帧多次刷新会残留重复按钮）
		c.queue_free()
	var skills = me.get("active_skills", [])
	if skills.is_empty():
		skill_row.visible = false
		return
	skill_row.visible = true
	for sk in skills:
		var b = Button.new()
		b.text = sk.get("name", sk.get("id", "技能"))
		b.add_theme_font_size_override("font_size", 28)
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(150, 90)
		b.tooltip_text = sk.get("desc", "")  # 悬停/长按显示技能完整描述（含限制如"不能推人"）
		var reason := _skill_disabled_reason(sk)
		if sk.id == _skill_pick:
			b.text += "\n选择中"
			b.disabled = true
			var active_style := StyleBoxFlat.new()
			active_style.bg_color = Color("192d48")
			active_style.border_color = CardWidget.SKILL_COLOR
			active_style.set_border_width_all(3)
			active_style.set_corner_radius_all(6)
			b.add_theme_stylebox_override("disabled", active_style)
			b.add_theme_color_override("font_disabled_color", CardWidget.SKILL_COLOR)
			skill_row.add_child(b)
			continue
		b.disabled = not reason.is_empty()
		if b.disabled:
			b.modulate = Color(0.55, 0.55, 0.55)
			b.add_theme_color_override("font_disabled_color", Color(0.85, 0.85, 0.85))
			b.tooltip_text = reason + "\n\n" + b.tooltip_text
			b.gui_input.connect(func(event):
				if (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed) or (event is InputEventScreenTouch and event.pressed):
					_on_status_clicked(reason)
			)
		b.pressed.connect(func(sid = sk.id): _exec_skill(sid))
		skill_row.add_child(b)


func _on_hand_revealed(cards: Array, from_idx: int = -1):
	var old = get_node_or_null("RevealedHandPopup")
	if old != null:
		remove_child(old)
		old.queue_free()
	var c = Control.new()
	c.name = "RevealedHandPopup"
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 640, 460)
	# 多人局明确"谁"的手牌（鹰眼等查看效果）
	var who = "对方"
	for p in _game_state.players:
		if p.index == from_idx:
			who = "P%d %s" % [from_idx + 1, p.get("char_name", "?")]
			break
	vb.add_child(_lbl("%s的手牌：" % who))
	if cards.is_empty():
		vb.add_child(_lbl("  (无手牌)"))
	else:
		for tid in cards:
			vb.add_child(_lbl("  " + Config.card_name(tid)))
	var cb = _mkbtn("关闭")
	cb.pressed.connect(func(): c.queue_free()); vb.add_child(cb)
	add_child(c)

func _show_fighter_popup():
	# 场景切换/结束瞬间状态刷新会触发：battle_ui 已离树，跳过避免 get_viewport_rect 报错
	if not is_inside_tree():
		return
	# 防堆叠：状态刷新会多次触发，先移除旧弹窗
	var old = get_node_or_null("SwordsmanPopup")
	if old != null and not old.is_queued_for_deletion(): return
	var c = Control.new()
	c.name = "SwordsmanPopup"
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 620, 320)
	vb.add_child(_lbl("斗士技能: 近战命中后"))
	var hb = HBoxContainer.new(); vb.add_child(hb)
	var hbtn = _mkbtn("回2HP")
	hbtn.pressed.connect(func(): c.queue_free(); _n().send_fighter_choice("heal"))
	hb.add_child(hbtn)
	var dbtn = _mkbtn("抽1张牌")
	dbtn.pressed.connect(func(): c.queue_free(); _n().send_fighter_choice("draw"))
	hb.add_child(dbtn)
	add_child(c)

func _on_end_turn():
	if not _skill_pick.is_empty(): return
	if _submitting: return
	if not _is_my_turn:
		return
	if tutorial != null and not tutorial.allow_end_turn():
		status_label.text = "当前步骤请按引导操作"
		return
	if _game_state.get("waiting_for_discard", false):
		_n().send_confirm_discard(_discard_selected.duplicate())
		_discard_selected.clear()
		return
	# 结束出牌防误触：首次点击进入"确认中"（按钮变橙+提示），3 秒内再点才真正结束；
	# 超时或操作其他卡牌（状态刷新）自动还原。撤销结束出牌需回滚弃牌/回合流转，
	# 服务端权威下风险高，双击确认是更稳妥的方案。
	var now = Time.get_ticks_msec()
	if _end_confirm_at == 0 or now - _end_confirm_at > 3000:
		_end_confirm_at = now
		end_turn_btn.text = "再点一次确认结束"
		end_turn_btn.add_theme_color_override("font_color", Color(1, 0.6, 0.3))
		status_label.text = "再次点击「结束出牌」确认（3 秒后自动取消）"
		var click_at: int = now
		get_tree().create_timer(3.0).timeout.connect(func():
			# 期间若有新的确认点击（_end_confirm_at 更新）或已真正结束，跳过还原
			if is_instance_valid(self) and _end_confirm_at != 0 and _end_confirm_at == click_at:
				_end_confirm_at = 0
				end_turn_btn.text = "结束出牌"
				end_turn_btn.remove_theme_color_override("font_color")
				status_label.text = ""
		)
		return
	_end_confirm_at = 0
	end_turn_btn.text = "结束出牌"
	end_turn_btn.remove_theme_color_override("font_color")
	_n().send_end_turn()
