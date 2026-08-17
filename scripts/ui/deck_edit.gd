# deck_edit.gd — 卡组管理界面（主菜单「卡组管理」入口）
# 三级页面：角色列表 → 槽位列表（每角色 3 套，可命名） → 卡组编辑（卡池加减卡）。
# 编辑规则（DeckData 方案 B 大池设计）：
#   40 张；攻击池17/战术池14/回复数值池6/装备池5；强化攻击子上限5、武器3、防具2；
#   回复套餐 A/B/C（回复组合固定，数值加成配额随套餐）；单卡上限防极端。
# 存档：user://decks.json（DeckData.set_deck 校验通过才写入，含套餐字段）。
extends Control

const Style = preload("res://scripts/theme/style_const.gd")
const DeckData = preload("res://scripts/data/deck_data.gd")

const GROUP_ORDER = ["attack", "tactics", "sustain", "equipment"]

var _char_id: String = ""
var _slot: int = 0              # 0 = 未进入编辑
var _draft: Array = []          # 编辑中的卡组（type_id 列表）
var _draft_weapon_pool: Dictionary = {}  # 编辑中的武器幻化池
var _draft_name: String = ""
var _package_id: String = DeckData.DEFAULT_PACKAGE  # 回复套餐 A/B/C
# 编辑页节点引用（避免脆弱的 get_child 索引）
var _edit_count_label: Label
var _edit_pool_box: VBoxContainer
var _edit_sel_box: VBoxContainer
var _budget_label: Label
var _pkg_buttons: Dictionary = {}  # 套餐按钮（pid -> Button），选中态刷新用

@onready var root: Control
var _body: Control              # 当前页面容器（每次切换重建）
var _status: Label

func _ready():
	Style.scale_node_fonts(self)
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.12, 0.18, 1)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_status = Label.new()
	_status.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_status.offset_top = -80
	_status.offset_bottom = -20
	_status.offset_left = -400
	_status.offset_right = 400
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", Style.fs(24))
	add_child(_status)
	BackHandler.scene_back = func() -> bool:
		_on_back()
		return true
	_show_roles()

func _exit_tree():
	BackHandler.scene_back = Callable()

func _on_back():
	if _char_id != "" and _slot > 0:
		_slot = 0
		_show_slots()
	elif _char_id != "":
		_char_id = ""
		_show_roles()
	else:
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _flash(text: String, color: Color = Style.MODE_FEATURE):
	_status.text = text
	_status.add_theme_color_override("font_color", color)

# 全面屏/刘海屏安全区：横屏刘海在左时，页面内容整体右移避开（卡池/列表贴左会被挡）
func _apply_safe_area():
	if _body == null:
		return
	var sa = DisplayServer.get_display_safe_area()
	var win = DisplayServer.window_get_size()
	var vp = get_viewport_rect().size
	if vp.x <= 0 or vp.y <= 0:
		return
	var sx = win.x / vp.x if vp.x > 0 else 1.0
	var left = sa.position.x / sx
	_body.offset_left = left
	_body.offset_right = left

func _clear_body():
	if _body != null and is_instance_valid(_body):
		_body.queue_free()

func _add_page(title_text: String, back_text: String) -> Control:
	_clear_body()
	_status.text = ""  # 切页清空旧提示，避免残留
	var page := Control.new()
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(page)
	_body = page
	_apply_safe_area()
	var t := Label.new()
	t.text = title_text
	t.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	t.offset_top = 24
	t.offset_bottom = 96
	t.offset_left = -400
	t.offset_right = 400
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", Style.fs(38))
	t.add_theme_color_override("font_color", Style.MODE_TITLE)
	page.add_child(t)
	var back := Button.new()
	back.text = back_text
	back.anchor_left = 0.0
	back.anchor_top = 1.0
	back.offset_left = 24
	back.offset_top = -120
	back.offset_right = 264
	back.offset_bottom = -24
	back.add_theme_font_size_override("font_size", Style.fs(28))
	back.pressed.connect(_on_back)
	page.add_child(back)
	return page

