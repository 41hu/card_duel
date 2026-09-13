extends Node

const MatchState = preload("res://scripts/core/match_state.gd")
const DeckData = preload("res://scripts/data/deck_data.gd")

class RecordingServer extends "res://scripts/server/server_main.gd":
	var sent: Array = []
	func _send_to(peer_idx: int, msg: Dictionary):
		sent.append({"peer": peer_idx, "msg": msg.duplicate(true)})

var _fails := 0
var _checks := 0

func _ready():
	_test_deck_identity()
	_test_weapon_pool()
	_test_independent_rules()
	_test_discard_floor()
	_test_ffa_turns()
	_test_movement_occupancy()
	_test_server_visibility()
	_test_server_actions()
	_test_weapon_pending()
	_test_match_release()
	_test_local_restart()
	_test_ffa_action_death()
	_test_ffa_ground_destroy()
	_test_vine_first_turn()
	_test_channel_target()
	_test_response_clocks()
	print("CORE AUDIT: %d checks, %d failures" % [_checks, _fails])
	get_tree().quit(0 if _fails == 0 else 1)

func _expect(ok: bool, label: String):
	_checks += 1
	if not ok:
		_fails += 1
	print("[%s] %s" % ["PASS" if ok else "FAIL", label])

func _test_response_clocks():
	for kind in ["near", "freeze", "priest_chant"]:
		for timeout in [false, true]:
			var g = _game()
			g.disable_timeout = false
			g.players[1].position = g.players[0].position
			g.card_systems[0].hand = [{"uid": 880, "type_id": kind}]
			g._action_deadline = Time.get_ticks_msec() + 50000
			if kind == "priest_chant":
				g._begin_priest_chant(0, {"type_id": "heal_3"}, 1)
			else:
				g.process_action(0, {"action": "play_card", "card_uid": 880})
			var label: String = "%s (timeout=%s): " % [kind, timeout]
			_expect(g.response_pending and g._action_deadline == 0 and g.get_full_state().action_time_left == 20, label + "response gets 20s and pauses action clock")
			g.process_response(0, false)
			_expect(g.response_pending and g._action_deadline == 0, label + "wrong player cannot resume the clock")
			g._response_deadline = Time.get_ticks_msec() + 5000
			_expect(g.get_full_state().action_time_left == 5, label + "snapshot shows response time")
			if timeout:
				g._response_deadline = Time.get_ticks_msec() - 1
				g.check_timers()
			else:
				g.skip_response(1)
			var left: int = g._action_deadline - Time.get_ticks_msec()
			_expect(not g.response_pending and left > 49000 and left <= 50000, label + "original 50s resumes, not 5s or 60s")
			if kind == "freeze":
				_expect(g.attacker_last_damage == 0 and g.players[1].frozen, label + "zero-damage freeze still applies")
			g._action_deadline = Time.get_ticks_msec() - 1
			g.check_timers()
			_expect(g.waiting_for_discard, label + "resumed action clock still expires normally")
	var g = _game()
	g.disable_timeout = false
	g.players[1].position = g.players[0].position
	g.card_systems[0].hand = [{"uid": 881, "type_id": "near"}]
	g._action_deadline = Time.get_ticks_msec() + 50000
	g.process_action(0, {"action": "play_card", "card_uid": 881})
	g.pending_attack_segments = 2
	g._response_deadline = Time.get_ticks_msec() - 1
	g.check_timers()
	_expect(g.response_pending and g.pending_attack_segment == 2 and g._action_deadline == 0, "Multi-hit timeout starts a fresh response, not an action turn")
	_expect(g.get_full_state().action_time_left == 20 and g._paused_action_ms > 49000, "Multi-hit response preserves the same action budget")
	g.skip_response(1)
	_expect(g.get_full_state().action_time_left >= 49, "Final hit resumes original budget")
	g = _game(true)
	g.disable_timeout = false
	g._action_deadline = Time.get_ticks_msec() + 50000
	g.card_systems[0].hand = [{"uid": 884, "type_id": "freeze"}]
	g.process_action(0, {"action": "play_card", "card_uid": 884, "extra": {"target": 2}})
	g.skip_response(1)
	_expect(g.response_pending and g._action_deadline == 0, "FFA bystander cannot end another player's response")
	g.skip_response(2)
	_expect(g.players[2].frozen and g.get_full_state().action_time_left >= 49, "FFA target response restores the attacker's budget")
	g = _game()
	g.disable_timeout = false
	g.players[1].hp = 1
	g.players[1].position = g.players[0].position
	g.card_systems[1].deck = [{"uid": 890, "type_id": "heal_5"}, {"uid": 891, "type_id": "heal_5"}, {"uid": 892, "type_id": "heal_5"}, {"uid": 893, "type_id": "heal_5"}]
	g.card_systems[0].hand = [{"uid": 889, "type_id": "near"}]
	g._action_deadline = Time.get_ticks_msec() + 50000
	g.process_action(0, {"action": "play_card", "card_uid": 889})
	g.skip_response(1)
	_expect(g.stats[1].resurrected == 1 and g.get_full_state().action_time_left >= 49, "Defender resurrection does not reset the action budget")
	for unlimited in [0, 1]:
		g = _game()
		g.disable_timeout = false
		g.no_timeout_for = unlimited
		g._action_deadline = Time.get_ticks_msec() + 50000
		g.card_systems[0].hand = [{"uid": 882, "type_id": "freeze"}]
		g.card_systems[1].hand = [{"uid": 883, "type_id": "magic"}]
		g.process_action(0, {"action": "play_card", "card_uid": 882})
		if unlimited == 1:
			g._response_deadline = Time.get_ticks_msec() - 1
			g.check_timers()
			_expect(g.response_pending and g.get_full_state().action_time_left == -1, "Untimed defender never auto-skips")
		g.process_response(1, true, 883)
		_expect(not g.players[1].frozen and g.attacker_last_damage == 0, "Magic dodges zero-damage freeze")
		_expect(g.get_full_state().action_time_left == -1 if unlimited == 0 else g.get_full_state().action_time_left >= 49, "Mixed timed/untimed players retain their own clock policy")

