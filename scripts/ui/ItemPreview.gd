extends Control
## A live, slowly rotating 3D preview of an item for the satchel detail panel.
##
## Headless test runs skip the SubViewport entirely and show the flattened icon
## instead: the renderer is a presentation nicety, never a correctness
## dependency.

const PREVIEW_SIZE := Vector2i(256, 210)

var _viewport: SubViewport = null
var _pivot: Node3D = null
var _icon: TextureRect = null
var _glow: TextureRect = null
var _headless := false
var _current: String = ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(226, 180)
	clip_contents = true
	_headless = DisplayServer.get_name() == "headless"
	_build_backdrop()
	if _headless:
		_build_icon_fallback()
		return
	_build_viewport()


func show_item(id: String) -> void:
	_current = id
	if _glow != null:
		_glow.modulate = (
			Color(ItemVisuals.color(id), 0.50) if not id.is_empty()
			else Color(0.42, 0.68, 0.36, 0.22)
		)
	if _headless:
		if _icon != null:
			_icon.texture = ItemVisuals.icon(id) if not id.is_empty() else null
			_icon.visible = not id.is_empty()
		return
	if _pivot == null:
		return
	for child in _pivot.get_children():
		child.queue_free()
	if id.is_empty():
		return
	var model := ItemVisuals.build_model(id, 1.25)
	_pivot.add_child(model)
	_pivot.rotation = Vector3(0.0, -0.55, 0.0)


func _process(delta: float) -> void:
	if _headless or _pivot == null or not is_visible_in_tree():
		return
	_pivot.rotation.y += delta * 0.55
	_pivot.position.y = sin(Time.get_ticks_msec() * 0.0016) * 0.025


func _build_backdrop() -> void:
	_glow = TextureRect.new()
	_glow.name = "Glow"
	_glow.texture = _glow_texture()
	_glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_glow.stretch_mode = TextureRect.STRETCH_SCALE
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow.modulate = Color(0.42, 0.68, 0.36, 0.22)
	add_child(_glow)

	var vignette := ColorRect.new()
	vignette.name = "Floor"
	vignette.color = Color(0.02, 0.035, 0.025, 0.45)
	vignette.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	vignette.offset_top = -28.0
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vignette)


func _build_icon_fallback() -> void:
	_icon = TextureRect.new()
	_icon.name = "Icon"
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_icon.offset_left = 30.0
	_icon.offset_top = 10.0
	_icon.offset_right = -30.0
	_icon.offset_bottom = -16.0
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_icon)


func _build_viewport() -> void:
	var container := SubViewportContainer.new()
	container.name = "ViewportContainer"
	container.stretch = true
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)

	_viewport = SubViewport.new()
	_viewport.name = "Viewport"
	_viewport.size = PREVIEW_SIZE
	_viewport.transparent_bg = true
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(_viewport)

	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.72, 0.58)
	env.ambient_light_energy = 0.85
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment = env
	_viewport.add_child(environment)

	var key := DirectionalLight3D.new()
	key.name = "Key"
	key.light_color = Color(1.0, 0.95, 0.82)
	key.light_energy = 1.7
	key.rotation_degrees = Vector3(-48.0, -38.0, 0.0)
	key.shadow_enabled = false
	_viewport.add_child(key)

	var fill := OmniLight3D.new()
	fill.name = "Fill"
	fill.light_color = Color(0.55, 0.85, 0.62)
	fill.light_energy = 1.5
	fill.omni_range = 5.0
	fill.position = Vector3(-1.6, 1.8, 1.4)
	_viewport.add_child(fill)

	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.45
	camera.position = Vector3(1.65, 1.25, 2.25)
	camera.look_at_from_position(camera.position, Vector3(0.0, 0.55, 0.0), Vector3.UP)
	camera.current = true
	_viewport.add_child(camera)

	_pivot = Node3D.new()
	_pivot.name = "Pivot"
	_pivot.position = Vector3(0.0, 0.02, 0.0)
	_viewport.add_child(_pivot)


func _glow_texture() -> ImageTexture:
	var size := 256
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var nx := (float(x) + 0.5) / float(size) * 2.0 - 1.0
			var ny := (float(y) + 0.5) / float(size) * 2.0 - 1.0
			var distance := sqrt(nx * nx + ny * ny)
			var alpha := clampf(1.0 - distance, 0.0, 1.0)
			alpha = alpha * alpha * 0.85
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	return ImageTexture.create_from_image(image)
