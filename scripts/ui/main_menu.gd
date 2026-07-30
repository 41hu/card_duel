# main_menu.gd — 主菜单界面
extends Control

const Style = preload("res://scripts/theme/style_const.gd")

@onready var main_panel = $MainPanel
@onready var create_panel = $CreatePanel
@onready var join_panel = $JoinPanel
@onready var c_server = $CreatePanel/CServerInput
@onready var c_name = $CreatePanel/CNameInput
@onready var c_create_btn = $CreatePanel/CCreateBtn
@onready var c_back_btn = $CreatePanel/CBackBtn
@onready var c_room_label = $CreatePanel/CRoomLabel
@onready var j_server = $JoinPanel/JServerInput
@onready var j_room = $JoinPanel/JRoomInput
@onready var j_name = $JoinPanel/JNameInput
@onready var j_join_btn = $JoinPanel/JJoinBtn
@onready var j_back_btn = $JoinPanel/JBackBtn
@onready var status_label = $StatusLabel

func _ready():
	$MainPanel/CreateBtn.pressed.connect(_show_create)
	$MainPanel/JoinBtn.pressed.connect(_show_join)
	$MainPanel/SelfBtn.pressed.connect(_on_self_play)
	c_back_btn.pressed.connect(_show_main)
	j_back_btn.pressed.connect(_show_main)
	c_create_btn.pressed.connect(_on_create)
	j_join_btn.pressed.connect(_on_join)
	Network.connected_to_server.connect(_on_connected)
	Network.server_disconnected.connect(_on_disconnected)
	Network.room_created.connect(_on_room_created)
	Network.room_joined.connect(_on_room_joined)
	Network.game_starting.connect(_on_game_starting)
	Network.network_error.connect(_on_error)

func _show_create():
	main_panel.visible = false
	create_panel.visible = true
	join_panel.visible = false

func _show_join():
	main_panel.visible = false
	create_panel.visible = false
	join_panel.visible = true

func _show_main():
	main_panel.visible = true
	create_panel.visible = false
	join_panel.visible = false

func _on_create():
	status_label.text = "正在连接..."
	Network.connect_to_server(c_server.text.strip_edges())
	await Network.connected_to_server
	var pname = c_name.text.strip_edges()
	if pname == "": pname = "Player1"
	Network.create_room(pname)

func _on_join():
	var rid = j_room.text.strip_edges()
	if rid == "": status_label.text = "请输入房间号"; return
	status_label.text = "正在连接..."
	Network.connect_to_server(j_server.text.strip_edges())
	await Network.connected_to_server
	var pname = j_name.text.strip_edges()
	if pname == "": pname = "Player2"
	Network.join_room(rid, pname)

func _on_connected(): status_label.text = "已连接"
func _on_disconnected(): status_label.text = "断开连接"

func _on_room_created(room_id: String):
	c_room_label.text = "房间号: %s" % room_id
	status_label.text = "等待对手加入..."
	var btn = _make_ready_btn(create_panel, 360)
	btn.pressed.connect(func(): Network.ready_up(); btn.disabled = true; btn.text = "已准备")

func _on_room_joined(room_id: String, _players: Array):
	status_label.text = "已加入房间 %s" % room_id
	var btn = _make_ready_btn(join_panel, 390)
	btn.pressed.connect(func(): Network.ready_up(); btn.disabled = true; btn.text = "已准备")

func _make_ready_btn(parent: Control, y: float) -> Button:
	for c in parent.get_children():
		if c is Button and "准备" in c.text: c.queue_free()
	var btn = Button.new()
	btn.text = "准备开始"
	btn.position = Vector2(100, y)
	btn.size = Vector2(200, 45)
	btn.add_theme_color_override("font_color", Style.READY_YELLOW)
	parent.add_child(btn)
	return btn

func _on_game_starting(data: Dictionary):
	status_label.text = "进入BP..."
	Network.bp_state_cache = data.get("bp_state", {})
	get_tree().change_scene_to_file("res://scenes/bp_scene.tscn")

func _on_self_play():
	LocalGame.start_bp()
	get_tree().change_scene_to_file("res://scenes/bp_scene.tscn")

func _on_error(msg: String):
	status_label.text = "错误: " + msg
	status_label.add_theme_color_override("font_color", Style.ERROR_RED)
