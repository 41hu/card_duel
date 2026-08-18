# deck_pick.gd — BP 后「配置卡组」环节
# 目标：让玩家看清双方角色后，根据对手调整自己的卡组。
# 流程：BP 完成 → 本界面常驻显示「你：X vs 对手：Y」→ 选卡组（预设槽位 / 默认40张）
#      → 可「调整卡组」现场改（本局临时生效，不写槽位存档）→ 确认 → 下一人 → 开战。
# 信息隐藏：只展示当前选卡者自己的卡组构成，不显示对方（为联机规则做准备）。
extends Control

const Style = preload("res://scripts/theme/style_const.gd")
const DeckData = preload("res://scripts/data/deck_data.gd")

const GROUP_ORDER = ["attack", "tactics", "sustain", "equipment"]

var _step := 0                  # 0 = P1，1 = P2
var _decks: Array = [[], []]    # 已确认卡组（type_id 列表）
var _weapon_pools: Array = [{}, {}]  # 已确认武器幻化池（每玩家一份）
var _page := "pick"             # pick 选择页 / edit 编辑页
var _sel_kind := ""             # 当前选中："slot_1".."slot_3" / "default"
var _draft: Array = []          # 编辑页草稿
var _draft_weapon_pool: Dictionary = {}  # 编辑页武器池草稿
var _package_id: String = DeckData.DEFAULT_PACKAGE  # 当前选中卡组的回复套餐

@onready var title: Label
@onready var vs_label: Label
@onready var options_box: VBoxContainer
@onready var action_row: HBoxContainer
@onready var confirm_btn: Button
@onready var edit_btn: Button
@onready var back_btn: Button
@onready var pick_root: Control
@onready var edit_root: Control
var wait_root: Control = null  # 联机确认卡组后的等待页（隐藏配置界面）
var _edit_count_label: Label
var _edit_pool_box: VBoxContainer
var _edit_sel_box: VBoxContainer
var _edit_title: Label  # 编辑页标题
var _edit_ok_btn: Button  # 编辑页确认按钮（联机时文案改为"准备完成"）
var _edit_vs_info: Button  # 双方角色信息行（点击看技能）
var _pkg_buttons: Dictionary = {}  # 编辑页套餐按钮（pid -> Button）
var _flash_label: Label  # 临时提示（新提示覆盖旧的防残留）

func _ready():
	Style.scale_node_fonts(self)
	_build_layout()
	_apply_safe_area()  # 手机端刘海屏：选择页/编辑页整体右移避开
	BackHandler.scene_back = func() -> bool:
		if _page == "edit":
			_show_pick()
		else:
			_quit_to_menu()
		return true
	# 联机：双方卡组就绪后服务端发 game_starting → 直接进对战
	Network.game_starting.connect(_on_online_game_starting)
	# 联机：配置阶段对手断线 → 服务端发 game_over → 跳结算（对手逃跑获胜）
	Network.game_ended.connect(_on_game_ended)
	# 联机：自己断线 → 回主菜单（避免卡在配置页）
	Network.server_disconnected.connect(_on_server_disconnected)
	_show_pick()

func _exit_tree():
	BackHandler.scene_back = Callable()
	if Network.game_starting.is_connected(_on_online_game_starting):
		Network.game_starting.disconnect(_on_online_game_starting)
	if Network.game_ended.is_connected(_on_game_ended):
		Network.game_ended.disconnect(_on_game_ended)
	if Network.server_disconnected.is_connected(_on_server_disconnected):
		Network.server_disconnected.disconnect(_on_server_disconnected)

# 全面屏/刘海屏安全区：横屏刘海在左时，选择页/编辑页整体右移、返回按钮右移避开
func _apply_safe_area():
	# 桌面端无刘海：跳过安全区（部分环境缩放/多屏返回值异常会把 UI 整体右推并裁切右侧）
	if not (OS.has_feature("mobile") or OS.has_feature("web")):
		return
	var sa = DisplayServer.get_display_safe_area()
	var win = DisplayServer.window_get_size()
	var vp = get_viewport_rect().size
	if vp.x <= 0 or vp.y <= 0:
		return
	var sx = win.x / vp.x if vp.x > 0 else 1.0
	var left = sa.position.x / sx
	var right = (win.x - sa.end.x) / sx
	for r in [pick_root, edit_root]:
		if r != null:
			r.offset_left = left
			r.offset_right = -right
	back_btn.offset_left += left
	back_btn.offset_right += left

