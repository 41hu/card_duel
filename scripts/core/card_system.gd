# card_system.gd — 卡牌系统（牌堆管理、手牌、弃牌堆、抽牌、洗牌）
extends RefCounted

var deck: Array = []          # [{uid, type_id}]
var hand: Array = []          # [{uid, type_id}]
var discard: Array = []       # [{uid, type_id}]

func _init(initial_deck: Array, shared_discard = null):
	if shared_discard != null:
		# 共享模式：使用外部传入的 deck 和 discard 引用
		deck = initial_deck
		discard = shared_discard
	else:
		deck = initial_deck.duplicate()
		shuffle_deck()

func shuffle_deck():
	deck.shuffle()

# 抽N张牌，抽完则洗弃牌堆
func draw_cards(count: int) -> Array:
	var drawn = []
	for _i in range(count):
		var card = _draw_one()
		if not card.is_empty():
			drawn.append(card)
			hand.append(card)
	return drawn

func _draw_one() -> Dictionary:
	if deck.is_empty():
		if discard.is_empty():
			return {}
		_recycle_discard()
		if deck.is_empty():
			return {}
	var card = deck.pop_back()
	return card

func _recycle_discard():
	deck.clear()
	deck.append_array(discard)
	discard.clear()
	shuffle_deck()

# 从手牌中打出卡牌
func play_card(card_uid: int) -> Dictionary:
	for i in range(hand.size()):
		if hand[i].uid == card_uid:
			var card = hand[i]
			hand.remove_at(i)
			_append_discard(card)
			return card
	return {}

# 弃牌（进入弃牌堆，牌堆耗尽时整体回炉重洗）
func discard_card(card_uid: int) -> Dictionary:
	for i in range(hand.size()):
		if hand[i].uid == card_uid:
			var card = hand[i]
			hand.remove_at(i)
			_append_discard(card)
			return card
	return {}

# 弃掉所有手牌
func discard_all() -> Array:
	var discarded = hand.duplicate()
	for card in hand:
		_append_discard(card)
	hand.clear()
	return discarded

# 随机弃掉N张手牌
func random_discard(count: int) -> Array:
	var discarded = []
	var to_discard = min(count, hand.size())
	for _i in range(to_discard):
		var idx = randi() % hand.size()
		discarded.append(hand[idx])
		_append_discard(hand[idx])
		hand.remove_at(idx)
	return discarded

# 丢弃指定手牌（被摧毁等）
func discard_specific(card_uid: int) -> Dictionary:
	return discard_card(card_uid)

# 随机从手牌中获取一张（夺取）
func random_take() -> Dictionary:
	if hand.is_empty():
		return {}
	var idx = randi() % hand.size()
	var card = hand[idx]
	hand.remove_at(idx)
	return card

# ---------- 卡牌流转统一入口（防牌堆污染） ----------
# 所有卡牌必须是 {uid, type_id} 结构；非法卡（如装备数据结构）直接拒绝并报错。
# 新增牌堆操作功能时，必须走这些入口，禁止直接碰 hand/discard/deck 数组。
func _is_valid_card(card) -> bool:
	return card is Dictionary and card.has("uid") and card.has("type_id")

func _append_discard(card: Dictionary) -> bool:
	if not _is_valid_card(card):
		push_error("[CardSystem] 拒绝非法卡进入弃牌堆: %s" % str(card))
		return false
	discard.append(card)
	return true

# 将卡牌加入手牌
func add_to_hand(card: Dictionary):
	if not _is_valid_card(card):
		push_error("[CardSystem] 拒绝非法卡进入手牌: %s" % str(card))
		return
	hand.append(card)

# 是否包含某张卡
func has_card(card_uid: int) -> bool:
	for c in hand:
		if c.uid == card_uid:
			return true
	return false

# 按type_id查找手牌中是否有攻击卡可用于响应
func find_response_card(response_type: int) -> Dictionary:
	# BLOCK(0): 近战/重击卡可格挡
	# RESTRAIN(1): 远程/穿心卡可牵制
	# DODGE(2): 魔法/吟唱卡可闪避
	for c in hand:
		var type_id = c.type_id
		match response_type:
			0:  # BLOCK
				if type_id == "near" or type_id == "heavy":
					return c
			1:  # RESTRAIN
				if type_id == "range" or type_id == "pierce":
					return c
			2:  # DODGE
				if type_id == "magic" or type_id == "chant":
					return c
	return {}

# 手牌中是否有回复卡
func has_heal_card() -> bool:
	for c in hand:
		if c.type_id == "heal_3" or c.type_id == "heal_5":
			return true
	return false

# 使用手牌中的一张回复卡
func use_heal_card() -> Dictionary:
	for i in range(hand.size()):
		var type_id = hand[i].type_id
		if type_id == "heal_3" or type_id == "heal_5":
			var card = hand[i]
			hand.remove_at(i)
			_append_discard(card)
			return card
	return {}

func get_hand_type_ids() -> Array:
	var ids = []
	for c in hand:
		ids.append(c.type_id)
	return ids

func to_dict() -> Dictionary:
	return {
		deck_size = deck.size(),
		discard_size = discard.size(),
		hand = hand.duplicate(),
	}

func from_dict(data: Dictionary):
	deck.clear()
	discard.clear()
	hand = data.get("hand", []).duplicate()
	# deck_size and discard_size are tracked but actual content is server-only
