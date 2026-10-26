extends SceneTree
## Windowed frame-capture + camera-framing harness.
##
## Run WITHOUT `--headless` so a real frame exists:
##   Godot_v4.7.2-stable_win64.exe --path . --script res://tests/capture_frame.gd
##
## Prints the full player/camera/spring-arm state, checks that the player is in
## front of the camera and inside the frustum, then saves seven frames: normal
## gameplay with the HUD, the open inventory panel, a gather in progress, the
## plot row in build mode, a melee hit on a creature, the death overlay and the
## vocation modal with its four cards.
## Every PNG path is printed as an absolute path.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const CAPTURE_PATH := "res://tests/_capture.png"
const INVENTORY_CAPTURE_PATH := "res://tests/_capture_inventory.png"
const GATHER_CAPTURE_PATH := "res://tests/_capture_gather.png"
const COMBAT_CAPTURE_PATH := "res://tests/_capture_combat.png"
const DEATH_CAPTURE_PATH := "res://tests/_capture_death.png"
const PLOT_CAPTURE_PATH := "res://tests/_capture_plots.png"
const VOCATION_CAPTURE_PATH := "res://tests/_capture_vocation.png"
## The capture tool must not start from a real save: a loaded level-20 character
## would auto-open the vocation modal over every frame. The file is put back
## when the tool exits.
const SAVE_PATH := "user://player_save.json"
## The camera collapse in the bug report showed up ~10 s after load.
const LATE_FRAMES := 600

var _player: Node3D
var _camera: Camera3D
var _arm: SpringArm3D
var _failures := 0
var _had_save := false
var _saved_text := ""
var _save_restored := false


func _initialize() -> void:
	_run()


func _run() -> void:
	_isolate_save()
	var packed := load(MAIN_SCENE_PATH) as PackedScene
	if packed == null:
		print("FAIL  main.tscn could not be loaded")
		_restore_save()
		quit(1)
		return
	var main := packed.instantiate()
	root.add_child(main)

	for _frame in 30:
		await physics_frame

	var players := get_nodes_in_group(&"player")
	print("players in group 'player': %d" % players.size())
	if players.is_empty():
		print("FAIL  no player node was spawned")
		_restore_save()
		quit(1)
		return
	_player = players[0] as Node3D
	_camera = _player.find_children("*", "Camera3D", true, false)[0] as Camera3D
	_arm = _camera.get_parent() as SpringArm3D

	# Seed the inventory so the hotbar and the 48-slot grid both show items.
	var inventory := _player.get_node_or_null("InventorySystem")
	if inventory != null:
		inventory.call(&"add_item", &"glowcap", 5)
		inventory.call(&"add_item", &"emberstem", 12)
		inventory.call(&"add_item", &"venomveil", 3)
		inventory.call(&"add_item", &"sunheart", 1)
		inventory.call(&"add_item", &"geodecap", 2)

	_dump("AT 30 PHYSICS FRAMES")
	await _save(CAPTURE_PATH)

	# --- inventory panel ----------------------------------------------------
	var inventory_ui := main.get_node_or_null("InventoryUI")
	_check("InventoryUI exists under Main", inventory_ui != null)
	if inventory_ui != null and inventory_ui.has_method(&"toggle"):
		inventory_ui.call(&"toggle")
		await _save(INVENTORY_CAPTURE_PATH)
		print("inventory panel visible: %s" % inventory_ui.visible)
		inventory_ui.call(&"toggle")
		await process_frame

	# Same measurement late, to catch anything that only collapses the arm once
	# the running scene's physics has settled. No extra PNG: the deliverable is
	# the three frames above/below.
	for _frame in LATE_FRAMES:
		await physics_frame
	_dump("AT %d PHYSICS FRAMES (~10 s)" % LATE_FRAMES)

	await _capture_gather()
	await _capture_plots()
	await _capture_combat()
	await _capture_death()
	await _capture_vocation()

	print("\ncapture files:")
	print("  normal:    %s" % ProjectSettings.globalize_path(CAPTURE_PATH))
	print("  inventory: %s" % ProjectSettings.globalize_path(INVENTORY_CAPTURE_PATH))
	print("  gather:    %s" % ProjectSettings.globalize_path(GATHER_CAPTURE_PATH))
	print("  plots:     %s" % ProjectSettings.globalize_path(PLOT_CAPTURE_PATH))
	print("  combat:    %s" % ProjectSettings.globalize_path(COMBAT_CAPTURE_PATH))
	print("  death:     %s" % ProjectSettings.globalize_path(DEATH_CAPTURE_PATH))
	print("  vocation:  %s" % ProjectSettings.globalize_path(VOCATION_CAPTURE_PATH))

	_restore_save()
	if _failures == 0:
		print("\nPASSED  player is framed in front of the camera")
		quit(0)
	else:
		print("\nFAILED  %d framing assertion(s)" % _failures)
		quit(1)


