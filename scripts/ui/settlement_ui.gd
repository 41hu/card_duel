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