func _test_channel_target():
	var g = MatchState.new()
	g.disable_timeout = true
	g._setup_match(["spellblade", "mage", "hunter", "priest"], 0, [], true)
	g._start_game()
	for id in Config.WEAPON_DB:
		if Config.WEAPON_DB[id].get("type", "") == "near":
			g.players[0].weapon = {"id": id, "data": Config.WEAPON_DB[id]}
			break
	g.card_systems[0].hand = [{"uid": 800, "type_id": "magic"}]
	var result = g.process_action(0, {"action": "use_skill", "skill": "spellblade_channel", "card_uid": 800, "target": 2})
	_expect(result.success and g._pending_target == 2, "Channel preserves the chosen multiplayer target")

func _test_vine_first_turn():
	for multi in [false, true]:
		for first in [0, 1]:
			var g = MatchState.new()
			g.disable_timeout = true
			var chars = ["vine_ent", "mage", "hunter", "priest"] if multi else ["vine_ent", "mage"]
			var decks: Array = []
			for i in range(chars.size()): decks.append(DeckData.default_deck())
			g._setup_match(chars, first, decks, true)
			g._start_game()
			while g.current_player != 0: g._advance_to_next_player()
			var origin: Vector2i = g.players[0].position
			var geo = g.movement.geometry
			var label = "Vine first turn (multi=%s, first=%d): " % [multi, first]
			_expect(g.item_system.get_seed_layers(origin) == 1, label + "one root seed without moving")
			g.card_systems[0].hand = [{"uid": 80, "type_id": "near"}, {"uid": 81, "type_id": "item"}]
			var snapshot = g.get_full_state()
			_expect(snapshot.items.size() == 1 and geo.from_dict(snapshot.items[0].position) == origin, label + "snapshot includes root seed")
			var direction = geo.direction_between(origin, g.players[1].position)
			var target = origin + direction
			_expect(g.item_system.can_spread_to(target).is_empty(), label + "adjacent cell permits spread")
			_expect(not g.item_system.can_spread_to(origin + direction * 2).is_empty(), label + "spread cannot skip a cell")
			var spread = g.process_action(0, {"action": "use_skill", "skill": "vine_spread", "card_uid": 80, "pos": geo.to_dict(target)})
			_expect(spread.success and g.item_system.get_seed_layers(target) == 1, label + "spread action succeeds")
			var item = g.process_action(0, {"action": "play_card", "card_uid": 81, "extra": {"trap_pos": geo.to_dict(origin)}})
			_expect(item.success and g.item_system.get_seed_layers(origin) == 2, label + "item stacks under self")
			g._ensure_vine_seed(0)
			_expect(g.item_system.get_seed_layers(origin) == 2 and g.players[0].buffs.is_empty(), label + "root does not overstack or cripple self")
			# 位移后生根：树妖移动一格 → 新位置 1 层、旧位置种子保留（持续存在）
			var dir_m = geo.direction_between(g.players[0].position, g.players[1].position)
			g.movement.move_player(0, dir_m, false)
			_expect(g.item_system.get_seed_layers(g.players[0].position) == 1, label + "root seed regrows after moving")
			_expect(g.item_system.get_seed_layers(origin) == 2, label + "old seed persists after moving")

