extends Node

const DeckData = preload("res://scripts/data/deck_data.gd")
const BattleScene = preload("res://scenes/battle_scene.tscn")
const DeckPick = preload("res://scenes/deck_pick.tscn")

var _fails := 0
var _checks := 0

func _ready():
	await _run()
	print("MOBILE AUDIT: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(0 if _fails == 0 else 1)

func _expect(ok: bool, label: String):
	_checks += 1
	if not ok: _fails += 1
	print("[%s] %s" % ["PASS" if ok else "FAIL", label])

func _frames():
	for i in range(6): await get_tree().process_frame

func _snapshot(label: String):
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	var img = get_viewport().get_texture().get_image()
	var path = "user://audit_%s_%dx%d.png" % [label, DisplayServer.window_get_size().x, DisplayServer.window_get_size().y]
	img.save_png(path)
	print("SCREENSHOT: " + ProjectSettings.globalize_path(path))

func _run():
	LocalGame.start_local_game_multi(["fighter", "mage", "hunter", "priest"])
	LocalGame.game.current_player = 0
	var b = BattleScene.instantiate()
	add_child(b)
	var st = LocalGame.game.get_full_state()
	st.phase = Config.Phase.PLAYER_TURN
	st.response_pending = false
	for p in st.players:
		p.weapon = {"id": "spiked_flail", "data": Config.WEAPON_DB.spiked_flail}
		p.armor = {"data": Config.ARMOR_DB.near_armor, "durability": 3, "max_durability": 3}
		p.buffs = []
		for kind in ["near_up", "attack_up", "attack_down", "calibration", "mage_empower", "vine_cripple", "wither_weapon", "exposed"]:
			p.buffs.append({"type": kind, "value": 2, "duration": 2})
		p.dots = [{"type": "burn", "damage": 2, "duration": 2}, {"type": "poison", "damage": 1, "duration": 4}]
		p.frozen_move = true
	b._on_state_updated(st)
	b._on_state_updated(st.duplicate(true))
	_expect(b._self_panel._status_row.get_child_count() <= 11, "Repeated same-frame refresh removes obsolete status slots immediately")
	await _frames()
	await _snapshot("ffa")
	_check_panels(b)
	b._opp_scroll.scroll_vertical = 100000
	await _frames()
	var last_panel = b._opp_panels.back()
	_expect(last_panel.get_global_rect().end.y <= b._opp_scroll.get_global_rect().end.y + 1, "Last opponent's statuses are reachable by scrolling")
	await _snapshot("ffa_scrolled")
	b._opp_scroll.scroll_vertical = 0
	var responding = st.duplicate(true)
	responding.response_pending = true
	responding.phase = Config.Phase.RESPONSE_WINDOW
	responding.pending_target = 2
	responding.pending_attack_card = "range"
	b._on_state_updated(responding)
	_expect(b._player_index == 2, "Local FFA response view belongs to the actual target")
	b._on_state_updated(st)
	_expect(not b._resp_popup.visible, "Response popup closes when response expires")
	LocalGame.ai_mode = true
	b._on_state_updated(responding)
	_expect(not b._resp_popup.visible, "Uninvolved player does not see another player's response popup")
	LocalGame.ai_mode = false
	b._on_state_updated(st)
	b._on_weapon_prompt({"data": Config.WEAPON_DB.spiked_flail})
	b._on_state_updated(st)
	_expect(not b._wpn_popup.visible, "Weapon popup closes when the offer expires")
	b._popup_move(-1)
	var next = st.duplicate(true)
	next.current_player = 1
	b._on_state_updated(next)
	var expired := false
	for c in b.get_children():
		if c is Control and c.visible and c.z_index == 10 and not c.is_queued_for_deletion(): expired = true
	_expect(not expired, "Turn change removes action-choice overlays")
	b._on_state_updated(st)
	b._hunter_pos1 = {"x": 1, "y": 0}
	b._selected_type = "hunter_ambush"
	b._selected_uid = 80
	b._on_cancel_select()
	_expect(b._hunter_pos1.is_empty() and b._selected_type.is_empty(), "Cancel clears staged board selections")
	b._on_status_clicked(Config.CHARACTER_DB.vine_ent.skill_desc)
	await _frames()
	await _snapshot("details")
	var detail = b.get_node_or_null("StatusDetailPopup")
	_expect(detail != null and detail.visible, "Mobile character details remain readable in a scrollable popup")
	_expect(b._handle_back() and not detail.visible, "Back closes an information popup before leaving the match")
	b.queue_free()
	await _frames()
	LocalGame.disconnect_from_server()
	LocalGame.start_local_game("vine_ent", "rogue", 0, [DeckData.default_deck(), DeckData.default_deck()], true)
	b = BattleScene.instantiate()
	add_child(b)
	await _frames()
	var board_rect = b.board.get_global_rect()
	var board_fits := true
	for cell in b.board._cells.values():
		if not board_rect.grow(1).encloses(cell.get_global_rect()): board_fits = false
	_expect(board_fits, "All 11 linear board cells fit the allocated board width")
	var clicked: Array = []
	b.board.cell_clicked.connect(func(pos): clicked.append(pos))
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	b.board._on_cell_input(press, Vector2i.ZERO)
	var drag := InputEventMouseMotion.new()
	drag.position = Vector2(30, 0)
	b.board._on_cell_input(drag, Vector2i.ZERO)
	press.pressed = false
	b.board._on_cell_input(press, Vector2i.ZERO)
	_expect(clicked.is_empty(), "Dragging across a linear cell does not play a card on release")
	b._on_card_clicked(int(LocalGame.game.card_systems[0].hand[0].uid), "item")
	await _frames()
	await _snapshot("duel")
	b.queue_free()
	await _frames()
	LocalGame.disconnect_from_server()
	LocalGame.bp_chars = ["fighter", "mage"]
	LocalGame.bp_first = 0
	var picker = DeckPick.instantiate()
	add_child(picker)
	picker._sel_kind = "default"
	picker._on_edit()
	picker._on_package_switch("C")
	picker._draft = ["heal_3", "heal_3", "heal_3", "heal_3", "near_buf", "range_buf"]
	picker._on_add("magic_buf")
	_expect(picker._draft.count("magic_buf") == 0, "Package C blocks a third stat card in temporary editing")
	picker._draft = ["heavy", "heavy", "pierce", "pierce", "chant"]
	picker._on_add("chant")
	_expect(picker._draft.size() == 5, "Temporary editing enforces the enhanced-attack sublimit")
	await _frames()
	await _snapshot("deck")
	picker.queue_free()
	await _frames()
	LocalGame.disconnect_from_server()
	Network.player_index = 0
	Network._handle_packet(JSON.stringify({"t": "game_over", "winner": 0, "names": ["测试玩家", "对手"], "stats": []}))
	Network._close()
	var settlement = load("res://scenes/settlement.tscn").instantiate()
	add_child(settlement)
	await _frames()
	_expect(settlement.title_label.text == "胜利！", "Disconnect preserves the winner's settlement perspective")
	var summary = settlement.detail_label.text
	settlement._show_export_notice("audit")
	settlement._show_export_notice("audit-again")
	await get_tree().create_timer(3.1).timeout
	_expect(settlement.detail_label.text == summary, "Repeated export notices restore the original match result")
	settlement.queue_free()
	await _frames()

func _check_panels(b):
	var viewport = get_viewport().get_visible_rect()
	var panels = [b._self_panel] + b._opp_panels
	for i in range(panels.size()):
		var p = panels[i]
		var rect = p.get_global_rect()
		var visible_rect = rect if i == 0 else rect.intersection(b._opp_scroll.get_global_rect())
		_expect(not visible_rect.has_area() or viewport.encloses(visible_rect), "Player panel %d visible area stays inside the viewport" % i)
		var fits := true
		for child in [p._name_label, p._hp_num, p._attr_label, p._deck_label, p._equip_label]:
			if child.visible and not rect.grow(1).encloses(child.get_global_rect()): fits = false
		for slot in p._status_row.get_children():
			if not slot.is_queued_for_deletion() and not rect.grow(1).encloses(slot.get_global_rect()): fits = false
			for label in slot.find_children("*", "Label", true, false):
				if not slot.get_global_rect().grow(1).encloses(label.get_global_rect()): fits = false
		for badge in p._ap_badges:
			if not rect.grow(1).encloses(badge.get_global_rect()): fits = false
			if not badge.get_parent().get_global_rect().grow(1).encloses(badge.get_global_rect()): fits = false
			if not badge.get_global_rect().grow(1).encloses(badge._value.get_global_rect()): fits = false
		_expect(fits, "Player panel %d contains all visible information" % i)
	for i in range(b._opp_panels.size() - 1):
		_expect(not b._opp_panels[i].get_global_rect().intersects(b._opp_panels[i + 1].get_global_rect()), "Opponent panels %d and %d do not overlap" % [i, i + 1])
	_expect(viewport.encloses(b._opp_scroll.get_global_rect()), "Scrollable opponent area stays inside the viewport")
	_expect(not b._opp_scroll.get_global_rect().intersects(b.skill_row.get_global_rect()), "Clipped opponent information does not cover skill buttons")
