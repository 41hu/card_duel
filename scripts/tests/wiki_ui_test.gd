extends Node

var failures := 0
var checks := 0

func expect(ok: bool, label: String):
	checks += 1
	if not ok: failures += 1
	print("[%s] %s" % ["PASS" if ok else "FAIL", label])

func settle():
	await get_tree().create_timer(0.25).timeout

func shot(label: String):
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	var path = "user://wiki_%s_%d.png" % [label, DisplayServer.window_get_size().x]
	get_viewport().get_texture().get_image().save_png(path)
	print(ProjectSettings.globalize_path(path))

func _ready():
	var wiki = load("res://scenes/wiki_scene.tscn").instantiate()
	add_child(wiki)
	await settle()
	expect(wiki._rows.get_child_count() == Config.CHARACTER_IDS.size(), "All characters have independent entries")
	expect(wiki._back.size.y < 100 and wiki._count.get_line_count() == 1, "Header stays compact without wrapping the entry count")
	await shot("list")
	wiki._select_category("cards")
	await settle()
	expect(wiki._rows.get_child_count() == Config.CARD_DB.size() + 3, "Every card type and the three effect overviews are indexed")
	var tree: Dictionary = {}
	var groups: Array = []
	var specials := 0
	for e in wiki.entries:
		if e.id == "char:vine_ent": tree = e
		if e.id.begins_with("group:"): groups.append(e.id)
		if e.id in ["char:hunter", "char:miko", "char:vine_ent"]:
			for section in e.sections:
				if section.kind == "item": specials += 1
	expect(specials == 3 and tree.sections[-1].kind == "item", "Special character items have independent description sections")
	expect(tree.sections.size() == 4 and tree.sections[-1].body.contains("1→2"), "Tree seed stacking is described as an item rather than another skill")
	expect(groups.has("group:enhanced") and groups.has("group:movement"), "Enhanced attacks and displacement have separate overview entries")
	wiki._list_scroll.scroll_vertical = 240
	await settle()
	var position: int = wiki._list_position
	wiki._open_entry("card:near")
	await settle()
	expect(wiki._detail_scroll.visible and (not wiki.narrow or not wiki._list_scroll.visible), "Narrow displays dedicate the content area to reading")
	wiki._open_entry("char:vine_ent")
	await settle()
	await shot("detail")
	expect(wiki._home.visible and wiki._home.pressed.get_connections().size() > 0, "Direct main-menu navigation remains available beside the back button")
	wiki._detail_scroll.scroll_vertical = int(wiki._detail_scroll.get_v_scroll_bar().max_value)
	await settle()
	await shot("special_item")
	wiki._go_back()
	expect(wiki.selected == "card:near", "Related-entry back returns to the previous article")
	wiki._go_back()
	await settle()
	expect(wiki._list_position == position, "Returning preserves list scroll position")
	wiki._select_category("all")
	wiki._search.text = "致残"
	wiki._search.text_changed.emit("致残")
	await settle()
	expect(wiki._rows.get_child_count() > 1, "Effect search finds related entries across categories")
	wiki._open_entry("char:vine_ent")
	wiki._go_back()
	expect(wiki._search.text == "致残", "Returning from an article preserves the current search")
	wiki._search.text = "不存在的百科条目"
	wiki._search.text_changed.emit(wiki._search.text)
	expect(wiki._count.text.begins_with("0"), "Empty searches have an explicit empty state")
	wiki._search.text = ""
	wiki._select_category("rules")
	wiki._open_entry("rules:deck")
	await settle()
	await shot("deck")
	var in_bounds := true
	for child in wiki._detail.get_children():
		if child is Label and child.size.x > wiki._detail_scroll.size.x: in_bounds = false
	expect(in_bounds, "Detail paragraphs stay within reading width")
	wiki._search.text = "致残"
	wiki.queue_free()
	await settle()
	var reopened = load("res://scenes/wiki_scene.tscn").instantiate()
	add_child(reopened)
	await settle()
	expect(reopened._search.text.is_empty() and reopened.selected.is_empty() and reopened._list_position == 0, "Reopening the encyclopedia clears search and filtered navigation state")
	# --- 手机端滑动修复回归：拖动滚动 vs 轻点选择 ---
	var drag_wiki = load("res://scenes/wiki_scene.tscn").instantiate()
	add_child(drag_wiki)
	await settle()
	var row := drag_wiki._rows.get_child(1) as Control
	var start: Vector2 = row.global_position + row.size / 2.0
	# 轻点（无位移）应打开条目
	var tap := InputEventMouseButton.new()
	tap.button_index = MOUSE_BUTTON_LEFT
	tap.position = start
	tap.pressed = true
	get_viewport().push_input(tap, true)
	tap = tap.duplicate()
	tap.pressed = false
	get_viewport().push_input(tap, true)
	await settle()
	expect(not drag_wiki.selected.is_empty(), "Light tap still opens an entry")
	drag_wiki._go_back()
	await settle()
	# 拖动（起点在按钮上、位移超过阈值）应滚动且不打开条目
	Input.warp_mouse(start)
	await settle()
	var touch := InputEventScreenTouch.new()
	touch.index = 0
	touch.position = start
	touch.pressed = true
	Input.parse_input_event(touch)
	await settle()
	Input.warp_mouse(start + Vector2(0, -60))
	await settle()
	Input.warp_mouse(start + Vector2(0, -140))
	await settle()
	var touch_up := InputEventScreenTouch.new()
	touch_up.index = 0
	touch_up.position = start + Vector2(0, -140)
	touch_up.pressed = false
	Input.parse_input_event(touch_up)
	await settle()
	expect(drag_wiki.selected.is_empty(), "Dragging the list does not open an entry")
	expect(drag_wiki._list_scroll.scroll_vertical > 0, "Dragging scrolls the list")
	# 拖动结束后条目应恢复可点
	var tap2 := InputEventMouseButton.new()
	tap2.button_index = MOUSE_BUTTON_LEFT
	tap2.position = start
	tap2.pressed = true
	get_viewport().push_input(tap2, true)
	tap2 = tap2.duplicate()
	tap2.pressed = false
	get_viewport().push_input(tap2, true)
	await settle()
	expect(not drag_wiki.selected.is_empty(), "Rows are clickable again after the drag ends")
	print("WIKI: %d checks, %d failures" % [checks, failures])
	get_tree().quit(0 if failures == 0 else 1)