## Put the developer's own save back, whatever the capture wrote.
func _finalize() -> void:
	_restore_save()


func _isolate_save() -> void:
	_had_save = FileAccess.file_exists(SAVE_PATH)
	if _had_save:
		var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if file != null:
			_saved_text = file.get_as_text()
			file.close()
	_remove_save()


func _restore_save() -> void:
	if _save_restored:
		return
	_save_restored = true
	_remove_save()
	if not _had_save or _saved_text.is_empty():
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(_saved_text)
	file.close()


func _remove_save() -> void:
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists(SAVE_PATH.get_file()):
		dir.remove(SAVE_PATH.get_file())



func _dump(label: String) -> void:
	print("\n=== %s ===" % label)
	var vp_size := root.get_visible_rect().size
	print("viewport size: %s" % _vec2(vp_size))
	print("window size: %s  screen size: %s  screen scale: %.2f" % [
		DisplayServer.window_get_size(), DisplayServer.screen_get_size(), DisplayServer.screen_get_scale()
	])
	print("player.global_position: %s" % _vec(_player.global_position))
	print("player.global_rotation_degrees: %s" % _vec(_player.global_rotation_degrees))
	print("player.is_visible_in_tree(): %s" % _player.is_visible_in_tree())
	print("camera.global_position: %s" % _vec(_camera.global_position))
	print("camera.global_rotation_degrees: %s" % _vec(_camera.global_rotation_degrees))
	print("camera.global_transform.basis.z: %s" % _vec(_camera.global_transform.basis.z))
	print("camera.cull_mask: 0x%x" % _camera.cull_mask)

	var parent := _camera.get_parent()
	print("camera parent: %s (%s)" % [parent.name, parent.get_class()])
	if parent is SpringArm3D:
		print("  spring_length: %.6f" % parent.spring_length)
		print("  margin: %.6f" % parent.margin)
		print("  rotation_degrees: %s" % _vec(parent.rotation_degrees))
		print("  global_transform.basis.z: %s" % _vec(parent.global_transform.basis.z))
		print("  collision_mask: 0x%x" % parent.collision_mask)
		print("  hit_length: %.6f" % parent.get_hit_length())

	var to_player := _player.global_position - _camera.global_position
	var to_pivot := _player.global_position + Vector3(0.0, 0.8, 0.0) - _camera.global_position
	var forward := -_camera.global_transform.basis.z
	var dot_root := forward.dot(to_player.normalized())
	var dot_pivot := forward.dot(to_pivot.normalized())
	print("camera -> player vector: %s (%.6f m)" % [_vec(to_player), to_player.length()])
	print("camera -> pivot vector: %s (%.6f m)" % [_vec(to_pivot), to_pivot.length()])
	_check("dot(forward, player dir) = %.6f" % dot_root, dot_root > 0.5)
	_check("dot(forward, pivot dir) = %.6f" % dot_pivot, dot_pivot > 0.5)

	var in_frustum := _camera.is_position_in_frustum(_player.global_position)
	var in_frustum_pivot := _camera.is_position_in_frustum(_player.global_position + Vector3(0.0, 1.0, 0.0))
	_check("is_position_in_frustum(player origin) = %s" % in_frustum, in_frustum)
	_check("is_position_in_frustum(player + 1 m) = %s" % in_frustum_pivot, in_frustum_pivot)
	var projected := _camera.unproject_position(_player.global_position)
	var projected_core := _camera.unproject_position(_player.global_position + Vector3(0.0, 1.0, 0.0))
	print("unproject(player origin): %s (middle third x: %.1f..%.1f)" % [
		_vec2(projected), vp_size.x / 3.0, vp_size.x * 2.0 / 3.0
	])
	print("unproject(player + 1 m): %s" % _vec2(projected_core))
	_check(
		"player projects into horizontal middle third (x = %.1f of %.1f)" % [projected_core.x, vp_size.x],
		projected_core.x >= vp_size.x / 3.0 and projected_core.x <= vp_size.x * 2.0 / 3.0
	)

	print("-- player meshes --")
	for mi in _player.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := mi as MeshInstance3D
		var world_centre := mesh_instance.global_transform * mesh_instance.get_aabb().get_center()
		_check(
			"%s is visible in tree" % mesh_instance.get_path(),
			mesh_instance.visible and mesh_instance.is_visible_in_tree()
		)
		print("  %s: visible=%s in_tree=%s layers=0x%x" % [
			mesh_instance.get_path(), mesh_instance.visible,
			mesh_instance.is_visible_in_tree(), mesh_instance.layers
		])
		print("    world AABB centre: %s  size=%s" % [
			_vec(world_centre), _vec(mesh_instance.get_aabb().size)
		])

	print("-- decor props within 8 m of the camera --")
	var decor_root := _player.get_parent().get_node_or_null("World")
	var shown := 0
	if decor_root != null:
		for decor in decor_root.get_children():
			if not String(decor.name).begins_with("Decor"):
				continue
			var prop := decor as Node3D
			var dist := prop.global_position.distance_to(_camera.global_position)
			if dist > 8.0:
				continue
			shown += 1
			var cap := prop.get_node_or_null("Cap") as MeshInstance3D
			var albedo := Color.MAGENTA
			if cap != null:
				var mat := cap.material_override if cap.material_override != null else cap.mesh.surface_get_material(0)
				if mat is StandardMaterial3D:
					albedo = (mat as StandardMaterial3D).albedo_color
			print("  %s at %s  dist_to_camera=%.3f m  layer=0x%x  scale=%s  cap_albedo=%s" % [
				prop.name, _vec(prop.global_position), dist,
				(prop as CollisionObject3D).collision_layer, _vec(prop.scale), albedo
			])
	print("  (%d prop(s) within 8 m)" % shown)
	_check("no decoration within 8 m of the camera (found %d)" % shown, shown == 0)

	# Who is between the lens and the player? This distinguishes "prop in front
	# of the camera" from "player simply not rendered".
	var query := PhysicsRayQueryParameters3D.create(
		_camera.global_position, _player.global_position + Vector3(0.0, 0.8, 0.0)
	)
	query.exclude = [_player.get_rid()]
	var hit := _player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		print("-- camera->pivot ray: clear --")
	else:
		var collider := hit.get("collider") as Node
		print("-- camera->pivot ray: hit %s at %s (%.3f m from lens) --" % [
			collider.get_path() if collider != null else "<null>",
			_vec(hit.get("position")), _camera.global_position.distance_to(hit.get("position"))
		])


