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
		_check("the default view is first person (camera %.2f m from the body)" % camera_distance,
			camera_distance < 1.0)
		_check("camera is not underground (y = %.2f)" % camera.global_position.y, camera.global_position.y >= player.global_position.y - 0.5)

		# First person is the default now: the camera looks forward with the
		# body and the arm is pulled to the eyes. The third-person framing is
		# covered by test_fp_camera after zooming the wheel out.
		var forward := -camera.global_transform.basis.z
		var body_forward := -player.global_transform.basis.z
		_check(
			"the first-person camera looks forward (dot = %.2f)" % forward.dot(body_forward),
			forward.dot(body_forward) > 0.5
		)
		_check("the controller reports first person", bool(player.call(&"is_first_person")))
		var arm := camera.get_parent() as SpringArm3D
		_check("camera hangs off a SpringArm3D", arm != null)
		if arm != null:
			_check(
				"the arm is pulled to the eyes (%.2f m)" % arm.spring_length,
				arm.spring_length <= 0.6
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