func _game(multi: bool = false):
	var g = MatchState.new()
	g.disable_timeout = true
	if multi:
		g._setup_match(["fighter", "mage", "hunter", "priest"], 0, [], true)
	else:
		g.init_match("fighter", "mage", 0, [DeckData.default_deck(), DeckData.default_deck()], true)
	g._start_game()
	return g

func _server(g):
	var s = RecordingServer.new()
	var peers: Array = []
	var names: Array = []
	var ready: Array = []
	for i in range(g.players.size()):
		s._peers.append({"player_index": i, "room_id": "audit", "peer_name": "P%d" % i, "dead": false})
		peers.append(i)
		names.append("P%d" % i)
		ready.append(true)
	s._rooms.append({"id": "audit", "stage": "game", "match": g,
		"peer_indices": peers, "peer_names": names, "ready": ready,
		"max_players": peers.size(), "rapid_mode": false, "config": {}})
	return s

func _test_deck_identity():
	var g = _game(true)
	var seen := {}
	var unique := true
	for cs in g.card_systems:
		for card in cs.deck + cs.hand + cs.discard:
			if seen.has(card.uid): unique = false
			seen[card.uid] = true
	_expect(unique, "Independent default decks have globally unique card UIDs")

func _test_weapon_pool():
	var pool = DeckData.default_weapon_pool()
	pool.near = [pool.near[0], pool.near[0], pool.near[0], pool.near[0]]
	_expect(not DeckData.validate_weapon_pool(pool), "Weapon pools reject duplicate weapons")

func _test_independent_rules():
	var g = _game()
	g._apply_game_config({"freeze_no_cooldown": true})
	g.players[0].ap_attack = 0
	g.card_systems[0].hand = [{"uid": 80, "type_id": "range"}]
	var result = g.process_action(0, {"action": "play_card", "card_uid": 80})
	_expect(not result.success and not g.rapid_mode, "Freeze-only rule does not enable unlimited play")
	var rapid = MatchState.new()
	rapid.rapid_mode = true
	rapid._apply_game_config({})
	_expect(rapid.rapid_mode, "Legacy rapid mode survives empty room config")

func _test_discard_floor():
	var g = _game()
	g.hand_min_override = 3
	g.hand_limit_override = 5
	g.card_systems[0].hand = []
	for i in range(5): g.card_systems[0].hand.append({"uid": i + 80, "type_id": "near"})
	g._discard_phase()
	g.confirm_discard(0, [80, 81, 82, 83, 84])
	_expect(g.card_systems[0].hand.size() >= 3, "Batch discard preserves the configured hand minimum")
	g.current_player = 0
	g.waiting_for_discard = true
	g.card_systems[0].hand = [{"uid": 80, "type_id": "near"}, {"uid": 81, "type_id": "near"}, {"uid": 82, "type_id": "near"}]
	g.discard_one(0, 80)
	_expect(g.card_systems[0].hand.size() == 3, "Single discard preserves the configured hand minimum")

