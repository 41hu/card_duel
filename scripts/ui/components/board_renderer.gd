# BoardRenderer — 棋盘渲染组件
# 双模式：
#   LINEAR（2 人局）：Panel 逐格渲染（11 格线性），可点击选格，不支持拖动
#   HEX（4 人局）：单个 Control 自绘六边形蜂窝（真六边形形状，方便目测距离），
#     棋盘居中显示，支持鼠标拖动平移视图（_drag_offset），点击选格。
# 拖动/自绘只在 HEX 模式生效；切换模式时清掉 Panel 格子。
extends Control

const Style = preload("res://scripts/theme/style_const.gd")
const Geometry = preload("res://scripts/core/map_geometry.gd")
signal cell_clicked(cell_pos: Vector2i)
signal cell_long_pressed(cell_pos: Vector2i)  # 长按有道具的地格：查看道具详情
signal cell_released(cell_pos: Vector2i)      # 松手（无论是否长按，用于隐藏悬浮框）

const LONG_PRESS_MS = 500  # 长按判定：按住超过 0.5 秒

var _geo = Geometry.new()
var _cells: Dictionary = {}  # Vector2i → Panel（仅 LINEAR 模式使用）
var _mode: int = Geometry.MODE_LINEAR

# 长按检测状态（LINEAR/HEX 共用）
var _press_time: int = 0
var _pressed_cell: Vector2i = Vector2i(-999, -999)  # -999 = 未按下
var _long_fired: bool = false
var _press_pos_px: Vector2 = Vector2.ZERO

func _process(_delta):
	# 长按判定：按住超过阈值且未滑动取消 → 发长按信号（弹道具悬浮框）
	if _pressed_cell != Vector2i(-999, -999) and not _long_fired:
		if Time.get_ticks_msec() - _press_time >= LONG_PRESS_MS:
			_long_fired = true
			cell_long_pressed.emit(_pressed_cell)
	# 长按已触发但鼠标/触摸已释放（滑出格子后松手收不到 release 事件）：补发释放信号
	if _long_fired and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_long_fired = false
		_pressed_cell = Vector2i(-999, -999)
		cell_released.emit(Vector2i(-999, -999))

# 格子全局中心点（悬浮框定位用；LINEAR 用 Panel 位置，HEX 用自绘六边形中心）
func cell_global_center(pos: Vector2i) -> Vector2:
	if _mode == Geometry.MODE_HEX:
		return global_position + _hex_center(pos)
	if _cells.has(pos):
		return _cells[pos].global_position + Vector2(50, 50)
	return global_position

# HEX 自绘状态
var _players_draw: Array = []
var _items_draw: Array = []
var _my_index: int = 0
var _drag_offset: Vector2 = Vector2.ZERO  # 拖动平移量（视图居中后叠加）
var _drag_start: Vector2 = Vector2.ZERO
var _dragging: bool = false

func _ready():
	_rebuild_cells()

# 切换地图模式（线性/六边形）并重建；模式不变时跳过
func set_geometry_mode(mode: int):
	if mode == _mode: return
	_mode = mode
	_geo.set_mode(mode)
	_drag_offset = Vector2.ZERO
	_rebuild_cells()
	queue_redraw()

func _rebuild_cells():
	for key in _cells:
		_cells[key].queue_free()
	_cells.clear()
	if _mode == Geometry.MODE_HEX:
		return  # HEX 模式由 _draw 自绘，不需要 Panel
	for x in range(Geometry.WIDTH):
		var pos = Vector2i(x, 0)
		var cell = _create_cell(pos)
		add_child(cell)
		_cells[pos] = cell

# 创建一个格子及其标签（仅 LINEAR 模式）
func _create_cell(pos: Vector2i) -> Panel:
	var p = Panel.new()
	p.position = Vector2(pos.x * 100, 0)
	p.size = Vector2(100, 100)
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
	l.size = Vector2(100, 100)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", Style.fs(26))
	l.add_theme_color_override("font_color", Style.CELL_TEXT)
	p.add_child(l)
	return p

# 处理格子点击事件（LINEAR 模式）：按下记录起点，短按=选格点击，长按=道具详情，
# 滑动超过阈值取消（既不点击也不长按）；HEX 模式走 _gui_input
func _on_cell_input(event: InputEvent, cell_pos: Vector2i):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressed_cell = cell_pos
			_press_time = Time.get_ticks_msec()
			_long_fired = false
			_press_pos_px = event.position
		else:
			var was_long = _long_fired
			_pressed_cell = Vector2i(-999, -999)
			cell_released.emit(cell_pos)
			if not was_long:
				cell_clicked.emit(cell_pos)  # 短按=正常点击；长按后松手不触发点击（防误触）
	elif event is InputEventMouseMotion and _pressed_cell != Vector2i(-999, -999):
		if (event.position - _press_pos_px).length() > 12.0:
			_pressed_cell = Vector2i(-999, -999)  # 滑动取消长按与点击

# 根据玩家和地格道具数据刷新棋盘显示（position 为 {x,y} 协议结构或 Vector2i）
func update(players: Array, items: Array, my_index: int):
	_players_draw = players
	_items_draw = items
	_my_index = my_index
	if _mode == Geometry.MODE_HEX:
		queue_redraw()
		return
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
	# 有道具的格子红色边框高亮（存在标记，与选中态区分）
	var has_item := {}
	for it in items:
		var pos2: Vector2i = _geo.from_dict(it.position)
		if _cells.has(pos2):
			has_item[pos2] = true
	for key in _cells:
		var sb: StyleBoxFlat = _cells[key].get_theme_stylebox("panel")
		if has_item.has(key):
			sb.border_color = Color(1, 0.35, 0.3, 0.95)
			sb.set_border_width_all(3)
		else:
			sb.border_color = Style.CELL_BORDER
			sb.set_border_width_all(2)
	for it in items:
		var pos: Vector2i = _geo.from_dict(it.position)
		if _cells.has(pos):
			_cells[pos].get_child(0).text += " " + item_marks.get(it.item_type, "?")

