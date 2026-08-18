# settlement_ui.gd — 结算界面（2026-08 布局重构）
# 布局：左上=返回主菜单 / 右上=导出对局数据 / 顶部中间=胜负大字+获胜者+自己的称号徽章
# 下方：一行统计卡片（2人居中两张 / 4人撑满四张），每张卡片底部"查看称号"按钮
# 点击展开该玩家的称号（方案B：默认隐藏，方便多人局总结数据展示）
extends Control

const Style = preload("res://scripts/theme/style_const.gd")

# 称号 → 获得条件（与 match_state._calc_titles 的判定一致）
const _TITLE_CONDITIONS := {
	"完美击杀": "全程未受到任何伤害",
	"毁灭之王": "本局造成伤害 ≥ 45",
	"耐杀王": "本局承受伤害 ≥ 50",
	"不死鸟": "本局复活 ≥ 2 次",
	"险胜": "取胜时自身血量 < 5 点",
	"征服者": "获得胜利（默认称号）",
	"出师不利": "对敌人造成 0 点伤害且战败",
	"负隅顽抗": "战败且本局复活 ≥ 2 次",
	"虽败犹荣": "造成伤害 > 胜者造成的伤害（仅2人局）",
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
@onready var detail_label = $Detail
@onready var title_row: FlowContainer = $TitleBox/TitleRow
@onready var cond_label: Label = $TitleBox/CondLabel
@onready var stats_scroll: ScrollContainer = $StatsScroll
@onready var stats_row: HBoxContainer = $StatsScroll/StatsRow
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
	# 对局记录导出按钮：右上角（与左上返回按钮对置，不占中间空间）
	var has_record = false
	if LocalGame.game != null:
		has_record = not LocalGame.game.game_result.get("battle_record", []).is_empty()
	else:
		has_record = not Network.last_game_result.get("battle_record", []).is_empty()
	if has_record:
		var export_btn := Button.new()
		export_btn.name = "ExportBtn"
		export_btn.text = "导出对局数据"
		export_btn.anchor_left = 1.0; export_btn.anchor_right = 1.0
		export_btn.anchor_top = 0.0; export_btn.anchor_bottom = 0.0
		export_btn.offset_left = -324.0; export_btn.offset_right = -24.0
		export_btn.offset_top = 24.0; export_btn.offset_bottom = 120.0
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

# 点击徽章：条件常驻显示在称号行下方条件栏
func _show_title_condition(cond: String):
	cond_label.text = "条件：%s" % cond
	cond_label.visible = true

# 称号徽章：按难度分级着色（gold=金框大字 / blue=蓝框 / white=白框）；
# small=true 用于统计卡片内展开的小徽章
func _make_title_badge(title: String, small: bool = false) -> Button:
	var cond: String = _TITLE_CONDITIONS.get(title, "")
	var tier: String = _TITLE_TIERS.get(title, "blue")
	var b := Button.new()
	b.text = title
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(2)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	if small:
		# 统计卡片内的小徽章：同样按称号难度级别着色（金/蓝/白边框）
		match tier:
			"gold":
				sb.bg_color = Color(0.3, 0.24, 0.05, 1)
				sb.border_color = Color(1, 0.85, 0.3, 1)
			"blue":
				sb.bg_color = Color(0.09, 0.14, 0.24, 1)
				sb.border_color = Color(0.35, 0.55, 0.9, 1)
			"white":
				sb.bg_color = Color(0.2, 0.22, 0.28, 1)
				sb.border_color = Color(1, 1, 1, 0.8)
		b.add_theme_font_size_override("font_size", Style.fs(18))
	else:
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
	# 顶部徽章：悬停 tooltip；点击在条件栏常驻显示
	if not small:
		b.tooltip_text = "条件：%s" % cond if cond != "" else ""
		if cond != "":
			b.pressed.connect(_show_title_condition.bind(cond))
	# 统计卡片内徽章：不常驻条件栏——按住弹出悬浮条件框（button_up 收起）
	else:
		if cond != "":
			b.button_down.connect(func():
				_show_float_cond(cond, b.global_position)
			)
			b.button_up.connect(func():
				_hide_float_cond()
			)
	return b

# 悬浮条件框：统计卡片内按住徽章时显示（与顶部点击常驻条件栏互不影响）
var _float_popup: Label = null

func _show_float_cond(cond: String, at_global: Vector2):
	if _float_popup == null:
		_float_popup = Label.new()
		_float_popup.name = "FloatCond"
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0.88)
		sb.border_color = Color(1, 0.85, 0.3, 0.9)
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(8)
		sb.content_margin_left = 14.0
		sb.content_margin_right = 14.0
		sb.content_margin_top = 8.0
		sb.content_margin_bottom = 8.0
		_float_popup.add_theme_stylebox_override("normal", sb)
		_float_popup.add_theme_font_size_override("font_size", Style.fs(22))
		_float_popup.add_theme_color_override("font_color", Color(1, 0.9, 0.6))
		_float_popup.z_index = 30
		add_child(_float_popup)
	_float_popup.text = "条件：%s" % cond
	_float_popup.reset_size()
	_float_popup.position = at_global - global_position - Vector2(0, _float_popup.size.y + 14)
	_float_popup.position.x = clampf(_float_popup.position.x, 8.0, size.x - _float_popup.size.x - 8.0)
	_float_popup.position.y = maxf(_float_popup.position.y, 8.0)
	_float_popup.visible = true

