# settlement_ui.gd — 结算界面
extends Control

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
	var is_winner = (winner == Network.player_index)
	if is_winner:
		title_label.text = "胜利！"
		title_label.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
	else:
		title_label.text = "败北"
		title_label.add_theme_color_override("font_color", Color(0.7, 0.3, 0.3))
	detail_label.text = "玩家 %d 获胜" % (winner + 1)