# ---------- 页面 1：角色列表 ----------
func _show_roles():
	_char_id = ""
	_slot = 0
	var page = _add_page("卡组管理 · 选择角色", "← 返回主菜单")
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", Style.fs(18))
	grid.add_theme_constant_override("v_separation", Style.fs(18))
	grid.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	grid.offset_left = -540
	grid.offset_right = 540
	grid.offset_top = -420
	grid.offset_bottom = 300
	page.add_child(grid)
	for cid in Config.CHARACTER_IDS:
		var entry = DeckData.get_char_decks(cid)
		var count := 0
		for s in entry:
			if not entry[s].get("cards", []).is_empty():
				count += 1
		var b := Button.new()
		b.text = "%s（%d套）" % [Config.char_name(cid), count]
		b.custom_minimum_size = Vector2(Style.fs(330), Style.fs(110))
		b.add_theme_font_size_override("font_size", Style.fs(26))
		b.pressed.connect(_on_role_pick.bind(cid))
		grid.add_child(b)

func _on_role_pick(cid: String):
	_char_id = cid
	_show_slots()

# ---------- 页面 2：槽位列表 ----------
func _show_slots():
	_slot = 0
	var page = _add_page("卡组管理 · %s" % Config.char_name(_char_id), "← 选择角色")
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", Style.fs(16))
	vb.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vb.offset_left = -420
	vb.offset_right = 420
	vb.offset_top = -300
	vb.offset_bottom = 280
	page.add_child(vb)
	var hint := Label.new()
	hint.text = "每角色可预设 %d 套卡组（各 %d 张），开局配置环节从中选择" % [DeckData.SLOTS_PER_CHAR, DeckData.DECK_SIZE]
	hint.add_theme_font_size_override("font_size", Style.fs(22))
	hint.add_theme_color_override("font_color", Style.MODE_DESC)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(hint)
	for slot in range(1, DeckData.SLOTS_PER_CHAR + 1):
		var d = DeckData.get_deck(_char_id, slot)
		var cards: Array = d.get("cards", [])
		var slot_name = str(d.get("name", ""))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Style.fs(12))
		row.custom_minimum_size = Vector2(0, Style.fs(100))
		vb.add_child(row)
		var label := Label.new()
		if cards.is_empty():
			label.text = "槽位 %d · 未配置" % slot
			label.add_theme_color_override("font_color", Color(0.55, 0.58, 0.64))
		else:
			label.text = "槽位 %d · %s（%d张）" % [slot, slot_name if slot_name != "" else "未命名", cards.size()]
			label.add_theme_color_override("font_color", Style.CONFIG_VALUE)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_font_size_override("font_size", Style.fs(26))
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(label)
		var edit := Button.new()
		edit.text = "编辑"
		edit.custom_minimum_size = Vector2(Style.fs(140), Style.fs(72))
		edit.add_theme_font_size_override("font_size", Style.fs(24))
		edit.pressed.connect(_on_edit_slot.bind(slot))
		row.add_child(edit)
		var clear := Button.new()
		clear.text = "清空"
		clear.custom_minimum_size = Vector2(Style.fs(140), Style.fs(72))
		clear.add_theme_font_size_override("font_size", Style.fs(24))
		clear.pressed.connect(_on_clear_slot.bind(slot))
		row.add_child(clear)

func _on_edit_slot(slot: int):
	var d = DeckData.get_deck(_char_id, slot)
	_draft = d.get("cards", []).duplicate()
	_draft_weapon_pool = DeckData.normalize_weapon_pool(d.get("weapon_pool", {}))
	_draft_name = str(d.get("name", ""))
	_package_id = str(d.get("package", DeckData.DEFAULT_PACKAGE))
	# 空卡组：自动填充套餐回复卡（回复卡 +/- 禁用，不自动填充则永远凑不齐套餐组合）
	if _draft.is_empty():
		var pkg: Dictionary = DeckData.HEAL_PACKAGES.get(_package_id, DeckData.HEAL_PACKAGES[DeckData.DEFAULT_PACKAGE])
		for tid in pkg.heal:
			for _i in range(int(pkg.heal[tid])):
				_draft.append(tid)
	_slot = slot
	_show_edit()

func _on_clear_slot(slot: int):
	var all = DeckData.load_all()
	if all.has(_char_id):
		all[_char_id][str(slot)] = {"name": "", "package": DeckData.DEFAULT_PACKAGE, "cards": []}
		DeckData.save_all(all)
	_flash("槽位 %d 已清空" % slot)
	_show_slots()

