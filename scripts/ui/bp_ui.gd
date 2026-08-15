# bp_ui.gd — BP禁选界面
# 角色按钮完全由服务器下发的 bp_state 驱动（available+banned+picked 并集），
# 本地 CHARACTER_IDS 仅在没有 bp_state 时兜底。
# 杜绝"新角色无法 BP"：服务器未部署新角色时，按钮不显示该角色并提示服务器版本过低，
# 而不是显示一个永远禁用的按钮。
extends Control

const Style = preload("res://scripts/theme/style_const.gd")
const VERSION_SCRIPT = preload("res://scripts/version.gd")

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
	Style.scale_node_fonts(self)  # 移动端字号适配（tscn 写死的字号）
	_is_local = (LocalGame.game != null)
	# 触摸友好的滚动条宽度
	char_grid.get_parent().get_v_scroll_bar().custom_minimum_size = Vector2(24, 0)
	# 先按本地角色兜底建按钮（无缓存时也能显示），收到 bp_state 后按服务器集合校正
	_create_char_buttons(Config.CHARACTER_IDS)
	_n().bp_state_updated.connect(_on_bp_state)
	_n().state_updated.connect(_on_game_state)
	# 自定义卡组联机：BP 完成后服务端发 deck_config → 跳配置卡组环节
	Network.deck_config.connect(_on_deck_config)
	# 联机：BP 阶段对手断线 → 服务端发 game_over → 跳结算（对手逃跑获胜）
	Network.game_ended.connect(_on_game_ended)
	# 联机：自己断线 → 回主菜单（避免卡在 BP 页）
	Network.server_disconnected.connect(_on_server_disconnected)
	var cached = _n().bp_state_cache
	if not cached.is_empty():
		_on_bp_state(cached); _n().bp_state_cache = {}

func _exit_tree():
	if Network.game_ended.is_connected(_on_game_ended):
		Network.game_ended.disconnect(_on_game_ended)
	if Network.deck_config.is_connected(_on_deck_config):
		Network.deck_config.disconnect(_on_deck_config)
	if Network.server_disconnected.is_connected(_on_server_disconnected):
		Network.server_disconnected.disconnect(_on_server_disconnected)

# 联机：BP 阶段对手断线 → 跳结算
func _on_game_ended(r: Dictionary):
	Network.last_game_result = r
	get_tree().change_scene_to_file("res://scenes/settlement.tscn")

# 联机：自己断线 → 回主菜单
func _on_server_disconnected():
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

# 联机自定义卡组：进入配置卡组环节（deck_pick 场景）
func _on_deck_config(_data: Dictionary):
	get_tree().change_scene_to_file("res://scenes/deck_pick.tscn")

# 服务器 bp_state 中的角色集合（available + banned + picked 并集）
# 排序固定为本地角色表顺序：角色被禁用/选择后停留在原位（仅变色+标记），
# 不随状态重排（否则每次操作后按钮位置跳动）；服务器有而本地表没有的角色追加末尾
func _server_char_ids() -> Array:
	var sv := {}
	for cid in _bp_state.get("available_chars", []) + _bp_state.get("banned_chars", []) + _bp_state.get("picked_chars", []):
		if str(cid) == "": continue  # picked_chars 初始占位空串，不是角色
		sv[cid] = true
	var out := []
	for cid in Config.CHARACTER_IDS:
		if sv.has(cid):
			out.append(cid)
	for cid in sv:
		if not cid in out:
			out.append(cid)
	return out

# 本地配置有而服务器 bp_state 没有的角色（服务器未部署新角色数据）
func _missing_chars() -> Array:
	var sv := {}
	for cid in _server_char_ids(): sv[cid] = true
	var missing := []
	for cid in Config.CHARACTER_IDS:
		if not sv.has(cid):
			missing.append(Config.char_name(cid))
	return missing

