# battle_ui.gd — 对战界面
extends Control

const Style = preload("res://scripts/theme/style_const.gd")
const CardWidget = preload("res://scripts/ui/components/card_widget.gd")

@onready var opp_info = $OppInfo
@onready var phase_label = $PhaseLabel
@onready var hand_area = $HandArea
@onready var me_info = $MeInfo
@onready var end_turn_btn = $EndTurnBtn
@onready var confirm_btn = $ConfirmBtn
@onready var cancel_btn = $CancelBtn
@onready var status_label = $StatusLabel
@onready var board = $Board
@onready var action_log = $ActionLog
var _deck_label: Label

var _game_state: Dictionary = {}
var _player_index: int = -1
var _is_my_turn: bool = false
var _selected_uid: int = -1
var _selected_type: String = ""
var _discard_selected: Array = []
@onready var card_info = $CardInfo
@onready var skill_btn = $SkillBtn
@onready var skill_confirm = $SkillConfirm
@onready var skill_cancel = $SkillCancel
var _last_hp: Array = [-1, -1]
var _last_turn: int = -1
var _last_player: int = -1
var _cheat_on: bool = false
var _timer_left: int = -1
var _skill_waiting: bool = false
var _resp_popup: Control
var _wpn_popup: Control
var _skill_labels = {}

func _n():
	if LocalGame.game != null: return LocalGame
	return Network

func _ready():
	skill_cancel.pressed.connect(func():
		skill_btn.visible = true
		skill_confirm.visible = false
		skill_cancel.visible = false
		_skill_waiting = false
	)
	skill_btn.pressed.connect(func():
		skill_btn.visible = false
		skill_confirm.visible = true
		skill_cancel.visible = true
		_skill_waiting = false
	)
	skill_confirm.pressed.connect(_on_skill_use)
	board.cell_clicked.connect(_on_board_cell_clicked)
	_deck_label = Label.new()
	_deck_label.add_theme_font_size_override("font_size", 26)
	_deck_label.add_theme_color_override("font_color", Style.HAND_TITLE)
	add_child(_deck_label)
	_build_popups()
	end_turn_btn.pressed.connect(_on_end_turn)
	confirm_btn.pressed.connect(_on_confirm_card)
	cancel_btn.pressed.connect(_on_cancel_select)
	_n().state_updated.connect(_on_state_updated)
	_n().response_needed.connect(_on_response_needed)
	_n().hand_revealed.connect(_on_hand_revealed)
	_n().weapon_prompt.connect(_on_weapon_prompt)
	_n().game_ended.connect(_on_game_ended)
	_n().network_error.connect(_on_error)
	var cached = _n().battle_state_cache
	if not cached.is_empty():
		_on_state_updated(cached)
		_n().battle_state_cache = {}
	_apply_safe_area()

# 全面屏/刘海屏安全区适配：横屏时刘海在左右两侧，给角落信息留出边距
func _apply_safe_area():
	var sa = DisplayServer.get_display_safe_area()
	var win = DisplayServer.window_get_size()
	var vp = get_viewport_rect().size
	if vp.x <= 0 or vp.y <= 0: return
	var sx = win.x / vp.x
	var sy = win.y / vp.y
	var left = sa.position.x / sx
	var right = (win.x - sa.end.x) / sx
	var top = sa.position.y / sy
	var bottom = (win.y - sa.end.y) / sy
	if left > 0:
		me_info.offset_left = left + 12
		skill_btn.offset_left += left
		skill_btn.offset_right += left
		skill_confirm.offset_left += left
		skill_confirm.offset_right += left
		skill_cancel.offset_left += left
		skill_cancel.offset_right += left
	if right > 0:
		opp_info.offset_right = -(right + 12)
	if bottom > 0:
		end_turn_btn.offset_top -= bottom
		end_turn_btn.offset_bottom -= bottom
		skill_btn.offset_top -= bottom
		skill_btn.offset_bottom -= bottom
		skill_confirm.offset_top -= bottom
		skill_confirm.offset_bottom -= bottom
		skill_cancel.offset_top -= bottom
		skill_cancel.offset_bottom -= bottom

