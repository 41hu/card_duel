extends Node

class TestServer extends "res://scripts/server/server_main.gd":
	func _start_server():
		_tcp_server = TCPServer.new()
		var err = _tcp_server.listen(0, "127.0.0.1")
		assert(err == OK)

class TestClients extends "res://scripts/tests/online_deck_test.gd":
	signal finished(ok: bool)
	var port: int
	func _ready():
		ws1 = WebSocketPeer.new()
		ws2 = WebSocketPeer.new()
		ws1.connect_to_url("ws://127.0.0.1:%d" % port)
		ws2.connect_to_url("ws://127.0.0.1:%d" % port)
		_deck = DeckData.default_deck()
		var timer = Timer.new()
		timer.wait_time = 0.05
		timer.timeout.connect(_tick)
		add_child(timer)
		timer.start()
	func _write(result: String, detail: String):
		var private := true
		var budgets := true
		var affordability := true
		var budget_views := 0
		var config_clocks := 0
		for messages in [msgs1, msgs2]:
			var viewer = 0 if messages == msgs1 else 1
			for msg in messages:
				if msg.get("t") == "deck_config" and int(msg.get("time_left", -1)) == 90:
					config_clocks += 1
				if msg.get("t") == "game_starting" and msg.has("state"):
					budget_views += 1
					for p in msg.state.players:
						for card in p.hand:
							if not card.has("ap_affordable"): affordability = false
						if p.index != viewer and not p.hand.is_empty(): private = false
						for field in ["ap_attack_max", "ap_move_max", "ap_function_max"]:
							if not p.has(field): budgets = false
		print("ONLINE AUDIT: %s; private=%s; budgets=%s; affordability=%s; views=%d; %s" % [result, private, budgets, affordability, budget_views, detail])
		ws1.close()
		ws2.close()
		print("ONLINE CONFIG CLOCKS: %d/2" % config_clocks)
		finished.emit(result == "PASS" and private and budgets and affordability and budget_views >= 2 and config_clocks == 2)

func _ready():
	var server = TestServer.new()
	add_child(server)
	var clients = TestClients.new()
	clients.port = server._tcp_server.get_local_port()
	clients.finished.connect(func(ok): get_tree().quit(0 if ok else 1))
	add_child(clients)
	get_tree().create_timer(20.0).timeout.connect(func():
		push_error("ONLINE AUDIT: timed out")
		get_tree().quit(1)
	)
