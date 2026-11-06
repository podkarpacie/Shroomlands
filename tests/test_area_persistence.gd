extends SceneTree
## Headless save test: a forest layer and the player's position survive a full
## session restart (the save stores area + forest_layer, not just coordinates).

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const FOREST_PATH := "res://scenes/world/layered_forest.tscn"
const TOWN_PATH := "res://scenes/world/town.tscn"
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _game: Node = null
var _saves: Node = null


func _initialize() -> void:
	TestEnv.isolate("test_area_persistence")
	TestEnv.stash("user://plots.json")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	await process_frame
	_game = root.get_node_or_null("/root/Game")
	_saves = root.get_node_or_null("/root/SaveSystem")
	_check("Game and SaveSystem autoloads exist", _game != null and _saves != null)
	if _game == null or _saves == null:
		_finish()
		return

	# --- first session: layer 3, a known spot, save ---------------------
	var main1 := (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	root.add_child(main1)
	await _wait(30)
	_check("the first session starts in town",
		(main1.get_node_or_null("World") as Node3D).scene_file_path == TOWN_PATH)

	_game.set(&"forest_layer", 3)
	_check("the layer-3 area loads", bool(main1.call(&"enter_area", FOREST_PATH)))
	await _wait(12)
	var world1 := main1.get_node_or_null("World") as Node3D
	_check("the first session is in the forest",
		world1 != null and world1.scene_file_path == FOREST_PATH)
	_check("the first session is on layer 3", int(_game.get(&"forest_layer")) == 3)

	var player1 := get_first_node_in_group(&"player") as Node3D
	_check("the first session has a player", player1 != null)
	if player1 == null:
		_finish()
		return
	var target := player1.global_position + Vector3(3.0, 0.0, 2.0)
	player1.global_position = target
	await _wait(3)
	_check("the first session saves", bool(_saves.call(&"save_now")))
	var saved_position := player1.global_position
	var data: Dictionary = _saves.call(&"load_player")
	_check("the save records the area (%s)" % data.get("area", ""),
		str(data.get("area", "")) == FOREST_PATH)
	_check("the save records the layer (%d)" % int(data.get("forest_layer", 0)),
		int(data.get("forest_layer", 0)) == 3)

	# --- second session: fresh boot, Game must learn the area from the save
	main1.queue_free()
	await _wait(3)
	_game.set(&"area_path", "")
	_game.set(&"forest_layer", 0)

	var main2 := (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	root.add_child(main2)
	await _wait(30)
	var world2 := main2.get_node_or_null("World") as Node3D
	_check("the second session restores the forest",
		world2 != null and world2.scene_file_path == FOREST_PATH)
	_check("the second session restores layer 3 (%d)" % int(_game.get(&"forest_layer")),
		int(_game.get(&"forest_layer")) == 3)
	_check("the restored area names the layer (%s)" % str(main2.call(&"get_area_name")),
		str(main2.call(&"get_area_name")).contains("Layer 3"))
	var player2 := get_first_node_in_group(&"player") as Node3D
	_check("the second session has a player", player2 != null)
	if player2 != null:
		var delta := player2.global_position - saved_position
		_check("the saved position is restored (%.2f m)" % Vector2(delta.x, delta.z).length(),
			Vector2(delta.x, delta.z).length() < 1.0)
	_finish()


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
		print("PASSED  all area persistence assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