func _input(event):
	if not OS.is_debug_build(): return
	if not event is InputEventKey or not event.pressed: return
	if event.keycode == KEY_F12: _cheat_on = not _cheat_on; return
	if not _cheat_on or not _is_my_turn: return
	var cheat = {KEY_F1: "near", KEY_F2: "range", KEY_F3: "magic", KEY_F4: "heavy", KEY_F5: "range_weapon", KEY_F6: "magic_weapon", KEY_F7: "move", KEY_F8: "blessing", KEY_F9: "heal_3", KEY_F10: "near_weapon"}
	if event.keycode in cheat:
		_n().send_use_skill("_cheat", {"type_id": cheat[event.keycode]})

func _on_cancel_select():
	_selected_uid = -1
	_discard_selected.clear()
	confirm_btn.visible = false
	cancel_btn.visible = false
	card_info.text = ""

func _build_popups():
	_resp_popup = _make_resp_popup()
	_wpn_popup = _make_wpn_popup()

func _make_resp_popup() -> Control:
	var c = Control.new()
	c.visible = false; c.z_index = 10; c.name = "RespPopupRoot"
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new()
	bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(bg)
	add_child(c)
	return c

func _show_resp_popup(atk_card: String):
	var c = _resp_popup
	for child in c.get_children():
		if child is ColorRect: continue
		c.remove_child(child); child.queue_free()
	var box = _box(c, 140, 100, 700, 480)
	box.name = "RespBox"
	var t = _lbl("对方使用 %s 攻击！选择响应卡：" % atk_card)
	t.add_theme_font_size_override("font_size", 28)
	box.add_child(t)
	var has_any = false
	var defender_hand = []
	for p in _game_state.players:
		if p.index != _game_state.current_player:
			defender_hand = p.get("hand", [])
			break
	for card in defender_hand:
		var tid = card.type_id
		var ok = false
		if tid in ["magic"]: ok = true
		elif tid in ["range"] and atk_card in ["range", "pierce", "magic", "chant"]: ok = true
		elif tid in ["near"] and atk_card in ["near", "heavy"]: ok = true
		if ok:
			has_any = true
			var rb = _mkbtn("  %s  " % Config.card_name(tid))
			rb.pressed.connect(func(uid=card.uid): c.visible = false; _n().send_response(true, uid))
			box.add_child(rb)
	var sb = _mkbtn("不响应" if has_any else "无法响应（跳过）")
	sb.pressed.connect(func(): c.visible = false; _n().send_response(false))
	box.add_child(sb)
	c.visible = true

func _make_wpn_popup() -> Control:
	var c = Control.new()
	c.visible = false; c.z_index = 10
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new()
	bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(bg)
	add_child(c)
	var box = _box(c, 200, 160, 640, 320)
	var t = _lbl("获得武器！")
	t.name = "WpnTitle"
	box.add_child(t)
	var d = _lbl("")
	d.name = "WpnDesc"
	d.add_theme_color_override("font_color", Style.HAND_TITLE)
	box.add_child(d)
	var hb = HBoxContainer.new()
	box.add_child(hb)
	var eb = _mkbtn("装备")
	eb.pressed.connect(func(): c.visible = false; _n().send_weapon_choice(true))
	hb.add_child(eb)
	var db = _mkbtn("丢弃")
	db.pressed.connect(func(): c.visible = false; _n().send_weapon_choice(false))
	hb.add_child(db)
	return c

func _box(parent: Control, x: float, y: float, w: float, h: float) -> VBoxContainer:
	# x/y 已废弃（原实现未使用），统一走滚动弹窗框架
	return _popup_box(parent, w, h)

