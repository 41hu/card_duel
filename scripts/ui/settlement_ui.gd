# settlement_ui.gd — 结算界面
extends Control

const Style = preload("res://scripts/theme/style_const.gd")

# 获胜称号 → 获得条件（与 match_state._calc_titles 的判定一致）
# 可同时获得多个：满足条件全部计入，第一个为最亮眼主称号
const _TITLE_CONDITIONS := {
	"完美击杀": "全程未受到任何伤害",
	"毁灭之王": "本局造成伤害 ≥ 45",
	"耐杀王": "本局承受伤害 ≥ 50",
	"不死鸟": "本局复活 ≥ 2 次",
	"险胜": "取胜时自身血量 < 5 点",
	"征服者": "获得胜利（默认称号）",
	"出师不利": "对敌人造成 0 点伤害且战败",
	"负隅顽抗": "战败且本局复活 ≥ 2 次",
	"虽败犹荣": "造成伤害 > 胜者造成的伤害",
	"伤痕累累": "承受伤害 ≥ 50",
	"苦战": "对局回合数 > 20",
	"武器专家": "本局装备过 6 把不同的武器",
	"战术大师": "牵制/魔法/满耐久护甲完全抵挡的伤害 > 45",
	"坚守阵地": "本局响应 ≥ 15 次（格挡/牵制/闪避）",
	"马拉松冠军": "本局位移 > 10 格（含移动卡/威慑/吸引/暗影步等所有位移）",
	"火力压制": "本局造成伤害 ≥ 30",
	"致命一击": "单次攻击造成 > 15 点伤害",
	"完美形态": "游戏结束时近战/远程/魔法面板均 > 6",
}

# 称号难度分级（gold/blue/white）统一定义在 match_state.TITLE_TIERS，UI 引用
const MatchStateClass = preload("res://scripts/core/match_state.gd")
const _TITLE_TIERS: Dictionary = MatchStateClass.TITLE_TIERS

@onready var title_label = $Title
@onready var title_row: WrapContainer = $TitleBox/TitleRow
@onready var loser_row: WrapContainer = $TitleBox/LoserRow
@onready var cond_label: Label = $TitleBox/CondLabel
@onready var stat_cards: Array = [
	$StatsScroll/StatsRow/P0Card,
	$StatsScroll/StatsRow/P1Card,
]
@onready var stat_names: Array = [
	$StatsScroll/StatsRow/P0Card/V/P0Name,
	$StatsScroll/StatsRow/P1Card/V/P1Name,
]
@onready var stat_labels: Array = [
	$StatsScroll/StatsRow/P0Card/V/P0Stats,
	$StatsScroll/StatsRow/P1Card/V/P1Stats,
]
@onready var detail_label = $Detail
@onready var back_btn = $BackBtn

var _current_title: String = ""
var _current_titles: Array = []

func _n():
	if LocalGame.game != null: return LocalGame
	return Network

