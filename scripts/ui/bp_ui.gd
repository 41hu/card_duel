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
var char_grid: GridContainer
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
	_build_layout()
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
	_n().network_error.connect(_on_action_error)
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
	var n = _n()
	if n.network_error.is_connected(_on_action_error):
		n.network_error.disconnect(_on_action_error)
	if n.bp_state_updated.is_connected(_on_bp_state):
		n.bp_state_updated.disconnect(_on_bp_state)
	if n.state_updated.is_connected(_on_game_state):
		n.state_updated.disconnect(_on_game_state)

# 联机：BP 阶段对手断线 → 跳结算
func _on_game_ended(r: Dictionary):
	Network.last_game_result = r
	get_tree().change_scene_to_file("res://scenes/settlement.tscn")

# 联机：自己断线 → 回主菜单
func _on_server_disconnected():
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _on_action_error(message: String):
	_submitted = false
	status_label.text = message
	_refresh_preview()

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
		char_grid.remove_child(b)
		b.queue_free()
	_char_buttons.clear()
	_create_char_buttons(ids)

const PAGE_SIZE := 12
var _page := 0
var _query := ""
var _filter := 0
var _preview_id := ""
var _submitted := false
var _side_labels: Array = []
var _page_label: Label
var _previous: Button
var _next: Button
var _preview_title: Label
var _preview_stats: Label
var _preview_desc: RichTextLabel
var _portrait: TextureRect
var _confirm: Button
var _grid_area: Control

func _text(value: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

func _button(value: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 64
	button.add_theme_font_size_override("font_size", 26)
	button.pressed.connect(callback)
	return button

func _build_layout():
	$Title.hide()
	$CharScroll.hide()
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 32)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 16)
	margin.add_child(root)
	phase_label.reparent(root)
	phase_label.add_theme_font_size_override("font_size", 34)
	turn_label.reparent(root)
	turn_label.add_theme_font_size_override("font_size", 24)
	var sides := HBoxContainer.new()
	sides.add_theme_constant_override("separation", 32)
	root.add_child(sides)
	for i in range(2):
		var label := _text("", 28)
		label.custom_minimum_size.y = 106
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_color_override("font_color", Style.ME_INFO if i == 0 else Style.OPP_INFO)
		sides.add_child(label)
		_side_labels.append(label)
	root.add_child(HSeparator.new())
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 28)
	root.add_child(body)
	var roster := VBoxContainer.new()
	roster.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(roster)
	var filters := HBoxContainer.new()
	roster.add_child(filters)
	var search := LineEdit.new()
	search.placeholder_text = "搜索角色名称"
	search.custom_minimum_size.y = 64
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.add_theme_font_size_override("font_size", 26)
	search.text_changed.connect(func(value): _query = value.strip_edges(); _page = 0; _paginate())
	filters.add_child(search)
	var filter := OptionButton.new()
	for value in ["全部角色", "近战面板最高", "远程面板最高", "法术面板最高"]:
		filter.add_item(value)
	filter.add_theme_font_size_override("font_size", 24)
	filter.item_selected.connect(func(index): _filter = index; _page = 0; _paginate())
	filters.add_child(filter)
	_grid_area = Control.new()
	_grid_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	roster.add_child(_grid_area)
	char_grid = GridContainer.new()
	char_grid.columns = 4
	char_grid.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	char_grid.add_theme_constant_override("h_separation", 12)
	char_grid.add_theme_constant_override("v_separation", 12)
	_grid_area.add_child(char_grid)
	_grid_area.resized.connect(_size_tiles)
	var pages := HBoxContainer.new()
	pages.alignment = BoxContainer.ALIGNMENT_CENTER
	roster.add_child(pages)
	_previous = _button("‹", func(): _page -= 1; _paginate())
	_previous.tooltip_text = "上一页"
	_previous.custom_minimum_size.x = 90
	pages.add_child(_previous)
	_page_label = _text("", 24)
	_page_label.custom_minimum_size.x = 400
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pages.add_child(_page_label)
	_next = _button("›", func(): _page += 1; _paginate())
	_next.tooltip_text = "下一页"
	_next.custom_minimum_size.x = 90
	pages.add_child(_next)
	body.add_child(VSeparator.new())
	var preview := VBoxContainer.new()
	preview.custom_minimum_size.x = 500
	body.add_child(preview)
	_preview_title = _text("选择角色", 32)
	preview.add_child(_preview_title)
	_portrait = TextureRect.new()
	_portrait.custom_minimum_size.y = 170
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.add_child(_portrait)
	_preview_stats = _text("", 25)
	preview.add_child(_preview_stats)
	_preview_desc = RichTextLabel.new()
	_preview_desc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview_desc.add_theme_font_size_override("normal_font_size", 25)
	preview.add_child(_preview_desc)
	_confirm = _button("确认选择", _confirm_preview)
	preview.add_child(_confirm)
	status_label.reparent(root)
	status_label.add_theme_font_size_override("font_size", 22)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size.y = 36