func _save(path: String) -> Image:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var error := image.save_png(path)
	print("saved %s (%dx%d, error=%d), absolute: %s" % [
		path, image.get_width(), image.get_height(), error, ProjectSettings.globalize_path(path)
	])

	# A black capture is not proof of anything. Sample a coarse grid.
	var lit := 0
	var samples := 0
	for y in range(0, image.get_height(), 32):
		for x in range(0, image.get_width(), 32):
			samples += 1
			var colour := image.get_pixel(x, y)
			if maxf(colour.r, maxf(colour.g, colour.b)) > 0.02:
				lit += 1
	print("non-black samples: %d / %d" % [lit, samples])
	_check("capture is a rendered frame, not black", lit > samples / 10)
	return image


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _vec(v: Vector3) -> String:
	return "(%.6f, %.6f, %.6f)" % [v.x, v.y, v.z]


func _vec2(v: Vector2) -> String:
	return "(%.3f, %.3f)" % [v.x, v.y]


## Mid-gather frame: stand next to the nearest mushroom, start the real timed
## gather (no input simulation) and stop the clock at ~0.5 s so the HUD bar is
## visibly partially filled.
func _capture_gather() -> void:
	var gathering: Node = _player.get_node_or_null("GatheringSystem")
	var target := _nearest_mushroom()
	_check("a mushroom is available for the gather capture", target != null)
	if gathering == null or target == null:
		return

	_player.global_position = target.global_position + Vector3(0.0, 0.9, 3.0)
	_player.velocity = Vector3.ZERO
	_player.reset_physics_interpolation()
	await _wait_physics(4)

	var started := bool(gathering.call(&"begin", target))
	_check("gather starts for the capture", started)
	if not started:
		return
	await _wait_seconds(0.5)
	print("gather ratio at capture: %.2f" % float(gathering.call(&"progress_ratio")))
	await _save(GATHER_CAPTURE_PATH)
	gathering.call(&"cancel")


