# CardWidget — 手牌卡牌组件（纯代码创建）
extends Control

const Style = preload("res://scripts/theme/style_const.gd")

signal pressed(card_uid: int)

var _panel: Panel
var _name_label: Label
var _ap_label: Label
var _select_mark: Label

var card_uid: int = -1
var type_id: String = ""
var ap_type: int = -1
var _selected: bool = false
var _respondable: bool = false

func _init():
	custom_minimum_size = Vector2(64, 80)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)

	_ap_label = Label.new()
	_ap_label.position = Vector2(3, 2)
	_ap_label.size = Vector2(20, 16)
	_ap_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel.add_child(_ap_label)

	_name_label = Label.new()
	_name_label.position = Vector2(2, 20)
	_name_label.size = Vector2(60, 38)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.add_child(_name_label)

	_select_mark = Label.new()
	_select_mark.position = Vector2(2, 58)
	_select_mark.size = Vector2(60, 18)
	_select_mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel.add_child(_select_mark)

func _ready():
	gui_input.connect(_on_gui_input)
	mouse_entered.connect(_on_hover)
	mouse_exited.connect(_on_unhover)

func setup(uid: int, tid: String, card_name: String, ap: int, is_discard: bool = false):
	card_uid = uid
	type_id = tid
	ap_type = ap
	_name_label.text = card_name

	match ap:
		Config.APType.ATTACK: _ap_label.text = "攻"
		Config.APType.MOVE:   _ap_label.text = "移"
		Config.APType.FUNCTION: _ap_label.text = "功"
		_:                     _ap_label.text = "免"

	var bg_color = _card_bg_color(ap)
	_apply_panel_style(bg_color, is_discard)

	_name_label.add_theme_font_size_override("font_size", 11)
	_ap_label.add_theme_font_size_override("font_size", 10)
	_select_mark.text = ""
	_selected = false

func _card_bg_color(ap: int) -> Color:
	match ap:
		Config.APType.ATTACK: return Color(0.25, 0.08, 0.08)
		Config.APType.MOVE:   return Color(0.05, 0.12, 0.25)
		Config.APType.FUNCTION: return Color(0.05, 0.2, 0.12)
		_:                     return Color(0.18, 0.15, 0.05)

func _apply_panel_style(bg: Color, is_discard: bool):
	var s = StyleBoxFlat.new()
	s.bg_color = bg
	s.border_width_left = 2; s.border_width_right = 2
	s.border_width_top = 2; s.border_width_bottom = 2
	s.corner_radius_top_left = 6; s.corner_radius_top_right = 6
	s.corner_radius_bottom_left = 6; s.corner_radius_bottom_right = 6
	if is_discard:
		s.border_color = Style.DISCARD_RED
	else:
		s.border_color = bg.lightened(0.3)
	_panel.add_theme_stylebox_override("panel", s)

func set_respondable(v: bool):
	_respondable = v
	if v:
		_select_mark.text = "◈"
		_select_mark.add_theme_color_override("font_color", Style.SELECTED_CYAN)

func set_selected(v: bool):
	_selected = v
	if v:
		_select_mark.text = "◆"
		_select_mark.add_theme_color_override("font_color", Style.SELECTED_CYAN)
		var s = _panel.get_theme_stylebox("panel").duplicate()
		s.border_color = Style.SELECTED_CYAN
		s.border_width_left = 3; s.border_width_right = 3
		s.border_width_top = 3; s.border_width_bottom = 3
		_panel.add_theme_stylebox_override("panel", s)
	else:
		_select_mark.text = "◈" if _respondable else ""
		var is_discard = (_select_mark.text == "✕")
		_apply_panel_style(_card_bg_color(ap_type), is_discard)

func set_discard_mark(active: bool):
	if active:
		_selected = false
		_select_mark.text = "✕"
		_select_mark.add_theme_color_override("font_color", Style.DISCARD_RED)
		_apply_panel_style(_card_bg_color(ap_type), true)

func _on_gui_input(event: InputEvent):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pressed.emit(card_uid)

func _on_hover():
	var s = _panel.get_theme_stylebox("panel").duplicate()
	s.bg_color = s.bg_color.lightened(0.15)
	_panel.add_theme_stylebox_override("panel", s)

func _on_unhover():
	var is_discard = (_select_mark.text == "✕")
	_apply_panel_style(_card_bg_color(ap_type), is_discard)
	if _selected:
		set_selected(true)
	elif _respondable:
		set_respondable(true)
