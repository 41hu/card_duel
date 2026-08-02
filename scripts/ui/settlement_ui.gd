# settlement_ui.gd — 结算界面
extends Control

const Style = preload("res://scripts/theme/style_const.gd")

# 获胜称号 → 获得条件（与 match_state._calc_title 的判定一致）
# 判定顺序即此表顺序：满足第一个条件即获得对应称号
const _TITLE_CONDITIONS := {
	"无伤传说": "全程未受到任何伤害",
	"毁灭之王": "本局造成伤害 ≥ 25",
	"绝对防御": "对手本局造成伤害为 0",
	"圣光使者": "本局回复血量 ≥ 10",
	"不死凤凰": "本局复活过",
	"出牌大师": "本局打出卡牌 ≥ 15",
	"征服者": "获得胜利（默认称号）",
}

@onready var title_label = $Title
@onready var title2_label: Button = $Title2
@onready var stats_label = $StatsLabel
@onready var detail_label = $Detail
@onready var back_btn = $BackBtn

var _current_title: String = ""

func _n():
	if LocalGame.game != null: return LocalGame
	return Network

func _ready():
	back_btn.pressed.connect(func():
		# 清理本地模式残留（自我/人机对局），再开网络局不串状态
		LocalGame.disconnect_from_server()
		Network.disconnect_from_server()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	)
	# 称号悬停显示条件（PC）；点击显示条件，3 秒后恢复（移动端无 hover）
	title2_label.pressed.connect(_show_title_condition)
	# 对局记录导出（本地/联机都有：本地来自 game，联机由服务器随结算下发）
	var has_record = false
	if LocalGame.game != null:
		has_record = not LocalGame.game.game_result.get("battle_record", []).is_empty()
	else:
		has_record = not Network.last_game_result.get("battle_record", []).is_empty()
	if has_record:
		var export_btn := Button.new()
		export_btn.text = "导出对局数据"
		export_btn.anchor_left = 0.5; export_btn.anchor_right = 0.5
		export_btn.anchor_top = 1.0; export_btn.anchor_bottom = 1.0
		export_btn.offset_left = -180.0; export_btn.offset_right = 180.0
		export_btn.offset_top = -140.0; export_btn.offset_bottom = -100.0
		export_btn.add_theme_font_size_override("font_size", 30)
		export_btn.pressed.connect(func():
			var result = LocalGame.game.game_result if LocalGame.game != null else Network.last_game_result
			var path = _export_record(result)
			if path != "":
				detail_label.text = "对局数据已导出：%s" % path
				detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			else:
				detail_label.text = "导出失败"
		)
		add_child(export_btn)
	_n().game_ended.connect(_on_game_ended)
	# 从缓存读取结果：battle_ui 切场景时信号已发完，直接 connect 收不到
	var cached = _n().last_game_result
	if not cached.is_empty():
		_on_game_ended(cached)

func _show_title_condition():
	if _current_title == "": return
	var cond: String = _TITLE_CONDITIONS.get(_current_title, "")
	if cond == "": return
	title2_label.text = "条件：%s" % cond
	await get_tree().create_timer(3.0).timeout
	if _current_title != "":
		title2_label.text = "称号：%s" % _current_title

func _on_game_ended(result: Dictionary):
	var winner = result.get("winner", -1)
	if winner == -1:
		title_label.text = "对手断线"
		title_label.add_theme_color_override("font_color", Style.WIN_GOLD)
		title2_label.text = ""
		_current_title = ""
		stats_label.text = ""
		detail_label.text = "对方已断开连接"
	else:
		var is_winner = (winner == _n().player_index)
		if is_winner:
			title_label.text = "胜利！"
			title_label.add_theme_color_override("font_color", Style.WIN_GOLD)
		else:
			title_label.text = "败北"
			title_label.add_theme_color_override("font_color", Style.LOSE_RED)
		var title = result.get("title", "")
		_current_title = title
		title2_label.text = "称号：%s" % title if title != "" else ""
		if title != "":
			title2_label.tooltip_text = "条件：%s" % _TITLE_CONDITIONS.get(title, "")
		var names = result.get("names", ["P1", "P2"])
		stats_label.text = _fmt_stats(result.get("stats", []), names)
		# 优先显示玩家名（联机为创建房间时输入的名字），否则回退"玩家 N"
		var wname = names[winner] if winner < names.size() else "玩家 %d" % (winner + 1)
		detail_label.text = "%s 获胜" % wname

