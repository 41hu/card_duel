# back_handler.gd — 返回键/ESC 拦截（Android 全面屏手势）
# 默认行为：Godot 收到未处理的返回请求会直接退出应用（划一下就走）。
# Android 返回键不产生输入事件，而是发 NOTIFICATION_WM_GO_BACK_REQUEST 通知 + Window.go_back_requested 信号；
# 桌面 ESC 则走 KEY_ESCAPE 输入事件。本 autoload 三通道全部拦截，
# 实现"2 秒内再按一次才退出"，第一次按只显示提示。
extends Node

const HINT_TIME_MS = 2000

var _last_back_time: int = 0
var _hint_label: Label
# 同一次返回会同时触发通知和信号，防重入避免双击判定被计两次
var _handling_back: bool = false

func _ready():
	# 通道 2：Window.go_back_requested 信号（Android 返回）
	get_tree().root.go_back_requested.connect(_handle_back)

func _notification(what):
	# 通道 1：NOTIFICATION_WM_GO_BACK_REQUEST（Node 级通知，传播到场景树）
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_handle_back()

func _unhandled_input(event: InputEvent):
	# 通道 3：桌面 ESC 等输入事件
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_handle_back()

func _handle_back():
	if _handling_back: return  # 防重入（通知+信号同帧双触发）
	_handling_back = true
	get_viewport().set_input_as_handled()  # 阻止 Godot 默认退出
	var now = Time.get_ticks_msec()
	if _last_back_time > 0 and now - _last_back_time < HINT_TIME_MS:
		_clear_hint()
		get_tree().quit()
	else:
		_last_back_time = now
		_show_hint()
	_handling_back = false

func _show_hint():
	if _hint_label == null or not is_instance_valid(_hint_label):
		_hint_label = Label.new()
		_hint_label.name = "BackHint"
		_hint_label.text = "再按一次退出游戏"
		_hint_label.add_theme_font_size_override("font_size", 28)
		_hint_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
		_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		get_tree().root.add_child(_hint_label)
	# 居中于屏幕底部（覆盖在任意场景之上）
	var vp = get_viewport().get_visible_rect().size
	_hint_label.position = Vector2((vp.x - _hint_label.size.x) / 2.0, vp.y - 120)
	_hint_label.visible = true
	_clear_hint_after(HINT_TIME_MS)

func _clear_hint_after(ms: int):
	await get_tree().create_timer(ms / 1000.0).timeout
	if _hint_label != null and is_instance_valid(_hint_label):
		_hint_label.visible = false

func _clear_hint():
	if _hint_label != null and is_instance_valid(_hint_label):
		_hint_label.visible = false