func _test_ffa_turns():
	var g = _game(true)
	g.players[0].eliminated = true
	g.players[0].hp = 0
	g.current_player = 3
	g.turn_number = 4
	g._advance_to_next_player()
	_expect(g.current_player == 1 and g.turn_number == 5, "FFA rounds advance across an eliminated first player")
	g = _game(true)
	g.current_player = 1
	g.players[1].hp = 1
	g.players[1].dots = [{"type": "burn", "damage": 2, "duration": 2, "source": 0}]
	g._judgment_phase()
	_expect(g.players[1].eliminated and g.current_player != 1, "Judgment death skips the eliminated player's action phase")
	_expect(g.get_opponent(0, 1) == -1, "Eliminated players cannot be targeted")

func _test_movement_occupancy():
	var g = _game(true)
	g.players[0].position = Vector2i(-1, 0)
	g.players[1].position = Vector2i(0, 0)
	g.players[2].position = Vector2i(1, 0)
	g.players[3].position = Vector2i(0, 2)
	_expect(not g.movement.move_player(0, Vector2i(1, 0)), "Push cannot move a player into a third player")
	_expect(not g.movement.deter(0, 1), "Deter cannot overlap a third player")

func _test_server_visibility():
	var g = _game()
	var s = _server(g)
	var room = s._rooms[0]
	room.stage = "deck"
	room.decks = [DeckData.default_deck(), DeckData.default_deck()]
	room.weapon_pools = [DeckData.default_weapon_pool(), DeckData.default_weapon_pool()]
	room.bp_chars = ["fighter", "mage"]
	room.bp_first = 0
	s._try_start_deck(room)
	var hidden := true
	var starts := 0
	for entry in s.sent:
		if entry.msg.get("t") == "game_starting":
			starts += 1
			for p in entry.msg.state.players:
				if p.index != entry.peer and not p.hand.is_empty(): hidden = false
	_expect(starts == 2 and hidden, "Custom-deck start packets hide opponents' hands")
	s.sent.clear()
	g.players[1].buffs.append({"type": "exposed", "value": 1, "duration": 1})
	g.players[1].frozen_move = true
	g._reveal_to = 0
	g._reveal_from = 1
	s._on_match_state_changed(g.get_full_state(), room)
	_expect(not s.sent[0].msg.players[1].hand.is_empty(), "Exposed target hand is selectable online")
	_expect(not s.sent[1].msg.has("revealed_hand"), "Private reveal payload is not sent to other viewers")
	_expect(s.sent[0].msg.players[1].get("frozen_move", false), "Movement lock is serialized for the status display")
	g.players[1].buffs.clear()
	s.sent.clear()
	s._on_reveal_hand(0)
	var leaked := false
	for entry in s.sent:
		if not entry.msg.get("cards", []).is_empty(): leaked = true
	_expect(not leaked, "Unsolicited reveal_hand cannot read hidden cards")
	s.free()