# 联机模式判断：本地时 LocalGame.game 非空；联机时 deck_config_data 由服务端下发
func _is_online() -> bool:
	return LocalGame.game == null and not Network.deck_config_data.is_empty()

# 联机：双方就绪后服务端开战，直接进对战场景
func _on_online_game_starting(data: Dictionary):
	Network.battle_state_cache = data.get("state", {})
	Network.deck_config_data = {}
	get_tree().change_scene_to_file("res://scenes/battle_scene.tscn")

# 联机：配置阶段对手断线 → 跳结算（胜利方结算）
func _on_game_ended(r: Dictionary):
	Network.last_game_result = r
	get_tree().change_scene_to_file("res://scenes/settlement.tscn")

# 联机：自己断线 → 回主菜单
func _on_server_disconnected():
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _build_layout():
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.12, 0.18, 1)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	back_btn = Button.new()
	back_btn.text = "← 返回主菜单"
	back_btn.anchor_left = 0.0
	back_btn.anchor_top = 1.0
	back_btn.offset_left = 24
	back_btn.offset_top = -120
	back_btn.offset_right = 264
	back_btn.offset_bottom = -24
	back_btn.add_theme_font_size_override("font_size", Style.fs(28))
	back_btn.pressed.connect(_on_back)
	# 联机：配置阶段不允许随意退出（对手断线由服务端结算），隐藏返回按钮
	back_btn.visible = not _is_online()
	# 注意：Godot 4 输入命中按场景树顺序（后添加的兄弟优先），z_index 只影响绘制。
	# back_btn 必须在 pick_root/edit_root 之后 add_child，否则全屏层拦截点击（按钮可见但按不动）
	back_btn.z_index = 10  # 绘制置于全屏页面之上
	# 选择页
	pick_root = Control.new()
	pick_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(pick_root)
	title = Label.new()
	title.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	title.offset_top = 30
	title.offset_bottom = 105
	title.offset_left = -450
	title.offset_right = 450
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", Style.fs(38))
	title.add_theme_color_override("font_color", Style.MODE_TITLE)
	pick_root.add_child(title)
	vs_label = Label.new()
	vs_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	vs_label.offset_top = 105
	vs_label.offset_bottom = 175
	vs_label.offset_left = -450
	vs_label.offset_right = 450
	vs_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vs_label.add_theme_font_size_override("font_size", Style.fs(28))
	vs_label.add_theme_color_override("font_color", Style.CONFIG_VALUE)
	pick_root.add_child(vs_label)
	var hint := Label.new()
	hint.text = "选择 1 / 2 · 对方不可见你的卡组构成"
	hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	hint.offset_top = 175
	hint.offset_bottom = 230
	hint.offset_left = -450
	hint.offset_right = 450
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", Style.fs(22))
	hint.add_theme_color_override("font_color", Style.MODE_DESC)
	pick_root.add_child(hint)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_top = 240
	scroll.offset_bottom = -260
	pick_root.add_child(scroll)
	options_box = VBoxContainer.new()
	options_box.add_theme_constant_override("separation", Style.fs(14))
	options_box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	options_box.custom_minimum_size = Vector2(760, 0)
	scroll.add_child(options_box)
	action_row = HBoxContainer.new()
	action_row.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	action_row.offset_top = -200
	action_row.offset_bottom = -90
	action_row.offset_left = -380
	action_row.offset_right = 380
	action_row.add_theme_constant_override("separation", Style.fs(24))
	action_row.alignment = BoxContainer.ALIGNMENT_CENTER
	pick_root.add_child(action_row)
	confirm_btn = Button.new()
	confirm_btn.text = "确认使用"
	confirm_btn.custom_minimum_size = Vector2(Style.fs(300), Style.fs(96))
	confirm_btn.add_theme_font_size_override("font_size", Style.fs(28))
	confirm_btn.pressed.connect(_on_confirm)
	action_row.add_child(confirm_btn)
	edit_btn = Button.new()
	edit_btn.text = "调整卡组"
	edit_btn.custom_minimum_size = Vector2(Style.fs(300), Style.fs(96))
	edit_btn.add_theme_font_size_override("font_size", Style.fs(28))
	edit_btn.pressed.connect(_on_edit)
	action_row.add_child(edit_btn)
	# 编辑页（内嵌，本局临时调整）
	edit_root = Control.new()
	edit_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	edit_root.visible = false
	add_child(edit_root)
	var et := Label.new()
	et.text = "调整卡组（本局临时，不保存到槽位）"
	et.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	et.offset_top = 30
	et.offset_bottom = 105
	et.offset_left = -450
	et.offset_right = 450
	et.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	et.add_theme_font_size_override("font_size", Style.fs(36))
	et.add_theme_color_override("font_color", Style.MODE_TITLE)
	edit_root.add_child(et)
	_edit_title = et
	# 双方角色信息行（编辑时可见自己与对手面板数值；角色名可点看技能）
	var vs_info := Button.new()
	vs_info.flat = true
	vs_info.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	vs_info.offset_top = 105
	vs_info.offset_bottom = 160
	vs_info.offset_left = -450
	vs_info.offset_right = 450
	vs_info.add_theme_font_size_override("font_size", Style.fs(24))
	vs_info.add_theme_color_override("font_color", Style.CONFIG_VALUE)
	vs_info.pressed.connect(_show_char_skills)
	edit_root.add_child(vs_info)
	_edit_vs_info = vs_info
	# 顶栏下移给角色信息行留空间
	var top := HBoxContainer.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	top.offset_top = 170
	top.offset_bottom = 246
	top.offset_left = -260
	top.offset_right = 260
	top.add_theme_constant_override("separation", Style.fs(20))
	top.alignment = BoxContainer.ALIGNMENT_CENTER
	edit_root.add_child(top)
	_edit_count_label = Label.new()
	_edit_count_label.custom_minimum_size = Vector2(Style.fs(220), Style.fs(64))
	_edit_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_edit_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_edit_count_label.add_theme_font_size_override("font_size", Style.fs(28))
	top.add_child(_edit_count_label)
	var ok_btn := Button.new()
	ok_btn.text = "确认（进入下一人）"
	ok_btn.custom_minimum_size = Vector2(Style.fs(320), Style.fs(64))
	ok_btn.add_theme_font_size_override("font_size", Style.fs(26))
	ok_btn.pressed.connect(_on_edit_confirm)
	top.add_child(ok_btn)
	_edit_ok_btn = ok_btn  # 联机时文案改为"准备完成"（见 _show_edit）
	var cancel_btn := Button.new()
	cancel_btn.text = "取消"
	cancel_btn.custom_minimum_size = Vector2(Style.fs(140), Style.fs(64))
	cancel_btn.add_theme_font_size_override("font_size", Style.fs(26))
	cancel_btn.pressed.connect(_show_pick)
	top.add_child(cancel_btn)
	# 套餐行：回复套餐选择（切换自动替换回复卡）
	var pkg_row := HBoxContainer.new()
	pkg_row.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	pkg_row.offset_top = 252
	pkg_row.offset_bottom = 322
	pkg_row.offset_left = -260
	pkg_row.offset_right = 260
	pkg_row.add_theme_constant_override("separation", Style.fs(12))
	pkg_row.alignment = BoxContainer.ALIGNMENT_CENTER
	edit_root.add_child(pkg_row)
	var pkg_lbl := Label.new()
	pkg_lbl.text = "套餐"
	pkg_lbl.add_theme_font_size_override("font_size", Style.fs(24))
	pkg_lbl.add_theme_color_override("font_color", Style.CONFIG_LABEL)
	pkg_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pkg_row.add_child(pkg_lbl)
	_pkg_buttons.clear()
	for pid in DeckData.HEAL_PACKAGES:
		var pb := Button.new()
		pb.text = str(DeckData.HEAL_PACKAGES[pid].name)
		pb.custom_minimum_size = Vector2(Style.fs(110), Style.fs(56))
		pb.add_theme_font_size_override("font_size", Style.fs(22))
		pb.pressed.connect(_on_package_switch.bind(pid))
		pkg_row.add_child(pb)
		_pkg_buttons[pid] = pb
	var mid := HBoxContainer.new()
	mid.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mid.offset_top = 330
	mid.offset_bottom = -100
	mid.add_theme_constant_override("separation", Style.fs(10))
	edit_root.add_child(mid)
	var pool_scroll := ScrollContainer.new()
	pool_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_child(pool_scroll)
	_edit_pool_box = VBoxContainer.new()
	_edit_pool_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit_pool_box.add_theme_constant_override("separation", Style.fs(6))
	pool_scroll.add_child(_edit_pool_box)
	var sel_scroll := ScrollContainer.new()
	sel_scroll.custom_minimum_size = Vector2(Style.fs(400), 0)
	sel_scroll.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	mid.add_child(sel_scroll)
	_edit_sel_box = VBoxContainer.new()
	_edit_sel_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit_sel_box.add_theme_constant_override("separation", Style.fs(6))
	sel_scroll.add_child(_edit_sel_box)
	# 等待进入对局页（联机确认卡组后显示）：隐藏配置界面，提示等待其他玩家
	wait_root = Control.new()
	wait_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wait_root.visible = false
	add_child(wait_root)
	var wt := Label.new()
	wt.text = "卡组已确认"
	wt.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	wt.offset_top = 220
	wt.offset_bottom = 320
	wt.offset_left = -450
	wt.offset_right = 450
	wt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wt.add_theme_font_size_override("font_size", Style.fs(44))
	wt.add_theme_color_override("font_color", Style.MODE_SELECTED)
	wait_root.add_child(wt)
	var wd := Label.new()
	wd.text = "等待其他玩家确认...\n全部就绪后自动进入对局"
	wd.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	wd.offset_top = 330
	wd.offset_bottom = 450
	wd.offset_left = -450
	wd.offset_right = 450
	wd.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wd.add_theme_font_size_override("font_size", Style.fs(28))
	wd.add_theme_color_override("font_color", Style.CONFIG_VALUE)
	wait_root.add_child(wd)
	# back_btn 最后添加：树序最靠后 → 输入命中优先于全屏 pick_root/edit_root
	add_child(back_btn)

