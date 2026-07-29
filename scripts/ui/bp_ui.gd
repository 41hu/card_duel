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
var _char_data = {
	"swordsman":  {"name":"剑士","hp":28,"s":"近7远3魔2","sk":"近战命中后: 抽1牌或回2HP (每回合限一)"},
	"archer":     {"name":"弓手","hp":24,"s":"近2远8魔2","sk":"每回合首次普通远程不消耗攻击点"},
	"mage":       {"name":"法师","hp":22,"s":"近2远2魔8","sk":"弃1手牌, 本次魔法+2 (每回合限一)"},
	"paladin":    {"name":"圣骑士","hp":36,"s":"近5远2魔2","sk":"每回合首次受伤-2 (最低0)"},
	"assassin":   {"name":"刺客","hp":22,"s":"近7远5魔1","sk":"每回合免费移动1格"},
	"priest":     {"name":"牧师","hp":28,"s":"近2远4魔6","sk":"使用回复卡额外+2"},
	"berserker":  {"name":"狂战士","hp":28,"s":"近8远2魔2","sk":"受直接攻击后近战+1 (2回合可叠加)"},
	"warlock":    {"name":"术士","hp":24,"s":"近2远3魔7","sk":"功能点+1; 未用功能牌回合结束抽1张"},
}

func _ready():
	_create_char_buttons()
	Network.bp_state_updated.connect(_on_bp_state)
	Network.state_updated.connect(_on_game_state)
	var cached = Network.bp_state_cache
	if not cached.is_empty():
		_on_bp_state(cached); Network.bp_state_cache = {}

func _create_char_buttons():
	var ids = Config.CHARACTER_IDS
	for i in range(8):
		var char_id = ids[i]; var cd = _char_data[char_id]
		var btn = Button.new()
		btn.text = "%s\nHP:%d | %s\n%s" % [cd.name, cd.hp, cd.s, cd.sk]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(200, 120)
		btn.set_meta("char_id", char_id)
		btn.pressed.connect(_on_char_clicked.bind(char_id))
		char_grid.add_child(btn)
		_char_buttons.append(btn)
		_btn_base_text[char_id] = btn.text

func _on_bp_state(data: Dictionary):
	_bp_state = data; _player_index = Network.player_index; _update_ui()

func _on_game_state(_data: Dictionary):
	Network.battle_state_cache = _data
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
	var my_turn = (acting == _player_index)
	var pn = "禁用" if is_ban else "选择"
	var role = "先手" if acting == bp_first else "后手"
	if my_turn: phase_label.text = "[你的回合] %s阶段" % pn; turn_label.text = "请点击角色进行%s（你是%s）" % [pn, role]
	else: phase_label.text = "[对手的回合] %s阶段" % pn; turn_label.text = "等待对手%s..." % pn
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
	Network.send_bp_action(action, char_id); status_label.text = "已选择..."
