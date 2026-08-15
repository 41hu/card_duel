# battle_ui.gd — 对战界面
extends Control

const Style = preload("res://scripts/theme/style_const.gd")
const CardWidget = preload("res://scripts/ui/components/card_widget.gd")
const MapGeometry = preload("res://scripts/core/map_geometry.gd")
const InfoPanel = preload("res://scripts/ui/components/info_panel.gd")

@onready var phase_label = $PhaseLabel
@onready var hand_area = $HandScroll/HandArea
@onready var end_turn_btn = $EndTurnBtn
@onready var confirm_btn = $ConfirmBtn
@onready var cancel_btn = $CancelBtn
@onready var status_label = $StatusLabel
@onready var board = $Board
@onready var action_log = $ActionLog

var _game_state: Dictionary = {}
var _player_index: int = -1
var _is_my_turn: bool = false
var _selected_uid: int = -1
var _selected_type: String = ""
var _hunter_pos1: Dictionary = {}  # 猎人埋伏（穿心）：第 1 个放置位置（{x,y}），空=未选
var _discard_selected: Array = []
@onready var card_info = $CardInfo
@onready var skill_row = $SkillRow
var _last_hp: Array = [-1, -1]
var _last_turn: int = -1
var _last_player: int = -1
var _board_hex: bool = false  # 棋盘当前是否六边形模式（多人局）
# 数据驱动玩家面板：自己面板（左下）+ 对手面板（右侧竖排，数量随玩家数动态增减）
# 彻底消除 me_info/opp_info 二元假设，2 人 / 4 人 / 未来 N 人统一走同一套渲染
var _self_panel: PanelContainer = null
var _opp_panels: Array = []
var _opp_indices: Array = []  # 与 _opp_panels 平行：每个面板对应的玩家 index（HP 闪烁/安全区定位用）
var _cheat_on: bool = false
var _timer_left: int = -1
var _resp_popup: Control
var tutorial = null  # 教程控制器（新手教程模式时非空）
var _wpn_popup: Control

func _n():
	if LocalGame.game != null: return LocalGame
	return Network

# ---------- 数据驱动：玩家查找（消除 players[0]/[1] 二元假设） ----------
# 从给定列表（默认 _game_state.players）找自己；找不到返回空字典。
# 关键：不再假设只有 2 个玩家，多人局（4 人）任意 index 都能正确命中。
func _find_self(pls: Array = []) -> Dictionary:
	if pls.is_empty():
		pls = _game_state.get("players", [])
	for p in pls:
		if p.get("index", -1) == _player_index:
			return p
	return {}

# 从给定列表找第一个对手（2 人局=唯一对手；多人局取第一个，用于单目标场景）
func _find_opponent(pls: Array = []) -> Dictionary:
	if pls.is_empty():
		pls = _game_state.get("players", [])
	for p in pls:
		if p.get("index", -1) != _player_index:
			return p
	return {}

func _ready():
	Style.scale_node_fonts(self)  # 移动端字号适配（tscn 写死的字号）
	board.cell_clicked.connect(_on_board_cell_clicked)
	_create_self_panel()
	_build_popups()
	# 日志加宽后左缘与棋盘第 0/1 格有重叠：PASS 让点按穿透到棋盘，
	# 拖动仍由 ScrollContainer 先处理（发生滚动时 accept，否则继续下传）
	action_log.mouse_filter = Control.MOUSE_FILTER_PASS
	end_turn_btn.pressed.connect(_on_end_turn)
	confirm_btn.pressed.connect(_on_confirm_card)
	cancel_btn.pressed.connect(_on_cancel_select)
	_n().state_updated.connect(_on_state_updated)
	_n().response_needed.connect(_on_response_needed)
	_n().hand_revealed.connect(_on_hand_revealed)
	_n().weapon_prompt.connect(_on_weapon_prompt)
	_n().game_ended.connect(_on_game_ended)
	_n().network_error.connect(_on_error)
	Network.server_disconnected.connect(_on_server_disconnected)
	var cached = _n().battle_state_cache
	if not cached.is_empty():
		_on_state_updated(cached)
		_n().battle_state_cache = {}
	_apply_safe_area()
	_setup_debug_button()
	# 新手教程模式：创建教程控制器（步骤引导/脚本对手/操作限制）
	if LocalGame.tutorial_mode:
		var tm = load("res://scripts/ui/tutorial_manager.gd").new()
		tm.battle = self
		tm.g = LocalGame.game
		add_child(tm)
		tutorial = tm

func _exit_tree():
	# 与其它场景风格对齐：显式断开全部信号，防未来节点复用累积重复连接
	var n = _n()
	if n.state_updated.is_connected(_on_state_updated):
		n.state_updated.disconnect(_on_state_updated)
	if n.response_needed.is_connected(_on_response_needed):
		n.response_needed.disconnect(_on_response_needed)
	if n.hand_revealed.is_connected(_on_hand_revealed):
		n.hand_revealed.disconnect(_on_hand_revealed)
	if n.weapon_prompt.is_connected(_on_weapon_prompt):
		n.weapon_prompt.disconnect(_on_weapon_prompt)
	if n.game_ended.is_connected(_on_game_ended):
		n.game_ended.disconnect(_on_game_ended)
	if n.network_error.is_connected(_on_error):
		n.network_error.disconnect(_on_error)
	if Network.server_disconnected.is_connected(_on_server_disconnected):
		Network.server_disconnected.disconnect(_on_server_disconnected)
	# 教程控制器随场景释放（其引导横幅/跳过按钮已挂在本节点下）

