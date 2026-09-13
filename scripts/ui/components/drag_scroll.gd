# drag_scroll.gd — 可拖动内容滚动的 ScrollContainer（桌面鼠标通用；触摸走系统手势 + 轮询兜底）
# 背景：Godot 桌面端 ScrollContainer 默认只能拖滚动条，不能拖内容。
# 双通道互斥：
#   · _gui_input（事件通道，空白/滚动条区按下可拖；MCP 模拟输入可测）：
#     用事件局部坐标差值计算位移（同一坐标系内相对位移 = 屏幕位移）
#   · _process（轮询通道，Input 全局状态驱动）：拖动起点在子按钮上（按钮吞掉事件）时兜底，
#     位移超过阈值才视为拖动（防误触点击）；_gui_active 时跳过，避免双重滚动。
# 拖动激活后递归把内容子树中所有可交互控件临时设为不可点（MOUSE_FILTER_IGNORE），
# 避免滚动过程松手落在某个按钮上误触发点击（拖完恢复）。_content 允许运行时才挂子节点
# （纯代码构建的 UI），因此用惰性缓存而不是 _ready 时固定。
extends ScrollContainer

var _gui_active: bool = false
var _gui_last: Vector2 = Vector2.ZERO
var _gui_accum: float = 0.0
var _drag_active: bool = false
var _last_pos: Vector2 = Vector2.ZERO
var _accum: float = 0.0
var _content: Control = null
var _guard_active: bool = false
var _guard_nodes: Array = []
var _guard_filters: Array = []
var _last_gui_motion_frame := -100
const DRAG_THRESHOLD := 14.0

func _ready():
	_cache_content.call_deferred()

func _cache_content():
	if _content == null and get_child_count() > 0:
		_content = get_child(0)

func _apply_scroll(dy: float) -> bool:
	var max_v := maxi(0, int(get_v_scroll_bar().max_value))
	var before := scroll_vertical
	scroll_vertical = clampi(scroll_vertical - int(dy), 0, max_v)
	return scroll_vertical != before

func _collect_interactive(node: Node):
	for child in node.get_children():
		if child is Control and child.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			_guard_nodes.append(child)
			_guard_filters.append(child.mouse_filter)
		_collect_interactive(child)

func _activate_drag_guard():
	if _guard_active:
		return
	_cache_content()
	if _content == null:
		return
	_guard_active = true
	_guard_nodes.clear()
	_guard_filters.clear()
	_collect_interactive(_content)
	for i in _guard_nodes.size():
		_guard_nodes[i].mouse_filter = Control.MOUSE_FILTER_IGNORE

func _restore_content():
	if not _guard_active:
		return
	_guard_active = false
	for i in _guard_nodes.size():
		_guard_nodes[i].mouse_filter = _guard_filters[i]
	_guard_nodes.clear()
	_guard_filters.clear()

func _gui_input(ev: InputEvent):
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		_gui_active = ev.pressed
		_gui_last = ev.position
		_gui_accum = 0.0
		if not ev.pressed:
			_restore_content()
	elif ev is InputEventMouseMotion and _gui_active:
		var pos: Vector2 = ev.position
		var dy: float = pos.y - _gui_last.y
		_gui_last = pos
		if _gui_accum >= DRAG_THRESHOLD:
			_activate_drag_guard()
			if _apply_scroll(dy):
				_last_gui_motion_frame = Engine.get_process_frames()
		else:
			_gui_accum += absf(dy)

func _process(_delta):
	if not is_visible_in_tree():
		return
	# _gui_input 通道最近两帧确实滚动过则跳过，避免双重滚动；
	# 若 motion 被内容按钮吃掉（_gui_input 收不到），则 _process 兜底接管，滚动不中断。
	if Engine.get_process_frames() - _last_gui_motion_frame < 2:
		return
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var mp := get_global_mouse_position()
		if _drag_active or get_global_rect().grow(6).has_point(mp):
			if not _drag_active:
				_drag_active = true
				_last_pos = mp
				_accum = 0.0
			else:
				var dy := mp.y - _last_pos.y
				_last_pos = mp
				if _accum >= DRAG_THRESHOLD:
					_activate_drag_guard()
					_apply_scroll(dy)
				else:
					_accum += absf(dy)
	else:
		if _drag_active:
			_drag_active = false
			_restore_content()
