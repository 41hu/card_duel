# battle_ui.gd — 对战界面
extends Control

@onready var opp_info = $OppInfo
@onready var phase_label = $PhaseLabel
@onready var hand_area = $HandArea
@onready var me_info = $MeInfo
@onready var end_turn_btn = $EndTurnBtn
@onready var confirm_btn = $ConfirmBtn
@onready var cancel_btn = $CancelBtn
@onready var status_label = $StatusLabel

var _game_state: Dictionary = {}
var _player_index: int = -1
var _is_my_turn: bool = false
var _selected_uid: int = -1
var _selected_type: String = ""
var _discard_selected: Array = []
var _board_cells: Array = []
var _board_container: Control
var _log_scroll: ScrollContainer
var _log_vbox: VBoxContainer
var _resp_popup: Control
var _wpn_popup: Control
var _card_info: Label

func _n():
	return LocalGame if LocalGame.game != null else Network

func _ready():
	_card_info = Label.new()
	_card_info.position = Vector2(10, 338)
	_card_info.size = Vector2(350, 30)
	_card_info.add_theme_font_size_override("font_size", 14)
	_card_info.add_theme_color_override("font_color", Color(0.8, 0.8, 0.5))
	add_child(_card_info)
	_build_board()
	_build_log()
	_build_popups()
	end_turn_btn.pressed.connect(_on_end_turn)
	confirm_btn.pressed.connect(_on_confirm_card)
	cancel_btn.pressed.connect(_on_cancel_select)
	_n().state_updated.connect(_on_state_updated)
	_n().response_needed.connect(_on_response_needed)
	_n().weapon_prompt.connect(_on_weapon_prompt)
	_n().game_ended.connect(_on_game_ended)
	_n().network_error.connect(_on_error)
	var cached = _n().battle_state_cache
	if not cached.is_empty():
		_on_state_updated(cached)
		_n().battle_state_cache = {}

func _on_cancel_select():
	_selected_uid = -1
	_discard_selected.clear()
	confirm_btn.visible = false
	cancel_btn.visible = false
	_card_info.text = ""
	_refresh_highlight()

func _build_board():
	_board_container = Control.new()
	_board_container.position = Vector2(10, 130)
	_board_container.size = Vector2(790, 70)
	add_child(_board_container)
	for i in range(11):
		var x = i * 72
		var p = Panel.new()
		p.position = Vector2(x, 0)
		p.size = Vector2(68, 70)
		p.set_meta("index", i)
		p.mouse_filter = Control.MOUSE_FILTER_STOP
		p.gui_input.connect(_on_board_click.bind(i))
		var s = StyleBoxFlat.new()
		s.bg_color = Color(0.12, 0.14, 0.2)
		s.border_width_left = 1
		s.border_width_right = 1
		s.border_width_top = 1
		s.border_width_bottom = 1
		s.border_color = Color(0.25, 0.25, 0.35)
		p.add_theme_stylebox_override("panel", s)
		var l = Label.new()
		l.position = Vector2(0, 0)
		l.size = Vector2(68, 70)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", 10)
		l.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
		p.add_child(l)
		_board_container.add_child(p)
		_board_cells.append(p)

func _build_log():
	_log_scroll = ScrollContainer.new()
	_log_scroll.position = Vector2(10, 210)
	_log_scroll.size = Vector2(350, 140)
	add_child(_log_scroll)
	_log_vbox = VBoxContainer.new()
	_log_scroll.add_child(_log_vbox)

func _build_popups():
	_resp_popup = _make_resp_popup()
	_wpn_popup = _make_wpn_popup()

func _make_resp_popup() -> Control:
	var c = Control.new()
	c.position = Vector2(0, 0)
	c.size = Vector2(800, 500)
	c.visible = false
	c.z_index = 10
	c.name = "RespPopupRoot"
	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(bg)
	add_child(c)
	return c