# 自己面板（左下角，动态创建，替代原场景 MeInfo 固定节点）
func _create_self_panel():
	var pc: PanelContainer = InfoPanel.new()
	pc.anchor_left = 0.0
	pc.anchor_top = 1.0
	pc.anchor_bottom = 1.0
	pc.offset_left = 16
	pc.offset_top = -220
	pc.offset_right = 594
	pc.offset_bottom = -20
	pc.status_clicked.connect(_on_status_clicked)
	add_child(pc)
	_self_panel = pc

# 调试菜单按钮（仅编辑器运行时显示，导出到真机不显示）：快速结束对局/发牌
func _setup_debug_button():
	if not OS.has_feature("editor"): return
	var dbg = Button.new()
	dbg.name = "DebugBtn"
	dbg.text = "调试"
	dbg.position = Vector2(12, 12)
	dbg.size = Vector2(140, 70)
	dbg.add_theme_font_size_override("font_size", Style.fs(26))
	dbg.pressed.connect(_show_debug_menu)
	add_child(dbg)

func _show_debug_menu():
	var c = Control.new()
	c.name = "DebugMenu"
	c.z_index = 15
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new()
	bg.name = "DebugBg"
	bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.add_child(bg)
	var vb = _popup_box(c, 480, 420)
	vb.name = "DebugBox"
	vb.add_child(_lbl("调试菜单"))
	var win = _mkbtn("立即胜利")
	win.name = "DebugWinBtn"
	win.pressed.connect(func():
		c.queue_free()
		_n().send_use_skill("_debug_end", {"win": true})
	)
	vb.add_child(win)
	var lose = _mkbtn("立即失败")
	lose.name = "DebugLoseBtn"
	lose.pressed.connect(func():
		c.queue_free()
		_n().send_use_skill("_debug_end", {"win": false})
	)
	vb.add_child(lose)
	var deal = _mkbtn("随机发5张牌")
	deal.name = "DebugDealBtn"
	deal.pressed.connect(func():
		c.queue_free()
		var keys = Config.CARD_DB.keys()
		for i in range(5):
			_n().send_use_skill("_cheat", {"type_id": keys[randi() % keys.size()]})
	)
	vb.add_child(deal)
	var close = _mkbtn("关闭")
	close.name = "DebugCloseBtn"
	close.pressed.connect(func(): c.queue_free())
	vb.add_child(close)
	add_child(c)

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
	var _top = sa.position.y / sy
	var bottom = (win.y - sa.end.y) / sy
	if left > 0:
		_self_panel.offset_left = left + 12
		skill_row.offset_left += left
		skill_row.offset_right += left
		action_log.offset_left += left
		action_log.offset_right += left
	if right > 0:
		for p in _opp_panels:
			p.offset_right = -(right + 12)
	if bottom > 0:
		end_turn_btn.offset_top -= bottom
		end_turn_btn.offset_bottom -= bottom
		skill_row.offset_top -= bottom
		skill_row.offset_bottom -= bottom

func _input(event):
	if not OS.has_feature("editor"): return  # F12 作弊仅在编辑器运行时有效
	if not event is InputEventKey or not event.pressed: return
	if event.keycode == KEY_F12: _cheat_on = not _cheat_on; return
	if not _cheat_on or not _is_my_turn: return
	var cheat = {KEY_F1: "near", KEY_F2: "range", KEY_F3: "magic", KEY_F4: "heavy", KEY_F5: "range_weapon", KEY_F6: "magic_weapon", KEY_F7: "move", KEY_F8: "blessing", KEY_F9: "heal_3", KEY_F10: "near_weapon"}
	if event.keycode in cheat:
		_n().send_use_skill("_cheat", {"type_id": cheat[event.keycode]})

# 状态槽/角色名/装备点击（移动端无 hover）：详情显示到状态栏，3 秒自动消失
func _on_status_clicked(text: String):
	status_label.text = text
	_status_msg_timer = 3.0

