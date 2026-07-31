# bp_ui.gd — BP禁选界面
extends Control

@onready var phase_label = $PhaseLabel
@onready var turn_label = $TurnLabel
@onready var char_grid = $CharScroll/CharGrid
@onready var status_label = $StatusLabel

var _char_buttons: Array = []
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
	# 触摸友好的滚动条宽度
	char_grid.get_parent().get_v_scroll_bar().custom_minimum_size = Vector2(24, 0)
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
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# 滚动容器内垂直方向不拉伸，高度由 custom_minimum_size 决定
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		btn.custom_minimum_size = Vector2(250, 190)
		btn.set_meta("char_id", char_id)
		btn.pressed.connect(_on_char_clicked.bind(char_id))
		# 内部用 Label 布局（Label 自动换行，避免 Button 文本撑宽列）
		var vb = VBoxContainer.new()
		vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		vb.add_theme_constant_override("separation", 4)
		for l in vb.get_children(): l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(vb)
		# 状态标签放在顶部：明确属于本卡片，避免与下一行卡片混淆
		var st = Label.new()
		st.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		st.add_theme_font_size_override("font_size", 24)
		st.visible = false
		vb.add_child(st)
		var n = Label.new()
		n.text = cd.name
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		n.add_theme_font_size_override("font_size", 26)
		vb.add_child(n)
		var s = Label.new()
		s.text = "HP%d 近%d 远%d 魔%d" % [cd.hp, cd.near, cd.range, cd.magic]
		s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		s.add_theme_font_size_override("font_size", 20)
		vb.add_child(s)
		var d = Label.new()
		d.text = cd.skill_desc
		d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.size_flags_vertical = Control.SIZE_EXPAND_FILL
		d.add_theme_font_size_override("font_size", 18)
		vb.add_child(d)
		btn.set_meta("state_label", st)
		btn.set_meta("labels", [st, n, s, d])
		char_grid.add_child(btn)
		_char_buttons.append(btn)

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
		var cid = btn.get_meta("char_id")
		var st: Label = btn.get_meta("state_label")
		st.visible = false
		btn.disabled = true
		var card_color: Color = Color(1, 1, 1)
		if cid in banned:
			st.text = "[已禁用]"
			st.visible = true
			card_color = Color(1, 0.45, 0.45)
		elif cid in picked:
			st.text = "[已选]"
			st.visible = true
			card_color = Color(0.45, 1, 0.45)
		elif cid in available:
			if my_turn: btn.disabled = false
		# 整卡文字统一变色（禁用红色调/已选绿色调），状态一目了然
		for l in btn.get_meta("labels"):
			l.add_theme_color_override("font_color", card_color)
	if phase == "done": phase_label.text = "BP完成！进入对战..."

func _on_char_clicked(char_id: String):
	var phase = _bp_state.get("phase","")
	var action = "ban" if "ban" in phase else "pick"
	var verb = "禁用" if action == "ban" else "选择"
	_n().send_bp_action(action, char_id)
	status_label.text = "已%s：%s" % [verb, Config.char_name(char_id)]