func _show_resp_popup(atk_card: String):
	var c = _resp_popup
	# 清除旧内容
	for child in c.get_children():
		if child is ColorRect: continue
		c.remove_child(child); child.queue_free()
	var box = _box(c, 180, 120, 440, 300)
	box.name = "RespBox"
	var t = _lbl("对方使用 %s 攻击！选择响应卡：" % atk_card)
	t.add_theme_font_size_override("font_size", 16)
	box.add_child(t)
	# 从防守方手牌数据直接列出可用响应卡
	var has_any = false
	var defender_hand = []
	for p in _game_state.players:
		if p.index != _game_state.current_player:
			defender_hand = p.get("hand", [])
			break
	for card in defender_hand:
		var tid = card.type_id
		var ok = false
		if tid in ["magic"]:
			ok = true
		elif tid in ["range"] and atk_card in ["range", "pierce", "magic", "chant"]:
			ok = true
		elif tid in ["near"] and atk_card in ["near", "heavy"]:
			ok = true
		if ok:
			has_any = true
			var rb = Button.new()
			rb.text = "  %s  " % Config.card_name(tid)
			rb.pressed.connect(func(uid=card.uid): c.visible = false; _n().send_response(true, uid))
			box.add_child(rb)
	var sb = Button.new()
	sb.text = "不响应" if has_any else "无法响应（跳过）"
	sb.pressed.connect(func(): c.visible = false; _n().send_response(false))
	box.add_child(sb)
	c.visible = true

func _make_wpn_popup() -> Control:
	var c = Control.new()
	c.position = Vector2(0, 0)
	c.size = Vector2(800, 500)
	c.visible = false
	c.z_index = 10
	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(bg)
	add_child(c)
	var box = _box(c, 200, 180, 400, 170)
	var t = _lbl("获得武器！")
	t.name = "WpnTitle"
	box.add_child(t)
	var d = _lbl("")
	d.name = "WpnDesc"
	d.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	box.add_child(d)
	var hb = HBoxContainer.new()
	box.add_child(hb)
	var eb = Button.new()
	eb.text = "装备"
	eb.pressed.connect(func(): c.visible = false; _n().send_weapon_choice(true))
	hb.add_child(eb)
	var db = Button.new()
	db.text = "丢弃"
	db.pressed.connect(func(): c.visible = false; _n().send_weapon_choice(false))
	hb.add_child(db)
	return c

func _box(parent: Control, x: float, y: float, w: float, h: float) -> VBoxContainer:
	var vb = VBoxContainer.new()
	vb.position = Vector2(x + 10, y + 10)
	vb.size = Vector2(w - 20, h - 20)
	parent.add_child(vb)
	return vb

func _lbl(txt: String) -> Label:
	var l = Label.new()
	l.text = txt
	l.add_theme_color_override("font_color", Color.WHITE)
	return l

func _on_state_updated(state: Dictionary):
	_game_state = state
	if _n() == LocalGame:
		# 响应窗口期间扮演防守方，其他时间扮演当前回合玩家
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
		_card_info.text = ""
	_refresh_all(state)