## Plot row + build ghost still. Owns plot 5 for the shot, stands the body on it
## (so the HUD plot status line is populated) and uses a temporary elevated
## camera so all six 12 x 12 m plots fit in one 1280x720 frame. The ghost is
## aimed with the deterministic `aim_override` seam instead of the OS cursor.
func _capture_plots() -> void:
	var system := _main_plot_system()
	_check("Main has a PlotSystem", system != null)
	var build := _main_build_mode()
	_check("Main has a BuildMode layer", build != null)
	if system == null:
		return
	var game: Node = root.get_node_or_null("Game")
	var bus: Node = root.get_node_or_null("EventBus")
	system.call(&"reset_plots")
	if game != null:
		game.set(&"gold", 600)
		if bus != null:
			bus.emit_signal(&"gold_changed", 600)
	var owner: StringName = system.call(&"local_owner_id")
	_check("plot 5 can be bought for the capture", bool(system.call(&"buy_plot", 4, owner)))
	_check(
		"a hut can be placed for the capture",
		bool(system.call(&"place_object", 4, &"hut", Vector3i(16, 0, 28)))
	)

	_player.global_position = Vector3(20.0, 1.2, 33.0)
	_player.velocity = Vector3.ZERO
	_player.reset_physics_interpolation()

	var main := _player.get_parent()
	var shot_camera := Camera3D.new()
	shot_camera.name = "PlotCaptureCamera"
	shot_camera.fov = 88.0
	main.add_child(shot_camera)
	shot_camera.global_position = Vector3(0.0, 13.0, 52.0)
	shot_camera.look_at(Vector3(0.0, 0.0, 30.0), Vector3.UP)
	shot_camera.current = true

	if build != null:
		build.set(&"has_aim_override", true)
		build.set(&"aim_override", Vector3(21.0, 0.0, 30.0))
		build.call(&"set_active", true)
	# Long enough for the HUD's 0.25 s plot-status poll and the ghost's frame.
	await _wait_seconds(0.4)
	await _save(PLOT_CAPTURE_PATH)

	if build != null:
		build.set(&"has_aim_override", false)
		build.call(&"set_active", false)
	shot_camera.queue_free()
	_camera.current = true
	# Leave no purchased plot behind in the user profile.
	system.call(&"reset_plots")
	system.call(&"save_plots")
	if game != null:
		game.set(&"gold", 50)
		if bus != null:
			bus.emit_signal(&"gold_changed", 50)


func _nearest_mushroom() -> Node3D:
	var best: Node3D = null
	var best_distance := INF
	for node: Node in get_nodes_in_group(&"interactable"):
		if not node.has_method(&"is_available") or not bool(node.call(&"is_available")):
			continue
		var body := node as Node3D
		if body == null:
			continue
		var distance := body.global_position.distance_to(_player.global_position)
		if distance < best_distance:
			best = body
			best_distance = distance
	return best


func _nearest_enemy() -> Node3D:
	var best: Node3D = null
	var best_distance := INF
	for node: Node in get_nodes_in_group(&"enemy"):
		var body := node as Node3D
		if body == null:
			continue
		var distance := body.global_position.distance_to(_player.global_position)
		if distance < best_distance:
			best = body
			best_distance = distance
	return best


