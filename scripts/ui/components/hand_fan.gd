extends Control

const Card = preload("res://scripts/ui/components/card_widget.gd")
const MIN_STEP := 96.0
const LONG_PRESS_MS := 450

signal card_clicked(uid: int, type_id: String)
signal card_details(uid: int, type_id: String)
signal empty_clicked()

var cards: Array = []
var selected_uid := -1
var hovered_uid := -1
var locked := false
var skill_selection := false

func set_skill_selection(value: bool):
	if skill_selection == value: return
	skill_selection = value
var _offset := 0.0
var _max_offset := 0.0
var _centers: Array[float] = []
var _rest_transforms: Array[Transform2D] = []
var _pressed_uid := -1
var _seeded := false  # 首次 sync_hand（初始手牌）不触发"新牌"闪烁，之后新增的牌才算新抽到
var _known_uids: Dictionary = {}  # 已见过的牌 UID，用于识别新拿到的牌
var _owner_index := -1
var _press_pos := Vector2.ZERO
var _last_pos := Vector2.ZERO
var _press_time := 0
var _dragging := false
var _long_fired := false
var _press_active := false
var _touch := false
var _scrollbar: HScrollBar
var _empty_label: Label

func _ready():
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	_empty_label = Label.new()
	_empty_label.text = "无手牌"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_font_size_override("font_size", 24)
	_empty_label.modulate = Color(1, 1, 1, 0.6)
	_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_empty_label)
	_scrollbar = HScrollBar.new()
	_scrollbar.custom_minimum_size.y = 12
	_scrollbar.page = 1
	_scrollbar.value_changed.connect(func(value):
		_offset = value
		_layout(true)
	)
	add_child(_scrollbar)
	resized.connect(_layout)
	mouse_exited.connect(func():
		if not _press_active: _hover(-1)
	)
	get_window().focus_exited.connect(cancel_gesture)

func sync_hand(hand: Array, me: Dictionary, responding: Array, discarded: Array, ignore_ap: bool = false):
	var player_index := int(me.get("index", -1))
	var owner_changed := player_index != _owner_index
	if owner_changed:
		for child in get_children():
			if child is Card and not child in cards:
				remove_child(child)
				child.queue_free()
		_seeded = false
		_known_uids.clear()
		_owner_index = player_index
		_offset = 0
	var old := {}
	for card in cards: old[card.card_uid] = card
	var next: Array = []
	var current_uids := {}
	for data in hand:
		var uid := int(data.uid)
		var card = old.get(uid)
		if card == null:
			card = Card.new()
			add_child(card)
		old.erase(uid)
		# 新牌识别：首次同步（初始手牌）不闪，之后新出现的 UID 视为"新抽到/夺取/天赐"的牌
		var is_new := _seeded and not _known_uids.has(uid)
		current_uids[uid] = true
		var tid := str(data.type_id)
		var cd: Dictionary = Config.CARD_DB.get(tid, {})
		var title: String = me.get("item_type_name", cd.get("name", tid)) if tid == "item" else cd.get("name", tid)
		card.setup(uid, tid, title, int(cd.get("ap", 0)), uid in discarded)
		if tid == "item":
			card.set_description(me.get("item_type_desc", cd.get("desc", "")))
			var character_art := "res://art/cards/item_%s.png" % me.get("char_id", "")
			if ResourceLoader.exists(character_art): card.set_art_path(character_art)
		card.set_respondable(tid in responding)
		card.set_selected(uid == selected_uid)
		# Old snapshots without affordability metadata stay neutral, not falsely blocked.
		card.blocked_reason = "" if ignore_ap else str(data.get("blocked_reason", ""))
		if not ignore_ap and not data.has("blocked_reason") and not bool(data.get("ap_affordable", true)):
			card.blocked_reason = "行动点不足"
		card.set_unaffordable(not card.blocked_reason.is_empty())
		if is_new:
			card.mark_new()
		next.append(card)
	for card in old.values():
		if owner_changed:
			remove_child(card)
			card.queue_free()
		else:
			card.retire()
	cards = next
	_known_uids = current_uids
	_seeded = true
	if get_card(selected_uid) == null: selected_uid = -1
	if get_card(hovered_uid) == null: hovered_uid = -1
	if _press_active and get_card(_pressed_uid) == null: cancel_gesture()
	_layout()

func get_card(uid: int):
	for card in cards:
		if card.card_uid == uid: return card
	return null

func select(uid: int):
	if uid == selected_uid: return
	selected_uid = uid
	for card in cards: card.set_selected(card.card_uid == uid)
	_layout()

func clear_focus():
	cancel_gesture()
	hovered_uid = -1
	selected_uid = -1
	for card in cards: card.set_selected(false)
	_layout()