func _refresh_all(state: Dictionary):
	_card_info.text = ""
	var pls = state.players
	if pls.size() < 2:
		return
	var opp = pls[0] if pls[0].index != _player_index else pls[1]
	var me = pls[0] if pls[0].index == _player_index else pls[1]
	opp_info.text = _fmt_player(opp, "对手")
	me_info.text = _fmt_player(me, "自己")
	var tp = ["判定", "摸牌", "出牌", "弃牌"]
	var tn = tp[state.get("turn_phase", 0)] if state.get("turn_phase", 0) < tp.size() else "?"
	var who = "你的回合" if _is_my_turn else "对手回合"
	phase_label.text = "T%d | %s | %s" % [state.turn_number, tn, who]

	for cell in _board_cells:
		var idx = cell.get_meta("index")
		var lbl = cell.get_child(0)
		lbl.text = str(idx)
		lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	for p in pls:
		var pos = p.position
		if pos >= 0 and pos < _board_cells.size():
			var lbl = _board_cells[pos].get_child(0)
			lbl.text = "P%d" % (p.index + 1)
			var col = Color(0.3, 1, 0.3) if p.index == _player_index else Color(1, 0.4, 0.4)
			lbl.add_theme_color_override("font_color", col)
	for t in state.get("traps", []):
		var pos = t.position
		if pos >= 0 and pos < _board_cells.size():
			_board_cells[pos].get_child(0).text += " X"

	for c in hand_area.get_children():
		c.queue_free()
	var mh = me.get("hand", [])
	if mh.is_empty():
		var el = _lbl("无手牌")
		el.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
		hand_area.add_child(el)
	else:
		var can_resp = state.get("response_pending", false) and state.current_player != _player_index
		var in_disc = state.get("waiting_for_discard", false) and _is_my_turn
		for card in mh:
			var tid = card.type_id
			var cd = Config.CARD_DB.get(tid, {})
			var cn = cd.get("name", tid)
			var al = ""
			match cd.get("ap", 0):
				Config.APType.ATTACK: al = "攻"
				Config.APType.MOVE: al = "移"
				Config.APType.FUNCTION: al = "功"
				_: al = "免"
			var cm = {"uid": card.uid, "type_id": tid, "can_respond": false, "discard_selected": card.uid in _discard_selected}
			if can_resp:
				var atk = state.get("pending_attack_card", "")
				if tid in ["magic"]:
					cm.can_respond = true
				elif tid in ["range"]:
					cm.can_respond = atk in ["range", "pierce", "magic", "chant"]
				elif tid in ["near"]:
					cm.can_respond = atk in ["near", "heavy"]
			var btn = Button.new()
			btn.text = "%s [%s]" % [cn, al]
			if in_disc and card.uid in _discard_selected:
				btn.text = "[弃] " + btn.text
			btn.size = Vector2(64, 64)
			btn.set_meta("card_data", cm)
			btn.pressed.connect(_on_card_clicked.bind(card.uid, tid))
			hand_area.add_child(btn)

	for c in _log_vbox.get_children():
		c.queue_free()
	var log = state.get("action_log", [])
	var r = log.slice(max(0, log.size() - 8))
	for e in r:
		var lb = _lbl("[T%d] %s: %s" % [e.get("turn", 0), e.get("player_name", "?"), e.get("msg", "")])
		lb.add_theme_font_size_override("font_size", 11)
		_log_vbox.add_child(lb)

	if state.get("response_pending", false) and state.current_player != _player_index:
		_show_resp_popup(state.get("pending_attack_card", ""))

	var in_discard = state.get("waiting_for_discard", false)
	if in_discard and _is_my_turn:
		var lim = me.get("hand_limit", 5)
		var hs = mh.size()
		end_turn_btn.text = "确认弃牌(%d张)" % _discard_selected.size()
		end_turn_btn.visible = true
		status_label.text = "弃牌阶段:点手牌选择,点确认弃牌提交"
		confirm_btn.visible = false
		cancel_btn.visible = true
	else:
		_discard_selected.clear()
		end_turn_btn.text = "结束出牌"
		end_turn_btn.visible = _is_my_turn
		if not _is_my_turn:
			confirm_btn.visible = false
			cancel_btn.visible = false

func _fmt_player(p, tag: String) -> String:
	var hp_pct = float(p.hp) / max(p.max_hp, 1)
	var bar = ""
	for _i in range(20):
		bar += "=" if (float(_i) / 20.0) < hp_pct else "-"
	var txt = "%s:%s HP:%d/%d[%s] 坐标:%d 近%d远%d魔%d 攻%d移%d功%d 手牌:%d/%d 堆:%d" % [
		tag, p.char_name, p.hp, p.max_hp, bar, p.position,
		p.near_power, p.range_power, p.magic_power,
		p.get("ap_attack", 0), p.get("ap_move", 0), p.get("ap_function", 0),
		p.hand_size, p.get("hand_limit", 5), p.deck_size
	]
	if not p.weapon.is_empty():
		txt += " 武器:" + p.weapon.data.name
	if not p.armor.is_empty():
		txt += " 防具:" + p.armor.data.name + "(%d/3)" % p.armor.durability
	if p.get("frozen", false):
		txt += " 冻结!"
	return txt

func _on_card_clicked(card_uid: int, type_id: String):
	var state = _game_state
	# 响应模式:直接发送选中卡作为响应
	if state.get("response_pending", false) and state.current_player != _player_index:
		_resp_popup.visible = false
		_n().send_response(true, card_uid)
		return
	if not _is_my_turn:
		return

	# 弃牌模式:切换选中
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
		_card_info.text = ""
	else:
		_selected_uid = card_uid
		_selected_type = type_id
		confirm_btn.visible = true
		cancel_btn.visible = true
		_card_info.text = Config.card_name(type_id) + ": " + Config.CARD_DB.get(type_id, {}).get("desc", "")
	_refresh_highlight()

