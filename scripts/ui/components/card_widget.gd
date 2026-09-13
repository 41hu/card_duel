extends Control

signal pressed(card_uid: int)

const CARD_SIZE := Vector2(180, 264)
const INK := Color("253238")
const PAPER := Color("f2f5f3")
const SKILL_COLOR := Color("489dff")
const GRAYSCALE = preload("res://scripts/ui/components/card_grayscale.gdshader")
const APBadge = preload("res://scripts/ui/components/action_point_badge.gd")
# 类型色（免费/攻击/移动/功能）：鲜明高区分度，卡面顶部色带+AP徽章+主体染色共用
const ACCENTS := [Color("d4a017"), Color("c0392b"), Color("2980b9"), Color("27ae60")]

class SelectionOverlay extends Control:
	var selected := false
	var discarded := false
	var skill_material := false
	var discard_phase := false
	var pulse_strength := 0.0

	func _init():
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_process(false)

	func _process(_delta: float):
		pulse_strength = 0.5 + 0.5 * sin(Time.get_ticks_msec() * TAU / 1800.0)
		queue_redraw()

	func set_state(is_selected: bool, is_discarded: bool):
		selected = is_selected
		discarded = is_discarded
		visible = selected or discarded or skill_material or discard_phase
		queue_redraw()

	func _draw():
		if not selected and not discarded and not skill_material and not discard_phase:
			return
		var rect := Rect2(Vector2.ZERO, size)
		if discard_phase and not discarded:
			draw_rect(rect.grow(-2), Color(0.74, 0.56, 1.0, 0.65), false, 3.0)
		if skill_material:
			var blue := Color("489dff")
			draw_rect(rect.grow(-6), Color(blue, 0.08 + pulse_strength * 0.22), false, 12.0)
			draw_rect(rect.grow(-2), Color(blue, 0.45 + pulse_strength * 0.55), false, 4.0)
		if discarded:
			draw_rect(rect, Color(0.42, 0.25, 0.74, 0.20), true)
			for x in range(-int(size.y), int(size.x) + int(size.y), 18):
				var start_x := maxf(4.0, x)
				var end_x := minf(size.x - 4.0, x + size.y)
				if start_x < end_x:
					draw_line(Vector2(start_x, clampf(size.y + x - start_x, 4, size.y - 4)), Vector2(end_x, clampf(size.y + x - end_x, 4, size.y - 4)), Color(0.83, 0.72, 1.0, 0.42), 5.0)
			draw_rect(rect.grow(-2), Color(0.74, 0.56, 1.0, 0.92), false, 6.0)
			draw_rect(Rect2(Vector2(size.x - 39, 5), Vector2(34, 34)), Color(0.24, 0.14, 0.45, 0.74), true)
			var cx := size.x - 22.0
			var cy := 22.0
			draw_line(Vector2(cx - 8, cy - 8), Vector2(cx + 8, cy + 8), Color(0.96, 0.91, 1.0, 0.96), 4.0)
			draw_line(Vector2(cx + 8, cy - 8), Vector2(cx - 8, cy + 8), Color(0.96, 0.91, 1.0, 0.96), 4.0)
		if selected:
			var tint := Color("489dff") if skill_material else Color(0.28, 0.94, 0.78)
			draw_rect(rect, Color(tint, 0.10), true)
			draw_rect(rect.grow(-3), tint, false, 6.0)
			draw_rect(rect.grow(-8), Color(0.92, 1.0, 0.96, 0.52), false, 2.0)

var card_uid: int = -1
var type_id := ""
var ap_type := 0
var _selected := false
var _respondable := false
var _skill_material := false
var _skill_unavailable := false
var _gray_material: ShaderMaterial
var _is_discarded := false
var _unaffordable := false
var blocked_reason := ""
var _face: Panel
var _top_band: ColorRect
var _ap_badge: Control
var _name_label: Label
var _ap_label: Label
var _description: Label
var _art: TextureRect
var _art_bg: ColorRect
var _mark: Label
var _overlay: SelectionOverlay
var _motion: Tween
var _art_path := ""
var _flash_active := false
var _flash_tween: Tween
var _focused := false
var _discard_sway := 0.0
var _pose_offset := Vector2.ZERO:
	set(value):
		_pose_offset = value
		_apply_pose()
