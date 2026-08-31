# ui_panel_test.gd — InfoPanel 高度估算 vs 实际布局（headless，场景 test_ui_panel.tscn）
# 回归目标：装备行出现 + 状态槽换行时 content_height 必须 ≥ 实际内容高（否则面板被内容
# 撑开、底部 buff 行冲出屏幕裁切）；也不许高估过多（浪费屏幕空间）。
# 实测方法：面板放进固定宽度的 VBox（宽=面板宽，高=2000）→ 面板宽度被限定、高度取内容
# 最小尺寸 → await 3 帧等真实布局后读 pc.size.y 即为实际内容高。
extends Node

const InfoPanel = preload("res://scripts/ui/components/info_panel.gd")
const RESULT_PATH = "res://_ui_panel_test_result.txt"

func _ready():
	var lines: Array = []
	var t0 := Time.get_ticks_msec()
	lines.append("=== InfoPanel 高度估算验证 ===")
	var fails := await _run(lines)
	lines.append("耗时 %.1fs" % ((Time.get_ticks_msec() - t0) / 1000.0))
	lines.append("=== RESULT: %s ===" % ("ALL PASS" if fails == 0 else "%d FAIL" % fails))
	var f = FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	for l in lines:
		print(l)
	get_tree().quit(0 if fails == 0 else 1)

func _run(lines: Array) -> int:
	var fails := 0
	var weapon := {"data": {"type": "range", "name": "测试弓", "desc": "测试武器效果"}}
	var armor := {"data": {"name": "测试甲", "desc": "测试防具效果"}, "durability": 3, "max_durability": 3}
	var buffs_light: Array = [
		{"type": "near_up", "value": 2, "duration": 2},
		{"type": "attack_up", "value": 1, "duration": 3},
		{"type": "attack_down", "value": 1, "duration": 2},
		{"type": "calibration", "value": 3, "duration": -1},
	]
	var buffs_full: Array = [
		{"type": "near_up", "value": 2, "duration": 2},
		{"type": "attack_up", "value": 1, "duration": 3},
		{"type": "attack_down", "value": 1, "duration": 2},
		{"type": "calibration", "value": 3, "duration": -1},
		{"type": "mage_empower", "value": 2, "duration": -1},
		{"type": "paladin_counter", "value": 1, "duration": 2, "turn": 3},
		{"type": "tracker_chase", "value": 1, "duration": 2, "turn": 3},
		{"type": "mage_phantom", "value": 2, "duration": -2},
	]
	var dots: Array = [{"type": "burn", "damage": 2, "duration": 3}, {"type": "poison", "damage": 1, "duration": 2}]
	var profiles := [
		{"label": "无装备无buff", "w": 460.0, "weapon": {}, "armor": {}, "frozen": false, "frozen_move": false, "dots": [], "buffs": []},
		{"label": "装备+4buff(2p宽460)", "w": 460.0, "weapon": weapon, "armor": armor, "frozen": false, "frozen_move": false, "dots": [], "buffs": buffs_light},
		{"label": "装备+11槽(2p宽460)", "w": 460.0, "weapon": weapon, "armor": armor, "frozen": true, "frozen_move": true, "dots": dots, "buffs": buffs_full},
		{"label": "装备+11槽(4p宽500)", "w": 500.0, "weapon": weapon, "armor": armor, "frozen": true, "frozen_move": true, "dots": dots, "buffs": buffs_full},
		{"label": "装备+11槽(自面板宽550)", "w": 550.0, "weapon": weapon, "armor": armor, "frozen": true, "frozen_move": true, "dots": dots, "buffs": buffs_full},
	]
	for pr in profiles:
		var host := VBoxContainer.new()
		host.size = Vector2(pr.w, 2000.0)
		add_child(host)
		var pc := InfoPanel.new()
		host.add_child(pc)
		pc.refresh(_fake_player(pr), "自己", Color(1, 1, 1))
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().process_frame
		var actual := pc.size.y
		var est := pc.content_height(pr.w)
		var verdict := "OK"
		if est < actual - 1.0:
			verdict = "低估→裁切"
			fails += 1
		elif est > actual + 60.0:
			verdict = "高估过多"
			fails += 1
		lines.append("  %s | 实际高=%.0f 估算=%.0f 差=%+.0f [%s]" % [pr.label, actual, est, est - actual, verdict])
		host.queue_free()
		await get_tree().process_frame
	return fails

func _fake_player(pr: Dictionary) -> Dictionary:
	return {
		"char_id": "hunter", "char_name": "猎人",
		"hp": 30, "max_hp": 30,
		"near_power": 3, "range_power": 5, "magic_power": 2,
		"ap_attack": 2, "ap_move": 1, "ap_function": 1,
		"hand_size": 5, "hand_limit": 5,
		"deck_size": 20, "discard_size": 15,
		"weapon": pr.weapon, "armor": pr.armor,
		"frozen": pr.frozen, "frozen_move": pr.frozen_move,
		"dots": pr.dots, "buffs": pr.buffs,
	}
