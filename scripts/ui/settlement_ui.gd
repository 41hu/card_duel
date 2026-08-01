# settlement_ui.gd — 结算界面
extends Control

const Style = preload("res://scripts/theme/style_const.gd")

@onready var title_label = $Title
@onready var title2_label = $Title2
@onready var stats_label = $StatsLabel
@onready var detail_label = $Detail
@onready var back_btn = $BackBtn

func _n():
	if LocalGame.game != null: return LocalGame
	return Network

func _ready():
	back_btn.pressed.connect(func():
		Network.disconnect_from_server()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	)
	_n().game_ended.connect(_on_game_ended)
	# 从缓存读取结果：battle_ui 切场景时信号已发完，直接 connect 收不到
	var cached = _n().last_game_result
	if not cached.is_empty():
		_on_game_ended(cached)

func _on_game_ended(result: Dictionary):
	var winner = result.get("winner", -1)
	if winner == -1:
		title_label.text = "对手断线"
		title_label.add_theme_color_override("font_color", Style.WIN_GOLD)
		title2_label.text = ""
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
		title2_label.text = "称号：%s" % title if title != "" else ""
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