func _popup_box(parent: Control, w: float, h: float) -> VBoxContainer:
	# 居中滚动弹窗：内容超出时滚动，最大占屏幕 92%，适配手机小屏
	var vp = get_viewport_rect().size
	w = min(w, vp.x * 0.92)
	h = min(h, vp.y * 0.92)
	var sc = ScrollContainer.new()
	sc.layout_mode = 1
	sc.anchor_left = 0.5; sc.anchor_right = 0.5
	sc.anchor_top = 0.5; sc.anchor_bottom = 0.5
	sc.offset_left = -w / 2.0; sc.offset_right = w / 2.0
	sc.offset_top = -h / 2.0; sc.offset_bottom = h / 2.0
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.get_v_scroll_bar().custom_minimum_size = Vector2(24, 0)
	parent.add_child(sc)
	var vb = VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(vb)
	return vb

func _flash(node: Control):
	var tw = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_property(node, "scale", Vector2(1.15, 1.15), 0.15)
	tw.tween_property(node, "scale", Vector2.ONE, 0.3)

func _flash_hp(node: Control, is_heal: bool):
	var c = Style.ME_GREEN if is_heal else Style.OPP_RED
	var default = node.get_theme_color("font_color")
	node.add_theme_color_override("font_color", c)
	var tw = create_tween().set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.0)
	tw.tween_callback(func(): node.add_theme_color_override("font_color", default))

func _lbl(txt: String) -> Label:
	var l = Label.new()
	l.text = txt
	l.add_theme_color_override("font_color", Style.LOG_TEXT)
	l.add_theme_font_size_override("font_size", 28)
	return l

func _mkbtn(txt: String) -> Button:
	var b = Button.new()
	b.text = txt
	b.custom_minimum_size = Vector2(220, 100)
	b.add_theme_font_size_override("font_size", 32)
	return b

func _on_state_updated(state: Dictionary):
	_game_state = state
	if _n() == LocalGame:
		if state.get("response_pending", false):
			_player_index = 1 - state.current_player
		else:
			_player_index = state.current_player
		_is_my_turn = (state.phase == Config.Phase.PLAYER_TURN)
	else:
		_player_index = _n().player_index
		_is_my_turn = (state.current_player == _player_index) and (state.phase == Config.Phase.PLAYER_TURN)
	if not _is_my_turn:
		_selected_uid = -1
		_discard_selected.clear()
		confirm_btn.visible = false
		cancel_btn.visible = false
		card_info.text = ""
	_refresh_all(state)

func _update_timer_label():
	if _timer_left <= 0:
		return
	var tp = ["判定", "摸牌", "出牌", "弃牌"]
	var tn = tp[_game_state.get("turn_phase", 0)] if _game_state.get("turn_phase", 0) < tp.size() else "?"
	var who = "你的回合" if _is_my_turn else "对手回合"
	phase_label.text = "T%d | %s | %s | %ds" % [_game_state.turn_number, tn, who, _timer_left]

func _process(delta):
	if _timer_left <= 0:
		return
	_timer_elapsed += delta
	if _timer_elapsed >= 1.0:
		_timer_elapsed -= 1.0
		_timer_left -= 1
		if _timer_left < 0: _timer_left = -1
		_update_timer_label()

var _timer_elapsed: float = 0.0

