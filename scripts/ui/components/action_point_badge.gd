extends Control

const PATHS := ["res://art/ui/ap_free.svg", "res://art/ui/ap_attack.svg", "res://art/ui/ap_move.svg", "res://art/ui/ap_function.svg"]
const NAMES := ["免费", "攻击行动点", "移动行动点", "功能行动点"]

var ap_type := 0
var _icon: TextureRect
var _value: Label

func _init():
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon = TextureRect.new()
	_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_SCALE
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_icon)
	_value = Label.new()
	_value.anchor_left = 0.16
	_value.anchor_right = 0.84
	_value.anchor_top = 0.28
	_value.anchor_bottom = 0.96
	_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_value.add_theme_color_override("font_color", Color("f5faf8"))
	_value.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_value)

func setup(kind: int, value: String, font_size: int = 26, depleted: bool = false):
	ap_type = clampi(kind, 0, 3)
	_icon.texture = load(PATHS[ap_type])
	_icon.modulate = Color(0.65, 0.65, 0.65) if depleted else Color.WHITE
	_value.text = value
	_value.add_theme_font_size_override("font_size", font_size)
	tooltip_text = NAMES[ap_type]