func _art_for(cid: String) -> Texture2D:
	var path := str(Config.CHARACTER_DB.get(cid, {}).get("portrait", "res://art/characters/%s.png" % cid))
	if ResourceLoader.exists(path): return load(path) as Texture2D
	return null

func _create_char_buttons(ids: Array):
	for cid in ids:
		if not Config.CHARACTER_DB.has(cid): continue
		var cd: Dictionary = Config.CHARACTER_DB[cid]
		var btn := Button.new()
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var frame := StyleBoxFlat.new()
		frame.bg_color = Color("202a30")
		frame.border_color = Color("46565b")
		frame.set_border_width_all(2)
		frame.set_corner_radius_all(6)
		btn.add_theme_stylebox_override("normal", frame)
		var hover := frame.duplicate()
		hover.border_color = Style.SELECTED_CYAN
		btn.add_theme_stylebox_override("hover", hover)
		btn.add_theme_stylebox_override("focus", hover)
		btn.set_meta("char_id", cid)
		btn.pressed.connect(_on_char_clicked.bind(cid))
		var content := VBoxContainer.new()
		content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		content.offset_left = 8
		content.offset_right = -8
		content.offset_top = 6
		content.offset_bottom = -6
		content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(content)
		var art := TextureRect.new()
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		art.size_flags_vertical = Control.SIZE_EXPAND_FILL
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		art.texture = _art_for(cid)
		if art.texture == null:
			var powers := [int(cd.near), int(cd.range), int(cd.magic)]
			var icon: String = ["ap_attack", "ap_move", "ap_function"][powers.find(powers.max())]
			art.texture = load("res://art/ui/%s.svg" % icon)
			art.modulate.a = 0.35
		content.add_child(art)
		var name_label := _text(str(cd.name), 27)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(name_label)
		var state_label := _text(" ", 22)
		state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		state_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(state_label)
		btn.set_meta("state_label", state_label)
		btn.set_meta("labels", [name_label, state_label])
		char_grid.add_child(btn)
		_char_buttons.append(btn)
	_paginate()

func _size_tiles():
	if _grid_area == null: return
	for btn in _char_buttons:
		btn.custom_minimum_size = Vector2(maxf(120, floorf((_grid_area.size.x - 40) / 4)), maxf(130, floorf((_grid_area.size.y - 28) / 3)))

func _paginate():
	var filtered: Array = []
	for btn in _char_buttons:
		var cd: Dictionary = Config.CHARACTER_DB[btn.get_meta("char_id")]
		var matches := _query.is_empty() or str(cd.name).contains(_query)
		if _filter > 0:
			var powers := [int(cd.near), int(cd.range), int(cd.magic)]
			matches = matches and powers[_filter - 1] == powers.max()
		if matches: filtered.append(btn)
	var count := maxi(1, ceili(filtered.size() / float(PAGE_SIZE)))
	_page = clampi(_page, 0, count - 1)
	for btn in _char_buttons:
		var index := filtered.find(btn)
		btn.visible = index >= _page * PAGE_SIZE and index < (_page + 1) * PAGE_SIZE
	_page_label.text = "%d / %d · %d 个角色" % [_page + 1, count, filtered.size()]
	_previous.disabled = _page == 0
	_next.disabled = _page == count - 1
	_size_tiles()