# ---------- 页面 3：卡组编辑 ----------
func _show_edit():
	var page = _add_page("编辑卡组 · %s（槽位%d）" % [Config.char_name(_char_id), _slot], "← 返回槽位")
	# 顶栏：命名 + 张数 + 保存
	var top := HBoxContainer.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	top.offset_top = 100
	top.offset_bottom = 176
	top.offset_left = -480
	top.offset_right = 480
	top.add_theme_constant_override("separation", Style.fs(14))
	page.add_child(top)
	var name_input := LineEdit.new()
	name_input.text = _draft_name
	name_input.placeholder_text = "卡组名称"
	name_input.custom_minimum_size = Vector2(Style.fs(320), Style.fs(64))
	name_input.add_theme_font_size_override("font_size", Style.fs(26))
	name_input.text_changed.connect(func(t: String): _draft_name = t)
	top.add_child(name_input)
	var count_label := Label.new()
	count_label.custom_minimum_size = Vector2(Style.fs(180), Style.fs(64))
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count_label.add_theme_font_size_override("font_size", Style.fs(26))
	top.add_child(count_label)
	var save := Button.new()
	save.text = "保存"
	save.custom_minimum_size = Vector2(Style.fs(140), Style.fs(64))
	save.add_theme_font_size_override("font_size", Style.fs(26))
	save.pressed.connect(_on_save)
	top.add_child(save)
	# 第二行：回复套餐选择 + 大池预算
	var top2 := HBoxContainer.new()
	top2.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	top2.offset_top = 182
	top2.offset_bottom = 258
	top2.offset_left = -480
	top2.offset_right = 480
	top2.add_theme_constant_override("separation", Style.fs(12))
	page.add_child(top2)
	var pkg_lbl := Label.new()
	pkg_lbl.text = "回复套餐"
	pkg_lbl.add_theme_font_size_override("font_size", Style.fs(24))
	pkg_lbl.add_theme_color_override("font_color", Style.CONFIG_LABEL)
	pkg_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top2.add_child(pkg_lbl)
	_pkg_buttons.clear()
	for pid in DeckData.HEAL_PACKAGES:
		var pb := Button.new()
		pb.text = str(DeckData.HEAL_PACKAGES[pid].name)
		pb.custom_minimum_size = Vector2(Style.fs(120), Style.fs(60))
		pb.add_theme_font_size_override("font_size", Style.fs(22))
		pb.pressed.connect(_on_package_switch.bind(pid))
		top2.add_child(pb)
		_pkg_buttons[pid] = pb
	var budget := Label.new()
	budget.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	budget.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	budget.add_theme_font_size_override("font_size", Style.fs(22))
	budget.add_theme_color_override("font_color", Style.MODE_DESC)
	top2.add_child(budget)
	_budget_label = budget
	# 中部：左卡池 / 右已选（上下分栏更适合手机）
	var mid := HBoxContainer.new()
	mid.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mid.offset_top = 270
	mid.offset_bottom = -120
	mid.add_theme_constant_override("separation", Style.fs(10))
	page.add_child(mid)
	var pool_scroll := ScrollContainer.new()
	pool_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_child(pool_scroll)
	var pool_box := VBoxContainer.new()
	pool_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pool_box.add_theme_constant_override("separation", Style.fs(6))
	pool_scroll.add_child(pool_box)
	var sel_scroll := ScrollContainer.new()
	sel_scroll.custom_minimum_size = Vector2(Style.fs(400), 0)
	sel_scroll.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	mid.add_child(sel_scroll)
	var sel_box := VBoxContainer.new()
	sel_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sel_box.add_theme_constant_override("separation", Style.fs(6))
	sel_scroll.add_child(sel_box)
	# 卡池分组渲染（数量列由 _refresh_edit 更新）
	for grp in GROUP_ORDER:
		if grp == "equipment":
			# 装备池标题行：标题 + 「武器池编辑」按钮（HBox 仍占一个子节点，索引兼容）
			var hrow := HBoxContainer.new()
			hrow.add_theme_constant_override("separation", Style.fs(16))
			pool_box.add_child(hrow)
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
			pool_box.add_child(gtitle)
		for tid in DeckData.pool_ids():
			if DeckData.card_group(tid) != grp:
				continue
			var row := HBoxContainer.new()
			row.custom_minimum_size = Vector2(0, Style.fs(52))
			row.add_theme_constant_override("separation", Style.fs(8))
			pool_box.add_child(row)
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
	# 已选卡组渲染（函数尾部更新）
	_edit_count_label = count_label
	_edit_pool_box = pool_box
	_edit_sel_box = sel_box
	_refresh_edit(count_label, pool_box, sel_box)

func _counts() -> Dictionary:
	var c := {}
	for tid in _draft:
		c[tid] = int(c.get(tid, 0)) + 1
	return c