func _on_cancel_select():
	_selected_uid = -1
	_selected_type = ""  # 清类型：残留会导致点棋盘误发 play_card（"手牌中没有此卡"）
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
	var box = _box(c, 140, 100, 720, 520)
	box.name = "RespBox"
	# 多段攻击显示段号（如 第1/2段）
	var seg = int(_game_state.get("pending_attack_segment", 0))
	var segs = int(_game_state.get("pending_attack_segments", 1))
	var seg_txt = "（第%d/%d段）" % [seg, segs] if segs > 1 else ""
	var t = _lbl("对方使用「%s」攻击%s！选择响应卡：" % [Config.card_name(atk_card), seg_txt])
	t.add_theme_font_size_override("font_size", Style.fs(30))
	t.add_theme_color_override("font_color", Color(1, 0.9, 0.6))
	t.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	t.add_theme_constant_override("outline_size", Style.fs(5))
	box.add_child(t)
	var has_any = false
	var defender_hand = []
	var defender = {}
	# 防守方 = 攻击目标（state.pending_target）；旧状态无此字段时兜底取第一个非攻击者
	var target_idx = int(_game_state.get("pending_target", -1))
	for p in _game_state.players:
		if p.index == target_idx or (target_idx < 0 and p.index != _game_state.current_player):
			defender_hand = p.get("hand", [])
			defender = p
			break
	# 牵制减免值（与服务端一致：远程面板-距离，连弩+2）
	var dist = int(_game_state.get("distance", 0))
	var restrain_value = max(0, int(defender.get("range_power", 0)) - dist)
	if not defender.get("weapon", {}).is_empty() and defender.weapon.id == "repeater":
		restrain_value += 2
	for card in defender_hand:
		var tid = card.type_id
		var ok = false
		var effect = ""
		if tid in ["magic"]:
			ok = true
			# 冻结需用魔法闪避；其他攻击闪避免疫伤害
			effect = "闪避：免疫此次%s" % ("冻结" if atk_card == "freeze" else "伤害")
		elif tid in ["range"] and atk_card in ["range", "pierce", "magic", "chant"]:
			ok = true
			effect = "牵制：减免%d伤害" % restrain_value
		elif tid in ["near"] and atk_card in ["near", "heavy"]:
			ok = true
			effect = "格挡：伤害减半"
		if ok:
			has_any = true
			var rb = _mkbtn("  %s（%s）  " % [Config.card_name(tid), effect])
			rb.custom_minimum_size = Vector2(380, 110)
			rb.add_theme_font_size_override("font_size", Style.fs(34))
			rb.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
			rb.add_theme_constant_override("outline_size", Style.fs(5))
			rb.pressed.connect(func(uid=card.uid): c.visible = false; _n().send_response(true, uid))
			box.add_child(rb)
	# 教程强制响应步骤：隐藏"不响应"（引导玩家必须响应）
	if tutorial != null and tutorial.force_response():
		var tip = _lbl("请选择一张响应卡（教程步骤）")
		tip.add_theme_font_size_override("font_size", Style.fs(26))
		tip.add_theme_color_override("font_color", Color(1, 0.9, 0.5))
		box.add_child(tip)
	else:
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

func _box(parent: Control, _x: float, _y: float, w: float, h: float) -> VBoxContainer:
	# _x/_y 已废弃（原实现未使用），统一走滚动弹窗框架
	return _popup_box(parent, w, h)

func _popup_box(parent: Control, w: float, h: float) -> VBoxContainer:
	# 居中滚动弹窗：内容超出时滚动，最大占屏幕 92%，适配手机小屏
	var vp = get_viewport_rect().size
	w = min(w, vp.x * 0.92)
	h = min(h, vp.y * 0.92)
	var sc = ScrollContainer.new()
	sc.name = "PopupScroll"
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

func _lbl(txt: String) -> Label:
	var l = Label.new()
	l.text = txt
	l.add_theme_color_override("font_color", Style.LOG_TEXT)
	l.add_theme_font_size_override("font_size", Style.fs(28))
	return l

func _mkbtn(txt: String) -> Button:
	var b = Button.new()
	b.text = txt
	b.custom_minimum_size = Vector2(220, 100)
	b.add_theme_font_size_override("font_size", Style.fs(32))
	return b

func _on_state_updated(state: Dictionary):
	_game_state = state
	if _n() == LocalGame:
		if LocalGame.tutorial_mode:
			# 教程：固定玩家 P0 视角（对手回合不泄露手牌）
			_player_index = 0
			_is_my_turn = (state.current_player == 0 and state.phase == Config.Phase.PLAYER_TURN)
		elif LocalGame.ai_mode:
			# 人机对战：人类固定 P0 视角（否则 AI 回合会泄露 AI 手牌）
			_player_index = 0
			_is_my_turn = (state.current_player == 0 and state.phase == Config.Phase.PLAYER_TURN)
		else:
			# 自我对战：轮流操作，视角跟随当前回合玩家
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
	# 状态详情（点击角色名/装备/状态槽）自动消失
	if _status_msg_timer > 0:
		_status_msg_timer -= delta
		if _status_msg_timer <= 0:
			_status_msg_timer = 0
			status_label.text = ""
	if _timer_left <= 0:
		return
	_timer_elapsed += delta
	if _timer_elapsed >= 1.0:
		_timer_elapsed -= 1.0
		_timer_left -= 1
		if _timer_left < 0: _timer_left = -1
		_update_timer_label()

var _timer_elapsed: float = 0.0
var _status_msg_timer: float = 0.0