func _on_back():
	if _page == "edit":
		_show_pick()
	else:
		_quit_to_menu()

# 页面切换时同步返回按钮文本（编辑页返回选择页，选择页返回主菜单）
func _show_pick_page_text(editing: bool):
	back_btn.text = "← 返回选择" if editing else "← 返回主菜单"

# 点击双方角色信息行：显示双方技能描述
func _show_char_skills():
	var me_cd: Dictionary = Config.CHARACTER_DB.get(_current_char_id(), {})
	var opp_cd: Dictionary = Config.CHARACTER_DB.get(_opponent_char_id(), {})
	_flash_status("%s：%s\n%s：%s" % [
		me_cd.get("name", "?"), me_cd.get("skill_desc", ""),
		opp_cd.get("name", "?"), opp_cd.get("skill_desc", "")])

func _quit_to_menu():
	if _is_online():
		Network.disconnect_from_server()
	else:
		LocalGame.disconnect_from_server()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _current_char_id() -> String:
	if _is_online():
		return str(Network.deck_config_data.get("chars", [])[Network.player_index])
	return str(LocalGame.bp_chars[_step])

func _opponent_char_id() -> String:
	if _is_online():
		return str(Network.deck_config_data.get("chars", [])[1 - Network.player_index])
	return str(LocalGame.bp_chars[1 - _step])