func _test_server_actions():
	var g = _game()
	var s = _server(g)
	g._wind_bow_pending = true
	g._wind_bow_target = 1
	g._response_attacker = 0
	s._handle_message(0, JSON.stringify({"t": "wind_bow_move", "cancel": true}))
	_expect(not g._wind_bow_pending, "Normal wind_bow_move packet reaches the correct action")
	g.items = [{"item_type": "vine_seed", "position": g.players[0].position, "owner": 1, "layers": 1}]
	g.card_systems[0].hand = [{"uid": 80, "type_id": "near"}]
	s._handle_message(0, JSON.stringify({"t": "vine_remove", "card_uid": 80, "pos": g.movement.geometry.to_dict(g.players[0].position)}))
	_expect(g.items.is_empty(), "Normal vine_remove packet reaches the correct action")
	# 除根范围（意图=相邻）：相邻格（distance=0）可除根；隔一格（distance=1）拒绝
	g.players[0].ap_attack = 3
	g.items = [{"item_type": "vine_seed", "position": g.players[0].position + Vector2i(1, 0), "owner": 1, "layers": 1}]
	g.card_systems[0].hand = [{"uid": 81, "type_id": "heavy"}]
	s._handle_message(0, JSON.stringify({"t": "vine_remove", "card_uid": 81, "pos": g.movement.geometry.to_dict(g.players[0].position + Vector2i(1, 0))}))
	_expect(g.items.is_empty(), "Adjacent tile seed can be uprooted")
	g.players[0].ap_attack = 3
	g.items = [{"item_type": "vine_seed", "position": g.players[0].position + Vector2i(2, 0), "owner": 1, "layers": 1}]
	g.card_systems[0].hand = [{"uid": 82, "type_id": "near"}]
	s._handle_message(0, JSON.stringify({"t": "vine_remove", "card_uid": 82, "pos": g.movement.geometry.to_dict(g.players[0].position + Vector2i(2, 0))}))
	_expect(g.items.size() == 1 and g.card_systems[0].has_card(82), "Seed two tiles away cannot be uprooted")
	s._handle_message(0, JSON.stringify({"t": "vine_remove", "action": "use_skill", "skill": "_debug_end", "win": true}))
	_expect(g.phase != Config.Phase.GAME_OVER, "An action override cannot invoke debug skills online")
	s.free()
	g = _game()
	s = _server(g)
	g.players[0].hp = 1
	g.card_systems[0].hand = [{"uid": 80, "type_id": "near"}]
	s._handle_message(0, JSON.stringify({"t": "play_card", "card_uid": 80, "extra": {"as_type": "heal_5"}}))
	_expect(g.players[0].hp == 1 and g.card_systems[0].has_card(80), "Clients cannot transform arbitrary cards via extra")
	s.free()

func _test_weapon_pending():
	var g = _game()
	g.waiting_for_weapon_choice = 0
	g.pending_weapon_id = "longbow"
	var result = g.process_action(0, {"action": "end_turn"})
	_expect(not result.success and g.turn_phase == Config.TurnPhase.ACTION, "Pending weapon choice blocks ending the action phase")

func _test_match_release():
	var g = _game()
	var reference = weakref(g)
	g = null
	_expect(reference.get_ref() == null, "Finished matches release their subsystem references")

func _test_local_restart():
	LocalGame.game_config = {"infinite_play": true}
	LocalGame.disconnect_from_server()
	_expect(LocalGame.game_config.is_empty(), "Disconnect clears previous local room rules")
	LocalGame.start_ai_game("fighter", "mage", 1, [], false, [], 0)
	_expect(LocalGame.game.first_player == 0, "AI match preserves the BP first player")
	LocalGame.disconnect_from_server()

func _test_ffa_action_death():
	var g = _game(true)
	g.players[0].hp = 1
	g.players[0].position = Vector2i.ZERO
	g.players[0].buffs = [{"type": "vine_cripple", "value": 1, "duration": -2}]
	g.card_systems[0].hand = [{"uid": 80, "type_id": "move"}]
	g.process_action(0, {"action": "play_card", "card_uid": 80, "extra": {"direction": {"x": 1, "y": 0}}})
	_expect(g.players[0].eliminated and g.current_player != 0, "Lethal movement in FFA immediately advances the turn")

func _test_ffa_ground_destroy():
	var g = _game(true)
	g.items = [{"item_type": "trap", "position": Vector2i.ZERO, "owner": 1}]
	g.card_systems[0].hand = [{"uid": 80, "type_id": "destroy"}]
	var result = g.process_action(0, {"action": "play_card", "card_uid": 80, "extra": {"destroy_target": "trap", "trap_pos": {"x": 0, "y": 0}}})
	_expect(result.success and g.items.is_empty(), "FFA ground-item destruction does not require a player target")
