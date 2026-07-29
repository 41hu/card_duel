# bp_system.gd — BP禁选系统
extends RefCounted

var match_ref
var bp_phase: String = ""
var _bp_first: int = 0  # 0=P1先手, 1=P2先手
var banned_chars: Array = []
var picked_chars: Array = []  # [first玩家的选择, second玩家的选择]
var available_chars: Array = []

func _init(match):
	match_ref = match
	reset()

func reset():
	_bp_first = randi() % 2
	bp_phase = "first_ban"
	banned_chars.clear()
	picked_chars = ["", ""]
	available_chars = Config.CHARACTER_IDS.duplicate()

func get_bp_state() -> Dictionary:
	return {
		phase = bp_phase,
		bp_first = _bp_first,
		banned_chars = banned_chars.duplicate(),
		picked_chars = picked_chars.duplicate(),
		available_chars = available_chars.duplicate(),
	}

func execute_action(player_idx: int, action: String, char_id: String) -> bool:
	if not char_id in available_chars: return false
	var is_first = (player_idx == _bp_first)

	match bp_phase:
		"first_ban":
			if not is_first or action != "ban": return false
			banned_chars.append(char_id); available_chars.erase(char_id)
			bp_phase = "second_ban"; return true
		"second_ban":
			if is_first or action != "ban": return false
			banned_chars.append(char_id); available_chars.erase(char_id)
			bp_phase = "first_pick"; return true
		"first_pick":
			if not is_first or action != "pick": return false
			picked_chars[0] = char_id; available_chars.erase(char_id)
			bp_phase = "second_pick"; return true
		"second_pick":
			if is_first or action != "pick": return false
			picked_chars[1] = char_id; available_chars.erase(char_id)
			bp_phase = "done"; return true
	return false

func is_done() -> bool:
	return bp_phase == "done"
