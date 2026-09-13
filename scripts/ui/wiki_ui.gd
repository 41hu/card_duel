extends Control
const Catalog = preload("res://scripts/ui/wiki_catalog.gd")
const INK = Color("24343b")
const MUTED = Color("65767d")
const ACCENT = Color("206c7b")
const CATEGORIES = {"chars": "角色", "cards": "卡牌", "equipment": "装备", "status": "状态", "rules": "规则", "all": "全部"}
static var memory: Dictionary = {}
var entries: Array = []
var category := "chars"
var selected := ""
var narrow := false
var history: Array = []
var _search: LineEdit
var _tabs: HBoxContainer
var _body: HBoxContainer
var _list_scroll: ScrollContainer
var _rows: VBoxContainer
var _detail_scroll: ScrollContainer
var _detail: VBoxContainer
var _back: Button
var _home: Button
var _count: Label
var _list_position := 0
var _restoring := false

func _ready():
	entries = Catalog.new().build()
	_build()
	category = memory.get("category", "chars")
	_render_list()
	if not selected.is_empty(): _render_detail()
	resized.connect(_layout)
	_layout()
	_restore_scroll.call_deferred()
	BackHandler.scene_back = _go_back

func _exit_tree():
	memory = {"category": category}
	if BackHandler.scene_back == _go_back: BackHandler.scene_back = Callable()

func _label(text: String, font_size: int, color: Color = INK) -> Label:
	var l = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _button(text: String, action: Callable) -> Button:
	var b = Button.new()
	b.text = text
	b.custom_minimum_size.y = 72
	b.add_theme_font_size_override("font_size", 30)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]: b.add_theme_color_override(state, INK)
	var normal = StyleBoxFlat.new()
	normal.bg_color = Color.WHITE
	normal.content_margin_left = 20
	normal.content_margin_right = 20
	normal.content_margin_top = 10
	normal.content_margin_bottom = 10
	b.add_theme_stylebox_override("normal", normal)
	var hover = normal.duplicate()
	hover.bg_color = Color("e2eff0")
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	var focus = StyleBoxFlat.new()
	focus.bg_color = Color.TRANSPARENT
	focus.border_color = ACCENT
	focus.set_border_width_all(2)
	b.add_theme_stylebox_override("focus", focus)
	b.pressed.connect(action)
	return b

func _build():
	var bg = ColorRect.new()
	bg.color = Color("eef2f2")
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var margin = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]: margin.add_theme_constant_override("margin_" + edge, 36)
	add_child(margin)
	var main = VBoxContainer.new()
	main.add_theme_constant_override("separation", 22)
	margin.add_child(main)
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 28)
	main.add_child(header)
	_back = _button("‹ 返回", _go_back)
	header.add_child(_back)
	_home = _button("主界面", _go_home)
	header.add_child(_home)
	var title = _label("游戏百科", 40)
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_count = _label("", 26, MUTED)
	_count.autowrap_mode = TextServer.AUTOWRAP_OFF
	_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_count)
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 8)
	main.add_child(_tabs)
	for key in CATEGORIES:
		var b = _button(CATEGORIES[key], func(): _select_category(key))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.set_meta("category", key)
		_tabs.add_child(b)
	_search = LineEdit.new()
	_search.custom_minimum_size.y = 74
	_search.placeholder_text = "搜索名称、技能或效果"
	_search.clear_button_enabled = true
	_search.add_theme_font_size_override("font_size", 30)
	_search.add_theme_color_override("font_color", INK)
	_search.add_theme_color_override("font_placeholder_color", MUTED)
	var search_style = StyleBoxFlat.new()
	search_style.bg_color = Color.WHITE
	search_style.set_content_margin_all(18)
	_search.add_theme_stylebox_override("normal", search_style)
	_search.add_theme_stylebox_override("focus", search_style)
	_search.text_changed.connect(func(_text):
		selected = ""
		history.clear()
		_list_position = 0
		_render_list()
		_layout()
	)
	main.add_child(_search)
	_body = HBoxContainer.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 36)
	main.add_child(_body)
	_list_scroll = ScrollContainer.new()
	_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(_list_scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 8)
	_list_scroll.add_child(_rows)
	_list_scroll.get_v_scroll_bar().value_changed.connect(func(value):
		if not _restoring and _list_scroll.visible: _list_position = int(value)
	)
	_detail_scroll = ScrollContainer.new()
	_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(_detail_scroll)
	var pad = MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for edge in ["left", "right"]: pad.add_theme_constant_override("margin_" + edge, 20)
	_detail_scroll.add_child(pad)
	_detail = VBoxContainer.new()
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.add_theme_constant_override("separation", 26)
	pad.add_child(_detail)

func _layout():
	if _body == null: return
	var physical = DisplayServer.window_get_size()
	narrow = physical.x < 1250 or get_viewport_rect().size.x < 1400
	_list_scroll.custom_minimum_size.x = 0 if narrow else 450
	_list_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL if narrow else Control.SIZE_FILL
	_list_scroll.visible = not narrow or selected.is_empty()
	_detail_scroll.visible = not selected.is_empty()
	if not narrow and selected.is_empty():
		_detail_scroll.show()
		_clear(_detail)
		_detail.add_child(_label("选择一个条目", 34, MUTED))
	_back.text = "‹ 条目列表" if not selected.is_empty() else "‹ 返回"
	_tabs.visible = not (narrow and not selected.is_empty())
	_search.visible = _tabs.visible

