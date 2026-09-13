extends Node

const BattleScene = preload("res://scenes/battle_scene.tscn")
const DeckData = preload("res://scripts/data/deck_data.gd")
const CardWidget = preload("res://scripts/ui/components/card_widget.gd")

class Transport extends Node:
	signal state_updated(state: Dictionary)
	signal response_needed(info: Dictionary)
	signal hand_revealed(cards: Array)
	signal weapon_prompt(data: Dictionary)
	signal wind_bow_prompt(index: int)
	signal game_ended(result: Dictionary)
	signal network_error(message: String)
	var player_index := 0
	var battle_state_cache := {}
	var sent: Array = []
	func send_play_card(uid: int, extra: Dictionary = {}): sent.append({"uid": uid, "extra": extra.duplicate(true)})
	func send_response(respond: bool, uid: int = -1): sent.append({"response": respond, "uid": uid})
	func send_use_skill(skill: String, params: Dictionary = {}): sent.append({"skill": skill, "params": params.duplicate(true)})

class ProbeBattle extends "res://scripts/ui/battle_ui.gd":
	var fake: Node
	func _n(): return fake

class ResponseTutorial extends RefCounted:
	func allow_card_click(_uid: int, _type_id: String) -> bool: return false
	func force_response() -> bool: return true

var _checks := 0
var _fails := 0
var _lines: Array[String] = []