func _refresh_all(state: Dictionary):
	card_info.text = ""
	var pls = state.players
	if pls.size() < 2:
		return
	# 多人局：棋盘切换六边形模式（模式不变时 BoardRenderer 内部跳过重建）
	var want_hex = pls.size() > 2
	if want_hex != _board_hex:
		_board_hex = want_hex
		board.set_geometry_mode(MapGeometry.MODE_HEX if want_hex else MapGeometry.MODE_LINEAR)
	# 分区式布局：棋盘居中于中列（左战报 300、右对手面板 460 之间，中心 x≈900）。
	# 每次刷新都应用（不能只在模式切换时，否则首次进入 2 人局保持 tscn 旧尺寸 1440×760）
	# 2 人局线性棋盘 1100×160（11 格×100）；4 人局六边形棋盘 900×640
	if want_hex:
		board.offset_left = -510; board.offset_right = 390
		board.offset_top = -380; board.offset_bottom = 260
	else:
		board.offset_left = -610; board.offset_right = 490
		board.offset_top = -140; board.offset_bottom = 20
	# HP 闪烁记录数组按玩家数扩展（4 人局原 2 元素会越界）
	while _last_hp.size() < pls.size():
		_last_hp.append(-1)
	# 数据驱动玩家面板：自己面板 + 所有对手面板（数量随玩家数动态，2/4/N 人统一）
	var me = _find_self(pls)
	_self_panel.refresh(me, "自己", Color(0.5, 0.8, 1))
	_refresh_opp_panels(pls)
	for p in pls:
		if p.hp != _last_hp[p.index]:
			var panel = _panel_for(int(p.index))
			if panel != null:
				panel.flash_hp(p.hp > _last_hp[p.index])
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

	board.update(pls, state.get("items", []), _player_index)

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
			# 通用道具卡：卡面按角色道具显示（猎人手里显示"捕兽夹"而非"陷阱"）
			var cname = cd.get("name", tid)
			if tid == "trap":
				cname = me.get("item_type_name", cname)
			# 注意：网络 JSON 传输后 uid 是 float，而 CardWidget.setup(uid: int) 强转 int，
			# 必须统一 int 比较（`in` 是严格类型匹配，37.0 in [37] 为 false → 弃牌红框不显示）
			cw.setup(card.uid, tid, cname, cd.get("ap", 0), int(card.uid) in _discard_selected)
			cw.pressed.connect(_on_card_clicked.bind(tid))
			if can_resp:
				var atk = state.get("pending_attack_card", "")
				if tid in ["magic"]: cw.set_respondable(true)
				elif tid in ["range"]: cw.set_respondable(atk in ["range", "pierce", "magic", "chant"])
				elif tid in ["near"]: cw.set_respondable(atk in ["near", "heavy"])
			if in_disc and int(card.uid) in _discard_selected:
				cw.set_discard_mark(true)
			if card.uid == _selected_uid:
				cw.set_selected(true)
			hand_area.add_child(cw)

	action_log.show_logs(state.get("action_log", []), 8, _player_index)

	if state.get("revealed_to", -1) == _player_index:
		_on_hand_revealed(state.get("revealed_hand", []), int(state.get("revealed_from", -1)))

	if state.get("response_pending", false) and state.current_player != _player_index:
		_show_resp_popup(state.get("pending_attack_card", ""))

	var in_discard = state.get("waiting_for_discard", false)
	if in_discard and _is_my_turn:
		var need = me.get("hand", []).size() - me.get("hand_limit", 5)
		var txt = "确认弃牌(%d张)" % _discard_selected.size()
		end_turn_btn.text = txt; end_turn_btn.visible = true
		_status_msg_timer = 0  # 弃牌提示常驻，不被详情自动消失误清
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
		_status_msg_timer = 0
		status_label.text = ""
		_refresh_skill_row(me)
		if me.get("pending_fighter_skill", false):
			_show_fighter_popup()

func _on_card_clicked(card_uid: int, type_id: String):
	var state = _game_state
	if state.get("response_pending", false) and state.current_player != _player_index:
		_resp_popup.visible = false
		_n().send_response(true, card_uid)
		return
	if not _is_my_turn:
		return
	# 教程限制：当前步骤不允许的卡不响应点击
	if tutorial != null and not tutorial.allow_card_click(card_uid, type_id):
		status_label.text = "当前步骤请按引导操作"
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
		# 通用道具卡：点击说明按角色道具显示（道具名 + 效果描述）
		if type_id == "trap":
			var me2 = _find_self()
			card_info.text = "%s：%s" % [me2.get("item_type_name", "道具"), me2.get("item_type_desc", "")]
		else:
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
		elif _is_armor_override(_selected_type):
			_show_armor_override_confirm(_selected_uid)
			_selected_uid = -1
		elif _is_targeted_card(_selected_type) and _game_state.players.size() > 2:
			_show_target_pick(_selected_uid, _selected_type)
			_selected_uid = -1
		else:
			_n().send_play_card(_selected_uid)
			_selected_uid = -1
	confirm_btn.visible = false
	cancel_btn.visible = false

# 数据驱动对手面板：右侧竖排，数量随对手数动态（2 人局 1 个，4 人局 3 个）
func _refresh_opp_panels(pls: Array):
	var opps := []
	for p in pls:
		if p.get("index", -1) != _player_index:
			opps.append(p)
	var need = opps.size()
	while _opp_panels.size() < need:
		_opp_panels.append(_make_opp_panel(_opp_panels.size()))
		_opp_indices.append(-1)
	while _opp_panels.size() > need:
		_opp_panels.pop_back().queue_free()
		_opp_indices.pop_back()
	for i in range(need):
		_opp_indices[i] = int(opps[i].index)
		_update_opp_panel(_opp_panels[i], opps[i])

# 指定玩家索引 → 其面板（自己 → 左下；对手 → 右侧竖排对应项）；找不到返回 null
func _panel_for(index: int) -> PanelContainer:
	if index == _player_index:
		return _self_panel
	var pos = _opp_indices.find(index)
	if pos >= 0 and pos < _opp_panels.size():
		return _opp_panels[pos]
	return null

func _make_opp_panel(slot: int) -> PanelContainer:
	var pc: PanelContainer = InfoPanel.new()
	pc.anchor_left = 1.0; pc.anchor_right = 1.0
	pc.offset_left = -460; pc.offset_right = 0
	pc.offset_top = 150 + slot * 206
	pc.offset_bottom = 350 + slot * 206
	pc.status_clicked.connect(_on_status_clicked)
	add_child(pc)
	return pc

func _update_opp_panel(pc: PanelContainer, p: Dictionary):
	var tag = "P%d %s" % [p.index + 1, p.get("char_name", "?")]
	if p.get("eliminated", false):
		tag += "（已淘汰）"
	pc.refresh(p, tag, Color(1, 0.7, 0.5))