func _refresh_edit(count_label: Label, pool_box: VBoxContainer, sel_box: VBoxContainer):
	count_label.text = "%d / %d" % [_draft.size(), DeckData.DECK_SIZE]
	# 大池预算显示
	var summary = DeckData.summarize(_draft)
	var parts: Array = []
	for cat in GROUP_ORDER:
		var used = int(summary.get(cat, 0))
		var mx = DeckData.category_max(cat)
		parts.append("%s %d/%d" % [DeckData.category_name(cat), used, mx])
	if _budget_label != null:
		_budget_label.text = " ｜ ".join(parts)
	# 套餐按钮选中态
	for pid in _pkg_buttons:
		var b: Button = _pkg_buttons[pid]
		var sel = (pid == _package_id)
		b.add_theme_color_override("font_color", Style.MODE_SELECTED if sel else Color(0.85, 0.87, 0.92))
		b.text = ("▶ " if sel else "") + str(DeckData.HEAL_PACKAGES[pid].name)
	# 卡池数量列 + +/- 可用性（与 _show_edit 构建顺序一致：每组一个标题 + 若干行）
	var counts := _counts()
	var child_idx := 0
	for grp in GROUP_ORDER:
		child_idx += 1  # 跳过组标题
		for tid in DeckData.pool_ids():
			if DeckData.card_group(tid) != grp:
				continue
			var row = pool_box.get_child(child_idx)
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
			minus.disabled = is_heal or n <= 0 or _draft.is_empty()
			var plus: Button = row.get_child(3)
			plus.disabled = is_heal or n >= lim or _draft.size() >= DeckData.DECK_SIZE
	# 已选列表重建
	for c in sel_box.get_children():
		c.queue_free()
	for tid in _draft:
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(0, Style.fs(48))
		row.add_theme_constant_override("separation", Style.fs(8))
		sel_box.add_child(row)
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

# 套餐切换：替换卡组里的回复卡（数值卡一并清空，由玩家按新配额重选）
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
	_flash("%s：%s" % [pkg.name, pkg.desc], Style.MODE_FEATURE)
	_refresh_edit_keep()

func _on_add(tid: String):
	var n := 0
	for c in _draft:
		if c == tid: n += 1
	if n >= DeckData.card_limit(tid, _package_id):
		_flash("%s 已达上限 %d 张" % [DeckData.card_name(tid), n], Style.ERROR_RED)
		return
	# 大池上限检查
	var cat = DeckData.category_of(tid)
	var summary = DeckData.summarize(_draft)
	if int(summary.get(cat, 0)) >= DeckData.category_max(cat):
		_flash("%s已满（%d）" % [DeckData.category_name(cat), DeckData.category_max(cat)], Style.ERROR_RED)
		return
	if _draft.size() >= DeckData.DECK_SIZE:
		_flash("卡组已满 %d 张" % DeckData.DECK_SIZE, Style.ERROR_RED)
		return
	_draft.append(tid)
	_refresh_edit_keep()

func _on_remove(tid: String):
	var idx = _draft.find(tid)
	if idx >= 0:
		_draft.remove_at(idx)
		_refresh_edit_keep()

# 编辑页刷新：重建已选列表 + 更新计数（无需重建卡池滚动位置）
func _refresh_edit_keep():
	if _edit_count_label != null and _edit_pool_box != null and _edit_sel_box != null:
		_refresh_edit(_edit_count_label, _edit_pool_box, _edit_sel_box)

func _on_save():
	if _draft.is_empty():
		_flash("卡组为空，无法保存", Style.ERROR_RED)
		return
	var v = DeckData.validate_deck(_draft, _package_id)
	if not v.ok:
		_flash(v.msg, Style.ERROR_RED)
		return
	var r = DeckData.set_deck(_char_id, _slot, _draft_name.strip_edges(), _package_id, _draft, _draft_weapon_pool)
	if r.ok:
		_flash("已保存", Style.ME_GREEN)
		_show_slots()
	else:
		_flash(r.msg, Style.ERROR_RED)

# 打开武器幻化池编辑器（覆盖层组件；返回时校验恰好 4 把，见 weapon_pool_editor.gd）
func _open_weapon_pool_editor():
	var ed = load("res://scripts/ui/components/weapon_pool_editor.gd").new()
	ed.z_index = 15
	add_child(ed)
	ed.setup(_draft_weapon_pool, func(pool: Dictionary):
		_draft_weapon_pool = pool.duplicate(true)
	)
