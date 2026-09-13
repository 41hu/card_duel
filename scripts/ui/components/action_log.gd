# ActionLog — 出牌历史日志组件
extends ScrollContainer

const Style = preload("res://scripts/theme/style_const.gd")
@onready var _vbox: VBoxContainer = $VBox
var _shown_logs: Array = []
var _shown_player := -2

func _ready():
	_vbox.size_flags_vertical = 0
	get_v_scroll_bar().changed.connect(_queue_scroll_bottom)
	visibility_changed.connect(_queue_scroll_bottom)

func show_logs(action_log: Array, max_count: int = 200, my_index: int = -1):
	var r = action_log.slice(max(0, action_log.size() - maxi(1, max_count)))
	if r == _shown_logs and my_index == _shown_player: return
	_shown_logs = r.duplicate(true)
	_shown_player = my_index
	for c in _vbox.get_children():
		_vbox.remove_child(c)
		c.queue_free()
	for e in r:
		var lb = Label.new()
		lb.text = "[T%d] %s: %s" % [e.get("turn", 0), e.get("player_name", "?"), e.get("msg", "")]
		lb.add_theme_font_size_override("font_size", Style.fs(24))
		# 长行自动换行：否则 Label 自然宽撑大 VBox 超出视口，右侧被水平裁剪
		lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		if my_index >= 0:
			lb.add_theme_color_override("font_color", Style.ME_GREEN if e.get("player", -1) == my_index else Style.OPP_RED)
		else:
			lb.add_theme_color_override("font_color", Style.LOG_TEXT)
		_vbox.add_child(lb)
	_queue_scroll_bottom()

func _queue_scroll_bottom():
	# 排版改变滚动范围时再次定位，包含专注界面关闭后的首次排版。
	if not is_inside_tree() or not is_visible_in_tree(): return
	call_deferred("_scroll_bottom")

func _scroll_bottom():
	if not is_inside_tree() or not is_visible_in_tree(): return
	var bar = get_v_scroll_bar()
	if bar: bar.value = bar.max_value