# ---------- 选择页 ----------
func _show_pick():
	_page = "pick"
	_show_pick_page_text(false)
	pick_root.visible = true
	edit_root.visible = false
	if wait_root != null:
		wait_root.visible = false
	if _is_online():
		_step = int(Network.player_index)  # 联机：只选自己的
		if Network.deck_config_data.get("chars", []).size() < 2:
			_quit_to_menu()
			return
	else:
		if LocalGame.bp_chars.size() < 2:
			_quit_to_menu()
			return
	var pname = "P1" if _step == 0 else "P2"
	title.text = "为 %s（%s）配置卡组" % [pname, Config.char_name(_current_char_id())]
	# 本地流程按钮文案：P1 确认进入下一人；P2（最后一人）确认直接进入对局
	if not _is_online():
		confirm_btn.text = "确认（进入对局）" if _step >= 1 else "确认（进入下一人）"
	# 常驻展示双方角色：玩家看清对手再决定卡组
	vs_label.text = "你：%s　vs　对手：%s" % [
		Config.char_name(_current_char_id()), Config.char_name(_opponent_char_id())]
	# 重建选项列表：remove_child 立即移出树，避免 queue_free 延迟删除
	# 导致 P2 选择页残留 P1 的按钮（重复选项/选中态错乱）
	for c in options_box.get_children():
		options_box.remove_child(c)
		c.queue_free()
	_sel_kind = ""
	var char_id = _current_char_id()
	# 预设槽位（有卡组才可选）
	for slot in range(1, DeckData.SLOTS_PER_CHAR + 1):
		var d = DeckData.get_deck(char_id, slot)
		var cards: Array = d.get("cards", [])
		var kind := "slot_%d" % slot
		var btn := _option_btn()
		if cards.is_empty():
			btn.text = "预设槽位 %d（未配置）" % slot
			btn.disabled = true
		else:
			var v = DeckData.validate_deck(cards, str(d.get("package", DeckData.DEFAULT_PACKAGE)))
			var tag = "（%d张）" % cards.size() if v.ok else "（%s）" % v.msg
			var nm = str(d.get("name", ""))
			btn.text = "预设槽位 %d · %s%s" % [slot, nm if nm != "" else "未命名", tag]
			btn.pressed.connect(_on_option.bind(kind))
		options_box.add_child(btn)
	# 默认 40 张卡组（初版配比，标准构成）
	var def := _option_btn()
	def.text = "默认卡组（40张 · 标准构成）"
	def.pressed.connect(_on_option.bind("default"))
	options_box.add_child(def)
	_refresh_action()

