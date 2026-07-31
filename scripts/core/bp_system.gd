# bp_system.gd — BP禁选系统
extends RefCounted

const BP_TIME = 30

var match_ref
var bp_phase: String = ""
var _bp_first: int = 0
var banned_chars: Array = []
var picked_chars: Array = []
var available_chars: Array = []
var bp_deadline: int = 0

func _init(match):
	match_ref = match
	reset()

func reset():
	_bp_first = randi() % 2
	bp_phase = "first_ban"
	banned_chars.clear()
	picked_chars = ["", ""]
	available_chars = Config.CHARACTER_IDS.duplicate()
	bp_deadline = Time.get_ticks_msec() + BP_TIME * 1000
	# 关键：BP 阶段必须处于 BP_PHASE，否则 check_timers 不会触发倒计时自动操作
	match_ref.phase = Config.Phase.BP_PHASE

func get_bp_state() -> Dictionary:
	var now = Time.get_ticks_msec()
	var left = max(0, int((bp_deadline - now) / 1000.0)) if bp_deadline > 0 else -1
	return {
		phase = bp_phase,
		bp_first = _bp_first,
		banned_chars = banned_chars.duplicate(),
		picked_chars = picked_chars.duplicate(),
		available_chars = available_chars.duplicate(),
		bp_time_left = left,
	}

func execute_action(player_idx: int, action: String, char_id: String) -> bool:
	if not char_id in available_chars: return false
	var is_first = (player_idx == _bp_first)

	match bp_phase:
		"first_ban":
			if not is_first or action != "ban": return false
			banned_chars.append(char_id); available_chars.erase(char_id)
			bp_phase = "second_ban"; bp_deadline = Time.get_ticks_msec() + BP_TIME * 1000; return true
		"second_ban":
			if is_first or action != "ban": return false
			banned_chars.append(char_id); available_chars.erase(char_id)
			bp_phase = "first_pick"; bp_deadline = Time.get_ticks_msec() + BP_TIME * 1000; return true
		"first_pick":
			if not is_first or action != "pick": return false
			picked_chars[0] = char_id; available_chars.erase(char_id)
			bp_phase = "second_pick"; bp_deadline = Time.get_ticks_msec() + BP_TIME * 1000; return true
		"second_pick":
			if is_first or action != "pick": return false
			picked_chars[1] = char_id; available_chars.erase(char_id)
			bp_phase = "done"; return true
	return false

func check_bp_timer():
	if bp_phase == "done" or bp_deadline <= 0: return
	var now = Time.get_ticks_msec()
	if now < bp_deadline: return
	# 超时自动随机操作
	if available_chars.is_empty(): return
	var random_char = available_chars[randi() % available_chars.size()]
	match bp_phase:
		"first_ban", "second_ban":
			execute_action(_get_acting(), "ban", random_char)
		"first_pick", "second_pick":
			execute_action(_get_acting(), "pick", random_char)
	bp_deadline = Time.get_ticks_msec() + BP_TIME * 1000

func _get_acting() -> int:
	if "first" in bp_phase: return _bp_first
	return 1 - _bp_first

func is_done() -> bool:
	return bp_phase == "done"