func _layout(immediate: bool = false):
	if not is_node_ready(): return
	var count := cards.size()
	_empty_label.visible = count == 0
	_empty_label.position = Vector2(0, size.y - 150)
	_empty_label.size = Vector2(size.x, 40)
	var step := minf(150.0, maxf(MIN_STEP, (size.x - 240.0) / maxf(1, count - 1)))
	var total := 240.0 + step * maxi(0, count - 1)
	_max_offset = maxf(0, total - size.x)
	_offset = clampf(_offset, 0, _max_offset)
	_scrollbar.visible = _max_offset > 0
	_scrollbar.position = Vector2(12, size.y - 12)
	_scrollbar.size = Vector2(maxf(0, size.x - 24), 12)
	_scrollbar.max_value = maxf(size.x, total)
	_scrollbar.page = size.x
	_scrollbar.set_value_no_signal(_offset)
	_centers.clear()
	_rest_transforms.clear()
	var focus := selected_uid if selected_uid != -1 else hovered_uid
	var focus_index := -1
	for i in range(count):
		if cards[i].card_uid == focus: focus_index = i
	for i in range(count):
		var card = cards[i]
		var norm := (float(i) / (count - 1) * 2.0 - 1.0) if count > 1 and _max_offset == 0 else 0.0
		var x := maxf(0, (size.x - total) / 2.0) + 30 + i * step - _offset
		var focused := i == focus_index
		# Keep root slots stable; animate only the face, including its resting sink.
		# Static resting transforms keep blank space above the fan noninteractive.
		var sink := 20.0 + norm * norm * 30.0
		card.position = Vector2(x, size.y - Card.CARD_SIZE.y - 8)
		var pivot := Vector2(Card.CARD_SIZE.x / 2, Card.CARD_SIZE.y)
		var resting := Transform2D(norm * 0.075, Vector2.ZERO)
		resting.origin = card.position + Vector2(0, sink) + pivot - resting.basis_xform(pivot)
		_rest_transforms.append(resting)
		_centers.append(x + Card.CARD_SIZE.x / 2)
		var shift := 0.0
		if focus_index >= 0 and not focused: shift = -12.0 if i < focus_index else 12.0
		card.z_index = 2 if focused else 0
		move_child(card, -1)
		card.pose(Vector2(shift, -40.0 if focused else sink), 0.0 if focused else norm * 0.075, 1.22 if focused else 1.0, immediate)
	_scrollbar.z_index = 3

# Picking uses resting slots, never animated/rotated bounds.
func card_at(point: Vector2) -> int:
	if point.y < size.y - Card.CARD_SIZE.y - 8:
		var focused = get_card(selected_uid if selected_uid != -1 else hovered_uid)
		return focused.card_uid if focused != null and focused.face_rect().has_point(point) else -1
	if point.y > size.y - 16: return -1
	var best := -1
	var distance := INF
	for i in range(cards.size()):
		var d := absf(point.x - _centers[i])
		var inside := Rect2(Vector2.ZERO, Card.CARD_SIZE).has_point(_rest_transforms[i].affine_inverse() * point)
		if inside and d < distance and d <= Card.CARD_SIZE.x / 2 + 4:
			distance = d
			best = cards[i].card_uid
	if best != -1: return best
	var focus = get_card(selected_uid if selected_uid != -1 else hovered_uid)
	return focus.card_uid if focus != null and focus.face_rect().has_point(point) else -1

func _has_point(point: Vector2) -> bool:
	return Rect2(Vector2.ZERO, size).has_point(point) and (point.y >= size.y - Card.CARD_SIZE.y - 8 or card_at(point) != -1)

func _hover(uid: int):
	if hovered_uid == uid: return
	hovered_uid = uid
	_layout()

func cancel_gesture():
	_press_active = false
	_pressed_uid = -1
	_dragging = false
	_long_fired = false

func _gui_input(event: InputEvent):
	if event is InputEventMouseButton:
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and event.pressed:
			_offset += -96 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 96
			_hover(-1)
			_layout(true)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			begin_pointer(event.position, event.device == InputEvent.DEVICE_ID_EMULATION)
			accept_event()
	elif event is InputEventMouseMotion and not _press_active:
		if event.device != InputEvent.DEVICE_ID_EMULATION: _touch = false
		if not _touch: _hover(card_at(event.position))

func begin_pointer(point: Vector2, touch: bool):
	if locked: return
	_touch = touch
	_pressed_uid = card_at(point)
	_press_active = true
	_press_pos = point
	_last_pos = point
	_press_time = Time.get_ticks_msec()
	_dragging = false
	_long_fired = false

func move_pointer(point: Vector2):
	if not _press_active: return
	if point.distance_to(_press_pos) > 16:
		_dragging = true
		_hover(-1)
	if _dragging:
		_offset -= point.x - _last_pos.x
		_layout(true)
	_last_pos = point

func end_pointer(point: Vector2):
	if not _press_active: return
	var uid := _pressed_uid
	var click := not locked and not _dragging and not _long_fired and point.distance_to(_press_pos) <= 16
	cancel_gesture()
	if not click: return
	var card = get_card(uid)
	if card != null and card_at(point) == uid: card_clicked.emit(uid, card.type_id)
	elif uid == -1: empty_clicked.emit()

func _input(event: InputEvent):
	if not _press_active: return
	if event is InputEventMouseMotion:
		move_pointer(get_global_transform_with_canvas().affine_inverse() * event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		end_pointer(get_global_transform_with_canvas().affine_inverse() * event.position)
		get_viewport().set_input_as_handled()

func _process(_delta: float):
	if _press_active and not _dragging and not _long_fired and Time.get_ticks_msec() - _press_time >= LONG_PRESS_MS:
		_long_fired = true
		var card = get_card(_pressed_uid)
		if card != null: card_details.emit(card.card_uid, card.type_id)
