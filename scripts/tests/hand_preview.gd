extends Node

const DeckData = preload("res://scripts/data/deck_data.gd")

func _ready():
	LocalGame.disconnect_from_server()
	LocalGame.start_local_game("mage", "rogue", 0, [DeckData.default_deck(), DeckData.default_deck()], true)
	var game = LocalGame.game
	game.card_systems[0].hand.clear()
	var types := ["near", "heavy", "move", "magic", "blessing", "item", "near_armor"]
	for i in range(types.size()):
		game.card_systems[0].hand.append({"uid": -3000 - i, "type_id": types[i]})
	game.players[0].position = Vector2i(3, 0)
	game.players[1].position = Vector2i(5, 0)
	game.players[0].hp = 18
	LocalGame.battle_state_cache = game.get_full_state()
	get_tree().call_deferred("change_scene_to_file", "res://scenes/battle_scene.tscn")
