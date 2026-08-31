# info_panel.gd — 对战信息面板（己方/对手共用）
# 结构：头部行(名字+HP数值+HP条) / 属性行(面板+AP+坐标+装备) / 状态行(状态槽 FlowContainer)
# 状态槽固定尺寸 + 超量合并，buff 再多也不会撑爆信息栏。
# ---- 后期加美术资源：只改 _STATUS_ICONS 注册表 ----
# 注册表 icon 值有两种：
#   · "res://art/xxx.png" → status_slot 自动用贴图渲染
#   · 其他字符串（当前是单字占位，如 "灼"）→ 渲染为 Label
# 角色头像/武器/防具图标同理，后续在对应行加图标位 + 注册表即可，UI 结构零改动。
extends PanelContainer

const Style = preload("res://scripts/theme/style_const.gd")
const StatusSlot = preload("res://scripts/ui/components/status_slot.gd")

signal status_clicked(text: String)

var _name_label: Button
var _hp_num: Label
var _hp_bar: ProgressBar
var _attr_label: Label
var _deck_label: Label
var _equip_label: Button
var _status_row: FlowContainer
var _skill_desc: String = ""
var _equip_detail: String = ""

# 状态图标注册表：icon(文字占位或贴图路径) + 强调色 + 中文名
const _STATUS_ICONS := {
	"burn": {"icon": "灼", "accent": Color(1.0, 0.45, 0.35), "name": "灼烧"},
	"poison": {"icon": "毒", "accent": Color(0.45, 0.9, 0.3), "name": "中毒"},
	"freeze": {"icon": "冻", "accent": Color(0.55, 0.8, 1.0), "name": "冻结"},
	"near_up": {"icon": "狂", "accent": Color(1.0, 0.65, 0.25), "name": "近战强化"},
	"calibration": {"icon": "准", "accent": Color(0.4, 0.85, 0.9), "name": "校准"},
	"attack_up": {"icon": "强", "accent": Color(1.0, 0.65, 0.25), "name": "攻击强化"},
	"attack_down": {"icon": "弱", "accent": Color(0.75, 0.75, 1.0), "name": "攻击弱化"},
	"mage_empower": {"icon": "法", "accent": Color(0.75, 0.5, 1.0), "name": "魔法强化"},
	"mage_phantom": {"icon": "幻", "accent": Color(0.75, 0.5, 1.0), "name": "幻影"},
	"ap_attack_down": {"icon": "滞", "accent": Color(0.7, 0.6, 1.0), "name": "攻击行动点-1"},
	"no_move": {"icon": "移", "accent": Color(0.85, 0.85, 0.85), "name": "无法移动"},
	"paladin_counter": {"icon": "反", "accent": Color(0.9, 0.8, 0.4), "name": "反击"},
	"tracker_chase": {"icon": "追", "accent": Color(0.6, 0.85, 0.5), "name": "追击"},
	"神隐": {"icon": "隐", "accent": Color(0.6, 0.5, 0.9), "name": "神隐"},
}
# 状态槽一行上限（面板宽度约 10 个），超出合并为 "+N" 槽，详情放 tooltip
const _MAX_STATUS_SLOTS := 11

# 内容高度（battle_ui 用它设面板高度）：
# 基础行（名字/属性/牌堆/装备）是单行 Label/Button，get_combined_minimum_size 准确；
# 状态行是 FlowContainer，它的 get_combined_minimum_size 只算单行（46px）——槽位换行时
# 严重低估 50~100px → 面板被内容强制撑开、底部 buff 行冲出屏幕裁切，必须按行数估算。
# 间距按实际可见行数算（VBox separation 4），最后加 StyleBox 内边距 16（8×2）。
# pw = 面板宽度（battle_ui 传入，决定状态槽每行几个）；不传时按最窄面板 460 兜底。
func content_height(pw: float = 0.0) -> float:
	var h := 0.0
	var rows := 0
	if _name_label != null:
		h += _name_label.get_combined_minimum_size().y
		rows += 1
	if _attr_label != null:
		h += _attr_label.get_combined_minimum_size().y
		rows += 1
	if _deck_label != null:
		h += _deck_label.get_combined_minimum_size().y
		rows += 1
	if _equip_label != null and _equip_label.visible:
		h += _equip_label.get_combined_minimum_size().y
		rows += 1
	if _status_row != null:
		h += _status_rows_height(pw)
		rows += 1
	if rows > 1:
		h += 4.0 * (rows - 1)  # VBox separation
	h += 16.0  # StyleBox 内边距 8×2
	return h

