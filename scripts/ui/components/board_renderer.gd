# BoardRenderer — 11格棋盘渲染组件
# 作为 Control 节点放入场景，编辑器中可见可拖动
extends Control

const Style = preload("res://scripts/theme/style_const.gd")
signal cell_clicked(cell_index: int)

var _cells: Array = []

func _ready():
	_cells.clear()
	for i in range(11):
		var cell = _create_cell(i)
		add_child(cell)
		_cells.append(cell)

# 创建一个格子及其标签
func _create_cell(index: int) -> Panel:
	var x = index * 84
	var p = Panel.new()
	p.position = Vector2(x, 0)
	p.size = Vector2(80, 80)
	p.set_meta("index", index)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.gui_input.connect(func(event): _on_cell_input(event, index))

	var s = StyleBoxFlat.new()
	s.bg_color = Style.CELL_BG
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.border_color = Style.CELL_BORDER
	p.add_theme_stylebox_override("panel", s)

	var l = Label.new()
	l.position = Vector2(0, 0)
	l.size = Vector2(68, 70)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Style.CELL_TEXT)
	p.add_child(l)
	return p

# 处理格子点击事件
func _on_cell_input(event: InputEvent, cell_index: int):
	if not (event is InputEventMouseButton):
		return
	if not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return
	cell_clicked.emit(cell_index)

# 根据玩家和陷阱数据刷新棋盘显示
func update(players: Array, traps: Array, my_index: int):
	for cell in _cells:
		var idx = cell.get_meta("index")
		var lbl = cell.get_child(0)
		lbl.text = str(idx)
		lbl.add_theme_color_override("font_color", Style.CELL_TEXT)

	for p in players:
		var pos = p.position
		if pos >= 0 and pos < _cells.size():
			var lbl = _cells[pos].get_child(0)
			lbl.text = "P%d" % (p.index + 1)
			var col = Style.ME_GREEN if p.index == my_index else Style.OPP_RED
			lbl.add_theme_color_override("font_color", col)

	for t in traps:
		var pos = t.position
		if pos >= 0 and pos < _cells.size():
			_cells[pos].get_child(0).text += " X"