## Combat frame: stand in front of a live creature, swing for real and capture
## while the hit flash is still on its material.
func _capture_combat() -> void:
	var enemy := _nearest_enemy()
	_check("a creature is available for the combat capture", enemy != null)
	if enemy == null:
		return
	var combat: Node = _player.get_node_or_null("CombatSystem")
	_check("the player has a CombatSystem", combat != null)
	if combat == null:
		return

	# 2.4 m in front of it: inside the swing's 2.6 m sphere cast, outside the
	# creature's 1.9 m bite range, so the still shows the creature and not a red
	# screen caused by being eaten while posing.
	_player.global_position = enemy.global_position + Vector3(0.0, 0.9, 2.4)
	_player.velocity = Vector3.ZERO
	_player.reset_physics_interpolation()
	var pivot := _player.get_node_or_null("CameraPivot") as Node3D
	var aim_right := Vector3.RIGHT
	if pivot != null:
		var to_enemy := enemy.global_position - _player.global_position
		pivot.rotation.y = atan2(-to_enemy.x, -to_enemy.z)
		aim_right = pivot.global_basis.x
		var arm := pivot.get_node_or_null("SpringArm3D") as SpringArm3D
		if arm != null:
			arm.rotation.x = deg_to_rad(-6.0)
	await _wait_physics(6)

	var hp_before := float(enemy.get("hp"))
	var swung := bool(combat.call(&"try_attack", false))
	_check("the capture swing is accepted", swung)
	# Step sideways before the shot: a third-person camera always keeps the player
	# dead-centre, so standing in line with the creature would hide it behind the
	# player's own cap.
	_player.global_position += aim_right * 2.6
	_player.velocity = Vector3.ZERO
	_player.reset_physics_interpolation()
	# Show the damage vignette in the same still; the creature is out of bite
	# range here, so this one hit is scripted.
	var stats := _player.get_node_or_null("Stats")
	if stats != null:
		stats.call(&"take_damage", 4.0, enemy)
	await _wait_physics(2)
	var image := await _save(COMBAT_CAPTURE_PATH)
	_check_combat_vignette(image)
	var damage := hp_before - float(enemy.get("hp"))
	print("capture swing: %.1f damage, creature hp %.1f -> %.1f" % [
		damage, hp_before, float(enemy.get("hp"))
	])
	_check("the capture swing damages the creature (%.1f)" % damage, damage > 0.0)


## The hit flash has to read as a frame: the middle of the screen keeps the
## world's own colour, only the border carries the red. Checks the generated
## texture (deterministic) and prints real frame pixels for the human.
func _check_combat_vignette(image: Image) -> void:
	var hud := _main_hud()
	var flash := hud.get_node_or_null("Root/DamageVignette") as TextureRect
	_check("the HUD has a damage vignette", flash != null)
	if flash == null or flash.texture == null:
		return
	var texture := flash.texture.get_image()
	var width := texture.get_width()
	var height := texture.get_height()
	var centre := texture.get_pixel(width / 2, height / 2)
	var inner := texture.get_pixel(int(width * 0.83), height / 2)
	var border := texture.get_pixel(0, height / 2)
	print("vignette texture %dx%d: centre alpha %.2f, x=83%% alpha %.2f, border alpha %.2f" % [
		width, height, centre.a, inner.a, border.a
	])
	print("vignette modulate alpha at capture: %.2f (peak 0.35, %.2f s fade)" % [
		flash.modulate.a, _vignette_fade(hud)
	])
	_check("the vignette is transparent in the middle third (alpha %.2f)" % centre.a, centre.a <= 0.01)
	_check("the vignette is still transparent at 66 %% of the half-extent (alpha %.2f)" % inner.a, inner.a <= 0.01)
	_check("the vignette peaks on the border (alpha %.2f)" % border.a, border.a >= 0.9)
	_check("the vignette peak is about 0.35 (%.2f)" % flash.modulate.a, flash.modulate.a <= 0.36)
	if image == null:
		return
	var mid := image.get_pixel(image.get_width() / 2, int(image.get_height() * 0.25))
	var left := image.get_pixel(4, image.get_height() / 2)
	print("frame pixels: middle third %s, left border %s" % [mid, left])