func _clear(node: Node):
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()

func _select_category(key: String):
	category = key
	selected = ""
	history.clear()
	_list_position = 0
	_render_list()
	_layout()
	_restore_scroll.call_deferred()

func _render_list():
	_restoring = true
	_clear(_rows)
	var query := _search.text.strip_edges().to_lower()
	var found := 0
	for e in entries:
		if category != "all" and e.category != category: continue
		if not query.is_empty() and not query in (e.name + " " + e.summary + " " + e.body).to_lower(): continue
		found += 1
		var row = _button("", func(): _open_entry(e.id))
		row.custom_minimum_size.y = 116
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var layout = HBoxContainer.new()
		layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		layout.offset_left = 22
		layout.offset_right = -22
		layout.offset_top = 16
		layout.offset_bottom = -16
		layout.add_theme_constant_override("separation", 20)
		row.add_child(layout)
		if e.has("portrait") or not e.icon.is_empty():
			layout.add_child(_image_slot(e.get("portrait", e.icon), 56, e.name.left(1)))
		var copy = VBoxContainer.new()
		copy.mouse_filter = Control.MOUSE_FILTER_IGNORE
		copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		copy.add_theme_constant_override("separation", 8)
		layout.add_child(copy)
		copy.add_child(_label(e.name, 32, ACCENT if e.id == selected else INK))
		var summary = _label(e.summary, 25, MUTED)
		summary.max_lines_visible = 1
		summary.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		copy.add_child(summary)
		layout.add_child(_label("›", 32, MUTED))
		_rows.add_child(row)
	if found == 0: _rows.add_child(_label("没有找到相关条目", 30, MUTED))
	_count.text = "%d 个条目" % found
	for tab in _tabs.get_children(): tab.add_theme_color_override("font_color", ACCENT if tab.get_meta("category") == category else MUTED)
	_restore_scroll.call_deferred()

func _restore_scroll():
	_list_scroll.scroll_vertical = _list_position
	_restoring = false

func _open_entry(id: String):
	if not selected.is_empty(): history.append({"id": selected, "scroll": _detail_scroll.scroll_vertical})
	selected = id
	_render_detail()
	_layout()

func _render_detail(scroll: int = 0):
	_clear(_detail)
	for e in entries:
		if e.id != selected: continue
		_detail.add_child(_label(CATEGORIES[e.category], 24, ACCENT))
		var heading = HBoxContainer.new()
		heading.add_theme_constant_override("separation", 24)
		if e.has("portrait"): heading.add_child(_image_slot(e.portrait, 96, e.name.left(1)))
		var title = _label(e.name, 44)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		heading.add_child(title)
		_detail.add_child(heading)
		_detail.add_child(_label(e.summary, 28, MUTED))
		_detail.add_child(HSeparator.new())
		if not e.get("sections", []).is_empty():
			for section in e.sections: _add_detail_section(section)
		else:
			for paragraph in e.body.split("\n\n", false):
				var p = _label(paragraph, 30)
				p.add_theme_constant_override("line_spacing", 10)
				_detail.add_child(p)
		var related: Array = []
		for other in entries:
			if other.id != e.id and other.name.length() >= 2 and other.name in e.body: related.append(other)
		if not related.is_empty():
			_detail.add_child(HSeparator.new())
			_detail.add_child(_label("相关条目", 28, MUTED))
			for other in related:
				var link = _button(other.name + "  ›", func(): _open_entry(other.id))
				link.alignment = HORIZONTAL_ALIGNMENT_LEFT
				_detail.add_child(link)
		break
	_detail_scroll.set_deferred("scroll_vertical", scroll)

func _image_slot(path: String, extent: int, fallback: String) -> Control:
	var slot = Control.new()
	slot.custom_minimum_size = Vector2(extent, extent)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(path):
		var image = TextureRect.new()
		image.texture = load(path)
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		image.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(image)
	else:
		var initial = _label(fallback, 30, ACCENT)
		initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		initial.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		slot.add_child(initial)
	return slot

func _add_detail_section(section: Dictionary):
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 12)
	margin.mouse_filter = Control.MOUSE_FILTER_PASS
	var block = VBoxContainer.new()
	block.add_theme_constant_override("separation", 12)
	block.mouse_filter = Control.MOUSE_FILTER_PASS
	margin.add_child(block)
	var heading = HBoxContainer.new()
	heading.add_theme_constant_override("separation", 18)
	heading.add_child(_image_slot(section.icon, 56, "技" if section.kind == "skill" else "物"))
	var title = _label(section.title, 32, ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title)
	block.add_child(heading)
	var body = _label(section.body, 30)
	body.add_theme_constant_override("line_spacing", 10)
	block.add_child(body)
	_detail.add_child(margin)

func _go_home():
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _go_back() -> bool:
	if not history.is_empty():
		var previous = history.pop_back()
		selected = previous.id
		_render_detail(previous.scroll)
		_layout()
	elif not selected.is_empty():
		selected = ""
		_layout()
		_restore_scroll.call_deferred()
	else:
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	return true