var _pose_angle := 0.0:
	set(value):
		_pose_angle = value
		_apply_pose()
var _pose_zoom := 1.0:
	set(value):
		_pose_zoom = value
		_apply_pose()

func _process(_delta: float):
	_update_discard_sway()

func _update_discard_sway():
	_discard_sway = 0.0
	if _overlay.discard_phase and not _focused and not _is_discarded:
		var time := Time.get_ticks_msec() / 1000.0
		_discard_sway = sin(time * 5.5 + card_uid * 1.7) * deg_to_rad(0.65)
	_apply_pose()

func _apply_pose():
	if _face == null: return
	_face.position = _pose_offset
	_face.rotation = _pose_angle + _discard_sway
	_face.scale = Vector2.ONE * _pose_zoom

func _init():
	set_process(false)
	size = CARD_SIZE
	custom_minimum_size = CARD_SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face = Panel.new()
	_face.size = CARD_SIZE
	_face.pivot_offset = Vector2(CARD_SIZE.x / 2, CARD_SIZE.y)
	_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_face)
	# 顶部类型色带（全宽 8px，醒目区分牌类型）
	_top_band = ColorRect.new()
	_top_band.position = Vector2.ZERO
	_top_band.size = Vector2(CARD_SIZE.x, 8)
	_top_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face.add_child(_top_band)
	_ap_badge = APBadge.new()
	_ap_badge.position = Vector2(3, 4)
	_ap_badge.size = Vector2(46, 42)
	_face.add_child(_ap_badge)
	_name_label = _label(Vector2(50, 13), Vector2(120, 30), 22)
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_art_bg = ColorRect.new()
	_art_bg.position = Vector2(10, 48)
	_art_bg.size = Vector2(160, 112)
	_art_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face.add_child(_art_bg)
	_art = TextureRect.new()
	_art.name = "CardArt"
	_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art_bg.add_child(_art)
	_ap_label = _label(Vector2(10, 164), Vector2(160, 26), 19)
	_description = _label(Vector2(10, 194), Vector2(160, 54), 19)
	_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_description.max_lines_visible = 2
	_description.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_mark = _label(Vector2(10, 133), Vector2(160, 27), 19)
	_mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_overlay = SelectionOverlay.new()
	_overlay.size = CARD_SIZE
	_overlay.visible = false
	_face.add_child(_overlay)

func _label(pos: Vector2, extent: Vector2, font_size: int) -> Label:
	var label := Label.new()
	label.position = pos
	label.size = extent
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", INK)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face.add_child(label)
	return label

func setup(uid: int, tid: String, card_name: String, ap: int, is_discard: bool = false):
	card_uid = uid
	type_id = tid
	ap_type = clampi(ap, 0, 3)
	_name_label.text = card_name
	var data: Dictionary = Config.CARD_DB.get(tid, {})
	_ap_badge.setup(ap_type, str(data.get("cost", 0)), 19)
	_ap_label.text = ["免费", "攻击", "移动", "功能"][ap_type]
	_description.text = data.get("desc", "")
	_is_discarded = is_discard
	# Art is presentation-only; local paths never enter network card data.
	set_art_path(str(data.get("art", "res://art/cards/%s.png" % tid)))
	_apply_style()

func set_description(text: String):
	_description.text = text

func set_art_path(path: String):
	if path == _art_path: return
	_art_path = path
	_art.texture = load(path) as Texture2D if not path.is_empty() and ResourceLoader.exists(path) else null

func set_art(texture: Texture2D):
	_art_path = ""
	_art.texture = texture

func set_respondable(value: bool):
	_respondable = value
	_apply_style()

func set_selected(value: bool):
	_selected = value
	_apply_style()

func set_skill_material(value: bool):
	if _skill_material == value: return
	_skill_material = value
	_overlay.skill_material = value
	_overlay.set_process(value)
	if not value: _overlay.pulse_strength = 0.0
	_overlay.queue_redraw()
	_apply_style()