# 状态行实际高度：FlowContainer 换行后 get_combined_minimum_size 只给单行（46px），
# 槽位一多就低估。按「槽数 ÷ 每行槽数」估行数：槽最小 46 宽 + 间距 4 = 50，值文本
# （"-3·2回" 等）会把槽加宽到 ~60，取 58 保守估计（行数偏多 → 面板偏高 20px 也不裁切）。
# 最窄面板内宽 444 也放得下 ≥7 槽/行，11 槽封顶 → 实际最多 2 行，估算不会失控。
func _status_rows_height(pw: float) -> float:
	var n := _status_row.get_child_count()
	if n <= 0:
		return 0.0
	var w := pw
	if w <= 0.0:
		w = 460.0
	var inner := w - 16.0
	var per_row := maxi(1, int(inner / 58.0))
	var rows := ceili(float(n) / float(per_row))
	return rows * 46.0 + (rows - 1) * 4.0

func _ready():
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.45)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(8)
	add_theme_stylebox_override("panel", sb)
	clip_contents = true
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	add_child(vb)
	# 头部行：名字 + HP 数值 + HP 条
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	vb.add_child(head)
	# 角色名可点击：PC 悬停看技能效果，移动端点击显示到底部状态栏
	_name_label = Button.new()
	_name_label.flat = true
	_name_label.add_theme_font_size_override("font_size", Style.fs(28))
	_name_label.pressed.connect(func(): status_clicked.emit(_skill_desc))
	head.add_child(_name_label)
	_hp_num = Label.new()
	_hp_num.add_theme_font_size_override("font_size", Style.fs(24))
	head.add_child(_hp_num)
	_hp_bar = ProgressBar.new()
	_hp_bar.show_percentage = false
	_hp_bar.custom_minimum_size = Vector2(0, 14)
	_hp_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hp_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.15, 0.18, 0.25, 0.8)
	bg.set_corner_radius_all(4)
	_hp_bar.add_theme_stylebox_override("background", bg)
	head.add_child(_hp_bar)
	# 属性行：面板 + AP + 坐标
	_attr_label = Label.new()
	_attr_label.add_theme_font_size_override("font_size", Style.fs(22))
	_attr_label.add_theme_color_override("font_color", Color(0.88, 0.9, 0.95))
	# 单行显示（数字 AP 后宽度足够，邪术师两点功能点也完整）：不加 autowrap——
	# autowrap 会让 get_combined_minimum_size 在布局前算出虚高最小尺寸（每字符一行），
	# 导致面板高度失控顶高挡技能按钮。不加 ellipsis：正常宽度内完整显示
	_attr_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(_attr_label)
	# 牌堆/弃牌行：独立一行（独立牌堆模式下每人各自显示，共享模式下双方一致）
	_deck_label = Label.new()
	_deck_label.add_theme_font_size_override("font_size", Style.fs(20))
	_deck_label.add_theme_color_override("font_color", Color(0.62, 0.68, 0.78))
	vb.add_child(_deck_label)
	# 装备行：武器/防具短信息，点击显示完整效果（PC 悬停 tooltip）
	_equip_label = Button.new()
	_equip_label.flat = true
	_equip_label.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_equip_label.add_theme_font_size_override("font_size", Style.fs(20))
	_equip_label.add_theme_color_override("font_color", Color(0.75, 0.8, 0.85))
	_equip_label.pressed.connect(func(): status_clicked.emit(_equip_detail))
	vb.add_child(_equip_label)
	# 状态行：FlowContainer 自动换行（面板 clip_contents 兜底）
	_status_row = FlowContainer.new()
	_status_row.add_theme_constant_override("h_separation", 4)
	_status_row.add_theme_constant_override("v_separation", 4)
	vb.add_child(_status_row)

