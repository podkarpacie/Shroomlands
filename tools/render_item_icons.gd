extends SceneTree
## Offline icon renderer for the satchel, hotbar and build palette.
##
## Run windowed (not headless), from the project root:
##   Godot_v4.7.2-stable_win64.exe --path . --script res://tools/render_item_icons.gd
##
## Every icon is rendered from the same `ItemVisuals.build_model()` used by the
## in-game rotating preview, so a Glowcap icon is literally a picture of the
## Glowcap mesh. Output: `assets/ui/items/<id>.png` and `assets/ui/build/<id>.png`.

const ITEM_DIR := "res://assets/ui/items"
const BUILD_DIR := "res://assets/ui/build"
const ICON_PIXELS := 192
const CAMERA_POSITION := Vector3(2.05, 1.48, 2.65)
const LOOK_AT := Vector3(0.0, 0.56, 0.0)

var _viewport: SubViewport = null
var _pivot: Node3D = null
var _rendered := 0
var _failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("ICONS   start (display=%s)" % DisplayServer.get_name())
	if DisplayServer.get_name() == "headless":
		print("FAIL  render_item_icons needs a windowed renderer; drop --headless.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ITEM_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BUILD_DIR))
	_build_stage()
	print("ICONS   stage built")

	var ids: Array[String] = ItemVisuals.all_ids()
	ids.append("gold")
	# `-- only=konop,weak_health_potion` renders just those, so a new item does not
	# overwrite every existing icon.
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("only="):
			var wanted := argument.trim_prefix("only=").split(",", false)
			ids = ids.filter(func(id: String) -> bool: return wanted.has(id))
	for id: String in ids:
		var dir := BUILD_DIR if ItemVisuals.BUILD_IDS.has(id) else ITEM_DIR
		var path := "%s/%s.png" % [dir, id]
		print("ICONS   rendering %s" % id)
		var ok := await _render(id, path)
		if ok:
			_rendered += 1
			print("PASS  %s -> %s" % [id, ProjectSettings.globalize_path(path)])
		else:
			_failed += 1
			print("FAIL  %s" % id)

	print("\n%d icons rendered, %d failed." % [_rendered, _failed])
	quit(0 if _failed == 0 else 1)


func _build_stage() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "IconViewport"
	_viewport.size = Vector2i(ICON_PIXELS, ICON_PIXELS)
	_viewport.transparent_bg = true
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)

	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.74, 0.58)
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment = env
	_viewport.add_child(environment)

	var key := DirectionalLight3D.new()
	key.light_color = Color(1.0, 0.95, 0.82)
	key.light_energy = 1.8
	key.rotation_degrees = Vector3(-42.0, -36.0, 0.0)
	_viewport.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.52, 0.74, 1.0)
	fill.light_energy = 0.55
	fill.rotation_degrees = Vector3(-18.0, 142.0, 0.0)
	_viewport.add_child(fill)

	var rim := OmniLight3D.new()
	rim.light_color = Color(0.72, 1.0, 0.58)
	rim.light_energy = 2.0
	rim.omni_range = 5.0
	rim.position = Vector3(-1.2, 1.4, -1.8)
	_viewport.add_child(rim)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.75
	camera.position = CAMERA_POSITION
	camera.look_at_from_position(CAMERA_POSITION, LOOK_AT, Vector3.UP)
	camera.current = true
	_viewport.add_child(camera)

	_pivot = Node3D.new()
	_pivot.name = "Pivot"
	_viewport.add_child(_pivot)


func _render(id: String, path: String) -> bool:
	for child in _pivot.get_children():
		child.free()
	var model := ItemVisuals.build_model(id, 1.35)
	if model == null:
		return false
	_pivot.add_child(model)
	_pivot.rotation = Vector3(0.0, -0.42, 0.0)
	# Give the renderer time to upload the meshes/material and draw a frame.
	for _frame in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := _viewport.get_texture().get_image()
	if image == null or image.is_empty():
		return false
	var result := image.save_png(ProjectSettings.globalize_path(path))
	return result == OK
