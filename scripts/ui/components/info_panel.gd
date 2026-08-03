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
	"ap_attack_down": {"icon": "滞", "accent": Color(0.7, 0.6, 1.0), "name": "攻击行动点-1"},
	"no_move": {"icon": "移", "accent": Color(0.85, 0.85, 0.85), "name": "无法移动"},
}
# 状态槽一行上限（面板宽度约 11 个），超出合并为 "+N" 槽，详情放 tooltip
const _MAX_STATUS_SLOTS := 11

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
	_name_label.add_theme_font_size_override("font_size", 28)
	_name_label.pressed.connect(func(): status_clicked.emit(_skill_desc))
	head.add_child(_name_label)
	_hp_num = Label.new()
	_hp_num.add_theme_font_size_override("font_size", 24)
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
	_attr_label.add_theme_font_size_override("font_size", 22)
	_attr_label.add_theme_color_override("font_color", Color(0.88, 0.9, 0.95))
	vb.add_child(_attr_label)
	# 装备行：武器/防具短信息，点击显示完整效果（PC 悬停 tooltip）
	_equip_label = Button.new()
	_equip_label.flat = true
	_equip_label.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_equip_label.add_theme_font_size_override("font_size", 20)
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
	fg.set_corner_radius_all(4)
	_hp_bar.add_theme_stylebox_override("fill", fg)
	_attr_label.text = "近%d 远%d 魔%d | %s | 手:%d/%d 格%d" % [p.near_power, p.range_power, p.magic_power,
		_ap_circles(p.get("ap_attack", 0), p.get("ap_move", 0), p.get("ap_function", 0)),
		p.get("hand_size", 0), p.get("hand_limit", 5), p.position]
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
	var agg := {}
	for b in p.get("buffs", []):
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

func _ap_circles(atk: int, mov: int, fun: int) -> String:
	var a := ""; for _i in range(2): a += "●" if _i < atk else "○"
	var m := ""; for _i in range(1): m += "●" if _i < mov else "○"
	# 功能点按实际值显示（术士 2 圆，其他角色 1 圆）；不显示空心圆避免误解上限为 2
	var f := ""; for _i in range(fun): f += "●"
	return "攻%s 移%s 功%s" % [a, m, f]

# HP 变化闪烁：改色 0.9 秒后恢复（低血红色由下次 refresh 覆盖）
func flash_hp(is_heal: bool):
	_hp_num.add_theme_color_override("font_color", Style.ME_GREEN if is_heal else Style.OPP_RED)
	var tw := create_tween().set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.9)
	tw.tween_callback(func():
		_hp_num.add_theme_color_override("font_color", Color(0.9, 0.95, 0.9))
	)