func refresh(p: Dictionary, tag: String, accent: Color):
	_name_label.text = "[%s] %s" % [tag, p.get("char_name", p.get("char_id", "?"))]
	_name_label.add_theme_color_override("font_color", accent)
	_skill_desc = Config.CHARACTER_DB.get(p.char_id, {}).get("skill_desc", "")
	_name_label.tooltip_text = _skill_desc
	_hp_num.text = "%d/%d" % [p.hp, p.max_hp]
	var pct: float = float(p.hp) / max(p.max_hp, 1)
	_hp_num.add_theme_color_override("font_color", Color(0.95, 0.3, 0.3) if pct <= 0.35 else Color(0.9, 0.95, 0.9))
	_hp_bar.max_value = max(p.max_hp, 1)
	_hp_bar.value = p.hp
	var fg := StyleBoxFlat.new()
	fg.bg_color = Style.OPP_RED if pct <= 0.35 else Style.ME_GREEN
	# fill 不设圆角：ProgressBar 满值时 fill 圆角会在右端留出空隙（看似没填满）
	fg.set_corner_radius_all(0)
	_hp_bar.add_theme_stylebox_override("fill", fg)
	# 属性行：面板 + AP + 手牌。去掉"格X"坐标（棋盘上可见，省宽度让 AP 完整显示）
	_attr_label.text = "近%d 远%d 魔%d | %s | 手:%d/%d" % [p.near_power, p.range_power, p.magic_power,
		_ap_circles(p.get("ap_attack", 0), p.get("ap_move", 0), p.get("ap_function", 0),
			2 if p.get("char_id", "") == "warlock" else 1),
		p.get("hand_size", 0), p.get("hand_limit", 5)]
	_deck_label.text = "牌堆 %d · 弃牌 %d" % [p.get("deck_size", 0), p.get("discard_size", 0)]
	_refresh_equip(p)
	_refresh_status(p)

# 装备行：武器/防具短信息（耐久），点击/悬停看完整效果
func _refresh_equip(p: Dictionary):
	var eq := ""
	var detail := ""
	if not p.weapon.is_empty():
		var wtype: String = {"near": "近战", "range": "远程", "magic": "法术"}.get(p.weapon.data.type, "?")
		eq += "武:%s(%s) " % [p.weapon.data.name, wtype]
		detail += "武器 %s（%s）：%s" % [p.weapon.data.name, wtype, p.weapon.data.desc]
	if not p.armor.is_empty():
		var maxd: int = p.armor.get("max_durability", 3)
		eq += "甲:%s(%d/%d)" % [p.armor.data.name, p.armor.durability, maxd]
		if detail != "": detail += "\n"
		detail += "防具 %s：%s（耐久%d/%d）" % [p.armor.data.name, p.armor.data.desc, p.armor.durability, maxd]
	_equip_detail = detail
	_equip_label.visible = not eq.is_empty()
	_equip_label.text = eq.strip_edges()
	_equip_label.tooltip_text = detail