func _on_bp_state(data: Dictionary):
	if data.get("phase", "") != _bp_state.get("phase", ""):
		_preview_id = ""
		_submitted = false
		status_label.text = ""
	_bp_state = data; _player_index = Network.player_index
	_sync_char_buttons()
	var t = _bp_state.get("bp_time_left", -1)
	if t >= 0: _bp_timer = t; _bp_timer_acc = 0.0
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

func _acting() -> int:
	return int(_bp_state.get("bp_first", 0)) if "first" in str(_bp_state.get("phase", "")) else 1 - int(_bp_state.get("bp_first", 0))

func _my_turn() -> bool:
	if _is_local: return not LocalGame.ai_mode or _acting() == 0
	return _acting() == _player_index

func _update_ui():
	var phase: String = _bp_state.get("phase", "")
	var verb := "禁用" if "ban" in phase else "选择"
	var own := 0 if _is_local else maxi(0, _player_index)
	var first := int(_bp_state.get("bp_first", 0))
	var banned: Array = _bp_state.get("banned_chars", [])
	var picked: Array = _bp_state.get("picked_chars", [])
	for side in range(2):
		var player := own if side == 0 else 1 - own
		var order := 0 if player == first else 1
		var ban_name := Config.char_name(banned[order]) if banned.size() > order else "待禁用"
		var pick_name := Config.char_name(picked[order]) if picked.size() > order and picked[order] != "" else "待选择"
		var team := ("我方" if side == 0 else "对方") if not (_is_local and not LocalGame.ai_mode) else "玩家"
		_side_labels[side].text = "%s P%d · %s%s\n禁用：%s    选择：%s" % [team, player + 1, "先手" if player == first else "后手", " · 正在" + verb if player == _acting() and phase != "done" else "", ban_name, pick_name]
	phase_label.text = "角色禁选 · %s阶段 · %s" % [verb, "%ds" % _bp_timer if _bp_timer >= 0 else "不限时"]
	turn_label.text = "轮到你%s" % verb if _my_turn() else "等待 P%d %s" % [_acting() + 1, verb]
	for btn in _char_buttons:
		var cid: String = btn.get_meta("char_id")
		var st: Label = btn.get_meta("state_label")
		st.text = "已禁用" if cid in banned else ("已选择" if cid in picked else ("预览中" if cid == _preview_id else " "))
		btn.modulate = Color(0.6, 0.6, 0.6) if cid in banned else Color.WHITE
		btn.self_modulate = Style.SELECTED_CYAN if cid == _preview_id else Color.WHITE
	_refresh_preview()
	if phase == "done":
		phase_label.text = "角色已确定"
		turn_label.text = "正在进入下一阶段"

func _on_char_clicked(char_id: String):
	_preview_id = char_id
	_update_ui()

func _refresh_preview():
	var cd: Dictionary = Config.CHARACTER_DB.get(_preview_id, {})
	var verb := "禁用" if "ban" in str(_bp_state.get("phase", "")) else "选择"
	_preview_title.text = str(cd.get("name", "选择角色"))
	_portrait.texture = _art_for(_preview_id)
	_portrait.visible = _portrait.texture != null
	_preview_stats.text = "生命 %d\n近战 %d · 远程 %d · 法术 %d" % [cd.hp, cd.near, cd.range, cd.magic] if not cd.is_empty() else ""
	_preview_desc.text = str(cd.get("skill_desc", ""))
	_confirm.text = "等待确认" if _submitted else "确认%s%s" % [verb, " · " + str(cd.name) if not cd.is_empty() else ""]
	_confirm.disabled = _submitted or not _my_turn() or not _preview_id in _bp_state.get("available_chars", []) or _bp_state.get("phase") == "done"

func _confirm_preview():
	if _confirm.disabled: return
	var action := "ban" if "ban" in str(_bp_state.get("phase", "")) else "pick"
	_submitted = true
	_refresh_preview()
	_n().send_bp_action(action, _preview_id)
