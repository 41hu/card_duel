# settlement_ui.gd — 结算界面
extends Control

const Style = preload("res://scripts/theme/style_const.gd")

@onready var title_label = $Title
@onready var detail_label = $Detail
@onready var back_btn = $BackBtn

func _ready():
	back_btn.pressed.connect(func():
		Network.disconnect_from_server()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	)
	Network.game_ended.connect(_on_game_ended)

func _on_game_ended(result: Dictionary):
	var winner = result.get("winner", -1)
	if winner == -1:
		title_label.text = "对手断线"
		title_label.add_theme_color_override("font_color", Style.WIN_GOLD)
		detail_label.text = "对方已断开连接"
	else:
		var is_winner = (winner == Network.player_index)
		if is_winner:
			title_label.text = "胜利！"
			title_label.add_theme_color_override("font_color", Style.WIN_GOLD)
		else:
			title_label.text = "败北"
			title_label.add_theme_color_override("font_color", Style.LOSE_RED)
		detail_label.text = "玩家 %d 获胜" % (winner + 1)
