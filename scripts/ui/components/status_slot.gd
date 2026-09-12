# status_slot.gd — 状态槽：固定尺寸图标 + 数值角标（buff/DoT/冻结通用）
# icon 支持两种占位，后期加美术资源时只需把注册表里的 icon 换成 "res://art/xxx.png"：
#   · "res://..." 开头 → 自动渲染 TextureRect（贴图模式）
#   · 其他字符串 → 渲染为单字 Label（如 "灼"/"毒"），不依赖 emoji 字体
# 悬停显示 tooltip（PC），点击发出 clicked 信号显示详情（移动端无 hover）
extends Button

const Style = preload("res://scripts/theme/style_const.gd")

signal clicked(detail_text: String)
var _content: VBoxContainer

func _ready():
	_update_size.call_deferred()

func _notification(what: int):
	if what == NOTIFICATION_THEME_CHANGED and is_inside_tree():
		_update_size.call_deferred()

func _update_size():
	if not is_inside_tree() or _content == null: return
	custom_minimum_size = (_content.get_combined_minimum_size() + Vector2(8, 8)).max(Vector2(46, 46))

func setup(icon_text: String, value_text: String, tooltip: String, accent: Color):
	custom_minimum_size = Vector2(46, 46)
	tooltip_text = tooltip
	flat = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.5)
	sb.set_corner_radius_all(6)
	sb.set_border_width_all(2)
	sb.border_color = accent
	add_theme_stylebox_override("normal", sb)
	var hv := sb.duplicate()
	hv.bg_color = Color(1, 1, 1, 0.12)
	add_theme_stylebox_override("hover", hv)
	add_theme_stylebox_override("pressed", hv)
	add_theme_stylebox_override("focus", hv)
	var vb := VBoxContainer.new()
	_content = vb
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 4; vb.offset_right = -4
	vb.offset_top = 4; vb.offset_bottom = -4
	add_child(vb)
	if icon_text.begins_with("res://"):
		var tex := TextureRect.new()
		tex.texture = load(icon_text)
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.custom_minimum_size = Vector2(26, 26)
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(tex)
	else:
		var il := Label.new()
		il.mouse_filter = Control.MOUSE_FILTER_IGNORE
		il.text = icon_text
		il.add_theme_font_size_override("font_size", Style.fs(20))
		il.add_theme_color_override("font_color", accent)
		il.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(il)
	var vl := Label.new()
	vl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vl.text = value_text
	vl.add_theme_font_size_override("font_size", Style.fs(13))
	vl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(vl)
	custom_minimum_size = vb.get_combined_minimum_size() + Vector2(8, 8)
	custom_minimum_size = custom_minimum_size.max(Vector2(46, 46))
	pressed.connect(func():
		clicked.emit(tooltip)
	)