func _refresh_all(state: Dictionary):
	card_info.text = ""
	var pls = state.players
	if pls.size() < 2:
		return
	var opp = pls[0] if pls[0].index != _player_index else pls[1]
	var me = pls[0] if pls[0].index == _player_index else pls[1]
	opp_info.text = _fmt_player(opp, "对手")
	me_info.text = _fmt_player(me, "自己")
	for p in pls:
		if p.hp != _last_hp[p.index]:
			var lbl = me_info if p.index == _player_index else opp_info
			_flash_hp(lbl, p.hp > _last_hp[p.index])
			_last_hp[p.index] = p.hp
	var tp = ["判定", "摸牌", "出牌", "弃牌"]
	var tn = tp[state.get("turn_phase", 0)] if state.get("turn_phase", 0) < tp.size() else "?"
	var who = "你的回合" if _is_my_turn else "对手回合"
	# 从服务端同步计时器
	var timer = state.get("action_time_left", -1)
	if timer <= 0: timer = state.get("discard_time_left", -1)
	_timer_left = timer if timer > 0 else -1
	_timer_elapsed = 0.0
	if _timer_left > 0:
		_update_timer_label()
	else:
		phase_label.text = "T%d | %s | %s" % [state.turn_number, tn, who]
	if state.turn_number != _last_turn or state.current_player != _last_player:
		_last_turn = state.turn_number; _last_player = state.current_player
		_flash(phase_label)

	_deck_label.text = "牌堆:%d  弃牌:%d" % [state.get("deck_size", 0), state.get("discard_size", 0)]
	_deck_label.anchor_left = 0.5; _deck_label.anchor_right = 0.5
	_deck_label.anchor_top = 0.05; _deck_label.anchor_bottom = 0.05
	_deck_label.offset_left = -100; _deck_label.offset_right = 100
	_deck_label.offset_top = 38; _deck_label.offset_bottom = 66
	_deck_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	board.update(pls, state.get("traps", []), _player_index)

	for c in hand_area.get_children():
		c.queue_free()
	var mh = me.get("hand", [])
	if mh.is_empty():
		var el = _lbl("无手牌")
		el.add_theme_color_override("font_color", Style.EMPTY_HAND)
		hand_area.add_child(el)
	else:
		var can_resp = state.get("response_pending", false) and state.current_player != _player_index
		var in_disc = state.get("waiting_for_discard", false) and _is_my_turn
		if in_disc: _selected_uid = -1
		for card in mh:
			var tid = card.type_id
			var cd = Config.CARD_DB.get(tid, {})
			var cw = CardWidget.new()
			cw.setup(card.uid, tid, cd.get("name", tid), cd.get("ap", 0), card.uid in _discard_selected)
			cw.pressed.connect(_on_card_clicked.bind(tid))
			if can_resp:
				var atk = state.get("pending_attack_card", "")
				if tid in ["magic"]: cw.set_respondable(true)
				elif tid in ["range"]: cw.set_respondable(atk in ["range", "pierce", "magic", "chant"])
				elif tid in ["near"]: cw.set_respondable(atk in ["near", "heavy"])
			if in_disc and card.uid in _discard_selected:
				cw.set_discard_mark(true)
			if card.uid == _selected_uid:
				cw.set_selected(true)
			hand_area.add_child(cw)

	action_log.show_logs(state.get("action_log", []), 8, _player_index)

	if state.get("revealed_to", -1) == _player_index:
		_on_hand_revealed(state.get("revealed_hand", []))

	if state.get("response_pending", false) and state.current_player != _player_index:
		_show_resp_popup(state.get("pending_attack_card", ""))

	var in_discard = state.get("waiting_for_discard", false)
	if in_discard and _is_my_turn:
		var need = me.get("hand", []).size() - me.get("hand_limit", 5)
		var txt = "确认弃牌(%d张)" % _discard_selected.size()
		end_turn_btn.text = txt; end_turn_btn.visible = true
		if need > 0:
			status_label.text = "还需弃%d张（手牌上限%d）" % [need, me.get("hand_limit", 5)]
		else:
			status_label.text = "手牌未超上限，可主动多弃（选%d张）" % _discard_selected.size()
		confirm_btn.visible = false
	else:
		_discard_selected.clear()
		end_turn_btn.text = "结束出牌"
		end_turn_btn.visible = _is_my_turn
		confirm_btn.visible = false
		cancel_btn.visible = false
		status_label.text = ""
		var skills = me.get("active_skills", [])
		skill_btn.visible = _is_my_turn and skills.size() > 0
		if skills.size() > 0:
			skill_btn.text = skills[0].name + ("…" if skills.size() > 1 else "")
		if me.get("pending_swordsman_skill", false):
			_show_swordsman_popup()