func _option_btn() -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(760, Style.fs(96))
	b.add_theme_font_size_override("font_size", Style.fs(28))
	b.add_theme_color_override("font_color", Color(0.92, 0.94, 0.97))
	b.add_theme_constant_override("outline_size", 0)
	return b

func _on_option(kind: String):
	_sel_kind = kind
	# 记录选中卡组的套餐（预设槽位读存档，默认卡组用 B）
	if kind == "default":
		_package_id = DeckData.DEFAULT_PACKAGE
	else:
		var slot = int(kind.trim_prefix("slot_"))
		_package_id = str(DeckData.get_deck(_current_char_id(), slot).get("package", DeckData.DEFAULT_PACKAGE))
	# 选中态：金边框高亮
	var idx := 0
	for c in options_box.get_children():
		if not c is Button:
			continue
		var sel = (kind == ("slot_%d" % (idx + 1))) or (kind == "default" and idx >= DeckData.SLOTS_PER_CHAR)
		idx += 1
		_apply_option_style(c, sel)
	_refresh_action()

func _apply_option_style(btn: Button, selected: bool):
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(12)
	sb.bg_color = Color(0.13, 0.16, 0.22)
	if selected:
		sb.border_color = Style.MODE_SELECTED
		sb.set_border_width_all(4)
	else:
		sb.border_color = Color(0.30, 0.32, 0.40)
		sb.set_border_width_all(2)
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", sb)
	btn.add_theme_stylebox_override("pressed", sb)
	btn.add_theme_stylebox_override("focus", sb)

func _refresh_action():
	var has_sel = _sel_kind != ""
	confirm_btn.disabled = not has_sel
	edit_btn.disabled = not has_sel

func _selected_cards() -> Array:
	if _sel_kind == "default":
		return DeckData.default_deck()
	var slot = int(_sel_kind.trim_prefix("slot_"))
	return DeckData.get_deck(_current_char_id(), slot).get("cards", []).duplicate()