# 指向性卡（多人局需要选择目标）：攻击/吸引/威慑/冻结/摧毁/夺取
func _is_targeted_card(type_id: String) -> bool:
	return type_id in ["near", "heavy", "range", "pierce", "magic", "chant",
		"attract", "deter", "freeze", "destroy", "seize"]

# 多人局：指向卡弹出目标选择（列所有存活对手：名字/HP/位置）
# extra：目标外的附加参数（如摧毁手牌/装备的 destroy_target 等）
func _show_target_pick(card_uid: int, type_id: String, extra: Dictionary = {}):
	var c = Control.new()
	c.name = "TargetPick"
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 560, 460)
	vb.add_child(_lbl("选择「%s」的目标：" % Config.card_name(type_id)))
	var any = false
	for p in _game_state.players:
		if p.index == _player_index or p.get("eliminated", false): continue
		any = true
		var pos = p.get("position", {})
		var pos_str = "%d,%d" % [pos.get("x", 0), pos.get("y", 0)]
		var b = _mkbtn("P%d %s  HP:%d/%d  格(%s)" % [p.index + 1, p.get("char_name", "?"), p.get("hp", 0), p.get("max_hp", 1), pos_str])
		b.pressed.connect(func(pid = p.index):
			c.queue_free()
			var send_extra = {"target": pid}
			for k in extra: send_extra[k] = extra[k]
			_n().send_play_card(card_uid, send_extra)
		)
		vb.add_child(b)
	if not any:
		vb.add_child(_lbl("没有可攻击的目标"))
	var close = _mkbtn("取消")
	close.pressed.connect(func(): c.queue_free())
	vb.add_child(close)
	add_child(c)

# 已有防具时再装备防具卡：弹确认（旧防具会被直接覆盖消失）
func _is_armor_override(type_id: String) -> bool:
	if not type_id.ends_with("_armor"): return false
	var me = _find_self()
	return not me.get("armor", {}).is_empty()

func _show_armor_override_confirm(card_uid: int):
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 640, 400)
	var me = _find_self()
	var old_name = me.get("armor", {}).get("data", {}).get("name", "防具")
	vb.add_child(_lbl("已装备防具「%s」\n新防具会覆盖旧防具（旧防具直接消失），确定装备？" % old_name))
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_theme_constant_override("separation", 24)
	var ok = _mkbtn("确定装备")
	ok.pressed.connect(func():
		c.queue_free()
		_n().send_play_card(card_uid)
	)
	hb.add_child(ok)
	var no = _mkbtn("取消")
	no.pressed.connect(func(): c.queue_free())
	hb.add_child(no)
	vb.add_child(hb)
	add_child(c)

func _has_matching_armor(attack_type: String) -> bool:
	var armor_needed = {"near": "physical", "heavy": "physical", "range": "ranged", "pierce": "ranged", "magic": "magical", "chant": "magical"}
	var need = armor_needed.get(attack_type, "")
	if need == "": return false
	for p in _game_state.players:
		if p.index != _player_index and not p.armor.is_empty():
			return p.armor.data.type == need
	return false

func _show_armor_confirm(card_uid: int, _attack_type: String):
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 700, 340)
	var armor_name = ""
	var is_full_durability = false
	for p in _game_state.players:
		if p.index != _player_index and not p.armor.is_empty():
			armor_name = p.armor.data.name
			is_full_durability = p.armor.durability >= p.armor.get("max_durability", 3)
			break
	vb.add_child(_lbl("对方装备了%s" % armor_name))
	# 按耐久区分提示：满耐久才完全免疫，其余是减免一半
	vb.add_child(_lbl("此次攻击将被完全免疫" if is_full_durability else "此次攻击将被减免一半"))
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

