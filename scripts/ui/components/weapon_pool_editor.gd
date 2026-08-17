# weapon_pool_editor.gd — 武器幻化池编辑组件（卡组编辑页复用）
# 布局：顶部标题 + 返回按钮；下方三列（近战/远程/法术武器），
#   每列顶部=类型按钮（点击展开/收拢），已选武器金框在上，展开后未选武器白框在下。
# 交互：点击切换（金→移出/白→加入）；拖动亦可（金框下拖=移出、白框上拖=加入）。
# 校验：返回时每类型必须恰好 4 把，否则恢复默认池 + 红色提示"武器池只能为四把武器"。
extends Control

const Style = preload("res://scripts/theme/style_const.gd")
const DeckData = preload("res://scripts/data/deck_data.gd")

var pool: Dictionary = {}
var _on_save: Callable = Callable()
var _error_label: Label
var _columns: Dictionary = {}  # type -> {box: VBox(已选区), unbox: VBox(未选区), title: Button, expanded: bool}

func setup(initial_pool: Dictionary, on_save: Callable):
	pool = DeckData.normalize_weapon_pool(initial_pool)
	_on_save = on_save
	_build()

func _build():
	for c in get_children():
		c.queue_free()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.12, 0.18, 1)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	# 顶部：返回按钮（左上）+ 标题
	var back := Button.new()
	back.text = "← 返回卡组编辑"
	back.position = Vector2(24, 24)
	back.size = Vector2(Style.fs(280), Style.fs(90))
	back.add_theme_font_size_override("font_size", Style.fs(28))
	back.pressed.connect(_on_back)
	add_child(back)
	var title := Label.new()
	title.text = "武器池编辑（每类型 4 把）"
	title.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	title.offset_top = 24
	title.offset_bottom = 110
	title.offset_left = -400
	title.offset_right = 400
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", Style.fs(40))
	title.add_theme_color_override("font_color", Style.MODE_TITLE)
	add_child(title)
	# 红色错误提示（4 把校验失败时显示）
	_error_label = Label.new()
	_error_label.visible = false
	_error_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_error_label.offset_top = 110
	_error_label.offset_bottom = 160
	_error_label.offset_left = -400
	_error_label.offset_right = 400
	_error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_error_label.add_theme_font_size_override("font_size", Style.fs(26))
	_error_label.add_theme_color_override("font_color", Style.ERROR_RED)
	add_child(_error_label)
	# 三列
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_top = 170
	row.offset_bottom = -20
	row.offset_left = 60
	row.offset_right = -60
	row.add_theme_constant_override("separation", 24)
	add_child(row)
	_columns.clear()
	for t in DeckData.WEAPON_POOL_TYPES:
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 8)
		row.add_child(col)
		var title_btn := Button.new()
		title_btn.text = "▸ %s" % _type_name(t)
		title_btn.add_theme_font_size_override("font_size", Style.fs(30))
		title_btn.pressed.connect(_toggle_expand.bind(t))
		col.add_child(title_btn)
		var sel_box := VBoxContainer.new()
		sel_box.name = "SelBox"
		sel_box.add_theme_constant_override("separation", 8)
		col.add_child(sel_box)
		var un_box := VBoxContainer.new()
		un_box.name = "UnBox"
		un_box.visible = false  # 默认收拢
		un_box.add_theme_constant_override("separation", 8)
		col.add_child(un_box)
		_columns[t] = {"title": title_btn, "sel": sel_box, "un": un_box, "expanded": false}
	_refresh()

func _type_name(t: String) -> String:
	match t:
		"near": return "近战武器"
		"range": return "远程武器"
		"magic": return "法术武器"
	return t

func _toggle_expand(t: String):
	var col: Dictionary = _columns[t]
	col.expanded = not col.expanded
	_refresh()

# 全部武器 - 池内 = 未选（展开时显示）
func _unselected(t: String) -> Array:
	var out: Array = []
	var sel: Array = pool.get(t, [])
	for wid in Config.WEAPON_DB:
		if str(Config.WEAPON_DB[wid].type) == t and not sel.has(str(wid)):
			out.append(str(wid))
	return out

func _refresh():
	for t in _columns:
		var col: Dictionary = _columns[t]
		var sel: Array = pool.get(t, [])
		col.title.text = "%s %s（%d/%d）" % [
			"▾" if col.expanded else "▸", _type_name(t), sel.size(), DeckData.WEAPON_POOL_SIZE]
		# 已选区（金框）
		for c in col.sel.get_children():
			col.sel.remove_child(c)
			c.queue_free()
		for wid in sel:
			col.sel.add_child(_make_item(str(wid), true, t))
		# 未选区（白框，展开才显示）
		for c in col.un.get_children():
			col.un.remove_child(c)
			c.queue_free()
		col.un.visible = col.expanded
		if col.expanded:
			for wid in _unselected(t):
				col.un.add_child(_make_item(str(wid), false, t))

# 武器项：金框=已选（点击/下拖=移出），白框=未选（点击/上拖=加入）
func _make_item(wid: String, selected: bool, wtype: String) -> Button:
	var b := Button.new()
	b.text = "%s　%s" % [wid, Config.WEAPON_DB[wid].name]
	b.custom_minimum_size = Vector2(0, Style.fs(72))
	b.add_theme_font_size_override("font_size", Style.fs(26))
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(10)
	if selected:
		sb.bg_color = Color(0.42, 0.33, 0.06, 1)
		sb.border_color = Style.MODE_SELECTED
	else:
		sb.bg_color = Color(0.2, 0.22, 0.28, 1)
		sb.border_color = Color(1, 1, 1, 0.75)
	sb.set_border_width_all(3 if selected else 2)
	for state in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(state, sb)
	# 点击切换（拖动不触发 pressed：拖出阈值后 _drag_flag 拦截）
	var drag_flag := [false]
	b.pressed.connect(func():
		if drag_flag[0]:
			drag_flag[0] = false
			return
		if selected:
			_remove_weapon(wid, wtype)
		else:
			_add_weapon(wid, wtype)
	)
	# 拖动手势：金框下拖（dy>48）=移出；白框上拖（dy<-48）=加入
	var start_y := [0.0]
	var pressed_now := [false]
	b.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
			if ev.pressed:
				pressed_now[0] = true
				start_y[0] = ev.position.y
			else:
				pressed_now[0] = false
				start_y[0] = 0.0
		elif ev is InputEventMouseMotion and pressed_now[0]:
			var dy = ev.position.y - start_y[0]
			if dy > 48.0:
				drag_flag[0] = true
				pressed_now[0] = false
				if selected:
					_remove_weapon(wid, wtype)
			elif dy < -48.0:
				drag_flag[0] = true
				pressed_now[0] = false
				if not selected:
					_add_weapon(wid, wtype)
	)
	return b

func _add_weapon(wid: String, wtype: String):
	if pool.get(wtype, []).has(wid): return
	var arr: Array = pool.get(wtype, [])
	arr.append(wid)
	pool[wtype] = arr
	_refresh()

func _remove_weapon(wid: String, wtype: String):
	var arr: Array = pool.get(wtype, [])
	arr.erase(wid)
	pool[wtype] = arr
	_refresh()

# 返回卡组编辑：恰好 4 把才保存；否则恢复默认池 + 红色提示
func _on_back():
	if DeckData.validate_weapon_pool(pool):
		if _on_save.is_valid():
			_on_save.call(pool.duplicate(true))
		queue_free()
		return
	pool = DeckData.default_weapon_pool()
	_refresh()
	_error_label.text = "武器池只能为四把武器"
	_error_label.visible = true
