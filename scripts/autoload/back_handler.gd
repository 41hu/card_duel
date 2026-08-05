# back_handler.gd — 返回键/ESC 拦截（Android 全面屏手势）
# 默认行为：Godot 收到未处理的返回请求会直接退出应用（划一下就走）。
# Android 返回键不产生输入事件，而是发 NOTIFICATION_WM_GO_BACK_REQUEST 通知 + Window.go_back_requested 信号；
# 桌面 ESC 则走 KEY_ESCAPE 输入事件。本 autoload 三通道全部拦截，
# 实现"2 秒内再按一次才退出"，第一次按只显示提示。
extends Node

const Style = preload("res://scripts/theme/style_const.gd")

const HINT_TIME_MS = 2000

var _last_back_time: int = 0
var _last_handle_time: int = 0
var _hint_label: Label
# 同一次返回会同时触发通知和信号，且真机划一次可能产生多次返回事件（跨帧）。
# 400ms 内重复事件忽略——同一次划的间隔极小，用户真正再划一次间隔远大于此
const REPEAT_GUARD_MS = 400

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

# 主菜单注册的回调：返回主面板（创建/加入房间界面返回时调用）。
# 回调返回 true = 已处理（本次返回不退出游戏）；false = 未处理（走正常退出逻辑）
var main_menu_back: Callable = Callable()

func _handle_back():
	var now = Time.get_ticks_msec()
	if now - _last_handle_time < REPEAT_GUARD_MS:
		return  # 同一次返回的重复事件（通知/信号/手势多次回调）
	_last_handle_time = now
	get_viewport().set_input_as_handled()  # 阻止 Godot 默认退出
	# 主菜单子面板（创建/加入房间）：返回键直接回主面板，不退出游戏
	if _is_main_menu() and main_menu_back.is_valid() and main_menu_back.call():
		_last_back_time = 0
		_clear_hint()
		return
	if _last_back_time > 0 and now - _last_back_time < HINT_TIME_MS:
		_clear_hint()
		if _is_main_menu():
			get_tree().quit()  # 主界面双击退出游戏
		else:
			_exit_to_menu()  # 其他界面双击退出对局回主界面
	else:
		_last_back_time = now
		_show_hint()

func _is_main_menu() -> bool:
	return get_tree().current_scene != null and get_tree().current_scene.name == "MainMenu"

# 退出当前对局并返回主界面（清理本地/网络对局状态）
func _exit_to_menu():
	if LocalGame.game != null:
		LocalGame.disconnect_from_server()
	else:
		Network.disconnect_from_server()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _show_hint():
	if _hint_label == null or not is_instance_valid(_hint_label):
		_hint_label = Label.new()
		_hint_label.name = "BackHint"
		_hint_label.text = "再按一次退出游戏"
		_hint_label.add_theme_font_size_override("font_size", Style.fs(28))
		_hint_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
		_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		get_tree().root.add_child(_hint_label)
	_hint_label.text = "再按一次退出游戏" if _is_main_menu() else "再按一次退出对局"
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
