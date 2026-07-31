# bp_ui.gd — BP禁选界面
extends Control

@onready var phase_label = $PhaseLabel
@onready var turn_label = $TurnLabel
@onready var char_grid = $CharGrid
@onready var status_label = $StatusLabel

var _char_buttons: Array = []
var _btn_base_text: Dictionary = {}
var _player_index: int = -1
var _bp_state: Dictionary = {}
var _is_local: bool = false
var _bp_timer: int = -1
var _bp_timer_acc: float = 0.0

func _n():
	if LocalGame.game != null: return LocalGame
	return Network

func _ready():
	_is_local = (LocalGame.game != null)
	_create_char_buttons()
	_n().bp_state_updated.connect(_on_bp_state)
	_n().state_updated.connect(_on_game_state)
	var cached = _n().bp_state_cache
	if not cached.is_empty():
		_on_bp_state(cached); _n().bp_state_cache = {}

func _create_char_buttons():
	var ids = Config.CHARACTER_IDS
	char_grid.columns = ceil(sqrt(ids.size()))
	for i in range(ids.size()):
		var char_id = ids[i]
		var cd = Config.CHARACTER_DB[char_id]
		var btn = Button.new()
		var txt = "%s\nHP:%d | 近%d 远%d 魔%d\n%s" % [cd.name, cd.hp, cd.near, cd.range, cd.magic, cd.skill_desc]
		btn.text = txt
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(240, 150)
		btn.add_theme_font_size_override("font_size", 20)
		btn.set_meta("char_id", char_id)
		btn.pressed.connect(_on_char_clicked.bind(char_id))
		char_grid.add_child(btn)
		_char_buttons.append(btn)
		_btn_base_text[char_id] = btn.text

func _on_bp_state(data: Dictionary):
	_bp_state = data; _player_index = Network.player_index
	var t = _bp_state.get("bp_time_left", -1)
	if t > 0: _bp_timer = t; _bp_timer_acc = 0.0
	else: _bp_timer = -1
	_update_ui()

func _process(delta):
	if _bp_timer <= 0: return
	_bp_timer_acc += delta
	if _bp_timer_acc >= 1.0:
		_bp_timer_acc -= 1.0
		_bp_timer -= 1
		if _bp_timer < 0: _bp_timer = -1
		_update_ui()

func _on_game_state(_data: Dictionary):
	_n().battle_state_cache = _data
	get_tree().change_scene_to_file("res://scenes/battle_scene.tscn")

func _update_ui():
	var phase = _bp_state.get("phase","")
	var banned = _bp_state.get("banned_chars",[])
	var picked = _bp_state.get("picked_chars",[])
	var available = _bp_state.get("available_chars",[])
	var bp_first = _bp_state.get("bp_first", 0)
	var is_ban = "ban" in phase
	var acting = -1
	if "first" in phase: acting = bp_first
	elif "second" in phase: acting = 1 - bp_first
	var my_turn = true if _is_local else (acting == _player_index)
	var pn = "禁用" if is_ban else "选择"
	var role = "先手" if acting == bp_first else "后手"
	var who = "你" if _is_local else ("你" if my_turn else "对手")
	if my_turn:
		phase_label.text = "[%s] %s阶段" % [who, pn]
		turn_label.text = "请点击角色进行%s（%s是%s）" % [pn, who, role]
	else:
		phase_label.text = "[对手的回合] %s阶段" % pn
		turn_label.text = "等待对手%s..." % pn
	if _bp_timer > 0:
		phase_label.text += " | %ds" % _bp_timer
	for btn in _char_buttons:
		var cid = btn.get_meta("char_id"); btn.text = _btn_base_text.get(cid,""); btn.disabled = true
		if cid in banned: btn.text += "\n[已禁用]"
		elif cid in picked: btn.text += "\n[已选]"
		elif cid in available:
			if my_turn: btn.disabled = false
	if phase == "done": phase_label.text = "BP完成！进入对战..."

func _on_char_clicked(char_id: String):
	var phase = _bp_state.get("phase","")
	var action = "ban" if "ban" in phase else "pick"
	_n().send_bp_action(action, char_id); status_label.text = "已选择..."