# 当前选中卡组的武器幻化池（默认卡组/槽位存档/编辑中草稿统一出口）
func _selected_weapon_pool() -> Dictionary:
	if _sel_kind == "default":
		return DeckData.default_weapon_pool()
	var slot = int(_sel_kind.trim_prefix("slot_"))
	return DeckData.normalize_weapon_pool(DeckData.get_deck(_current_char_id(), slot).get("weapon_pool", {}))

func _on_confirm():
	if _sel_kind == "":
		return
	_decks[_step] = _selected_cards()
	_weapon_pools[_step] = _selected_weapon_pool()
	_next_step()

func _on_edit():
	if _sel_kind == "":
		return
	_draft = _selected_cards()
	_draft_weapon_pool = _selected_weapon_pool()
	_show_edit()

func _next_step():
	if _is_online():
		# 联机：上报自己的卡组，进入等待页（隐藏配置界面，等对手就绪后服务端发 game_starting）
		Network.send_deck_ready(_decks[_step], _package_id, _weapon_pools[_step])
		pick_root.visible = false
		edit_root.visible = false
		wait_root.visible = true
		_page = "wait"
		_show_pick_page_text(false)
		return
	if _step == 0:
		_step = 1
		_show_pick()
	else:
		_start_battle()

# ---------- 编辑页（本局临时调整） ----------
func _show_edit():
	_page = "edit"
	_show_pick_page_text(true)
	pick_root.visible = false
	edit_root.visible = true
	if wait_root != null:
		wait_root.visible = false
	# 双方角色信息行（编辑时可见自己与对手数值；点此看技能）
	var me_cd: Dictionary = Config.CHARACTER_DB.get(_current_char_id(), {})
	var opp_cd: Dictionary = Config.CHARACTER_DB.get(_opponent_char_id(), {})
	_edit_vs_info.text = "你：%s 近%d远%d魔%d HP%d　vs　对手：%s 近%d远%d魔%d HP%d　（点此看技能）" % [
		me_cd.get("name", "?"), me_cd.get("near", 0), me_cd.get("range", 0), me_cd.get("magic", 0), me_cd.get("hp", 0),
		opp_cd.get("name", "?"), opp_cd.get("near", 0), opp_cd.get("range", 0), opp_cd.get("magic", 0), opp_cd.get("hp", 0)]
	# 联机只配自己的卡组：确认按钮文案改为"准备完成"，不再提示"下一人"；
	# 本地流程：P2（最后一人）确认直接进入对局
	if _is_online():
		_edit_ok_btn.text = "准备完成（等待对手）"
	else:
		_edit_ok_btn.text = "确认（进入对局）" if _step >= 1 else "确认（进入下一人）"
	# 重建卡池（remove_child 立即移出树，避免 queue_free 延迟删除导致
	# 第二次进入编辑页时 _refresh_edit 按索引取到旧行、数量显示到已销毁节点上）
	for c in _edit_pool_box.get_children():
		_edit_pool_box.remove_child(c)
		c.queue_free()
	for grp in GROUP_ORDER:
		if grp == "equipment":
			# 装备池标题行：标题 + 「武器池编辑」按钮（HBox 仍占一个子节点，child_idx 索引兼容）
			var hrow := HBoxContainer.new()
			hrow.add_theme_constant_override("separation", Style.fs(16))
			_edit_pool_box.add_child(hrow)
			var gtitle := Label.new()
			gtitle.text = DeckData.group_name(grp)
			gtitle.add_theme_font_size_override("font_size", Style.fs(24))
			gtitle.add_theme_color_override("font_color", Style.MODE_TITLE)
			hrow.add_child(gtitle)
			var wp_btn := Button.new()
			wp_btn.text = "🔧 武器池编辑"
			wp_btn.add_theme_font_size_override("font_size", Style.fs(22))
			wp_btn.add_theme_color_override("font_color", Style.CONFIG_VALUE)
			wp_btn.pressed.connect(_open_weapon_pool_editor)
			hrow.add_child(wp_btn)
		else:
			var gtitle := Label.new()
			gtitle.text = DeckData.group_name(grp)
			gtitle.add_theme_font_size_override("font_size", Style.fs(24))
			gtitle.add_theme_color_override("font_color", Style.MODE_TITLE)
			_edit_pool_box.add_child(gtitle)
		for tid in DeckData.pool_ids():
			if DeckData.card_group(tid) != grp:
				continue
			var row := HBoxContainer.new()
			row.custom_minimum_size = Vector2(0, Style.fs(52))
			row.add_theme_constant_override("separation", Style.fs(8))
			_edit_pool_box.add_child(row)
			var name_l := Label.new()
			name_l.text = DeckData.display_name(tid)
			name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			name_l.add_theme_font_size_override("font_size", Style.fs(24))
			name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			row.add_child(name_l)
			var cnt_l := Label.new()
			cnt_l.custom_minimum_size = Vector2(Style.fs(150), 0)
			cnt_l.add_theme_font_size_override("font_size", Style.fs(22))
			cnt_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			row.add_child(cnt_l)
			var minus := Button.new()
			minus.text = "−"
			minus.custom_minimum_size = Vector2(Style.fs(56), Style.fs(44))
			minus.add_theme_font_size_override("font_size", Style.fs(24))
			minus.mouse_filter = Control.MOUSE_FILTER_PASS  # 放行拖动给卡池滚动
			minus.pressed.connect(_on_remove.bind(tid))
			row.add_child(minus)
			var plus := Button.new()
			plus.text = "+"
			plus.custom_minimum_size = Vector2(Style.fs(56), Style.fs(44))
			plus.add_theme_font_size_override("font_size", Style.fs(24))
			plus.mouse_filter = Control.MOUSE_FILTER_PASS  # 放行拖动给卡池滚动
			plus.pressed.connect(_on_add.bind(tid))
			row.add_child(plus)
	_refresh_edit()