func _hide_float_cond():
	if _float_popup != null:
		_float_popup.visible = false

func _on_game_ended(result: Dictionary):
	var winner = result.get("winner", -1)
	if winner == -1:
		title_label.text = "对手断线"
		title_label.add_theme_color_override("font_color", Style.WIN_GOLD)
		_clear_title_row()
		cond_label.visible = false
		_current_title = ""
		_current_titles = []
		detail_label.text = "对方已断开连接"
		_clear_stat_cards()
		return
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
	# 顶部只显示自己的称号：
	# 联机/人机：player_titles[我的index]（我赢=我的胜者称号，我输=我的败者称号——绝不显示对手的）
	# 自我对战：无"我"概念，显示胜者称号；断线/旧数据兜底 result.titles
	var titles: Array = result.get("titles", [])
	if titles.is_empty() and result.get("title", "") != "":
		titles = [result.get("title", "")]  # 兼容旧版结算数据
	var ptitles: Array = result.get("player_titles", [])
	if not is_self_play:
		var mi = _n().player_index
		if mi >= 0 and mi < ptitles.size():
			titles = ptitles[mi]
	_clear_title_row()
	if not titles.is_empty():
		_current_titles = titles
		_current_title = str(titles[0])
		for t in titles:
			title_row.add_child(_make_title_badge(str(t)))
	else:
		_current_titles = []
		_current_title = ""
	cond_label.visible = false
	var names: Array = result.get("names", [])
	_build_stat_cards(result, names, winner)
	# 获胜者一行：优先玩家名（联机为输入的名字），否则回退"玩家 N"
	var wname = names[winner] if winner < names.size() else "玩家 %d" % (winner + 1)
	detail_label.text = "%s 获胜" % wname

func _clear_title_row():
	for c in title_row.get_children():
		title_row.remove_child(c)
		c.queue_free()

func _clear_stat_cards():
	for c in stats_row.get_children():
		stats_row.remove_child(c)
		c.queue_free()