func _ready():
	await _run()
	var summary := "HAND INTERACTION: %d checks, %d failures" % [_checks, _fails]
	print(summary)
	var f = FileAccess.open("res://_hand_interaction_test_result.txt", FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n" + summary + "\n")
		f.close()
	get_tree().quit(0 if _fails == 0 else 1)

func _expect(value: bool, label: String):
	_checks += 1
	if not value: _fails += 1
	var line := "[%s] %s" % ["PASS" if value else "FAIL", label]
	print(line)
	_lines.append(line)

func _settle():
	await get_tree().create_timer(0.2).timeout

func _snapshot(label: String):
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	var path := "user://hand_%s_%dx%d.png" % [label, DisplayServer.window_get_size().x, DisplayServer.window_get_size().y]
	get_viewport().get_texture().get_image().save_png(path)
	print("SCREENSHOT: " + ProjectSettings.globalize_path(path))

func _run():
	LocalGame.start_local_game("mage", "rogue", 0, [DeckData.default_deck(), DeckData.default_deck()], true)
	var state = LocalGame.game.get_full_state().duplicate(true)
	LocalGame.disconnect_from_server()
	state.phase = Config.Phase.PLAYER_TURN
	state.current_player = 0
	state.waiting_for_discard = false
	state.waiting_for_weapon_choice = -1
	state.response_pending = false
	state.players[0].position = {"x": 3, "y": 0}
	state.players[1].position = {"x": 7, "y": 0}
	state.players[0].hand = []
	var types := ["near", "move", "magic", "heal_3", "item", "near_armor"]
	for i in range(types.size()): state.players[0].hand.append({"uid": 100 + i, "type_id": types[i]})
	var fake := Transport.new()
	add_child(fake)
	var b = BattleScene.instantiate()
	b.set_script(ProbeBattle)
	b.fake = fake
	add_child(b)
	b._on_state_updated(state)
	await _settle()
	var hand = b.hand_area
	var card = hand.get_card(101)
	var original_instance: int = card.get_instance_id()
	var gap := Vector2(card.position.x + 90, hand.size.y - 264 - 8 + 2)
	_expect(hand.card_at(gap) == -1, "Blank space above sunken cards cannot select a card")
	var before_focus: Vector2 = card.face_rect().position
	hand._hover(101)
	_expect(card.face_rect().position.is_equal_approx(before_focus), "Hover starts without an instantaneous vertical jump")
	await _settle()
	hand.clear_focus()
	await _settle()
	card.mark_new()
	card.set_selected(true)
	_expect(card._overlay.visible and card._overlay.selected and not card._overlay.discarded, "New-card glow preserves the selected overlay")
	card.set_discard_mark(true)
	_expect(card._overlay.visible and card._overlay.selected and card._overlay.discarded, "New-card glow preserves the discard overlay")
	_expect(card._face.get_theme_stylebox("panel").border_color == CardWidget.ACCENTS[card.ap_type], "Discard selection no longer reuses a red card-border color")
	await get_tree().create_timer(1.4).timeout
	_expect(not card._flash_active and card._face.modulate == Color.WHITE, "New-card glow ends without tinting artwork or costs")
	card.set_discard_mark(false)
	card.set_selected(false)
	_expect(card._ap_badge._icon.texture == b._self_panel._ap_badges[1]._icon.texture, "Card cost and movement budget use the same icon asset")
	_expect(card._ap_badge.get_global_rect().encloses(card._ap_badge._value.get_global_rect()), "Cost number stays inside the compact card icon")
	_expect(b._self_panel._ap_badges[0]._value.text == "2/2", "Attack budget shows remaining and turn capacity")
	var textures := {}
	for badge in b._self_panel._ap_badges:
		textures[badge._icon.texture.resource_path] = true
	_expect(textures.size() == 3, "Attack, movement and function budgets have distinct icon assets")
	_expect(hand.cards.size() == 6, "All cards exist once")
	card.set_art_path("res://art/cards/__missing_test__.png")
	_expect(card._art.texture == null, "Missing future illustration uses a stable placeholder")
	var texture := GradientTexture2D.new()
	texture.gradient = Gradient.new()
	texture.gradient.colors = PackedColorArray([Color.RED, Color.RED])
	card.set_art(texture)
	_expect(card._art.texture == texture and card._art.size == Vector2(160, 112), "Card illustration has independent fixed dimensions")
	hand.select(101)
	await _settle()
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var img = get_viewport().get_texture().get_image()
		var ratio: Vector2 = Vector2(img.get_size()) / get_viewport().get_visible_rect().size
		var pixel: Vector2 = (card._art.get_global_transform() * Vector2(80, 56)) * ratio
		var color: Color = img.get_pixelv(Vector2i(pixel))
		_expect(color.r > 0.8 and color.g < 0.25, "Future card artwork actually renders inside its texture slot")
	hand.clear_focus()
	card.set_art_path("res://art/cards/move.png")
	b._on_state_updated(state.duplicate(true))
	_expect(hand.get_card(101).get_instance_id() == original_instance, "State refresh reuses card nodes by UID")
	await _snapshot("rest")
	var short_ap = state.duplicate(true)
	short_ap.players[0].ap_attack = 0
	short_ap.players[0].ap_move = 0
	for data in short_ap.players[0].hand:
		data.ap_affordable = not data.type_id in ["near", "move", "magic"]
	b._on_state_updated(short_ap)
	_expect(hand.get_card(101)._unaffordable and hand.get_card(101)._face.modulate.r < 0.7, "Insufficient AP dims the card face")
	_expect(not hand.get_card(103)._unaffordable, "Free cards remain bright when paid cards are unaffordable")
	b._on_card_clicked(102, "magic")
	_expect(b._selected_uid == 102 and fake.sent.is_empty(), "Dimmed cards remain selectable without automatic submission")
	b._on_card_details(102, "magic")
	_expect(b.get_node_or_null("StatusDetailPopup") != null, "Dimmed cards still expose their complete details")
	b._handle_back()
	b._on_cancel_select()
	hand.get_card(101).mark_new()
	await get_tree().create_timer(1.4).timeout
	_expect(hand.get_card(101)._face.modulate.r < 0.7, "New-card glow cannot brighten an unaffordable card")
	await _snapshot("insufficient_ap")
	var no_ap_response = short_ap.duplicate(true)
	no_ap_response.response_pending = true
	no_ap_response.pending_target = 0
	no_ap_response.pending_attack_card = "near"
	no_ap_response.phase = Config.Phase.RESPONSE_WINDOW
	b._on_state_updated(no_ap_response)
	_expect(not hand.get_card(100)._unaffordable and hand.get_card(100)._respondable, "Response cards ignore ordinary-play AP shortages")
	var no_ap_discard = short_ap.duplicate(true)
	no_ap_discard.waiting_for_discard = true
	b._on_state_updated(no_ap_discard)
	_expect(not hand.get_card(101)._unaffordable, "Discard selection does not dim cards for their play cost")
	b._on_state_updated(short_ap)
	_expect(hand.get_card(101)._unaffordable, "Leaving discard restores current AP dimming")
	var restored_ap = short_ap.duplicate(true)
	for data in restored_ap.players[0].hand: data.ap_affordable = true
	b._on_state_updated(restored_ap)
	_expect(hand.get_card(101)._face.modulate == Color.WHITE, "Restored AP removes stale dimming on reused card nodes")
	b._on_state_updated(state)
	await _settle()
	var point: Vector2 = card.position + Vector2(90, 50)
	var pick: int = hand.card_at(point)
	hand._hover(101)
	await _settle()
	_expect(hand.card_at(point) == pick, "Hover animation cannot change its own hit slot")
	_expect(card._face.scale.x > 1.2 and is_zero_approx(card._face.rotation), "Focused card enlarges and straightens")
	_expect(Rect2(Vector2.ZERO, hand.size).encloses(card.face_rect()), "Focused card stays inside hand bounds")
	await _snapshot("hover")
	hand.begin_pointer(point, true)
	hand.end_pointer(point)
	_expect(b._selected_uid == 101 and fake.sent.is_empty(), "Touch selects without playing")
	_expect(b.confirm_btn.disabled, "Movement requires a target before confirmation")
	_expect(b.board._target_cells.size() == 2, "Linear movement shows two candidate cells")
	b._on_board_cell_clicked(Vector2i(4, 0))
	_expect(fake.sent.is_empty() and not b.confirm_btn.disabled, "Choosing a board cell only stages the move")
	await _snapshot("selected")
	b._on_confirm_card()
	b._on_confirm_card()
	_expect(fake.sent.size() == 1 and fake.sent[0].extra.direction == {"x": 1, "y": 0}, "Final confirmation submits once with correct movement direction")
	_expect(b._submitting and hand.locked, "Hand locks until server acknowledgement")
	b._on_error("测试拒绝")
	_expect(not hand.locked and b._selected_uid == -1 and hand.get_card(101) != null, "Server rejection releases lock without losing the card")
	b._on_state_updated(state)
	fake.sent.clear()
	point = hand.get_card(102).position + Vector2(90, 50)
	hand.begin_pointer(point, true)
	hand.move_pointer(point + Vector2(70, 0))
	hand.end_pointer(point + Vector2(70, 0))
	_expect(b._selected_uid == -1 and fake.sent.is_empty(), "Swiping never selects or plays a card")
	hand.begin_pointer(point, true)
	hand._press_time = Time.get_ticks_msec() - 500
	hand._process(0)
	hand.end_pointer(point)
	_expect(b.get_node_or_null("StatusDetailPopup") != null and fake.sent.is_empty(), "Long press shows persistent details without playing")
	b._handle_back()
	await _settle()
	b._on_card_clicked(102, "magic")
	_expect(b._staged_extra.get("target", -1) == 1 and fake.sent.is_empty(), "Single enemy is preselected without automatic attack")
	b._on_state_updated(state.duplicate(true))
	_expect(b._selected_uid == 102 and b.confirm_btn.visible and not b.confirm_btn.disabled, "Identical snapshots keep the selection and confirmation usable")
	b._on_cancel_select()
	b._on_card_clicked(104, "item")
	b._on_board_cell_clicked(Vector2i(2, 0))
	_expect(fake.sent.is_empty() and b._staged_extra.get("trap_pos", {}) == {"x": 2, "y": 0}, "Item placement is staged until confirmation")
	b._on_cancel_select()
	var responding = state.duplicate(true)
	responding.response_pending = true
	responding.pending_target = 0
	responding.pending_attack_card = "near"
	responding.phase = Config.Phase.RESPONSE_WINDOW
	b._on_state_updated(responding)
	b.tutorial = ResponseTutorial.new()
	b._on_card_clicked(101, "move")
	_expect(not b.confirm_btn.visible, "Nonresponse cards remain inspectable but cannot respond")
	b._on_card_clicked(100, "near")
	_expect(fake.sent.is_empty() and b.confirm_btn.visible, "Response selection waits for confirmation")
	_expect(b._selected_uid == 100, "Tutorial ordinary-play restriction does not block response selection")
	b.tutorial = null
	await _snapshot("response")
	b._on_confirm_card()
	_expect(fake.sent.size() == 1 and fake.sent[0].response, "Response is submitted only on confirmation")
	b._on_state_updated(state)
	var discarded = state.duplicate(true)
	discarded.waiting_for_discard = true
	b._on_state_updated(discarded)
	_expect(b._discard_focus and b._skill_scrim.visible and b._skill_description.text.contains("弃牌阶段"), "Discard phase enters its own focus view")
	_expect(hand.get_card(100)._overlay.discard_phase and not hand.get_card(100)._skill_material, "Discard candidates have purple borders without skill material highlighting")
	await _settle()
	var sway_card = hand.get_card(100)
	var slot: Vector2 = sway_card.position
	var angle: float = sway_card._face.rotation
	await get_tree().create_timer(0.16).timeout
	_expect(absf(sway_card._face.rotation - angle) > 0.0001 and sway_card.position == slot, "Discard cards gently sway without moving their hit slots")
	hand._hover(100)
	await _settle()
	_expect(is_zero_approx(sway_card._discard_sway), "Hovered discard card stops swaying for inspection")
	hand.clear_focus()
	b._on_card_clicked(100, "near")
	_expect(is_zero_approx(sway_card._discard_sway), "Selected discard card stays steady")
	b._on_card_clicked(101, "move")
	_expect(b._discard_selected.size() == 2 and hand.get_card(100)._is_discarded, "Discard selection remains multiselect")
	_expect(hand.get_card(100)._overlay.discarded and hand.get_card(100)._overlay.visible, "Discard selection uses a visible overlay instead of only an outer red frame")
	_expect(b._skill_description.text.contains("已选 2 张") and b.end_turn_btn.z_index > b._skill_scrim.z_index, "Discard focus tracks the selected count and keeps confirmation visible")
	await _snapshot("discard")
	b._on_cancel_select()
	_expect(b._discard_focus and b._discard_selected.is_empty() and not hand.get_card(100)._overlay.discarded, "Clearing discard selection preserves the phase focus without stale card marks")
	b._on_state_updated(state)
	_expect(not b._discard_focus and not b._skill_scrim.visible and not hand.get_card(100)._overlay.discard_phase, "Leaving discard removes the focus view and purple candidate borders")
	_expect(not sway_card.is_processing() and is_zero_approx(sway_card._discard_sway), "Leaving discard stops the sway and removes its rotation offset")
	var many = state.duplicate(true)
	for i in range(6, 30): many.players[0].hand.append({"uid": 100 + i, "type_id": "magic"})
	b._on_state_updated(many)
	_expect(hand._max_offset > 0 and hand._scrollbar.visible, "Large hands scroll instead of shrinking cards")
	hand._scrollbar.value = hand._scrollbar.max_value
	await _settle()
	var last = hand.get_card(129)
	_expect(last.position.x < hand.size.x and hand.card_at(last.position + Vector2(90, 50)) == 129, "Last card in a large hand is reachable")
	await _snapshot("large")
	b._on_card_clicked(129, "magic")
	var next_turn = many.duplicate(true)
	next_turn.current_player = 1
	b._on_state_updated(next_turn)
	_expect(b._selected_uid == -1 and hand.selected_uid == -1 and b.board._target_cells.is_empty(), "Turn changes remove selection and target residue")
	b._on_card_clicked(129, "magic")
	_expect(hand.selected_uid == 129 and not b.confirm_btn.visible, "Opponent turn still allows safe hand inspection")
	b._on_state_updated(state)
	await _settle()
	var mouse_point: Vector2 = hand.global_position + hand.get_card(101).position + Vector2(90, 80)
	var motion := InputEventMouseMotion.new()
	motion.position = mouse_point
	get_viewport().push_input(motion, true)
	await _settle()
	var button := InputEventMouseButton.new()
	button.button_index = MOUSE_BUTTON_LEFT
	button.position = mouse_point
	button.pressed = true
	get_viewport().push_input(button, true)
	button = button.duplicate()
	button.pressed = false
	get_viewport().push_input(button, true)
	_expect(b._selected_uid == 101, "Real viewport mouse routing selects the card")
	button = button.duplicate()
	button.button_index = MOUSE_BUTTON_RIGHT
	button.pressed = true
	get_viewport().push_input(button, true)
	_expect(b._selected_uid == -1, "Right click cancels even over the hand's input surface")
	var added = state.duplicate(true)
	added.players[0].hand.append({"uid": 200, "type_id": "blessing"})
	b._on_state_updated(added)
	_expect(hand.get_card(200)._flash_active, "Newly acquired card keeps the user's flash animation")
	b._on_state_updated(state)
	b._on_state_updated(added)
	_expect(hand.get_card(200)._flash_active, "A previously played UID flashes when drawn again")
	var other_owner: Dictionary = added.players[0].duplicate(true)
	other_owner.index = 1
	other_owner.hand = [{"uid": 300, "type_id": "move"}]
	hand.sync_hand(other_owner.hand, other_owner, [], [])
	_expect(not hand.get_card(300)._flash_active, "Changing player perspective does not mark their initial hand as newly drawn")
	b._on_state_updated(state)
	var multi = state.duplicate(true)
	multi.players[0].position = {"x": 0, "y": 0}
	multi.players[1].position = {"x": 1, "y": 0}
	for i in range(2, 4):
		var p: Dictionary = state.players[1].duplicate(true)
		p.index = i
		p.position = {"x": 0, "y": 1} if i == 2 else {"x": -1, "y": 0}
		multi.players.append(p)
	b._on_state_updated(multi)
	b._on_card_clicked(102, "magic")
	_expect(b._staged_extra.is_empty() and b.board._target_cells.size() == 3, "FFA attacks require selecting one of the three opponents")
	b._on_board_cell_clicked(Vector2i(0, 1))
	_expect(b._staged_extra.get("target", -1) == 2, "Hex selection preserves the actual player index")
	await _settle()
	await _snapshot("ffa")
	var ffa_next_turn: Dictionary = multi.duplicate(true)
	ffa_next_turn.current_player = 2
	b._on_state_updated(ffa_next_turn)
	_expect(b._turn_notice.visible and b._turn_notice.text.contains("P3"), "FFA turn notice identifies the actual acting player")
	var notice_tween = b._turn_notice_tween
	b._on_state_updated(ffa_next_turn)
	_expect(b._turn_notice_tween == notice_tween, "Ordinary snapshots do not restart the turn notice")
	_expect(b._turn_notice.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Turn notices do not intercept card or board input")
	_expect(not b._turn_notice.get_global_rect().intersects(b._opp_scroll.get_global_rect()), "Turn notice does not cover opponents' information")
	await _snapshot("turn_notice")
	b._on_state_updated(multi)
	b._on_cancel_select()
	b._on_card_clicked(101, "move")
	_expect(b.board._target_cells.size() == 6, "Hex movement exposes all six adjacent directions")
	b._on_board_cell_clicked(Vector2i(1, -1))
	_expect(b._staged_extra.get("direction", {}) == {"x": 1, "y": -1}, "Hex moves stage axial direction coordinates")
	var hand_rect: Rect2 = hand.get_global_rect()
	_expect(not hand_rect.intersects(b.skill_row.get_global_rect()) and not hand_rect.intersects(b.confirm_btn.get_global_rect()), "Expanded hand region does not overlap action buttons")
	_expect(not b.status_label.get_global_rect().intersects(b.board.get_global_rect()), "Target captions do not cover the hex board")
	var empty = state.duplicate(true)
	empty.players[0].hand = []
	b._on_state_updated(empty)
	_expect(hand.cards.is_empty() and hand._empty_label.visible, "An empty hand has an explicit noninteractive state")
	b.queue_free()
	fake.queue_free()
	await _settle()
	await _test_local()
	_test_ap_affordability()
	await _test_skill_availability()
	await _test_skill_materials()

func _test_skill_materials():
	LocalGame.start_local_game("vine_ent", "mage", 0, [DeckData.default_deck(), DeckData.default_deck()], true)
	var state: Dictionary = LocalGame.game.get_full_state().duplicate(true)
	LocalGame.disconnect_from_server()
	state.players[0].active_skills = []
	state.players[0].armor = {"id": "near_armor"}
	state.players[0].hand = []
	var types = ["near", "magic", "chant", "heal_3", "item", "pierce", "heavy", "range"]
	for i in range(types.size()): state.players[0].hand.append({"uid": 500 + i, "type_id": types[i], "blocked_reason": "距离过远"})
	var fake = Transport.new()
	add_child(fake)
	var b = BattleScene.instantiate()
	b.set_script(ProbeBattle)
	b.fake = fake
	add_child(b)
	# Supply a real armor descriptor for the equipment view.
	state.players[0].armor = {"id": "near_armor", "data": Config.ARMOR_DB.near_armor, "durability": 4, "max_durability": 4}
	b._on_state_updated(state)
	await _settle()
	var cases = {"mage_discard": 504, "mage_phantom": 502, "wardsmith_infuse": 500, "wardsmith_repair": 506, "rogue_give": 504, "priest_chant": 503, "spellblade_channel": 501, "vine_spread": 500, "hunter_ambush": 505}
	for skill in cases:
		state.players[0].active_skills = [{"id": skill, "name": skill, "available": true}]
		b._on_state_updated(state.duplicate(true))
		var count: int = b.get_child_count()
		fake.sent.clear()
		b._exec_skill(skill)
		_expect(b._skill_pick == skill and b.get_child_count() == count, skill + " starts in the hand without a popup")
		# 描述经 Style.wj 插入 U+2060（防断行），比较时先剥离该零宽字符
		var shown_desc: String = b._skill_description.text.replace("\u2060", "")
		_expect(b._skill_scrim.visible and shown_desc.contains(Config.CHARACTER_DB.vine_ent.skill_desc), skill + " shows the full description on the focus backdrop")
		_expect(b.confirm_btn.disabled, skill + " cannot confirm without a material")
		b._on_card_clicked(cases[skill], "")
		var material_uid: int = b._selected_uid
		b._exec_skill(skill)
		_expect(b._selected_uid == material_uid, skill + " repeated activation preserves the selected material")
		_expect(b.skill_row.get_child(0).disabled and b.skill_row.get_child(0).text.contains("选择中"), skill + " active button is clearly selected and disabled")
		_expect(b.hand_area.skill_selection and b.hand_area.get_card(material_uid)._skill_material, skill + " hand and material show skill highlights")
		_expect(fake.sent.is_empty() and not b.hand_area.get_card(cases[skill])._unaffordable, skill + " selects blocked attack cards as material without spending")
		if skill == "vine_spread":
			_expect(not Vector2i(3, 0) in b._skill_targets() and Vector2i(4, 0) in b._skill_targets(), "Spread highlights only unseeded adjacent cells")
			b._on_board_cell_clicked(Vector2i(4, 0))
		elif skill == "hunter_ambush":
			b._on_board_cell_clicked(Vector2i(4, 0))
			_expect(b.confirm_btn.disabled, "Pierce ambush requires two positions")
			b._on_board_cell_clicked(Vector2i(4, 0))
		_expect(not b.confirm_btn.disabled and fake.sent.is_empty(), skill + " waits for final confirmation")
		if skill == "vine_spread":
			await _settle()
			var eligible = b.hand_area.get_card(501)
			var ineligible = b.hand_area.get_card(504)
			var pulse: float = eligible._overlay.pulse_strength
			await get_tree().create_timer(0.45).timeout
			_expect(eligible._overlay.visible and eligible._overlay.is_processing() and absf(eligible._overlay.pulse_strength - pulse) > 0.01, "Unselected skill materials breathe at their own card edges")
			_expect(not ineligible._overlay.is_processing() and eligible._face.modulate == Color.WHITE, "Ineligible cards do not pulse and artwork brightness remains stable")
			await _snapshot("skill_material")
		b._on_confirm_card()
		b._on_confirm_card()
		_expect(fake.sent.size() == 1 and fake.sent[0].skill == skill and fake.sent[0].params.card_uid == cases[skill], skill + " submits one skill request with the material UID")
		b._on_state_updated(state.duplicate(true))
	b._exec_skill("mage_phantom")
	b._on_card_clicked(500, "near")
	_expect(b._selected_uid == -1 and b.hand_area.get_card(500)._unaffordable, "Ineligible material stays dim and cannot be selected")
	b._on_card_clicked(501, "magic")
	b._on_card_clicked(501, "magic")
	_expect(b._selected_uid == -1 and b._skill_pick == "mage_phantom", "Clicking the material again deselects without leaving the skill")
	b._on_cancel_select()
	_expect(b.hand_area.get_card(501)._unaffordable and b._skill_pick.is_empty(), "Cancel restores ordinary card blocking")
	_expect(not b.hand_area.skill_selection and not b.hand_area.get_card(501)._skill_material, "Cancel removes all skill highlights")
	_expect(not b.hand_area.get_card(501)._overlay.is_processing(), "Cancel stops the material breathing animation")
	_expect(not b._skill_scrim.visible and b._skill_description.text.is_empty() and b.board.z_index == 0, "Cancel clears focus backdrop, description and raised layers")
	b._exec_skill("vine_spread")
	b._on_card_clicked(500, "near")
	b._on_state_updated(state.duplicate(true))
	_expect(b._skill_pick == "vine_spread" and b.confirm_btn.disabled, "Timer-only snapshots preserve incomplete skill selection")
	state.current_player = 1
	b._on_state_updated(state)
	_expect(b._skill_pick.is_empty() and not b.confirm_btn.visible, "Turn change clears skill materials and controls")
	var multi = preload("res://scripts/core/match_state.gd").new()
	multi.disable_timeout = true
	multi._setup_match(["rogue", "mage", "hunter", "priest"], 0, [], true)
	multi._start_game()
	multi.card_systems[0].hand = [{"uid": 900, "type_id": "heal_3"}]
	var multi_state: Dictionary = multi.get_full_state()
	multi_state.players[0].active_skills = []
	b._on_state_updated(multi_state)
	for skill in ["rogue_give", "priest_chant", "spellblade_channel"]:
		multi_state.players[0].hand[0].type_id = "magic" if skill == "spellblade_channel" else "heal_3"
		b._on_state_updated(multi_state.duplicate(true))
		b._exec_skill(skill)
		b._on_card_clicked(900, "")
		_expect(b._skill_targets().size() == 3 and b.confirm_btn.disabled, skill + " requires an explicit multiplayer target")
		var target: Vector2i = multi.players[2].position
		b._on_board_cell_clicked(target)
		_expect(b._skill_params.get("target", -1) == 2 and b.board._selected_target == target, skill + " highlights the chosen multiplayer target")
		b._on_cancel_select()
	b.queue_free()
	fake.queue_free()
	await _settle()

func _test_skill_availability():
	LocalGame.start_local_game("mage", "rogue", 0, [DeckData.default_deck(), DeckData.default_deck()], true)
	var game = LocalGame.game
	var p: Dictionary = game.players[0]
	game.card_systems[0].hand = [{"uid": -9200, "type_id": "magic"}, {"uid": -9201, "type_id": "near"}]
	var battle = BattleScene.instantiate()
	add_child(battle)
	battle._on_state_updated(game.get_full_state())
	await _settle()
	_expect(battle.skill_row.get_child_count() == 2, "Both mage skills have persistent slots")
	var result: Dictionary = game.process_action(0, {"action": "use_skill", "skill": "mage_discard", "card_uid": -9201})
	_expect(result.success, "Available skill still executes through the real action gate")
	battle._on_state_updated(game.get_full_state())
	await _settle()
	var used: Button = battle.skill_row.get_child(0)
	_expect(battle.skill_row.get_child_count() == 2 and used.disabled and used.modulate.r < 1, "Used skill remains visible and dims")
	_expect(not battle.skill_row.get_child(1).disabled, "Using one skill does not disable a separate skill")
	var tap := InputEventMouseButton.new()
	tap.button_index = MOUSE_BUTTON_LEFT
	tap.pressed = true
	tap.position = used.get_global_rect().get_center()
	get_viewport().push_input(tap, true)
	tap = tap.duplicate()
	tap.pressed = false
	get_viewport().push_input(tap, true)
	await _settle()
	_expect(battle.get_node_or_null("StatusDetailPopup") != null, "Disabled skill can be tapped to inspect its reason")
	var detail = battle.get_node_or_null("StatusDetailPopup")
	if detail != null: detail.queue_free()
	await _snapshot("skill_used")
	p.skills_used.clear()
	battle._on_state_updated(game.get_full_state())
	_expect(not battle.skill_row.get_child(0).disabled, "Resetting the turn allowance restores the skill")
	game.card_systems[0].hand.clear()
	battle._on_state_updated(game.get_full_state())
	_expect(battle.skill_row.get_child_count() == 2 and battle.skill_row.get_child(1).disabled, "Missing material dims rather than removes the skill")
	game.waiting_for_discard = true
	battle._on_state_updated(game.get_full_state())
	_expect(battle.skill_row.visible and battle.skill_row.get_child(0).disabled, "Discard phase preserves disabled skill slots")
	game.waiting_for_discard = false
	p.char_id = "wardsmith"
	p.armor = {}
	_expect(game._skill_list(0).size() == 2 and not game._skill_list(0)[0].available, "Unequipped armor skills remain discoverable")
	p.armor = {"id": "near_armor", "durability": 2, "max_durability": 4}
	p.ap_attack = 1
	game.card_systems[0].hand = [{"uid": -9202, "type_id": "pierce"}]
	_expect(not game.char_skills.skill_block_reason(0, "wardsmith_repair").is_empty(), "Repair requires a matching enhanced attack card")
	game.card_systems[0].hand[0].type_id = "heavy"
	_expect(game.char_skills.skill_block_reason(0, "wardsmith_repair").is_empty(), "Matching repair material enables the skill")
	p.ap_attack = 0
	_expect(game.char_skills.skill_block_reason(0, "wardsmith_repair").contains("行动点"), "Repair requires its action point")
	p.char_id = "assassin"
	p.frozen_move = true
	_expect(not game.char_skills.skill_block_reason(0, "assassin_move").is_empty(), "Movement lock disables shadow step")
	p.frozen_move = false
	p.char_id = "vine_ent"
	game.items.clear()
	_expect(not game.char_skills.skill_block_reason(0, "vine_spread").is_empty(), "Spread requires a legal seed location")
	p.char_id = "spellblade"
	p.weapon = {"data": {"type": "near"}}
	game.card_systems[0].hand[0].type_id = "chant"
	p.ap_attack = 1
	_expect(game.char_skills.skill_block_reason(0, "spellblade_channel").contains("行动点"), "Channel checks the transformed attack cost")
	p.ap_attack = 2
	_expect(game.char_skills.skill_block_reason(0, "spellblade_channel").is_empty(), "Channel is enabled with weapon, material and budget")
	var server = load("res://scripts/server/server_main.gd").new()
	var state: Dictionary = game.get_full_state()
	var other: Dictionary = server._state_for_player(state, 1)
	_expect(not other.players[0].active_skills[0].has("blocked_reason") and state.players[0].active_skills[0].has("blocked_reason"), "Private skill reasons do not reveal another player's hand requirements")
	server.free()
	battle.queue_free()
	await _settle()
	LocalGame.disconnect_from_server()

func _test_ap_affordability():
	LocalGame.start_local_game("mage", "rogue", 0, [DeckData.default_deck(), DeckData.default_deck()], true)
	var game = LocalGame.game
	var player: Dictionary = game.players[0]
	player.ap_attack = 0
	player.ap_move = 0
	player.ap_function = 0
	_expect(not game.has_card_ap(0, "near") and not game.has_card_ap(0, "move") and not game.has_card_ap(0, "seize"), "All three resource pools independently reject shortages")
	_expect(game.has_card_ap(0, "near_armor") and game.has_card_ap(0, "heal_3"), "Zero-cost cards do not require any resource pool")
	player.ap_move = 1
	_expect(game.has_card_ap(0, "move") and not game.has_card_ap(0, "near"), "Movement points do not pay for attack cards")
	player.char_id = "gunslinger"
	player.ap_attack = 1
	_expect(not game.has_card_ap(0, "range") and not game.has_card_ap(0, "pierce"), "Gunslinger attacks require their actual two-point cost")
	player.ap_attack = 2
	_expect(game.has_card_ap(0, "range"), "An exact two-point budget pays for a gunslinger attack")
	player.char_id = "rogue"
	_expect(game.has_card_ap(0, "seize"), "Rogue's free seize remains affordable at zero function points")
	player.char_id = "sharpshooter"
	player.ap_attack = 0
	player.skill_used_this_turn = false
	_expect(not game.has_card_ap(0, "range"), "Sharpshooter preview preserves the existing AP gate before free deduction")
	game.card_systems[0].hand = [{"uid": -9000, "type_id": "range"}]
	var snapshot: Dictionary = game.get_full_state()
	_expect(snapshot.players[0].hand[0].ap_affordable == false, "Private hand snapshot includes authoritative affordability")
	_expect(not game.card_systems[0].hand[0].has("ap_affordable"), "Presentation metadata never mutates the core deck cards")
	game.infinite_play = true
	_expect(game.has_card_ap(0, "range") and game.has_card_ap(0, "seize"), "Unlimited play bypasses AP shortages")
	game.infinite_play = false
	game.rapid_mode = true
	_expect(game.has_card_ap(0, "range"), "Legacy rapid mode also bypasses AP shortages")
	player.char_id = "mage"
	player.position = Vector2i(0, 0)
	player.range_power = 3
	player.weapon = {}
	game.players[1].position = Vector2i(4, 0)
	game.players[1].buffs.clear()
	_expect(not game.card_block_reason(0, "pierce").is_empty(), "Pierce is blocked at range equal to distance")
	_expect(game.card_block_reason(0, "range").is_empty(), "Zero base damage does not forbid ordinary ranged attacks")
	player.weapon = {"id": "longbow"}
	_expect(game.card_block_reason(0, "pierce").is_empty(), "Longbow range adjustment makes pierce playable")
	game.players[1].buffs.append({"type": "rogue_stealth"})
	_expect(game.card_block_reason(0, "range").contains("潜行"), "Stealth gives a specific ranged rejection reason")
	game.players[1].buffs.clear()
	player.weapon = {}
	player.char_id = "gunslinger"
	_expect(game.card_block_reason(0, "pierce").is_empty(), "Character damage override preserves its distance exception")
	game.rapid_mode = false
	player.char_id = "mage"
	player.ap_attack = 2
	game.items.clear()
	_expect(not game.card_block_reason(0, "near").is_empty() and not game.card_block_reason(0, "heavy").is_empty(), "Melee cards are blocked without nearby enemies or seeds")
	game.players[1].position = Vector2i(1, 0)
	_expect(game.card_block_reason(0, "near").is_empty(), "Adjacent enemy makes melee playable")
	game.players[1].position = Vector2i(4, 0)
	game.items.append({"item_type": "vine_seed", "position": Vector2i(1, 0)})
	player.ap_attack = 1
	_expect(not game.has_card_ap(0, "heavy") and game.card_block_reason(0, "heavy").is_empty(), "One-point seed removal keeps a two-point heavy card usable")
	game.card_systems[0].hand = [{"uid": -9001, "type_id": "heavy"}]
	var seed_snapshot: Dictionary = game.get_full_state()
	var fan = load("res://scripts/ui/components/hand_fan.gd").new()
	add_child(fan)
	fan.sync_hand(seed_snapshot.players[0].hand, seed_snapshot.players[0], [], [])
	_expect(not fan.get_card(-9001)._unaffordable, "Alternative use overrides normal attack affordability in the hand")
	player.ap_attack = 0
	_expect(game.card_block_reason(0, "heavy") == "行动点不足", "Seeds cannot bypass the removal action-point cost")
	player.ap_attack = 2
	game.items[0].position = Vector2i(4, 0)
	_expect(not game.card_block_reason(0, "near").is_empty(), "Distant seeds do not make melee usable")
	var blocked_snapshot: Dictionary = game.get_full_state()
	fan.sync_hand(blocked_snapshot.players[0].hand, blocked_snapshot.players[0], [], [])
	_expect(fan.get_card(-9001)._unaffordable, "Reused hand cards dim after the alternative target disappears")
	fan.queue_free()
	LocalGame.disconnect_from_server()

func _test_local():
	LocalGame.start_local_game("vine_ent", "mage", 0, [DeckData.default_deck(), DeckData.default_deck()], true)
	var vine = LocalGame.game
	vine.card_systems[0].hand = [{"uid": 8000, "type_id": "item"}]
	var vine_battle = BattleScene.instantiate()
	add_child(vine_battle)
	vine_battle._on_state_updated(vine.get_full_state())
	await _settle()
	var root_pos: Vector2i = vine.players[0].position
	vine_battle._on_card_clicked(8000, "item")
	_expect(root_pos in vine_battle._card_targets(), "First-turn item UI permits the seed under the unmoved tree")
	vine_battle._on_board_cell_clicked(root_pos)
	_expect(not vine_battle.confirm_btn.disabled, "Clicking the tree's own cell enables item confirmation")
	vine_battle._on_confirm_card()
	_expect(vine.item_system.get_seed_layers(root_pos) == 2 and not vine.card_systems[0].has_card(8000), "First-turn item confirmation stacks the root seed through the local UI")
	vine_battle.queue_free()
	await _settle()
	LocalGame.disconnect_from_server()
	LocalGame.start_local_game("mage", "rogue", 0, [DeckData.default_deck(), DeckData.default_deck()], true)
	var game = LocalGame.game
	game.card_systems[0].hand = [{"uid": -2000, "type_id": "move"}, {"uid": -2001, "type_id": "magic"}, {"uid": -2002, "type_id": "move"}]
	var battle = BattleScene.instantiate()
	add_child(battle)
	battle._on_state_updated(game.get_full_state())
	await _settle()
	var before: Vector2i = game.players[0].position
	battle._on_card_clicked(-2000, "move")
	battle._on_board_cell_clicked(before + Vector2i(1, 0))
	_expect(game.players[0].position == before, "Real local engine is unchanged during target preview")
	battle._on_confirm_card()
	_expect(game.players[0].position == before + Vector2i(1, 0) and not game.card_systems[0].has_card(-2000), "Real local engine moves and consumes the card only after confirmation")
	_expect(not battle._submitting and not battle.hand_area.locked, "Synchronous local acknowledgement releases submission lock")
	var after_move: Dictionary = game.get_full_state().players[0]
	_expect(after_move.ap_move == 0 and after_move.ap_move_max == 1, "Spending changes only the remaining budget, not its denominator")
	_expect(battle.hand_area.get_card(-2002)._unaffordable, "Real engine acknowledgement dims another movement card after spending")
	game.char_skills.on_turn_start(0)
	battle._on_state_updated(game.get_full_state())
	_expect(not battle.hand_area.get_card(-2002)._unaffordable, "Real turn budget reset restores movement card brightness")
	battle.queue_free()
	await _settle()
	LocalGame.disconnect_from_server()
	LocalGame.start_local_game("warlock", "mage", 0, [DeckData.default_deck(), DeckData.default_deck()], true)
	var warlock = LocalGame.game
	warlock.status.add_buff(0, "ap_attack_down", -1, 1)
	warlock.char_skills.on_turn_start(0)
	var capacity: Dictionary = warlock.get_full_state().players[0]
	_expect(capacity.ap_function == 2 and capacity.ap_function_max == 2, "Warlock function budget is two, not the default one")
	_expect(capacity.ap_attack == 1 and capacity.ap_attack_max == 1, "Attack budget denominator includes the turn-start debuff")
	LocalGame.disconnect_from_server()
