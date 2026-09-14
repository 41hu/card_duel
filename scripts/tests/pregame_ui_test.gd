extends Node

var failures := 0
var checks := 0

func expect(condition: bool, message: String):
	checks += 1
	if not condition: failures += 1
	print("[%s] %s" % ["PASS" if condition else "FAIL", message])

func settle():
	await get_tree().create_timer(0.15).timeout

func shot(label: String):
	await RenderingServer.frame_post_draw
	var path := "user://pregame_%s_%dx%d.png" % [label, DisplayServer.window_get_size().x, DisplayServer.window_get_size().y]
	get_viewport().get_texture().get_image().save_png(path)
	print(ProjectSettings.globalize_path(path))

func _ready():
	LocalGame.start_bp()
	expect(LocalGame.game.bp.bp_phase == "first_pick" and LocalGame.game.bp.banned_chars.is_empty(), "Self-play skips bans")
	LocalGame.game.bp._bp_first = 1
	LocalGame.bp_state_cache = LocalGame.game.bp.get_bp_state()
	var bp = load("res://scenes/bp_scene.tscn").instantiate()
	add_child(bp)
	await settle()
	var visible_cards := 0
	for button in bp._char_buttons:
		if button.visible:
			visible_cards += 1
			expect(bp._grid_area.get_global_rect().encloses(button.get_global_rect()), "BP tile fits the fixed grid")
	expect(visible_cards <= 12, "Roster has at most twelve visible characters")
	bp._on_char_clicked("mage")
	expect(LocalGame.game.bp.banned_chars.is_empty(), "Preview does not submit a ban")
	bp._confirm_preview()
	expect(LocalGame.game.bp.picked_chars[0] == "mage" and LocalGame.game.bp.bp_phase == "second_pick", "Confirmation picks once and rotates to second player")
	expect(bp._side_picks[1].text.contains(Config.char_name("mage")), "P2 selection appears on P2 side")
	expect(bp._preview_id.is_empty(), "New phase clears the old preview")
	var announcement = bp._turn_tween
	bp._on_bp_state(LocalGame.game.bp.get_bp_state())
	expect(bp._turn_tween == announcement, "Timer refresh does not repeat the rotation animation")
	bp._side_picks[1].pressed.emit()
	expect(bp._preview_id == "mage" and not bp._preview_desc.text.is_empty() and bp._confirm.disabled, "Picked character remains inspectable without being selectable twice")
	for button in bp._char_buttons:
		if button.get_meta("char_id") == "mage":
			expect(button.get_theme_stylebox("normal").border_width_left == 5 and button.get_meta("badge").text.contains("P2"), "Picked tile has a strong border and owner badge")
	var banned_state = LocalGame.game.bp.get_bp_state()
	banned_state.banned_chars = ["rogue"]
	banned_state.available_chars.erase("rogue")
	bp._is_local = false
	bp._on_bp_state(banned_state)
	bp._side_bans[1].pressed.emit()
	expect(bp._preview_id == "rogue" and bp._confirm.disabled and bp._preview_stats.text.contains("生命"), "Banned result button opens stats and skills without allowing another pick")
	bp._is_local = true
	bp._on_bp_state(LocalGame.game.bp.get_bp_state())
	bp._query = Config.char_name("gunslinger")
	bp._paginate()
	visible_cards = 0
	for button in bp._char_buttons:
		if button.visible: visible_cards += 1
	expect(visible_cards == 1, "Name search locates a character across pages")
	bp._query = ""
	bp._paginate()
	bp._on_char_clicked("vine_ent")
	await settle()
	await shot("bp")
	bp.queue_free()
	await settle()
	var first: int = LocalGame.game.bp._bp_first
	expect(LocalGame.game.bp.execute_action(1 - first, "pick", "rogue") and LocalGame.game.bp.is_done(), "Self-play finishes after only two selections")
	LocalGame.game.bp.reset()
	expect(LocalGame.game.bp.bp_phase == "first_ban", "Default BP retains bans for AI and online matches")
	LocalGame.disconnect_from_server()
	Network.player_index = 0
	Network._handle_packet(JSON.stringify({"t": "deck_config", "chars": ["mage", "rogue"], "first": 0, "time_left": 90}))
	var deck = load("res://scenes/deck_pick.tscn").instantiate()
	add_child(deck)
	await settle()
	expect(deck._deadline_label.text.contains("01:"), "Online configuration shows a countdown")
	var deadline: int = Network.deck_config_data.local_deadline
	deck._on_option("default")
	deck._on_edit()
	await settle()
	expect(int(Network.deck_config_data.local_deadline) == deadline, "Editing does not restart the countdown")
	Network._handle_packet(JSON.stringify({"t": "deck_timer", "time_left": 14}))
	deck._process(0)
	expect(deck._deadline_label.text.contains("00:14"), "Server countdown updates reach the editing page")
	expect(deck._deadline_label.get_theme_color("font_color") == deck.Style.ERROR_RED, "Final fifteen seconds have a warning color")
	await shot("deck_edit")
	deck.edit_root.hide()
	deck.wait_root.show()
	deck._process(0)
	expect(deck._deadline_label.text.contains("你的卡组已确认"), "Waiting player is not warned their submitted deck will be replaced")
	Network._handle_packet(JSON.stringify({"t": "deck_timer", "time_left": 0}))
	deck._process(0)
	expect(deck._deadline_label.text.contains("等待服务器"), "Zero remains expired rather than becoming unlimited")
	deck.queue_free()
	await settle()
	Network.deck_config_data = {}
	print("PREGAME UI: %d checks, %d failures" % [checks, failures])
	get_tree().quit(0 if failures == 0 else 1)