# 组装对战统计文本（结算页展示）
func _fmt_stats(stats: Array, names: Array) -> String:
	if stats.size() < 2: return ""
	var d0 = stats[0]; var d1 = stats[1]
	var m0 = _max_card(d0.get("cards_played", {}))
	var m1 = _max_card(d1.get("cards_played", {}))
	var out = "── 对战统计 ──\n"
	out += "造成伤害：%s %d  |  %s %d\n" % [names[0], d0.get("damage_dealt", 0), names[1], d1.get("damage_dealt", 0)]
	out += "受到伤害：%s %d  |  %s %d\n" % [names[0], d0.get("damage_taken", 0), names[1], d1.get("damage_taken", 0)]
	out += "  其中攻击：%s %d  |  %s %d\n" % [names[0], d0.get("damage_from_attack", 0), names[1], d1.get("damage_from_attack", 0)]
	out += "  陷阱/DoT：%s %d/%d  |  %s %d/%d\n" % [names[0], d0.get("damage_from_trap", 0), d0.get("damage_from_dot", 0), names[1], d1.get("damage_from_trap", 0), d1.get("damage_from_dot", 0)]
	out += "回复血量：%s %d  |  %s %d\n" % [names[0], d0.get("heal_total", 0), names[1], d1.get("heal_total", 0)]
	out += "移动步数：%s %d  |  %s %d\n" % [names[0], d0.get("moves", 0), names[1], d1.get("moves", 0)]
	out += "打出最多：%s %s  |  %s %s\n" % [names[0], _max_card_str(m0), names[1], _max_card_str(m1)]
	out += "复活次数：%s %d  |  %s %d" % [names[0], d0.get("resurrected", 0), names[1], d1.get("resurrected", 0)]
	return out

# 导出对局记录：生成文本文件（battle_records/ 目录），返回文件路径
# result 统一结构（本地 game.game_result / 联机服务器下发的 game_over 消息）：
#   winner/loser/reason/stats/names/title/battle_record/action_log
func _export_record(result: Dictionary) -> String:
	var record: Array = result.get("battle_record", [])
	var action_log: Array = result.get("action_log", [])
	var names: Array = result.get("names", ["P1", "P2"])
	var mode := "联机对战"
	if LocalGame.game != null:
		mode = "人机对战" if LocalGame.ai_mode else "自我对战"
	var turn := 0
	if not record.is_empty():
		turn = record[record.size() - 1].get("turn", 0)
	elif LocalGame.game != null:
		turn = LocalGame.game.turn_number
	var lines := ["=== 卡牌对决 对局记录 ==="]
	lines.append("角色: %s vs %s" % [names[0], names[1]])
	lines.append("模式: %s | 总回合: %d" % [mode, turn])
	lines.append("")
	lines.append("--- 每回合快照（手牌/血量/位置/AP/牌堆）---")
	for rec in record:
		var tag = "出牌" if rec.get("phase", 2) == 2 else "弃牌"
		var p0: Dictionary = rec.get("p0", {})
		var p1: Dictionary = rec.get("p1", {})
		var a0: Array = p0.get("ap", [0, 0, 0])
		var a1: Array = p1.get("ap", [0, 0, 0])
		lines.append("T%d P%d%s: P0 HP%d/%d 位%d 手[%s] AP(%d/%d/%d) | P1 HP%d/%d 位%d 手[%s] AP(%d/%d/%d) | 牌堆%d 弃牌%d" % [
			rec.get("turn", 0), rec.get("player", 0), tag,
			p0.get("hp", 0), p0.get("max_hp", 1), p0.get("pos", 0), "、".join(p0.get("hand", [])),
			a0[0], a0[1], a0[2],
			p1.get("hp", 0), p1.get("max_hp", 1), p1.get("pos", 0), "、".join(p1.get("hand", [])),
			a1[0], a1[1], a1[2],
			rec.get("deck", 0), rec.get("discard", 0)])
	lines.append("")
	lines.append("--- 战斗日志 ---")
	for e in action_log:
		lines.append("T%d %s: %s" % [e.get("turn", 0), e.get("player_name", "?"), e.get("msg", "")])
	lines.append("")
	lines.append("--- 结算 ---")
	var w = result.get("winner", -1)
	lines.append("胜者: %s（%s）| 称号: %s" % [
		names[w] if w >= 0 and w < names.size() else "?", result.get("reason", ""), result.get("title", "")])
	var dir = "res://battle_records"
	DirAccess.make_dir_recursive_absolute(dir)
	var ts = Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	var path = "%s/battle_%s.txt" % [dir, ts]
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(lines))
		f.close()
		if LocalGame.game != null:
			LocalGame.last_record_path = path
		return path
	return ""

# 从出牌统计字典里找出打出最多的牌，返回 [卡名, 次数]
func _max_card(cards: Dictionary) -> Array:
	var best = ["无", 0]
	for tid in cards:
		if cards[tid] > best[1]:
			best = [Config.card_name(tid), cards[tid]]
	return best

# 打出最多的展示：没出过牌显示"无"，否则"卡名×次数"
func _max_card_str(mc: Array) -> String:
	return "%s×%d" % [mc[0], mc[1]] if mc[1] > 0 else "无"