func _refresh_edit():
	if _edit_count_label == null:
		return
	_edit_count_label.text = "%d / %d" % [_draft.size(), DeckData.DECK_SIZE]
	_edit_count_label.add_theme_color_override("font_color",
		Color(0.9, 0.7, 0.4) if _draft.size() >= DeckData.DECK_SIZE else Color(1, 0.9, 0.5))
	# 套餐按钮选中态
	for pid in _pkg_buttons:
		var b: Button = _pkg_buttons[pid]
		var sel = (pid == _package_id)
		b.text = ("▶ " if sel else "") + str(DeckData.HEAL_PACKAGES[pid].name)
		b.add_theme_color_override("font_color", Style.MODE_SELECTED if sel else Color(0.85, 0.87, 0.92))
	var counts := {}
	for tid in _draft:
		counts[tid] = int(counts.get(tid, 0)) + 1
	var child_idx := 0
	for grp in GROUP_ORDER:
		child_idx += 1  # 组标题
		for tid in DeckData.pool_ids():
			if DeckData.card_group(tid) != grp:
				continue
			var row = _edit_pool_box.get_child(child_idx)
			child_idx += 1
			var n = int(counts.get(tid, 0))
			var lim = DeckData.card_limit(tid, _package_id)
			var is_heal = tid in ["heal_3", "heal_5"]
			var cnt_l: Label = row.get_child(1)
			if is_heal:
				cnt_l.text = "套餐固定 %d 张" % n
				cnt_l.add_theme_color_override("font_color", Style.MODE_SELECTED)
			else:
				cnt_l.text = "已有 %d / 上限 %d" % [n, lim]
				cnt_l.add_theme_color_override("font_color", Color(0.9, 0.7, 0.4) if n >= lim else Color(0.6, 0.65, 0.72))
			var minus: Button = row.get_child(2)
			minus.disabled = is_heal or n <= 0
			var plus: Button = row.get_child(3)
			plus.disabled = is_heal or n >= lim or _draft.size() >= DeckData.DECK_SIZE
	# 已选列表重建（remove_child 立即移出树，防旧行残留）
	for c in _edit_sel_box.get_children():
		_edit_sel_box.remove_child(c)
		c.queue_free()
	for tid in _draft:
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(0, Style.fs(48))
		row.add_theme_constant_override("separation", Style.fs(8))
		_edit_sel_box.add_child(row)
		var l := Label.new()
		l.text = DeckData.display_name(tid)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.add_theme_font_size_override("font_size", Style.fs(22))
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(l)
		var rm := Button.new()
		rm.text = "−"
		rm.custom_minimum_size = Vector2(Style.fs(52), Style.fs(40))
		rm.add_theme_font_size_override("font_size", Style.fs(22))
		rm.mouse_filter = Control.MOUSE_FILTER_PASS  # 放行拖动给已选列表滚动
		rm.disabled = tid in ["heal_3", "heal_5"]
		rm.pressed.connect(_on_remove.bind(tid))
		row.add_child(rm)

