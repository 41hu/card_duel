# settlement_ui.gd — 结算界面
extends Control

const Style = preload("res://scripts/theme/style_const.gd")

@onready var title_label = $Title
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
		detail_label.text = "对方已断开连接"
	else:
		var is_winner = (winner == _n().player_index)
		if is_winner:
			title_label.text = "胜利！"
			title_label.add_theme_color_override("font_color", Style.WIN_GOLD)
		else:
			title_label.text = "败北"
			title_label.add_theme_color_override("font_color", Style.LOSE_RED)
		detail_label.text = "玩家 %d 获胜" % (winner + 1)