# 服务器角色集合变化时重建按钮（新增角色/服务器版本变化）
func _sync_char_buttons():
	var ids = _server_char_ids()
	if ids.is_empty(): return  # 还没收到服务器数据，保持兜底按钮
	var same = ids.size() == _char_buttons.size()
	if same:
		for i in range(ids.size()):
			if ids[i] != _char_buttons[i].get_meta("char_id"):
				same = false
				break
	if same: return
	for b in _char_buttons:
		b.queue_free()
	_char_buttons.clear()
	_create_char_buttons(ids)

func _create_char_buttons(ids: Array):
	char_grid.columns = ceil(sqrt(ids.size()))
	for i in range(ids.size()):
		var char_id = ids[i]
		# 数据驱动容错：服务器数据含未知角色时跳过而非崩溃（并打印便于定位）
		if not Config.CHARACTER_DB.has(char_id):
			push_warning("[BP] 跳过未知角色数据: %s" % str(char_id))
			continue
		var cd = Config.CHARACTER_DB[char_id]
		var btn = Button.new()
		btn.name = "CharBtn_%s" % char_id
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# 滚动容器内垂直方向不拉伸，高度由 custom_minimum_size 决定
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		btn.custom_minimum_size = Vector2(250, 190)
		btn.set_meta("char_id", char_id)
		btn.pressed.connect(_on_char_clicked.bind(char_id))
		# 内部用 Label 布局（Label 自动换行，避免 Button 文本撑宽列）
		var vb = VBoxContainer.new()
		vb.name = "CardLayout"
		vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		vb.add_theme_constant_override("separation", 4)
		for l in vb.get_children(): l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(vb)
		# 状态标签放在顶部：明确属于本卡片，避免与下一行卡片混淆
		var st = Label.new()
		st.name = "StateLabel"
		st.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		st.add_theme_font_size_override("font_size", Style.fs(24))
		st.visible = false
		vb.add_child(st)
		var n = Label.new()
		n.name = "NameLabel"
		n.text = cd.name
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		n.add_theme_font_size_override("font_size", Style.fs(26))
		vb.add_child(n)
		var s = Label.new()
		s.name = "AttrLabel"
		s.text = "HP%d 近%d 远%d 魔%d" % [cd.hp, cd.near, cd.range, cd.magic]
		s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		s.add_theme_font_size_override("font_size", Style.fs(20))
		vb.add_child(s)
		var d = Label.new()
		d.name = "DescLabel"
		d.text = cd.skill_desc
		d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.size_flags_vertical = Control.SIZE_EXPAND_FILL
		d.add_theme_font_size_override("font_size", Style.fs(18))
		# 限制描述行数：超长描述（如快枪手）会撑高按钮 → 角色区超可视区/出现滚动条
		# → 第 3 行按钮（快枪手）点击异常。截断省略保持按钮高度固定 190。
		d.max_lines_visible = 2
		d.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		vb.add_child(d)
		btn.set_meta("state_label", st)
		btn.set_meta("labels", [st, n, s, d])
		char_grid.add_child(btn)
		_char_buttons.append(btn)

func _on_bp_state(data: Dictionary):
	_bp_state = data; _player_index = Network.player_index
	_sync_char_buttons()
	var t = _bp_state.get("bp_time_left", -1)
	if t > 0: _bp_timer = t; _bp_timer_acc = 0.0
	else: _bp_timer = -1
	_update_ui()
	_check_version()

# 服务器版本/角色缺失提示：联机时服务器旧代码 → 明确告知，避免"按钮在却点不了"
func _check_version():
	var sv: String = _bp_state.get("server_version", "")
	if sv != "" and sv != VERSION_SCRIPT.VERSION:
		status_label.text = "服务器版本 v%s ≠ 客户端 v%s（新角色可能不可用，请联系管理员部署服务器）" % [sv, VERSION_SCRIPT.VERSION]
		return
	var missing = _missing_chars()
	if missing.size() > 0:
		status_label.text = "服务器未包含角色：%s（服务器版本过低，请联系管理员部署）" % "、".join(missing)

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
	# 人机 BP：人类是 P0，轮到 acting==0 才可操作（AI 自动禁选）；自我对战始终可操作
	var my_turn = (acting == 0) if (_is_local and LocalGame.ai_mode) else (true if _is_local else (acting == _player_index))
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