func _on_add(tid: String):
	var n := 0
	for c in _draft:
		if c == tid:
			n += 1
	if n >= DeckData.card_limit(tid, _package_id):
		return
	# 大池上限检查
	var cat = DeckData.category_of(tid)
	var summary = DeckData.summarize(_draft)
	if int(summary.get(cat, 0)) >= DeckData.category_max(cat):
		return
	if _draft.size() >= DeckData.DECK_SIZE:
		return
	_draft.append(tid)
	_refresh_edit()

func _on_remove(tid: String):
	var idx = _draft.find(tid)
	if idx >= 0:
		_draft.remove_at(idx)
		_refresh_edit()

# 套餐切换：替换回复卡组合，清空数值卡（按新配额重选）
func _on_package_switch(pid: String):
	if pid == _package_id:
		return
	_package_id = pid
	var pkg: Dictionary = DeckData.HEAL_PACKAGES[pid]
	var new_draft: Array = []
	for tid in _draft:
		if tid in ["heal_3", "heal_5"] or tid in DeckData.BUF_CARDS:
			continue
		new_draft.append(tid)
	for tid in pkg.heal:
		for _i in range(int(pkg.heal[tid])):
			new_draft.append(tid)
	_draft = new_draft
	_flash_status("%s：%s" % [pkg.name, pkg.desc])
	_refresh_edit()

func _on_edit_confirm():
	var v = DeckData.validate_deck(_draft, _package_id)
	if not v.ok:
		_flash_status(v.msg)
		return
	_decks[_step] = _draft.duplicate()
	_weapon_pools[_step] = _draft_weapon_pool.duplicate(true)
	_next_step()

func _flash_status(text: String):
	# 覆盖旧提示，避免快速连续触发时多个 Label 叠加残留
	if _flash_label != null and is_instance_valid(_flash_label):
		_flash_label.queue_free()
	var l := Label.new()
	l.text = text
	l.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	l.offset_top = -80
	l.offset_bottom = -20
	l.offset_left = -400
	l.offset_right = 400
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", Style.fs(24))
	l.add_theme_color_override("font_color", Style.ERROR_RED)
	edit_root.add_child(l)
	_flash_label = l
	get_tree().create_timer(1.5).timeout.connect(l.queue_free)

# 打开武器幻化池编辑器（覆盖层组件；返回时校验恰好 4 把，见 weapon_pool_editor.gd）
func _open_weapon_pool_editor():
	var ed = load("res://scripts/ui/components/weapon_pool_editor.gd").new()
	ed.z_index = 15
	add_child(ed)
	ed.setup(_draft_weapon_pool, func(pool: Dictionary):
		_draft_weapon_pool = pool.duplicate(true)
	)

# ---------- 开战 ----------
func _start_battle():
	var chars: Array = LocalGame.bp_chars.duplicate()
	var bf: int = LocalGame.bp_first
	var decks: Array = [_decks[0], _decks[1]]
	var pools: Array = [_weapon_pools[0], _weapon_pools[1]]
	LocalGame.deck_mode = false
	LocalGame.bp_chars = []
	LocalGame.bp_first = -1
	LocalGame.start_local_game(str(chars[0]), str(chars[1]), bf, decks, true, pools)
	get_tree().change_scene_to_file("res://scenes/battle_scene.tscn")
