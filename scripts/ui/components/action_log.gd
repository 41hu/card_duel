# ActionLog — 出牌历史日志组件
extends ScrollContainer

const Style = preload("res://scripts/theme/style_const.gd")
@onready var _vbox: VBoxContainer = $VBox

func _ready():
	_vbox.layout_mode = 0
	_vbox.size_flags_vertical = 0

func show_logs(action_log: Array, max_count: int = 200, my_index: int = -1):
	for c in _vbox.get_children():
		c.queue_free()
	# ScrollContainer 可滚动查看；上限 200 条平衡性能（每次状态刷新会重建全部日志 Label）
	var r = action_log.slice(max(0, action_log.size() - 200))
	for e in r:
		var lb = Label.new()
		lb.text = "[T%d] %s: %s" % [e.get("turn", 0), e.get("player_name", "?"), e.get("msg", "")]
		lb.add_theme_font_size_override("font_size", Style.fs(24))
		if my_index >= 0:
			lb.add_theme_color_override("font_color", Style.ME_GREEN if e.get("player", -1) == my_index else Style.OPP_RED)
		else:
			lb.add_theme_color_override("font_color", Style.LOG_TEXT)
		_vbox.add_child(lb)
	# 强制 VBox 按内容撑高（节点可能已离开场景树（切场景时），await 前必须检查）
	if not is_inside_tree():
		return
	_vbox.size = Vector2(size.x, 0)
	await get_tree().process_frame
	if not is_inside_tree():
		return
	_vbox.size = Vector2(size.x, _vbox.get_minimum_size().y)
	call_deferred("_scroll_bottom")

func _scroll_bottom():
	var bar = get_v_scroll_bar()
	if bar: bar.value = bar.max_value