func _fmt_player(p, tag: String) -> String:
	var hp_pct = float(p.hp) / max(p.max_hp, 1)
	var bar = ""
	for _i in range(20):
		bar += "=" if (float(_i) / 20.0) < hp_pct else "-"
	var ap = _ap_circles(p.get("ap_attack", 0), p.get("ap_move", 0), p.get("ap_function", 0))
	var txt = "[%s] %s HP:%d/%d[%s] 坐标:%d\n" % [tag, p.char_name, p.hp, p.max_hp, bar, p.position]
	txt += "近%d 远%d 魔%d | %s | 手牌:%d/%d" % [p.near_power, p.range_power, p.magic_power, ap, p.hand_size, p.get("hand_limit", 5)]
	if not p.weapon.is_empty():
		txt += " | 武器:%s[%s](%s)" % [p.weapon.data.name, {"near":"近战","range":"远程","magic":"法术"}.get(p.weapon.data.type, "?"), p.weapon.data.desc]
	if not p.armor.is_empty():
		txt += " | 防具:%s" % p.armor.data.name + "(%d/%d)" % [p.armor.durability, p.armor.get("max_durability", 3)]
	if p.get("frozen", false):
		txt += " | 冻结!"
	var dots = p.get("dots", [])
	var buffs = p.get("buffs", [])
	var skill = Config.CHARACTER_DB.get(p.char_id, {}).get("skill_desc", "?")
	var extra = ""
	if dots.size() > 0 or buffs.size() > 0 or skill != "?":
		extra += "\n"
		if dots.size() > 0:
			for d in dots:
				var dname = "灼烧" if d.type == "burn" else ("中毒" if d.type == "poison" else d.type)
				var suffix = ("%d回" % d.duration) if d.type == "burn" else ("%d层" % d.duration)
				extra += " [DoT] %s -%dHP %s" % [dname, d.damage, suffix]
		if buffs.size() > 0:
			for b in buffs:
				var bname = {"attack_up": "攻击强化", "attack_down": "攻击弱化", "near_up": "近战强化"}.get(b.type, b.type)
				var sgn = "+" if b.value > 0 else ""
				var dur = ("%d回" % b.duration) if b.duration > 0 else ("回合" if b.duration == -1 else "")
				extra += " [Buff] %s %s%d %s" % [bname, sgn, b.value, dur]
		if skill != "?":
			if extra != "": extra += " |"
			extra += " 技能:%s" % skill
	return txt + extra

func _ap_circles(atk: int, mov: int, fun: int) -> String:
	var a = ""; for _i in range(2): a += "●" if _i < atk else "○"
	var m = ""; for _i in range(1): m += "●" if _i < mov else "○"
	var f = ""; for _i in range(1): f += "●" if _i < fun else "○"
	return "攻%s 移%s 功%s" % [a, m, f]

func _on_card_clicked(card_uid: int, type_id: String):
	var state = _game_state
	if state.get("response_pending", false) and state.current_player != _player_index:
		_resp_popup.visible = false
		_n().send_response(true, card_uid)
		return
	if not _is_my_turn:
		return

	if state.get("waiting_for_discard", false):
		if card_uid in _discard_selected:
			_discard_selected.erase(card_uid)
		else:
			_discard_selected.append(card_uid)
		_refresh_all(state)
		return

	if _selected_uid == card_uid:
		_selected_uid = -1
		confirm_btn.visible = false
		cancel_btn.visible = false
		card_info.text = ""
	else:
		_selected_uid = card_uid
		_selected_type = type_id
		confirm_btn.visible = true
		cancel_btn.visible = true
		card_info.text = Config.card_name(type_id) + ": " + Config.CARD_DB.get(type_id, {}).get("desc", "")
	_refresh_highlight()

func _on_confirm_card():
	if _selected_uid == -1:
		return
	if _selected_type in ["move", "destroy"]:
		match _selected_type:
			"move": _popup_move(_selected_uid)
			"destroy": _popup_destroy(_selected_uid)
		_selected_uid = -1
		confirm_btn.visible = false
	elif _selected_type == "trap":
		_popup_trap(_selected_uid)
		confirm_btn.visible = false
	else:
		if _has_matching_armor(_selected_type):
			_show_armor_confirm(_selected_uid, _selected_type)
			_selected_uid = -1
		else:
			_n().send_play_card(_selected_uid)
			_selected_uid = -1
	confirm_btn.visible = false
	cancel_btn.visible = false