func _on_board_cell_clicked(cell_pos: Vector2i):
	# 教程限制：当前步骤只允许特定格子放夹子（穿心/陷阱），保证教学流程可控
	if tutorial != null and _selected_type in ["hunter_ambush", "trap"]:
		var allowed = tutorial.allowed_trap_positions()
		if not allowed.is_empty() and not cell_pos in allowed:
			status_label.text = "夹子只能放在教学指定的格子"
			return
	var pos_dict := {"x": cell_pos.x, "y": cell_pos.y}
	if _selected_type == "hunter_ambush" and _is_my_turn:
		# 穿心：已选第 1 个位置，本次为第 2 个 → 发送放置
		if not _hunter_pos1.is_empty():
			_n().send_use_skill("hunter_ambush", {"card_uid": _selected_uid, "pos": _hunter_pos1, "pos2": pos_dict})
			_hunter_pos1 = {}
			_selected_uid = -1
			_selected_type = ""
			confirm_btn.visible = false
			cancel_btn.visible = false
			card_info.text = ""
			status_label.text = ""
			return
		# 判断所选卡是否为穿心（穿心需连续选 2 个放置位置）
		var me = _find_self()
		var is_pierce = false
		for card in me.get("hand", []):
			# _game_state 是 JSON 化状态，uid 是 float，需 int 强转后比较
			if int(card.uid) == _selected_uid and card.type_id == "pierce":
				is_pierce = true
				break
		if is_pierce:
			_hunter_pos1 = pos_dict
			status_label.text = "选择第2个捕兽夹位置"
			return
		_n().send_use_skill("hunter_ambush", {"card_uid": _selected_uid, "pos": pos_dict})
		_selected_uid = -1
		_selected_type = ""
		confirm_btn.visible = false
		cancel_btn.visible = false
		card_info.text = ""
		status_label.text = ""
		return
	if _selected_type == "destroy_trap" and _is_my_turn:
		_n().send_play_card(_selected_uid, {"destroy_target": "trap", "trap_pos": pos_dict})
		_selected_uid = -1
		_selected_type = ""
		confirm_btn.visible = false
		cancel_btn.visible = false
		card_info.text = ""
		status_label.text = ""
		return
	if _selected_type != "trap" or not _is_my_turn:
		return
	_n().send_play_card(_selected_uid, {"trap_pos": pos_dict})
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
	# 哨兵 -1 = 技能调用（暗影步）；调试发牌卡 uid 为负数（-1000 递减），必须走 play_card
	# 教程：限制可选移动方向（线性：左右；六边形教程不涉及）
	var dirs = [1, -1]
	if tutorial != null:
		dirs = tutorial.allowed_move_dirs()
	if _board_hex:
		# 六边形：米字格布局（3×3，方向按视觉位置摆放，中间是取消）
		#  西北  [北]  东北
		#  西   [取消] 东
		#  西南  [南]  东南
		# 注意：六边形没有正北/正南方向（尖顶朝上只有 6 个邻居），
		# 上中/下中放灰掉的占位按钮保持米字格视觉对齐
		var grid = GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 16)
		grid.add_theme_constant_override("v_separation", 10)
		vb.add_child(grid)
		# 行优先填入（与米字格位置一一对应）；占位项点击无效
		var cells = [
			["西北", Vector2i(0, -1), false],
			["北", Vector2i.ZERO, true],
			["东北", Vector2i(1, -1), false],
			["西", Vector2i(-1, 0), false],
			["取消", Vector2i.ZERO, true],
			["东", Vector2i(1, 0), false],
			["西南", Vector2i(-1, 1), false],
			["南", Vector2i.ZERO, true],
			["东南", Vector2i(0, 1), false],
		]
		for cell in cells:
			var text: String = cell[0]
			var dir: Vector2i = cell[1]
			var placeholder: bool = cell[2]
			if text == "取消":
				var cb = _mkbtn("取消")
				cb.pressed.connect(func(): c.queue_free())
				grid.add_child(cb)
				continue
			if placeholder:
				var d = _mkbtn(text)
				d.disabled = true
				grid.add_child(d)
				continue
			var b = _mkbtn("%s1格" % text)
			b.pressed.connect(func(dd=dir):
				c.queue_free()
				_send_move(card_uid, dd)
			)
			grid.add_child(b)
	else:
		var hb = HBoxContainer.new()
		vb.add_child(hb)
		var lb = _mkbtn("左1格")
		lb.visible = -1 in dirs
		lb.pressed.connect(func(): c.queue_free(); _send_move(card_uid, Vector2i(-1, 0)))
		hb.add_child(lb)
		var rb = _mkbtn("右1格")
		rb.visible = 1 in dirs
		rb.pressed.connect(func(): c.queue_free(); _send_move(card_uid, Vector2i(1, 0)))
		hb.add_child(rb)
	var cb = _mkbtn("取消")
	cb.pressed.connect(func(): c.queue_free())
	vb.add_child(cb)
	add_child(c)

# 移动/暗影步方向发送统一出口（card_uid == -1 表示暗影步技能）
func _send_move(card_uid: int, dir: Vector2i):
	if card_uid == -1:
		_n().send_use_skill("assassin_move", {"direction": {"x": dir.x, "y": dir.y}})
	else:
		_n().send_play_card(card_uid, {"direction": {"x": dir.x, "y": dir.y}, "steps": 1})

func _popup_destroy(card_uid: int):
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 700, 440)
	vb.add_child(_lbl("摧毁: 选择目标"))
	var multi = _game_state.players.size() > 2  # 多人局：选完摧毁类型再选目标
	var hb = _mkbtn("盲丢对方1手牌")
	hb.pressed.connect(func():
		c.queue_free()
		if multi:
			_show_target_pick(card_uid, "destroy", {"destroy_target": "hand"})
		else:
			_n().send_play_card(card_uid, {"destroy_target": "hand"})
	)
	vb.add_child(hb)
	var pls = _game_state.players
	# 多人局：武器/防具按钮始终显示（点选目标后由核心校验目标是否有对应装备）
	var opp = _find_opponent(pls)
	if multi or not opp.weapon.is_empty():
		var wb = _mkbtn("摧毁对方武器" + ((": " + opp.weapon.data.name) if not opp.weapon.is_empty() else ""))
		wb.pressed.connect(func():
			c.queue_free()
			if multi:
				_show_target_pick(card_uid, "destroy", {"destroy_target": "equip", "equip_type": "weapon"})
			else:
				_n().send_play_card(card_uid, {"destroy_target": "equip", "equip_type": "weapon"})
		)
		vb.add_child(wb)
	if multi or not opp.armor.is_empty():
		var ab = _mkbtn("摧毁对方防具" + ((": " + opp.armor.data.name) if not opp.armor.is_empty() else ""))
		ab.pressed.connect(func():
			c.queue_free()
			if multi:
				_show_target_pick(card_uid, "destroy", {"destroy_target": "equip", "equip_type": "armor"})
			else:
				_n().send_play_card(card_uid, {"destroy_target": "equip", "equip_type": "armor"})
		)
		vb.add_child(ab)
	var traps_list = _game_state.get("items", [])
	if traps_list.size() > 0:
		var tb = _mkbtn("摧毁道具：点击棋盘指定格子(%d个)" % traps_list.size())
		tb.pressed.connect(func(): c.queue_free(); _enter_destroy_trap(card_uid))
		vb.add_child(tb)
	add_child(c)