# ==================== HEX 自绘（六边形蜂窝） ====================
# 像素布局：尖顶六边形，轴向 (q, r) → 像素（棋盘局部坐标，中心格 (0,0) 在原点）
# 改视觉密度（更挤/更松）：调这两个系数即可；反算（_pixel_to_hex）自动跟随
func _hex_pixel(pos: Vector2i) -> Vector2:
	return Vector2(86 * (pos.x + pos.y * 0.5), 74 * pos.y)

# 六边形格中心（含视图居中 + 拖动偏移）
func _hex_center(pos: Vector2i) -> Vector2:
	return _hex_pixel(pos) + size / 2.0 + _drag_offset

func _draw():
	if _mode != Geometry.MODE_HEX: return
	var radius = 40.0
	var font = ThemeDB.fallback_font
	# 有道具的格子：红色六边形边框（存在标记）
	var has_item := {}
	for it in _items_draw:
		has_item[_geo.from_dict(it.position)] = true
	for q in range(-Geometry.HEX_RADIUS, Geometry.HEX_RADIUS + 1):
		for r in range(-Geometry.HEX_RADIUS, Geometry.HEX_RADIUS + 1):
			var pos = Vector2i(q, r)
			if not _geo.is_valid(pos): continue
			var c = _hex_center(pos)
			_draw_hex_cell(c, radius)
			if has_item.has(pos):
				var pts2 = PackedVector2Array()
				for i2 in range(6):
					var ang2 = PI / 180.0 * (60.0 * i2 - 30.0)
					pts2.append(c + Vector2(cos(ang2), sin(ang2)) * radius)
				draw_polyline(pts2 + PackedVector2Array([pts2[0]]), Color(1, 0.35, 0.3, 0.95), 4.0)
			# 格坐标编号（小字）
			draw_string(font, c + Vector2(-14, 4), "%d,%d" % [q, r],
				HORIZONTAL_ALIGNMENT_LEFT, -1, Style.fs(16), Style.CELL_TEXT)
	# 道具标记
	var item_marks = {"trap": "X", "snare": "S"}
	for it in _items_draw:
		var pos: Vector2i = _geo.from_dict(it.position)
		if not _geo.is_valid(pos): continue
		var c = _hex_center(pos)
		draw_string(font, c + Vector2(-10, 30), item_marks.get(it.item_type, "?"),
			HORIZONTAL_ALIGNMENT_LEFT, -1, Style.fs(20), Color(1, 0.9, 0.5))
	# 玩家棋子
	for p in _players_draw:
		if p.get("eliminated", false): continue
		var pos: Vector2i = _geo.from_dict(p.position)
		if not _geo.is_valid(pos): continue
		var c = _hex_center(pos)
		var col = Style.ME_GREEN if p.index == _my_index else Style.OPP_RED
		draw_circle(c, 24, col)
		draw_circle(c, 24, Color(0, 0, 0, 0.25), false, 2.0)
		draw_string(font, c + Vector2(-14, 9), "P%d" % (p.index + 1),
			HORIZONTAL_ALIGNMENT_LEFT, -1, Style.fs(22), Color.WHITE)

func _draw_hex_cell(center: Vector2, radius: float):
	var pts = PackedVector2Array()
	for i in range(6):
		var ang = PI / 180.0 * (60.0 * i - 30.0)  # 尖顶朝上
		pts.append(center + Vector2(cos(ang), sin(ang)) * radius)
	draw_colored_polygon(pts, Style.CELL_BG)
	draw_polyline(pts + PackedVector2Array([pts[0]]), Style.CELL_BORDER, 2.0)

# 鼠标位置 → 最近六边形格（遍历 37 格找最近中心，简单可靠）
func _pixel_to_hex(px: Vector2) -> Vector2i:
	var best = Vector2i.ZERO
	var best_d = 1e9
	for q in range(-Geometry.HEX_RADIUS, Geometry.HEX_RADIUS + 1):
		for r in range(-Geometry.HEX_RADIUS, Geometry.HEX_RADIUS + 1):
			var pos = Vector2i(q, r)
			if not _geo.is_valid(pos): continue
			var d = (_hex_center(pos) - px).length()
			if d < best_d:
				best_d = d
				best = pos
	return best

# HEX 输入：左键拖动平移视图；短按（位移 < 8px 且未长按）视为点击选格；
# 按住 0.5 秒=长按道具详情（与 LINEAR 一致的手势语义）
func _gui_input(event: InputEvent):
	if _mode != Geometry.MODE_HEX: return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_start = event.position
			_pressed_cell = _pixel_to_hex(event.position)
			_press_time = Time.get_ticks_msec()
			_long_fired = false
		else:
			_dragging = false
			var was_long = _long_fired
			var clicked = _pixel_to_hex(event.position)
			_pressed_cell = Vector2i(-999, -999)
			cell_released.emit(clicked)
			if not was_long and (_drag_start - event.position).length() < 8.0:
				cell_clicked.emit(clicked)
	elif event is InputEventMouseMotion and _dragging:
		_drag_offset += event.relative
		_drag_offset.x = clampf(_drag_offset.x, -400, 400)  # 防拖飞：限制平移范围
		_drag_offset.y = clampf(_drag_offset.y, -300, 300)
		if (_drag_start - event.position).length() > 8.0:
			_pressed_cell = Vector2i(-999, -999)  # 拖动取消长按与点击
		queue_redraw()