# 统计卡片行：每玩家一张横排（2人居中，>2人拉宽撑满屏幕利用率）；
# 卡片底部"查看称号 ▸"按钮默认隐藏该玩家称号，点击展开/收起（方案B）
func _build_stat_cards(result: Dictionary, names: Array, winner: int):
	_clear_stat_cards()
	var stats: Array = result.get("stats", [])
	if stats.is_empty(): return
	var ptitles: Array = result.get("player_titles", [])
	var eliminated: Array = result.get("eliminated", [])
	var my_idx: int = _n().player_index
	var is_self_play = (LocalGame.game != null) and not LocalGame.ai_mode
	# 卡片数决定区域宽度：2人居中，多人拉宽
	var n = stats.size()
	stats_scroll.offset_left = -620 if n <= 2 else -920
	stats_scroll.offset_right = 620 if n <= 2 else 920
	for i in range(n):
		var card := PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.custom_minimum_size = Vector2(340, 0)
		card.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var is_win = (i == winner)
		var is_me = (not is_self_play) and (i == my_idx)
		var is_out = i < eliminated.size() and bool(eliminated[i])
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.13, 0.16, 0.22, 0.9)
		if is_win:
			sb.border_color = Color(1, 0.85, 0.3, 0.95)
		elif is_me:
			sb.border_color = Color(0.35, 0.55, 0.9, 0.95)
		else:
			sb.border_color = Color(0.42, 0.46, 0.55, 0.85)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(12)
		card.add_theme_stylebox_override("panel", sb)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 10)
		card.add_child(v)
		# 名字行：P序号 名字 + 标记
		var nm = names[i] if i < names.size() else "玩家 %d" % (i + 1)
		var tag = ""
		if is_me: tag += "（我）"
		if is_out: tag += "（已淘汰）"
		var name_l := Label.new()
		name_l.text = "P%d %s%s" % [i + 1, nm, tag]
		name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_l.add_theme_font_size_override("font_size", Style.fs(28))
		name_l.add_theme_color_override("font_color",
			Color(1, 0.85, 0.3) if is_win else Color.WHITE)
		v.add_child(name_l)
		# 统计数据
		var d: Dictionary = stats[i]
		var mc = _max_card(d.get("cards_played", {}))
		var stat_l := Label.new()
		stat_l.text = "造成伤害  %d\n受到伤害  %d\n  · 攻击  %d\n  · 陷阱  %d\n  · DoT  %d\n回复血量  %d\n移动步数  %d\n复活次数  %d\n打出最多  %s" % [
			d.get("damage_dealt", 0), d.get("damage_taken", 0),
			d.get("damage_from_attack", 0), d.get("damage_from_trap", 0), d.get("damage_from_dot", 0),
			d.get("heal_total", 0), d.get("moves", 0), d.get("resurrected", 0), _max_card_str(mc)]
		stat_l.add_theme_color_override("font_color", Color(1, 1, 1, 1))
		stat_l.add_theme_font_size_override("font_size", Style.fs(24))
		v.add_child(stat_l)
		# 结束时面板（对局结束状态，方便查看成长：与初始 HP/近/远/魔对比）
		var endp: Array = result.get("end_players", [])
		if i < endp.size():
			var ep: Dictionary = endp[i]
			var init_cd: Dictionary = Config.CHARACTER_DB.get(str(ep.get("char_id", "")), {})
			var end_l := Label.new()
			end_l.text = "结束时：HP %d/%d ｜ 近%d 远%d 魔%d" % [
				int(ep.get("hp", 0)), int(ep.get("max_hp", 0)),
				int(ep.get("near", 0)), int(ep.get("range", 0)), int(ep.get("magic", 0))]
			end_l.add_theme_color_override("font_color", Style.SELECTED_CYAN)
			end_l.add_theme_font_size_override("font_size", Style.fs(22))
			v.add_child(end_l)
			# 成长对比：面板相对初始角色的变化（+n / -n）
			var init_n = int(init_cd.get("near", 0)); var init_r = int(init_cd.get("range", 0)); var init_m = int(init_cd.get("magic", 0))
			var dn = int(ep.get("near", 0)) - init_n
			var dr = int(ep.get("range", 0)) - init_r
			var dm = int(ep.get("magic", 0)) - init_m
			var parts: Array = []
			if dn != 0: parts.append("近%+d" % dn)
			if dr != 0: parts.append("远%+d" % dr)
			if dm != 0: parts.append("魔%+d" % dm)
			if not parts.is_empty():
				var g_l := Label.new()
				g_l.text = "成长：" + "  ".join(parts)
				g_l.add_theme_color_override("font_color", Color(0.55, 0.9, 0.6))
				g_l.add_theme_font_size_override("font_size", Style.fs(20))
				v.add_child(g_l)
		# 该玩家称号：默认隐藏，"查看称号 ▸"点击展开。
		# 自己的卡片不展示（自己的称号已在顶部查看）；自我对战时胜者卡片不重复（顶部已展示胜者称号）
		var pts: Array = ptitles[i] if i < ptitles.size() else []
		var skip_toggle = is_me or (is_self_play and is_win)
		if not pts.is_empty() and not skip_toggle:
			var badge_row := FlowContainer.new()
			badge_row.name = "BadgeRow"
			badge_row.visible = false
			badge_row.alignment = FlowContainer.ALIGNMENT_CENTER
			badge_row.add_theme_constant_override("h_separation", 6)
			badge_row.add_theme_constant_override("v_separation", 4)
			v.add_child(badge_row)
			for t in pts:
				badge_row.add_child(_make_title_badge(str(t), true))
			var toggle := Button.new()
			toggle.text = "查看称号 ▸"
			toggle.flat = true
			toggle.add_theme_font_size_override("font_size", Style.fs(20))
			toggle.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
			toggle.pressed.connect(func():
				badge_row.visible = not badge_row.visible
				toggle.text = "收起称号 ▾" if badge_row.visible else "查看称号 ▸"
			)
			v.add_child(toggle)
		stats_row.add_child(card)

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