func _refresh_status(p: Dictionary):
	for c in _status_row.get_children():
		c.queue_free()
	var slots: Array = []
	if p.get("frozen", false):
		slots.append(_slot_data("freeze", "", "冻结：本回合无法出牌"))
	if p.get("frozen_move", false):
		slots.append(_slot_data("no_move", "", "无法移动（霜咬等）：本回合位移=0"))
	for d in p.get("dots", []):
		if d.type == "burn":
			slots.append(_slot_data("burn", "-%d·%d回" % [d.damage, d.duration],
				"灼烧：每回合-%dHP，剩余%d回" % [d.damage, d.duration]))
		elif d.type == "poison":
			slots.append(_slot_data("poison", "-%d·%d层" % [d.damage, d.duration],
				"中毒：每回合-%dHP，剩余%d层" % [d.damage, d.duration]))
		else:
			slots.append(_slot_data(d.type, "", d.type))
	# Buff 按类型聚合显示：同类型合并为一个槽（层数/值合计），
	# 可无限叠加的 buff（如寻踪者校准叠几十层）不会撑爆状态行
	var counter_groups := {}
	var phantom_total := 0
	var agg := {}
	for b in p.get("buffs", []):
		if b.type == "paladin_counter" or b.type == "tracker_chase":
			# 反击（圣骑士）/追击（寻踪者）：每层独立计时（各 2 回合后清除，不因再触发刷新）；
			# 按叠加回合分组：同一回合叠的层合并一个槽（显示层数），不同回合各占一槽
			var bt := int(b.get("turn", 0))
			if not counter_groups.has(bt):
				counter_groups[bt] = {"value": 0, "duration": int(b.duration), "kind": b.type}
			counter_groups[bt].value += int(b.value)
			continue
		if b.type == "mage_phantom":
			# 幻影（法师）：层数合计显示，闪避概率随层数提升，永久存在
			phantom_total += int(b.value)
			continue
		var k: String = b.type
		if not agg.has(k):
			agg[k] = {"count": 0, "value": 0, "duration": b.duration}
		agg[k].count += 1
		agg[k].value += b.value
		agg[k].duration = max(agg[k].duration, b.duration)
	for k in agg:
		var a: Dictionary = agg[k]
		var sgn := "+" if a.value > 0 else ""
		var dur := ""
		if a.duration == -2: dur = "·永久"
		elif a.duration > 0: dur = "·%d回" % a.duration
		elif a.duration == -1: dur = "·本回"
		var cnt := "×%d" % a.count if a.count > 1 else ""
		slots.append(_slot_data(k, "%s%d%s%s" % [sgn, a.value, dur, cnt],
			"%s：%s%d，%s%s" % [_status_name(k), sgn, a.value, _dur_text(a.duration),
				("（%d层）" % a.count) if a.count > 1 else ""]))
	# 反击/追击槽：按叠加回合分组，每回合一个槽（组内层数合计，组内各层同时衰减）
	for bt in counter_groups:
		var g: Dictionary = counter_groups[bt]
		if g.kind == "tracker_chase":
			slots.append(_slot_data("tracker_chase", "+%d·%d回" % [g.value, g.duration],
				"追击：可抵消%d次校准清空（第%d回合叠加），剩余%d回合" % [g.value, bt, g.duration]))
		else:
			slots.append(_slot_data("paladin_counter", "+%d·%d回" % [g.value, g.duration],
				"反击：下次攻击伤害+%d（第%d回合叠加），剩余%d回合" % [g.value, bt, g.duration]))
	# 幻影（法师）：层数合计，闪避概率 = 层数/(层数+1)，永久存在
	if phantom_total > 0:
		slots.append(_slot_data("mage_phantom", "+%d·永久" % phantom_total,
			"幻影：%d 层，%d/%d 概率闪避一次攻击；闪避成功消耗 1 层，永久存在" % [
				phantom_total, phantom_total, phantom_total + 1]))
	# 超量合并防撑爆：只留前 N-1 个，剩余归并为 "+N" 槽
	if slots.size() > _MAX_STATUS_SLOTS:
		var overflow := slots.slice(_MAX_STATUS_SLOTS - 1)
		var brief := ""
		for s in overflow: brief += s.tooltip + "\n"
		slots = slots.slice(0, _MAX_STATUS_SLOTS - 1)
		slots.append({"icon": "+%d" % overflow.size(), "accent": Color(0.8, 0.8, 0.8),
			"value": "", "tooltip": brief.strip_edges()})
	for s in slots:
		var slot: Button = StatusSlot.new()
		slot.setup(s.icon, s.value, s.tooltip, s.accent)
		slot.clicked.connect(func(txt): status_clicked.emit(txt))
		_status_row.add_child(slot)

func _slot_data(kind: String, value: String, tooltip: String) -> Dictionary:
	var meta: Dictionary = _STATUS_ICONS.get(kind, {"icon": kind.substr(0, 1).to_upper(), "accent": Color(0.9, 0.9, 0.9)})
	return {"icon": meta.get("icon", kind), "accent": meta.get("accent", Color(0.9, 0.9, 0.9)), "value": value, "tooltip": tooltip}

func _status_name(kind: String) -> String:
	return _STATUS_ICONS.get(kind, {}).get("name", kind)

func _dur_text(duration: int) -> String:
	if duration == -1: return "本回合结束清除"
	if duration == -2: return "永久持续"
	return "剩余%d回" % duration

func _ap_circles(atk: int, mov: int, fun: int, _fun_max: int = 1) -> String:
	# 数字格式（攻2移1功2）：信息等价、宽度约为圆点版一半，配合 460 面板宽完整显示不换行；
	# 上限隐含（攻击2/位移1/功能1，邪术师功能2），比圆点更省空间且不会挤棋盘
	return "攻%d移%d功%d" % [atk, mov, fun]

# HP 变化闪烁：改色 0.9 秒后恢复（低血红色由下次 refresh 覆盖）
func flash_hp(is_heal: bool):
	_hp_num.add_theme_color_override("font_color", Style.ME_GREEN if is_heal else Style.OPP_RED)
	var tw := create_tween().set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.9)
	tw.tween_callback(func():
		_hp_num.add_theme_color_override("font_color", Color(0.9, 0.95, 0.9))
	)