func _vignette_fade(hud: Node) -> float:
	var script: Script = hud.get_script()
	if script == null:
		return 0.0
	return float(script.get_script_constant_map().get("DAMAGE_FLASH_SECONDS", 0.0))


## Death frame: kill the local player for real, capture the "You died" overlay,
## then let the HUD's 2.5 s timer respawn the body and verify where it lands.
func _capture_death() -> void:
	var stats := _player.get_node_or_null("Stats")
	_check("the player has a Stats component", stats != null)
	if stats == null:
		return
	stats.call(&"die")
	await _wait_physics(3)
	var hud := _main_hud()
	_check("Main has a HUD node", hud != null)
	var overlay: ColorRect = null
	if hud != null:
		overlay = hud.get_node_or_null("Root/DeathOverlay") as ColorRect
	_check("the HUD builds a death overlay", overlay != null)
	if overlay != null:
		_check("the death overlay is visible after player_died", overlay.is_visible_in_tree())
	await _save(DEATH_CAPTURE_PATH)
	print("player HP right after death: %.0f" % float(stats.get("hp")))
	await _wait_seconds(3.0)
	var hp := float(stats.get("hp"))
	print("player HP after the death overlay: %.0f" % hp)
	_check("the player respawns with full HP", is_equal_approx(hp, float(stats.get("max_hp"))))
	var spawn := _player.get_parent().find_child("PlayerSpawn", true, false) as Node3D
	if spawn != null:
		var distance := _player.global_position.distance_to(spawn.global_position)
		print("player distance to World/PlayerSpawn after the respawn: %.2f m" % distance)
		_check("the player is back at World/PlayerSpawn", distance < 1.5)
	else:
		_check("world has a PlayerSpawn marker", false)


## Vocation modal still: four cards with the Polish lore text. The level is
## raised through the same signal a real level-up emits, which also exercises
## the auto-open hook; afterwards the session is put back where it was.
func _capture_vocation() -> void:
	var ui := _main_vocation_ui()
	_check("Main has a VocationUI layer", ui != null)
	var stats := _player.get_node_or_null("Stats")
	_check("the player has a Stats component", stats != null)
	if ui == null or stats == null:
		return
	var game: Node = root.get_node_or_null("Game")
	var bus: Node = root.get_node_or_null("EventBus")
	if game != null:
		game.set(&"chosen_vocation", &"")
	if bus != null:
		stats.set("level", 20)
		bus.emit_signal(&"level_changed", 20)
	await _wait_physics(3)
	_check("the vocation modal opens at Lv 20", ui.visible)
	var cards := ui.get_node_or_null("Root/Center/Panel/Margin/Content/Cards") as HBoxContainer
	_check("the modal shows four cards", cards != null and cards.get_child_count() == 4)
	if cards != null:
		for id: String in ["knight", "healer", "harvester", "ranger"]:
			var body := cards.get_node_or_null("Card_%s/Body" % id)
			var description: Label = null
			if body != null:
				description = body.get_node_or_null("Description") as Label
			var length := 0 if description == null else description.text.length()
			_check(
				"%s card has a Polish description (%d chars)" % [id, length],
				description != null and length > 60
			)
	await _save(VOCATION_CAPTURE_PATH)
	ui.call(&"dismiss")
	# Leave the session as it was found.
	stats.set("level", 1)
	if game != null:
		game.set(&"chosen_vocation", &"")


func _main_hud() -> Node:
	var main := _player.get_parent()
	if main == null:
		return null
	return main.get_node_or_null("HUD")


func _main_vocation_ui() -> CanvasLayer:
	var main := _player.get_parent()
	if main == null:
		return null
	return main.get_node_or_null("VocationUI") as CanvasLayer


func _main_plot_system() -> Node:
	var main := _player.get_parent()
	if main == null:
		return null
	return main.get_node_or_null("PlotSystem")


func _main_build_mode() -> Node:
	var main := _player.get_parent()
	if main == null:
		return null
	return main.get_node_or_null("BuildMode")


func _wait_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _wait_seconds(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame

