extends SceneTree
## Headless playability test: `main.tscn` must spawn a controllable player that
## walks on the placeholder Verdant Bloom ground.
##
## Autoloads are instantiated *after* the `--script` main loop compiles, so
## `main.tscn` is loaded lazily here (`preload` would compile Main.gd too early
## and fail on the `Network`/`Game`/`EventBus` autoload identifiers).

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0


func _initialize() -> void:
	# Structural/behaviour run only: a private save and a private plots file,
	# so this suite never reads or writes the developer's profile.
	TestEnv.isolate("test_player")
	TestEnv.stash("user://plots.json")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	var packed := load(MAIN_SCENE_PATH) as PackedScene
	_check("main.tscn loads", packed != null)
	if packed == null:
		_finish()
		return
	var main := packed.instantiate()
	root.add_child(main)
	for _frame in 5:
		await physics_frame

	_check("main scene is in group 'main'", main.is_in_group(&"main"))
	_check("world is instanced as Main/World", main.get_node_or_null("World") != null)

	var spawn := main.find_child("PlayerSpawn", true, false)
	_check("world has a Marker3D named PlayerSpawn", spawn is Marker3D)

	var players := get_nodes_in_group(&"player")
	_check("exactly one node is in group 'player'", players.size() == 1)
	if players.is_empty():
		_finish()
		return

	var player := players[0] as Node3D
	var cameras := player.find_children("*", "Camera3D", true, false)
	_check("player has a Camera3D descendant", not cameras.is_empty())
	if not cameras.is_empty():
		# The spring arm's pivot lives inside the player capsule, so the rig only
		# reads correctly if the body is excluded from the arm's cast; a collapsed
		# arm leaves the camera ~0.1 m from the pivot, i.e. inside the model.
		var camera := cameras[0] as Camera3D
		var camera_distance := camera.global_position.distance_to(player.global_position)
		print("      camera distance from player origin: %.2f m" % camera_distance)
		_check("camera sits at least 2.5 m from the player (%.2f m)" % camera_distance, camera_distance >= 2.5)
		_check("camera is not underground (y = %.2f)" % camera.global_position.y, camera.global_position.y >= player.global_position.y - 0.5)

		# Framing regression guards: the camera must be *behind* the player and
		# looking at them, not in front and looking away. A distance check alone
		# would pass for either orientation.
		var forward := -camera.global_transform.basis.z
		var facing := forward.dot((player.global_position - camera.global_position).normalized())
		_check("camera looks at the player (dot = %.2f)" % facing, facing > 0.5)
		var focus := player.global_position + Vector3(0.0, 1.0, 0.0)
		_check("player is inside the camera frustum", camera.is_position_in_frustum(focus))
		# Headless uses a tiny dummy viewport; the centre check still catches a
		# camera that is aimed away from the player.
		var viewport_size := camera.get_viewport().get_visible_rect().size
		var projected := camera.unproject_position(focus)
		_check(
			"player projects into the horizontal middle third (x = %.0f of %.0f)" % [projected.x, viewport_size.x],
			projected.x >= viewport_size.x / 3.0 and projected.x <= viewport_size.x * 2.0 / 3.0
		)

		# Decoration lives on physics layer 2; the arm must only cast against
		# world geometry (layer 1) so a prop can never collapse it.
		var arm := camera.get_parent() as SpringArm3D
		_check("camera hangs off a SpringArm3D", arm != null)
		if arm != null:
			_check("spring arm collision mask is world-only (0x%x)" % arm.collision_mask, arm.collision_mask == 1)
			_check(
				"spring arm is not collapsed by decoration (hit length = %.2f m)" % arm.get_hit_length(),
				arm.get_hit_length() >= 2.5
			)

	var stats := player.get_node_or_null("Stats")
	_check("player has a PlayerStats component", stats != null)
	_check("PlayerStats.max_hp > 0", stats != null and float(stats.get("max_hp")) > 0.0)
	_check("player starts with full HP", stats != null and is_equal_approx(float(stats.get("hp")), float(stats.get("max_hp"))))

	var start := player.global_position
	var lowest := start.y
	Input.action_press(&"move_forward")
	for _frame in 60:
		await physics_frame
		lowest = minf(lowest, player.global_position.y)
	Input.action_release(&"move_forward")

	var moved := player.global_position - start
	var walked := Vector2(moved.x, moved.z).length()
	_check("player walked more than 0.5 m (%.2f m)" % walked, walked > 0.5)
	_check("player never fell below y = -5 (lowest %.2f)" % lowest, lowest > -5.0)
	_check("player is still grounded after walking", player.is_on_floor())

	_finish()


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	Input.action_release(&"move_forward")
	if _failures == 0:
		print("PASSED  all player assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