func _has_matching_armor(attack_type: String) -> bool:
	var armor_needed = {"near": "physical", "heavy": "physical", "range": "ranged", "pierce": "ranged", "magic": "magical", "chant": "magical"}
	var need = armor_needed.get(attack_type, "")
	if need == "": return false
	for p in _game_state.players:
		if p.index != _player_index and not p.armor.is_empty():
			return p.armor.data.type == need
	return false

func _show_armor_confirm(card_uid: int, attack_type: String):
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 700, 340)
	var armor_name = ""
	for p in _game_state.players:
		if p.index != _player_index and not p.armor.is_empty():
			armor_name = p.armor.data.name
			break
	vb.add_child(_lbl("对方装备了%s" % armor_name))
	vb.add_child(_lbl("此次攻击将被完全免疫"))
	vb.add_child(_lbl("确定要打出吗？"))
	var hb = HBoxContainer.new(); vb.add_child(hb)
	var ok = _mkbtn("确定")
	ok.pressed.connect(func(): c.queue_free(); _n().send_play_card(card_uid))
	hb.add_child(ok)
	var no = _mkbtn("取消")
	no.pressed.connect(func(): c.queue_free())
	hb.add_child(no)
	add_child(c)

func _refresh_highlight():
	for child in hand_area.get_children():
		if child is CardWidget:
			child.set_selected(child.card_uid == _selected_uid)

func _on_board_cell_clicked(cell_index: int):
	if _selected_type != "trap" or not _is_my_turn:
		return
	_n().send_play_card(_selected_uid, {"trap_pos": cell_index})
	_selected_uid = -1
	_selected_type = ""
	confirm_btn.visible = false
	cancel_btn.visible = false

func _popup_move(card_uid: int):
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 620, 360)
	vb.add_child(_lbl("移动方向"))
	var hb = HBoxContainer.new()
	vb.add_child(hb)
	var lb = _mkbtn("左1格")
	if card_uid < 0:
		lb.pressed.connect(func(): c.queue_free(); _n().send_use_skill("assassin_move", {"direction": -1}))
	else:
		lb.pressed.connect(func(): c.queue_free(); _n().send_play_card(card_uid, {"direction": -1, "steps": 1}))
	hb.add_child(lb)
	var rb = _mkbtn("右1格")
	if card_uid < 0:
		rb.pressed.connect(func(): c.queue_free(); _n().send_use_skill("assassin_move", {"direction": 1}))
	else:
		rb.pressed.connect(func(): c.queue_free(); _n().send_play_card(card_uid, {"direction": 1, "steps": 1}))
	hb.add_child(rb)
	var cb = _mkbtn("取消")
	cb.pressed.connect(func(): c.queue_free())
	vb.add_child(cb)
	add_child(c)

func _popup_destroy(card_uid: int):
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 700, 440)
	vb.add_child(_lbl("摧毁: 选择目标"))
	var hb = _mkbtn("盲丢对方1手牌")
	hb.pressed.connect(func(): c.queue_free(); _n().send_play_card(card_uid, {"destroy_target": "hand"}))
	vb.add_child(hb)
	var pls = _game_state.players
	var opp = pls[0] if pls[0].index != _player_index else pls[1]
	if not opp.weapon.is_empty():
		var wb = _mkbtn("摧毁对方武器: " + opp.weapon.data.name)
		wb.pressed.connect(func(): c.queue_free(); _n().send_play_card(card_uid, {"destroy_target": "equip", "equip_type": "weapon"}))
		vb.add_child(wb)
	if not opp.armor.is_empty():
		var ab = _mkbtn("摧毁对方防具: " + opp.armor.data.name)
		ab.pressed.connect(func(): c.queue_free(); _n().send_play_card(card_uid, {"destroy_target": "equip", "equip_type": "armor"}))
		vb.add_child(ab)
	var traps_list = _game_state.get("traps", [])
	if traps_list.size() > 0:
		var tb = _mkbtn("摧毁场上陷阱(%d个)" % traps_list.size())
		tb.pressed.connect(func(): c.queue_free(); _n().send_play_card(card_uid, {"destroy_target": "trap"}))
		vb.add_child(tb)
	add_child(c)

