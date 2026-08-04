# BoardRenderer — 棋盘渲染组件（当前 11 格线性地图，位置 Vector2i(x,0)）
# 格子生成/棋子/道具全部按地图坐标（Vector2i）索引；六边形地图未来只换几何映射
# 作为 Control 节点放入场景，编辑器中可见可拖动
extends Control

const Style = preload("res://scripts/theme/style_const.gd")
const Geometry = preload("res://scripts/core/map_geometry.gd")
signal cell_clicked(cell_pos: Vector2i)

var _geo = Geometry.new()
var _cells: Dictionary = {}  # Vector2i → Panel

func _ready():
	_cells.clear()
	for x in range(Geometry.WIDTH):
		var pos = Vector2i(x, 0)
		var cell = _create_cell(pos)
		add_child(cell)
		_cells[pos] = cell

# 创建一个格子及其标签
func _create_cell(pos: Vector2i) -> Panel:
	var p = Panel.new()
	p.position = Vector2(pos.x * 108, 0)
	p.size = Vector2(104, 104)
	p.set_meta("cell_pos", pos)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.gui_input.connect(func(event): _on_cell_input(event, pos))

	var s = StyleBoxFlat.new()
	s.bg_color = Style.CELL_BG
	s.border_width_left = 2
	s.border_width_right = 2
	s.border_width_top = 2
	s.border_width_bottom = 2
	s.border_color = Style.CELL_BORDER
	p.add_theme_stylebox_override("panel", s)

	var l = Label.new()
	l.position = Vector2(0, 0)
	l.size = Vector2(104, 104)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 26)
	l.add_theme_color_override("font_color", Style.CELL_TEXT)
	p.add_child(l)
	return p

# 处理格子点击事件（坐标传给上层）
func _on_cell_input(event: InputEvent, cell_pos: Vector2i):
	if not (event is InputEventMouseButton):
		return
	if not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return
	cell_clicked.emit(cell_pos)

# 根据玩家和地格道具数据刷新棋盘显示（position 为 {x,y} 协议结构或 Vector2i）
func update(players: Array, items: Array, my_index: int):
	for key in _cells:
		var lbl = _cells[key].get_child(0)
		lbl.text = str(key.x)
		lbl.add_theme_color_override("font_color", Style.CELL_TEXT)

	for p in players:
		var pos: Vector2i = _geo.from_dict(p.position)
		if _cells.has(pos):
			var lbl = _cells[pos].get_child(0)
			lbl.text = "P%d" % (p.index + 1)
			var col = Style.ME_GREEN if p.index == my_index else Style.OPP_RED
			lbl.add_theme_color_override("font_color", col)

	# 道具按类型差异化显示（新增道具类型时在此补充标记）
	var item_marks = {"trap": "X", "snare": "S"}
	for it in items:
		var pos: Vector2i = _geo.from_dict(it.position)
		if _cells.has(pos):
			_cells[pos].get_child(0).text += " " + item_marks.get(it.item_type, "?")