func _ready():
	Style.scale_node_fonts(self)  # 移动端字号适配（tscn 写死的字号）
	back_btn.pressed.connect(func():
		# 清理本地模式残留（自我/人机对局），再开网络局不串状态
		LocalGame.disconnect_from_server()
		Network.disconnect_from_server()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	)
	# 称号徽章：悬停显示条件（tooltip），点击在下方条件栏常驻显示
	# （无 hover 的移动端点击即可查看，无需恢复计时）
	# 对局记录导出（本地/联机都有：本地来自 game，联机由服务器随结算下发）
	var has_record = false
	if LocalGame.game != null:
		has_record = not LocalGame.game.game_result.get("battle_record", []).is_empty()
	else:
		has_record = not Network.last_game_result.get("battle_record", []).is_empty()
	if has_record:
		var export_btn := Button.new()
		export_btn.text = "导出对局数据"
		# 位置：获胜玩家(Detail)下方、返回主菜单上方，避免重叠
		export_btn.anchor_left = 0.5; export_btn.anchor_right = 0.5
		export_btn.offset_left = -180.0; export_btn.offset_right = 180.0
		export_btn.offset_top = 815.0; export_btn.offset_bottom = 920.0
		export_btn.add_theme_font_size_override("font_size", Style.fs(30))
		export_btn.pressed.connect(func():
			var result = LocalGame.game.game_result if LocalGame.game != null else Network.last_game_result
			var path = _export_record(result)
			if path != "":
				# 导出平台（APK 等）：文件在应用数据目录（用户不可见），提示已复制到剪贴板可直接粘贴分享
				if OS.has_feature("editor"):
					detail_label.text = "对局数据已导出：%s" % path
				else:
					detail_label.text = "已导出并复制到剪贴板（粘贴到聊天框即可分享）"
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

# 点击徽章：条件常驻显示在称号行下方条件栏（不覆盖称号行）
func _show_title_condition(cond: String):
	cond_label.text = "条件：%s" % cond
	cond_label.visible = true

# 称号徽章横排：按难度分级着色（gold=金色大框最难 / blue=蓝色框 / white=白色框最易）
# 每个徽章可点击/悬停查看达成条件；第一个为最亮眼主称号
func _refresh_title_row(row: Container, titles: Array):
	for c in row.get_children():
		if c is Button:
			row.remove_child(c)
			c.queue_free()
	for t in titles:
		row.add_child(_make_title_badge(str(t)))

func _make_title_badge(title: String) -> Button:
	var cond: String = _TITLE_CONDITIONS.get(title, "")
	var tier: String = _TITLE_TIERS.get(title, "blue")
	var b := Button.new()
	b.text = title
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(2)
	sb.content_margin_left = 20.0
	sb.content_margin_right = 20.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	match tier:
		"gold":
			sb.bg_color = Color(0.42, 0.33, 0.06, 1)
			sb.border_color = Color(1, 0.85, 0.3, 1)
			b.add_theme_font_size_override("font_size", Style.fs(40))
		"blue":
			sb.bg_color = Color(0.1, 0.16, 0.28, 1)
			sb.border_color = Color(0.35, 0.55, 0.9, 1)
			b.add_theme_font_size_override("font_size", Style.fs(26))
		"white":
			sb.bg_color = Color(0.22, 0.24, 0.3, 1)
			sb.border_color = Color(1, 1, 1, 0.85)
			b.add_theme_font_size_override("font_size", Style.fs(22))
	for state in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(state, sb)
	b.tooltip_text = "条件：%s" % cond if cond != "" else ""
	if cond != "":
		b.pressed.connect(_show_title_condition.bind(cond))
	return b

func _on_game_ended(result: Dictionary):
	var winner = result.get("winner", -1)
	if winner == -1:
		title_label.text = "对手断线"
		title_label.add_theme_color_override("font_color", Style.WIN_GOLD)
		_clear_title_rows()
		loser_row.visible = false
		_current_title = ""
		_current_titles = []
		for l in stat_labels:
			l.text = ""
		detail_label.text = "对方已断开连接"
	else:
		# 本地自我对战：双方都是玩家自己，无胜负之分，显示"对局结束"而非胜利/败北
		var is_self_play = (LocalGame.game != null) and not LocalGame.ai_mode
		if is_self_play:
			title_label.text = "对局结束"
			title_label.add_theme_color_override("font_color", Style.WIN_GOLD)
		elif winner == _n().player_index:
			title_label.text = "胜利！"
			title_label.add_theme_color_override("font_color", Style.WIN_GOLD)
		else:
			title_label.text = "败北"
			title_label.add_theme_color_override("font_color", Style.LOSE_RED)
		var titles: Array = result.get("titles", [])
		if titles.is_empty() and result.get("title", "") != "":
			titles = [result.get("title", "")]  # 兼容旧版结算数据
		var titles_loser: Array = result.get("titles_loser", [])
		var names = result.get("names", ["P1", "P2"])
		_clear_title_rows()
		if not titles.is_empty():
			_current_titles = titles
			_current_title = str(titles[0])
			_refresh_title_row(title_row, titles)
		else:
			_current_titles = []
			_current_title = ""
		loser_row.visible = not titles_loser.is_empty()
		if not titles_loser.is_empty():
			_refresh_title_row(loser_row, titles_loser)
		_fill_stats_panels(result.get("stats", []), names, winner)
		# 优先显示玩家名（联机为创建房间时输入的名字），否则回退"玩家 N"
		var wname = names[winner] if winner < names.size() else "玩家 %d" % (winner + 1)
		detail_label.text = "%s 获胜" % wname

func _clear_title_rows():
	for row in [title_row, loser_row]:
		for c in row.get_children():
			if c is Button:
				row.remove_child(c)
				c.queue_free()
	cond_label.visible = false

# 左右分栏统计卡片：各玩家一张，顶部名字（胜方金色），下方竖排数据
func _fill_stats_panels(stats: Array, names: Array, winner: int):
	if stats.size() < 2: return
	for i in [0, 1]:
		var card: PanelContainer = stat_cards[i]
		var name_lbl: Label = stat_names[i]
		var stat_lbl: Label = stat_labels[i]
		name_lbl.text = names[i]
		var is_win = (i == winner)
		# 卡片样式：胜方金色边框，败方灰色
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.13, 0.16, 0.22, 0.9)
		sb.border_color = Color(1, 0.85, 0.3, 0.95) if is_win else Color(0.42, 0.46, 0.55, 0.85)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(12)
		card.add_theme_stylebox_override("panel", sb)
		name_lbl.add_theme_color_override("font_color", Color(1, 0.85, 0.3) if is_win else Color.WHITE)
		var d = stats[i]
		var m = _max_card(d.get("cards_played", {}))
		stat_lbl.text = "造成伤害  %d\n受到伤害  %d\n  · 攻击  %d\n  · 陷阱  %d\n  · DoT  %d\n回复血量  %d\n移动步数  %d\n复活次数  %d\n打出最多  %s" % [
			d.get("damage_dealt", 0), d.get("damage_taken", 0),
			d.get("damage_from_attack", 0), d.get("damage_from_trap", 0), d.get("damage_from_dot", 0),
			d.get("heal_total", 0), d.get("moves", 0), d.get("resurrected", 0), _max_card_str(m)]

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
		lines.append("T%d P%d%s: P0 HP%d/%d 位%s 手[%s] AP(%d/%d/%d) | P1 HP%d/%d 位%s 手[%s] AP(%d/%d/%d) | 牌堆%d 弃牌%d" % [
			rec.get("turn", 0), rec.get("player", 0), tag,
			p0.get("hp", 0), p0.get("max_hp", 1), _pos_text(p0.get("pos", {})), "、".join(p0.get("hand", [])),
			a0[0], a0[1], a0[2],
			p1.get("hp", 0), p1.get("max_hp", 1), _pos_text(p1.get("pos", {})), "、".join(p1.get("hand", [])),
			a1[0], a1[1], a1[2],
			rec.get("deck", 0), rec.get("discard", 0)])
	lines.append("")
	lines.append("--- 战斗日志 ---")
	for e in action_log:
		lines.append("T%d %s: %s" % [e.get("turn", 0), e.get("player_name", "?"), e.get("msg", "")])
	lines.append("")
	lines.append("--- 结算 ---")
	var w = result.get("winner", -1)
	var titles: Array = result.get("titles", [])
	if titles.is_empty() and result.get("title", "") != "":
		titles = [result.get("title", "")]
	var tloser: Array = result.get("titles_loser", [])
	var loser_str = "、".join(tloser) if not tloser.is_empty() else "无"
	lines.append("胜者: %s（%s）| 称号: %s | 败者称号: %s" % [
		names[w] if w >= 0 and w < names.size() else "?", result.get("reason", ""), "、".join(titles), loser_str])
	# 导出路径：编辑器写项目目录（方便直接取文件）；导出平台（APK/PC 打包）res:// 只读，
	# 写 user:// 应用数据目录；移动端另复制到剪贴板（文件路径用户不可见，粘贴即可分享）
	var is_editor = OS.has_feature("editor")
	var dir = "res://battle_records" if is_editor else "user://battle_records"
	DirAccess.make_dir_recursive_absolute(dir)
	var ts = Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	var path = "%s/battle_%s.txt" % [dir, ts]
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(lines))
		f.close()
		if not is_editor:
			DisplayServer.clipboard_set("\n".join(lines))
		if LocalGame.game != null:
			LocalGame.last_record_path = path
		return path
	return ""

# 位置导出文本（协议为 {x,y} 结构；兼容旧 int）
func _pos_text(pos) -> String:
	if pos is Dictionary:
		return "%d,%d" % [pos.get("x", 0), pos.get("y", 0)]
	return str(pos)

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