# 摧毁陷阱：进入棋盘选格模式（复用放陷阱的格子点击交互）
func _enter_destroy_trap(card_uid: int):
	_selected_uid = card_uid
	_selected_type = "destroy_trap"
	cancel_btn.visible = true
	card_info.text = "点击棋盘上有道具的格子进行摧毁"
	status_label.text = "点击棋盘上有道具的格子进行摧毁"

func _popup_trap(card_uid: int):
	status_label.text = "已选陷阱,点击棋盘格子放置"
	_selected_uid = card_uid
	_selected_type = "trap"

func _on_response_needed(data: Dictionary):
	# 教程接管响应：对手自动不响应 / 复活步骤自动跳过
	if tutorial != null and tutorial.handle_response_needed():
		return
	var atk = data.get("card", "")
	status_label.text = "对方发动%s攻击！" % atk
	_show_resp_popup(atk)

func _on_weapon_prompt(weapon: Dictionary):
	var wd = weapon.get("data", {})
	_wpn_popup.find_child("WpnTitle", true, false).text = "获得武器: " + wd.get("name", "?")
	_wpn_popup.find_child("WpnDesc", true, false).text = wd.get("desc", "")
	_wpn_popup.visible = true

func _on_game_ended(r: Dictionary):
	if LocalGame.tutorial_mode:
		return  # 教程：反杀后由教程控制器继续（切猎人段），不跳结算页
	_n().last_game_result = r
	get_tree().change_scene_to_file("res://scenes/settlement.tscn")

func _on_error(msg: String):
	status_label.text = "错误: " + msg

func _on_server_disconnected():
	status_label.text = "连接断开，1秒后返回主菜单..."
	await get_tree().create_timer(1.0).timeout
	if is_instance_valid(self):
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _exec_skill(sk_id: String):
	if tutorial != null and not tutorial.allow_skill(sk_id):
		status_label.text = "当前步骤请按引导操作"
		return
	if sk_id == "mage_discard": _show_mage_pick()
	elif sk_id == "assassin_move": _popup_move(-1)
	elif sk_id == "hunter_ambush": _show_hunter_pick()
	elif sk_id == "wardsmith_imbue": _show_wardsmith_imbue()
	elif sk_id == "wardsmith_repair": _show_wardsmith_repair()
	elif sk_id == "spellblade_channel": _show_spellblade_pick()
	else: _n().send_use_skill(sk_id)

# 铸甲师护甲注魔：直接选择一种护甲装备（限一次，不耗卡）
func _show_wardsmith_imbue():
	var c = Control.new()
	c.name = "WardsmithImbue"
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 560, 380)
	vb.add_child(_lbl("护甲注魔：选择要装备的护甲（限一次）"))
	var options = [["near_armor", "近战防具"], ["range_armor", "远程防具"], ["magic_armor", "法术防具"]]
	for opt in options:
		var b = _mkbtn(opt[1])
		b.pressed.connect(func(at=opt[0]): c.queue_free(); _n().send_use_skill("wardsmith_imbue", {"armor_type": at}))
		vb.add_child(b)
	var close = _mkbtn("取消")
	close.pressed.connect(func(): c.queue_free())
	vb.add_child(close)
	add_child(c)

# 铸甲师修复：选一张与装备护甲匹配的重击/穿心/吟唱（耗2攻击点，修复1点耐久）
func _show_wardsmith_repair():
	var c = Control.new()
	c.name = "WardsmithRepair"
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 620, 420)
	var me = _find_self()
	var armor = me.get("armor", {})
	var expect_type = ""
	var armor_name = "未知护甲"
	if not armor.is_empty():
		var aid = armor.get("id", "")
		if Config.ARMOR_DB.has(aid): armor_name = Config.ARMOR_DB[aid].name
		match aid:
			"near_armor": expect_type = "heavy"
			"range_armor": expect_type = "pierce"
			"magic_armor": expect_type = "chant"
	vb.add_child(_lbl("修复：选择%s（耗2攻击点，耐久+1）" % armor_name))
	var has_any = false
	for card in me.get("hand", []):
		if card.type_id == expect_type:
			has_any = true
			var b = _mkbtn(Config.card_name(card.type_id))
			b.pressed.connect(func(uid=card.uid): c.queue_free(); _n().send_use_skill("wardsmith_repair", {"card_uid": uid}))
			vb.add_child(b)
	if not has_any:
		vb.add_child(_lbl("没有匹配的强化攻击牌"))
	var close = _mkbtn("取消")
	close.pressed.connect(func(): c.queue_free())
	vb.add_child(close)
	add_child(c)

# 猎人埋伏：第一步选一张远程攻击牌 → 进入选格放置
func _show_hunter_pick():
	var c = Control.new()
	c.name = "HunterPick"
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 560, 460)
	vb.add_child(_lbl("埋伏：选择一张远程攻击牌"))
	var me = _find_self()
	var has_any = false
	for card in me.get("hand", []):
		if card.type_id in ["range", "pierce"]:
			has_any = true
			var b = _mkbtn(Config.card_name(card.type_id))
			b.pressed.connect(func(uid=card.uid): c.queue_free(); _enter_hunter_pos(uid))
			vb.add_child(b)
	if not has_any:
		vb.add_child(_lbl("没有远程攻击牌"))
	var close = _mkbtn("取消")
	close.pressed.connect(func(): c.queue_free())
	vb.add_child(close)
	add_child(c)