func _on_confirm_card():
	if _selected_uid < 0:
		return
	if _selected_type in ["move", "destroy", "trap"]:
		match _selected_type:
			"move": _popup_move(_selected_uid)
			"destroy": _popup_destroy(_selected_uid)
			"trap": _popup_trap(_selected_uid)
		_selected_uid = -1
		confirm_btn.visible = false
	else:
		_n().send_play_card(_selected_uid)
		_selected_uid = -1
	confirm_btn.visible = false
	cancel_btn.visible = false

func _refresh_highlight():
	for child in hand_area.get_children():
		if child is Button:
			var cm = child.get_meta("card_data", {})
			var col = Color(1, 1, 0) if cm.get("uid", -1) == _selected_uid else Color.WHITE
			child.add_theme_color_override("font_color", col)

func _on_board_click(event: InputEvent, cell_index: int):
	if not (event is InputEventMouseButton):
		return
	if not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return
	if _selected_type != "trap" or not _is_my_turn:
		return
	_n().send_play_card(_selected_uid, {"trap_pos": cell_index})
	_selected_uid = -1
	_selected_type = ""
	confirm_btn.visible = false
	cancel_btn.visible = false

func _popup_move(card_uid: int):
	var c = Control.new()
	c.z_index = 10
	c.position = Vector2(0, 0)
	c.size = Vector2(800, 500)
	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(bg)
	var vb = VBoxContainer.new()
	vb.position = Vector2(260, 200)
	vb.size = Vector2(280, 140)
	c.add_child(vb)
	vb.add_child(_lbl("移动方向"))
	var hb = HBoxContainer.new()
	vb.add_child(hb)
	var lb = Button.new()
	lb.text = "向左"
	lb.pressed.connect(func(): c.queue_free(); _n().send_play_card(card_uid, {"direction": -1}))
	hb.add_child(lb)
	var rb = Button.new()
	rb.text = "向右"
	rb.pressed.connect(func(): c.queue_free(); _n().send_play_card(card_uid, {"direction": 1}))
	hb.add_child(rb)
	var cb = Button.new()
	cb.text = "取消"
	cb.pressed.connect(func(): c.queue_free())
	vb.add_child(cb)
	add_child(c)

func _popup_destroy(card_uid: int):
	var c = Control.new()
	c.z_index = 10
	c.position = Vector2(0, 0)
	c.size = Vector2(800, 500)
	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(bg)
	var vb = VBoxContainer.new()
	vb.position = Vector2(260, 180)
	vb.size = Vector2(280, 200)
	c.add_child(vb)
	vb.add_child(_lbl("摧毁: 选择目标"))
	var hb = Button.new()
	hb.text = "盲丢对方1手牌"
	hb.pressed.connect(func(): c.queue_free(); _n().send_play_card(card_uid, {"destroy_target": "hand"}))
	vb.add_child(hb)
	# 检查对方装备，只显示有效选项
	var pls = _game_state.players
	var opp = pls[0] if pls[0].index != _player_index else pls[1]
	if not opp.weapon.is_empty():
		var wb = Button.new()
		wb.text = "摧毁对方武器: " + opp.weapon.data.name
		wb.pressed.connect(func(): c.queue_free(); _n().send_play_card(card_uid, {"destroy_target": "equip", "equip_type": "weapon"}))
		vb.add_child(wb)
	if not opp.armor.is_empty():
		var ab = Button.new()
		ab.text = "摧毁对方防具: " + opp.armor.data.name
		ab.pressed.connect(func(): c.queue_free(); _n().send_play_card(card_uid, {"destroy_target": "equip", "equip_type": "armor"}))
		vb.add_child(ab)
	var traps_list = _game_state.get("traps", [])
	if traps_list.size() > 0:
		var tb = Button.new()
		tb.text = "摧毁场上陷阱(%d个)" % traps_list.size()
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

func _on_end_turn():
	if not _is_my_turn:
		return
	if _game_state.get("waiting_for_discard", false):
		_n().send_confirm_discard(_discard_selected.duplicate())
		_discard_selected.clear()
	else:
		_n().send_end_turn()