func set_discard_mark(value: bool):
	_is_discarded = value
	_update_discard_sway()
	_apply_style()

func set_discard_phase(value: bool):
	if _overlay.discard_phase == value: return
	_overlay.discard_phase = value
	set_process(value)
	_update_discard_sway()
	_apply_style()

func set_skill_unavailable(value: bool):
	if _skill_unavailable == value: return
	_skill_unavailable = value
	if value and _gray_material == null:
		_gray_material = ShaderMaterial.new()
		_gray_material.shader = GRAYSCALE
	_set_gray_material(_face, _gray_material if value else null)

func _set_gray_material(node: Node, gray: ShaderMaterial):
	if node is CanvasItem: node.material = gray
	for child in node.get_children(): _set_gray_material(child, gray)

func set_unaffordable(value: bool):
	if _unaffordable == value: return
	_unaffordable = value
	_apply_style()

func _apply_style():
	_face.modulate = Color(0.62, 0.62, 0.62) if _unaffordable else Color.WHITE
	var accent: Color = ACCENTS[ap_type]
	var gold := Color(1.0, 0.84, 0.2)
	var style := StyleBoxFlat.new()
	style.bg_color = PAPER.lerp(accent, 0.24)
	style.border_color = accent
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.shadow_color = gold if _flash_active else Color(0, 0, 0, 0.22)
	style.shadow_size = 8 if _flash_active else (5 if _selected else 2)
	_face.add_theme_stylebox_override("panel", style)
	_top_band.color = accent
	_art_bg.color = PAPER.lerp(accent, 0.30)
	_mark.visible = _respondable or _skill_material
	_overlay.set_state(_selected, _is_discarded)
	_mark.text = "弃牌" if _is_discarded else ("可响应" if _respondable else "")
	if _skill_material: _mark.text = "已选材料" if _selected else "技能材料"

# 新牌使用独立光晕，保留选中和弃牌边框，不给插画和数字染色。
# 触发来源：摸牌阶段抽牌、夺取（seize）、天赐（blessing）等任何导致手牌新增的时机。
func mark_new():
	_flash_active = true
	_apply_style()
	if _flash_tween != null:
		_flash_tween.kill()
	_flash_tween = create_tween()
	for _i in range(3):
		_flash_tween.tween_method(_set_flash_strength, 0.25, 0.8, 0.22)
		_flash_tween.tween_method(_set_flash_strength, 0.8, 0.25, 0.22)
	_flash_tween.tween_callback(func():
		_flash_active = false
		_apply_style()
	)

func _set_flash_strength(strength: float):
	var style := _face.get_theme_stylebox("panel") as StyleBoxFlat
	style.shadow_color = Color(1.0, 0.84, 0.2, strength)

func pose(offset: Vector2, angle: float, zoom: float, immediate: bool = false):
	_focused = zoom > 1.0
	_update_discard_sway()
	_description.visible = zoom > 1.0
	if _motion != null: _motion.kill()
	if immediate:
		_pose_offset = offset
		_pose_angle = angle
		_pose_zoom = zoom
		return
	_motion = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_motion.tween_property(self, "_pose_offset", offset, 0.15)
	_motion.tween_property(self, "_pose_angle", angle, 0.15)
	_motion.tween_property(self, "_pose_zoom", zoom, 0.15)

func face_rect() -> Rect2:
	var transform := _face.get_transform()
	var rect := Rect2(transform * Vector2.ZERO, Vector2.ZERO)
	for point in [Vector2(CARD_SIZE.x, 0), CARD_SIZE, Vector2(0, CARD_SIZE.y)]:
		rect = rect.expand(transform * point)
	return Rect2(position + rect.position, rect.size)

func retire():
	set_discard_phase(false)
	if _motion != null: _motion.kill()
	if _flash_tween != null: _flash_tween.kill()
	var exit_tween := create_tween().set_parallel()
	exit_tween.tween_property(self, "modulate:a", 0.0, 0.15)
	exit_tween.tween_property(self, "position:y", position.y - 24, 0.15)
	exit_tween.chain().tween_callback(queue_free)
