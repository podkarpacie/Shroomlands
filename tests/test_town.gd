extends SceneTree
## Headless town/area test on the real `main.tscn`: the spawn world is the town,
## the player stands on its `PlayerSpawn`, every station is an interactable with
## a prompt, and the gate swaps town -> forest -> town while the HUD survives.
##
## `main.tscn` is loaded lazily: autoload identifiers only resolve after the
## `--script` main loop starts (same constraint as test_player.gd).

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const TOWN_SCENE_PATH := "res://scenes/world/town.tscn"
const FOREST_SCENE_PATH := "res://scenes/world/verdant_bloom.tscn"
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0


func _initialize() -> void:
	TestEnv.isolate("test_town")
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
	await _wait_physics(30)

	var world := main.get_node_or_null("World") as Node3D
	_check("Main has a World", world != null)
	if world == null:
		_finish()
		return
	_check(
		"the spawn world is the town (%s)" % world.scene_file_path,
		world.scene_file_path == TOWN_SCENE_PATH
	)
	var spawn := world.get_node_or_null("PlayerSpawn") as Marker3D
	_check("the town has a PlayerSpawn marker", spawn != null)
	var player := get_first_node_in_group(&"player") as Node3D
	_check("a player was spawned", player != null)
	if player == null or spawn == null:
		_finish()
		return
	_check(
		"the player spawns on the town marker (%.2f m)" % player.global_position.distance_to(spawn.global_position),
		player.global_position.distance_to(spawn.global_position) < 1.5
	)

	var hud := main.get_node_or_null("HUD")
	var inventory_ui := main.get_node_or_null("InventoryUI")
	_check("Main has a HUD", hud != null)
	_check("Main has an InventoryUI", inventory_ui != null)
	var hud_id := hud.get_instance_id() if hud != null else 0
	# The caption is read before any gate interaction: the HUD is ready before
	# its `Main` parent, so this is the startup path that used to show the biome
	# default instead of the town.
	_check(
		"the HUD names the starting area (%s)" % _hud_caption(hud),
		_hud_caption(hud) == "MYCORIA"
	)

	# --- every station is an interactable with a prompt ---------------------
	for station_name: String in ["Shop", "AlchemyTable", "RepairBench", "PlotBoard", "ForestGate"]:
		var station := world.get_node_or_null(station_name)
		_check("the town has a %s" % station_name, station != null)
		if station == null:
			continue
		_check(
			"%s is in group 'interactable'" % station_name,
			station.is_in_group(&"interactable")
		)
		_check(
			"%s exposes get_interaction_text()" % station_name,
			station.has_method(&"get_interaction_text")
		)
		var text := str(station.call(&"get_interaction_text")) if station.has_method(&"get_interaction_text") else ""
		_check(
			"%s has a non-empty prompt (%s)" % [station_name, text],
			not text.is_empty()
		)

	# --- gate: town -> forest ----------------------------------------------
	var gate := world.get_node_or_null("ForestGate")
	_check("the town gate exists", gate != null)
	if gate == null:
		_finish()
		return
	gate.call(&"interact", player)
	await _wait_physics(5)

	var forest := main.get_node_or_null("World") as Node3D
	_check("the town gate swaps the world node", forest != null and forest != world)
	_check(
		"the forest world is verdant_bloom (%s)" % (forest.scene_file_path if forest != null else "missing"),
		forest != null and forest.scene_file_path == FOREST_SCENE_PATH
	)
	if forest == null:
		_finish()
		return
	var forest_spawn := forest.find_child("PlayerSpawn", true, false) as Marker3D
	_check("the forest has a PlayerSpawn marker", forest_spawn != null)
	if forest_spawn != null:
		var moved := player.global_position.distance_to(forest_spawn.global_position)
		print("player distance to the forest spawn: %.2f m" % moved)
		_check("the player moved to the forest spawn", moved < 1.5)
	_check("the HUD survived the swap", main.get_node_or_null("HUD") == hud and hud.is_inside_tree())
	if hud != null:
		_check("the HUD is the same instance", main.get_node("HUD").get_instance_id() == hud_id)
	_check(
		"the HUD caption follows the gate to the forest (%s)" % _hud_caption(hud),
		_hud_caption(hud) == "VERDANT BLOOM"
	)
	_check("the inventory UI survived the swap", main.get_node_or_null("InventoryUI") == inventory_ui)
	_check("the satchel panel still works after the swap", inventory_ui != null and inventory_ui.has_method(&"toggle"))

	# --- the forest has a gate back ----------------------------------------
	var town_gate := forest.find_child("Town Gate", true, false)
	_check("the forest has a Town Gate", town_gate != null)
	if town_gate == null:
		_finish()
		return
	_check(
		"the forest gate is interactable",
		town_gate.is_in_group(&"interactable")
	)
	var back_text := str(town_gate.call(&"get_interaction_text"))
	_check("the forest gate has a prompt (%s)" % back_text, not back_text.is_empty())

	town_gate.call(&"interact", player)
	await _wait_physics(5)
	var town := main.get_node_or_null("World") as Node3D
	_check(
		"the forest gate returns to town (%s)" % (town.scene_file_path if town != null else "missing"),
		town != null and town.scene_file_path == TOWN_SCENE_PATH and town != forest
	)
	if town != null:
		var town_spawn := town.find_child("PlayerSpawn", true, false) as Marker3D
		_check("the returned town has a PlayerSpawn", town_spawn != null)
		if town_spawn != null:
			var ended := player.global_position.distance_to(town_spawn.global_position)
			print("player distance after the round trip: %.2f m" % ended)
			_check("the round trip ends near the town spawn", ended < 1.5)
	_check(
		"the HUD caption follows the gate back to town (%s)" % _hud_caption(hud),
		_hud_caption(hud) == "MYCORIA"
	)

	# --- bad paths and a missing player stay safe ---------------------------
	var before := main.get_node_or_null("World")
	_check(
		"an unknown area path is refused",
		not bool(main.call(&"enter_area", "res://scenes/world/does_not_exist.tscn"))
	)
	_check("a refused swap keeps the current world", main.get_node_or_null("World") == before)

	player.queue_free()
	await _wait_physics(3)
	_check(
		"enter_area is safe with no player",
		bool(main.call(&"enter_area", FOREST_SCENE_PATH))
	)
	await _wait_physics(3)
	var final_world := main.get_node_or_null("World") as Node3D
	_check(
		"the world still changes with no player",
		final_world != null and final_world.scene_file_path == FOREST_SCENE_PATH
	)
	_check("the HUD is still alive after the playerless swap", main.get_node_or_null("HUD") == hud)

	_finish()


func _wait_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame


## Text of the HUD's top-right area caption, or "" when the label is missing.
func _hud_caption(hud: Node) -> String:
	if hud == null:
		return ""
	var label := hud.get_node_or_null("Root/Progression/BiomeLabel") as Label
	return label.text if label != null else ""


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all town assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