# 魔剑士魔力引导：选一张魔法/吟唱卡（装备近战武器时按钮才亮）
func _show_spellblade_pick():
	var c = Control.new()
	c.name = "SpellbladePick"
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 620, 420)
	vb.add_child(_lbl("魔力引导：选择魔法/吟唱（无视距离打出近战/重击）"))
	var me = _find_self()
	var has_any = false
	for card in me.get("hand", []):
		if card.type_id in ["magic", "chant"]:
			has_any = true
			var b = _mkbtn(Config.card_name(card.type_id))
			b.pressed.connect(func(uid=card.uid): c.queue_free(); _n().send_use_skill("spellblade_channel", {"card_uid": uid}))
			vb.add_child(b)
	if not has_any:
		vb.add_child(_lbl("没有魔法/吟唱卡"))
	var close = _mkbtn("取消")
	close.pressed.connect(func(): c.queue_free())
	vb.add_child(close)
	add_child(c)

# 猎人埋伏：第二步进入棋盘选格（复用陷阱落点流程）
func _enter_hunter_pos(card_uid: int):
	_selected_uid = card_uid
	_selected_type = "hunter_ambush"
	_hunter_pos1 = {}
	cancel_btn.visible = true
	status_label.text = "选择捕兽夹放置位置"

# 技能按钮行：每个主动技能一个按钮直接使用（多技能角色并排显示，3+ 技能自动加宽）
func _refresh_skill_row(me: Dictionary):
	for c in skill_row.get_children():
		skill_row.remove_child(c)  # 立即移除（queue_free 延迟删除，同帧多次刷新会残留重复按钮）
		c.queue_free()
	var skills = me.get("active_skills", [])
	if not _is_my_turn or skills.is_empty():
		skill_row.visible = false
		return
	skill_row.visible = true
	for sk in skills:
		var b = Button.new()
		b.text = sk.get("name", sk.get("id", "技能"))
		b.add_theme_font_size_override("font_size", Style.fs(28))
		b.custom_minimum_size = Vector2(150, 110)
		b.tooltip_text = sk.get("desc", "")  # 悬停/长按显示技能完整描述（含限制如"不能推人"）
		b.pressed.connect(func(sid = sk.id): _exec_skill(sid))
		skill_row.add_child(b)

func _show_mage_pick():
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 700, 460)
	vb.add_child(_lbl("选择一张要弃的牌（魔法强化+2，可叠加，打出魔法攻击后清除）："))
	var mh = _find_self().get("hand", [])
	for card in mh:
		var b = _mkbtn(Config.card_name(card.type_id))
		b.pressed.connect(func(uid=card.uid): c.queue_free(); _n().send_use_skill("mage_discard", {"card_uid": uid}))
		vb.add_child(b)
	var cb = _mkbtn("取消"); cb.pressed.connect(func(): c.queue_free()); vb.add_child(cb)
	add_child(c)

func _on_hand_revealed(cards: Array, from_idx: int = -1):
	var c = Control.new()
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 640, 460)
	# 多人局明确"谁"的手牌（鹰眼等查看效果）
	var who = "对方"
	for p in _game_state.players:
		if p.index == from_idx:
			who = "P%d %s" % [from_idx + 1, p.get("char_name", "?")]
			break
	vb.add_child(_lbl("%s的手牌：" % who))
	if cards.is_empty():
		vb.add_child(_lbl("  (无手牌)"))
	else:
		for tid in cards:
			vb.add_child(_lbl("  " + Config.card_name(tid)))
	var cb = _mkbtn("关闭")
	cb.pressed.connect(func(): c.queue_free()); vb.add_child(cb)
	add_child(c)

func _show_fighter_popup():
	# 场景切换/结束瞬间状态刷新会触发：battle_ui 已离树，跳过避免 get_viewport_rect 报错
	if not is_inside_tree():
		return
	# 防堆叠：状态刷新会多次触发，先移除旧弹窗
	var old = get_node_or_null("SwordsmanPopup")
	if old: old.queue_free()
	var c = Control.new()
	c.name = "SwordsmanPopup"
	c.z_index = 10; c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg = ColorRect.new(); bg.color = Style.POPUP_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); c.add_child(bg)
	var vb = _popup_box(c, 620, 320)
	vb.add_child(_lbl("斗士技能: 近战命中后"))
	var hb = HBoxContainer.new(); vb.add_child(hb)
	var hbtn = _mkbtn("回2HP")
	hbtn.pressed.connect(func(): c.queue_free(); _n().send_fighter_choice("heal"))
	hb.add_child(hbtn)
	var dbtn = _mkbtn("抽1张牌")
	dbtn.pressed.connect(func(): c.queue_free(); _n().send_fighter_choice("draw"))
	hb.add_child(dbtn)
	add_child(c)

func _on_end_turn():
	if not _is_my_turn:
		return
	if tutorial != null and not tutorial.allow_end_turn():
		status_label.text = "当前步骤请按引导操作"
		return
	if _game_state.get("waiting_for_discard", false):
		_n().send_confirm_discard(_discard_selected.duplicate())
		_discard_selected.clear()
	else:
		_n().send_end_turn()
