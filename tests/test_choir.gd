extends SceneTree
## Choir stalker test: it follows the loudest recent noise instead of the nearest
## body, it answers a nearby voice with a muffled echo (once per interval), it
## does not answer from across the map, and layers 4-5 spawn exactly one.

const TestEnv := preload("res://tests/test_env.gd")
const PLAYER_SCENE := "res://scenes/player/player.tscn"
const ENEMY_SCENE := "res://scenes/world/enemy.tscn"
const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const FOREST_PATH := "res://scenes/world/layered_forest.tscn"

var _failures := 0
var _echoes := 0
var _toasts: Array[String] = []


func _initialize() -> void:
	TestEnv.isolate("test_choir")
	TestEnv.stash("user://plots.json")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	var bus: Node = root.get_node_or_null("EventBus")
	_check("EventBus exists", bus != null)
	if bus == null:
		_finish()
		return
	bus.connect(&"choir_echo", func(_s: Vector3, _v: Vector3) -> void: _echoes += 1)
	bus.connect(&"toast_requested", func(text: String) -> void: _toasts.append(text))

	# --- it answers a nearby voice ----------------------------------------
	var player: Node3D = load(PLAYER_SCENE).instantiate()
	root.add_child(player)
	var stalker: Node3D = load(ENEMY_SCENE).instantiate()
	stalker.set(&"hunts_noise", true)
	stalker.set(&"echo_radius", 14.0)
	stalker.set(&"echo_interval", 0.2)
	root.add_child(stalker)
	await physics_frame
	_bind_authority(stalker)
	stalker.global_position = player.global_position + Vector3(6.0, 0.0, 0.0)
	await _wait(40)
	_check("a silent player gets no answer (%d)" % _echoes, _echoes == 0)
	bus.emit_signal(&"disturbance_emitted", player.global_position, 20.0)
	await _wait(40)
	_check("the stalker echoes a nearby voice (%d)" % _echoes, _echoes > 0)
	_check("the echo announces itself once (%s)" % str(_toasts),
		_toasts.any(func(text: String) -> bool: return text.contains("repeats your voice")))
	var first := _echoes
	await _wait(30)
	_check("the echo respects its interval (%d -> %d)" % [first, _echoes],
		_echoes <= first + 3)
	# Far away it stays silent even when it hears the noise.
	stalker.global_position = player.global_position + Vector3(40.0, 0.0, 0.0)
	_echoes = 0
	bus.emit_signal(&"disturbance_emitted", player.global_position, 100.0)
	await _wait(40)
	_check("no echo from across the layer (%d)" % _echoes, _echoes == 0)
	stalker.queue_free()
	player.queue_free()
	await physics_frame

	# --- it follows noise, not proximity ----------------------------------
	player = load(PLAYER_SCENE).instantiate()
	root.add_child(player)
	var hunter: Node3D = load(ENEMY_SCENE).instantiate()
	hunter.set(&"hunts_noise", true)
	hunter.set(&"echo_interval", 99.0)
	hunter.set(&"aggro_range", 40.0)
	hunter.name = "Hunter2"
	root.add_child(hunter)
	await physics_frame
	_bind_authority(hunter)
	hunter.global_position = Vector3.ZERO
	player.global_position = Vector3(5.0, 0.0, 0.0)
	await physics_frame
	var disturbance := Vector3(-18.0, 0.0, 0.0)
	bus.emit_signal(&"disturbance_emitted", disturbance, 30.0)
	_check("the hunter hears the noise", bool(hunter.call(&"is_investigating")))
	_check("the noise becomes its target (%s)" % hunter.call(&"investigation_target"),
		(hunter.call(&"investigation_target") as Vector3).distance_to(disturbance) < 0.01)
	var goal := hunter.call(&"movement_goal") as Vector3
	_check("its movement goal is the noise, not the nearby player (%s)" % goal,
		goal.distance_to(disturbance) < 0.01)

	# A normal creature with a player inside aggro still walks at the player.
	var normal: Node3D = load(ENEMY_SCENE).instantiate()
	normal.set(&"hunts_noise", false)
	normal.set(&"aggro_range", 40.0)
	root.add_child(normal)
	await physics_frame
	_bind_authority(normal)
	normal.global_position = Vector3.ZERO
	bus.emit_signal(&"disturbance_emitted", disturbance, 30.0)
	await physics_frame
	var normal_goal := normal.call(&"movement_goal") as Vector3
	_check("a normal creature keeps the nearby player as its goal (%s)" % normal_goal,
		normal_goal.distance_to(player.global_position) < 0.1)
	normal.queue_free()
	hunter.queue_free()
	player.queue_free()
	await physics_frame

	# --- deep layers spawn one ---------------------------------------------
	var main: Node = load(MAIN_SCENE_PATH).instantiate()
	root.add_child(main)
	await _wait(30)
	main.call(&"_swap_area", FOREST_PATH, 3)
	await _wait(16)
	var night := main.get_node_or_null("World") as Node3D
	_check("layer 3 spawns the Choir stalker",
		night != null and night.find_child("ChoirStalker", true, false) != null)
	main.call(&"_swap_area", FOREST_PATH, 4)
	await _wait(16)
	var deep := main.get_node_or_null("World") as Node3D
	_check("layer 4 loaded", deep != null and deep.scene_file_path == FOREST_PATH)
	var spawned := deep.find_child("ChoirStalker", true, false) as Node3D if deep != null else null
	_check("layer 4 spawns the Choir stalker", spawned != null)
	if spawned != null:
		_check("the stalker hunts noise", bool(spawned.get(&"hunts_noise")))
		_check("the stalker is hard to kill (%.0f hp)" % float(spawned.get(&"max_hp")),
			float(spawned.get(&"max_hp")) >= 250.0)
		_check("the stalker does not respawn (%.0f s)" % float(spawned.get(&"respawn_seconds")),
			float(spawned.get(&"respawn_seconds")) > 1000.0)
	main.call(&"_swap_area", FOREST_PATH, 1)
	await _wait(16)
	var shallow := main.get_node_or_null("World") as Node3D
	_check("layer 1 has no stalker",
		shallow != null and shallow.find_child("ChoirStalker", true, false) == null)
	_finish()


## The first player body is the authority offline; make sure the creature is too,
## even if the player scene grabbed a different id.
func _bind_authority(creature: Node) -> void:
	creature.set_multiplayer_authority(1)


func _wait(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all Choir assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
