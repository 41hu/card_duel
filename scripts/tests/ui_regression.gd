# ui_regression.gd — 对战 UI 显示回归测试（测试工具，不入游戏流程）
# 目的：杜绝「改动 battle_ui 导致多人局显示 bug」——每次改动后跑一遍，自动检查关键 UI 不变量。
# 覆盖 3 种配置：2 人经典(共享堆) / 2 人自定义(独立堆) / 4 人混战(独立堆)。
# 检查项：自己面板存在 / 对手面板数量正确 / 棋盘模式(线性/六边形)正确 / 牌堆标签非空且覆盖所有玩家。
# 用法：游戏中 eval 执行 `add_child(load("res://scripts/tests/ui_regression.gd").new()).start()`
# 结果写入 user://ui_regression_result.txt，末尾打印 PASS/FAIL 汇总。
extends Node

const DeckData = preload("res://scripts/data/deck_data.gd")
const RESULT_PATH = "user://ui_regression_result.txt"
const CHECK_FRAME = 12  # 场景切换后等待的帧数

var _cases := []
var _idx := 0
var _frame := 0
var _results := []

func start():
	_cases = [
		{"name": "2人经典共享堆", "chars": ["fighter", "berserker"], "decks": [[], []],
			"independent": false, "expect_opp_panels": 1, "expect_hex": false},
		{"name": "2人自定义独立堆", "chars": ["fighter", "mage"],
			"decks": [DeckData.default_deck(), DeckData.default_deck()],
			"independent": true, "expect_opp_panels": 1, "expect_hex": false},
		{"name": "4人混战", "chars": ["fighter", "mage", "berserker", "priest"], "decks": [],
			"independent": true, "expect_opp_panels": 3, "expect_hex": true},
	]
	_idx = 0
	_results.clear()
	_run_next()

func _run_next():
	if _idx >= _cases.size():
		_write_summary()
		set_process(false)
		return
	var c = _cases[_idx]
	LocalGame.disconnect_from_server()
	if c.name == "4人混战":
		LocalGame.start_local_game_multi(c.chars)
	else:
		LocalGame.start_local_game(c.chars[0], c.chars[1], 0, c.decks, c.independent)
	get_tree().change_scene_to_file("res://scenes/battle_scene.tscn")
	_frame = 0
	set_process(true)

func _process(_d):
	_frame += 1
	if _frame < CHECK_FRAME:
		return
	set_process(false)
	_check_current()
	_idx += 1
	_run_next()

func _check_current():
	var c = _cases[_idx]
	var b = get_node_or_null("/root/BattleScene")
	if b == null:
		_results.append({"case": c.name, "pass": false, "msg": "场景未加载"})
		return
	var fails := []
	if b._self_panel == null:
		fails.append("自己面板缺失")
	if b._opp_panels.size() != c.expect_opp_panels:
		fails.append("对手面板数 %d≠期望%d" % [b._opp_panels.size(), c.expect_opp_panels])
	if b._opp_indices.size() != c.expect_opp_panels:
		fails.append("对手索引数 %d≠期望%d" % [b._opp_indices.size(), c.expect_opp_panels])
	if b._board_hex != c.expect_hex:
		fails.append("棋盘模式 %s≠期望%s" % [str(b._board_hex), str(c.expect_hex)])
	# 牌堆/弃牌已移入玩家面板：检查自己面板的牌堆行非空
	if b._self_panel == null or b._self_panel._deck_label == null or b._self_panel._deck_label.text == "":
		fails.append("自己面板牌堆行为空")
	# 布局不重叠：棋盘不越入左右列（左战报右边界 316、右面板左边界 1420）
	var board = b.get_node("Board")
	if board != null:
		var bx = board.global_position.x
		var bw = board.size.x
		if bx < 316:
			fails.append("棋盘左越界 x=%d<316" % bx)
		if bx + bw > 1420:
			fails.append("棋盘右越界 x=%d>1420" % (bx + bw))
	_results.append({"case": c.name, "pass": fails.is_empty(), "msg": "；".join(fails)})

func _write_summary():
	var all_pass := true
	var lines := ["=== UI 显示回归测试 ==="]
	for r in _results:
		var mark = "PASS" if r.pass else "FAIL"
		if not r.pass:
			all_pass = false
		lines.append("[%s] %s%s" % [mark, r.case, (" — " + r.msg) if r.msg != "" else ""])
	lines.append("=== 汇总：%s ===" % ("全部通过" if all_pass else "存在失败"))
	var f = FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	print("\n".join(lines))
