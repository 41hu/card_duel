# ActionLog — 出牌历史日志组件
extends ScrollContainer

const Style = preload("res://scripts/theme/style_const.gd")
@onready var _vbox: VBoxContainer = $VBox

func _ready():
	pass  # 子节点 VBox 已在场景中创建

# 显示最近 N 条日志
func show_logs(action_log: Array, max_count: int = 8, my_index: int = -1):
	for c in _vbox.get_children():
		c.queue_free()
	var r = action_log.slice(max(0, action_log.size() - max_count))
	for e in r:
		var lb = Label.new()
		lb.text = "[T%d] %s: %s" % [e.get("turn", 0), e.get("player_name", "?"), e.get("msg", "")]
		lb.add_theme_font_size_override("font_size", 11)
		if my_index >= 0:
			lb.add_theme_color_override("font_color", Style.ME_GREEN if e.get("player", -1) == my_index else Style.OPP_RED)
		else:
			lb.add_theme_color_override("font_color", Style.LOG_TEXT)
		_vbox.add_child(lb)
	# 下一帧滚动到底部
	call_deferred("_scroll_bottom")

func _scroll_bottom():
	var bar = get_v_scroll_bar()
	if bar: bar.value = bar.max_value