func _popup_trap(card_uid: int):
	status_label.text = "已选陷阱,点击棋盘格子放置"
	_selected_uid = card_uid
	_selected_type = "trap"

func _on_response_needed(data: Dictionary):
	var atk = data.get("card", "")
	status_label.text = "对方发动%s攻击！" % atk
	_show_resp_popup(atk)

func _on_weapon_prompt(weapon: Dictionary):
	var wd = weapon.get("data", {})
	_wpn_popup.find_child("WpnTitle", true, false).text = "获得武器: " + wd.get("name", "?")
	_wpn_popup.find_child("WpnDesc", true, false).text = wd.get("desc", "")
	_wpn_popup.visible = true

func _on_game_ended(_r: Dictionary):
	get_tree().change_scene_to_file("res://scenes/settlement.tscn")

func _on_error(msg: String):
	status_label.text = "错误: " + msg

func _exec_skill(sk_id: String):
	if sk_id == "mage_discard": _show_mage_pick()
	elif sk_id == "assassin_move": _popup_move(-1)
	else: _n().send_use_skill(sk_id)

func _on_skill_use():
	var me = _game_state.players[0] if _game_state.players[0].index == _player_index else _game_state.players[1]
	var skills = me.get("active_skills", [])
	if skills.size() <= 1:
		_exec_skill(skills[0].id) if skills.size() == 1 else null
	else:
		_show_skill_select(skills)
	skill_confirm.visible = false
	skill_cancel.visible = false

func _show_skill_select(skills: Array):
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 480, skills.size() * 90 + 120)
	vb.add_child(_lbl("选择技能："))
	for sk in skills:
		var b = _mkbtn(sk.name)
		b.pressed.connect(func(sid=sk.id): c.queue_free(); _exec_skill(sid))
		vb.add_child(b)
	var cb = _mkbtn("取消"); cb.pressed.connect(func(): c.queue_free()); vb.add_child(cb)
	add_child(c)

func _show_mage_pick():
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 700, 460)
	vb.add_child(_lbl("选择一张要弃的牌："))
	var mh = (_game_state.players[0] if _game_state.players[0].index == _player_index else _game_state.players[1]).get("hand", [])
	for card in mh:
		var b = _mkbtn(Config.card_name(card.type_id))
		b.pressed.connect(func(uid=card.uid): c.queue_free(); _n().send_use_skill("mage_discard", {"card_uid": uid}))
		vb.add_child(b)
	var cb = _mkbtn("取消"); cb.pressed.connect(func(): c.queue_free()); vb.add_child(cb)
	add_child(c)

func _on_hand_revealed(cards: Array):
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 640, 460)
	vb.add_child(_lbl("对方手牌："))
	if cards.is_empty():
		vb.add_child(_lbl("  (无手牌)"))
	else:
		for tid in cards:
			vb.add_child(_lbl("  " + Config.card_name(tid)))
	var cb = _mkbtn("关闭")
	cb.pressed.connect(func(): c.queue_free()); vb.add_child(cb)
	add_child(c)

func _show_swordsman_popup():
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 620, 320)
	vb.add_child(_lbl("剑士技能: 近战命中后"))
	var hb = HBoxContainer.new(); vb.add_child(hb)
	var hbtn = _mkbtn("回2HP")
	hbtn.pressed.connect(func(): c.queue_free(); _n().send_swordsman_choice("heal"))
	hb.add_child(hbtn)
	var dbtn = _mkbtn("抽1张牌")
	dbtn.pressed.connect(func(): c.queue_free(); _n().send_swordsman_choice("draw"))
	hb.add_child(dbtn)
	add_child(c)

func _on_end_turn():
	if not _is_my_turn:
		return
	if _game_state.get("waiting_for_discard", false):
		_n().send_confirm_discard(_discard_selected.duplicate())
		_discard_selected.clear()
	else:
		_n().send_end_turn()
