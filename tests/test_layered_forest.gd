extends SceneTree
## Headless layered-forest test on the real `main.tscn`: the town's descent gate
## builds layer 1, the dressing matches the generator, the chest pays once, the
## descent gate builds layer 2 with tougher enemies, and the return gate resets
## the layer state.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const FOREST_PATH := "res://scenes/world/layered_forest.tscn"
const TOWN_PATH := "res://scenes/world/town.tscn"
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _main: Node = null
var _player: Node3D = null
## Autoloads are not resolvable while a `--script` suite compiles, so this is
## fetched at runtime like the rest of the scene.
var _game: Node = null


func _initialize() -> void:
	TestEnv.isolate("test_layered_forest")
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
	_main = packed.instantiate()
	root.add_child(_main)
	await _wait(30)
	_game = root.get_node_or_null("/root/Game")
	_check("the Game autoload is available", _game != null)
	if _game == null:
		_finish()
		return

	_player = get_first_node_in_group(&"player") as Node3D
	_check("a player was spawned", _player != null)
	if _player == null:
		_finish()
		return

	var town := _main.get_node_or_null("World") as Node3D
	_check("the session starts in town", town != null and town.scene_file_path == TOWN_PATH)
	if town == null:
		_finish()
		return

	var gate := town.get_node_or_null("DescentGate")
	_check("town has a descent gate", gate != null)
	if gate == null:
		_finish()
		return
	_check("the gate targets the layered forest", str(gate.get("target_scene")) == FOREST_PATH)
	_check("the gate selects layer 1", int(gate.get("target_layer")) == 1)

	# --- town -> layer 1 ---------------------------------------------------
	gate.call(&"interact", _player)
	await _wait(12)
	var forest := _main.get_node_or_null("World") as Node3D
	_check("the gate swaps to a forest world", forest != null and forest.scene_file_path == FOREST_PATH)
	if forest == null:
		_finish()
		return
	_check("layer state is 1", int(_game.get("forest_layer")) == 1)
	_check("biome follows layer 1 (%s)" % _game.get("current_biome"), _game.get("current_biome") == &"verdant_bloom")

	var caption := str(forest.get("display_name"))
	_check(
		"the caption names the layer (%s)" % caption,
		caption.contains("The Shallows") and caption.contains("Layer 1")
	)

	var spawn := forest.get_node_or_null("PlayerSpawn") as Marker3D
	_check("the forest has a PlayerSpawn", spawn != null)
	if spawn != null:
		_check(
			"the player starts on the forest spawn",
			_player.global_position.distance_to(spawn.global_position) < 1.0
		)

	var mushrooms := int(forest.get("generated_mushrooms"))
	var hazards := int(forest.get("generated_hazards"))
	_check("the forest placed mushrooms (%d)" % mushrooms, mushrooms >= 4)
	_check("the forest placed hazards (%d)" % hazards, hazards >= 2)
	_check(
		"every hazard has a node",
		forest.find_children("SporeBloom*", "", true, false).size() == hazards
	)
	_check("the run has a structure", forest.get_node_or_null("Props/Structure") != null)
	_check("layer 1 builds a hut (%d)" % int(forest.get("structure_kind")),
		int(forest.get("structure_kind")) == 0)
	_check("the hut marker exists", forest.get_node_or_null("Props/Structure/Hut") != null)
	_check("the hut posts have collision (%d solids)" % _solid_count(forest),
		_solid_count(forest) >= 4)
	var chest := forest.get_node_or_null("Props/Structure/Chest")
	_check("the structure has a loot chest", chest != null)
	_check("the entry has a return gate", forest.get_node_or_null("ReturnGate") != null)
	var descent := forest.get_node_or_null("DescentGate")
	_check("a shallows run has a descent gate", descent != null)
	if descent != null:
		_check("the descent targets layer 2", int(descent.get("target_layer")) == 2)

	var nearest := 999.0
	for bloom in forest.find_children("SporeBloom*", "", true, false):
		nearest = minf(nearest, _flat_distance((bloom as Node3D).global_position))
	_check("no bloom inside the 12 m spawn clearing (%.1f m)" % nearest, nearest >= 12.0)

	# --- chest pays exactly once ------------------------------------------
	var inventory := _player.get_node_or_null("InventorySystem")
	_check("the player has an inventory", inventory != null)
	if inventory == null or chest == null:
		_finish()
		return
	var resource_ids: Array[String] = []
	for id: String in (chest.get("loot") as Array):
		if (Lore.RESOURCES as Dictionary).has(id):
			resource_ids.append(id)
	_check("the hut chest drops crafting materials (%s)" % str(resource_ids),
		not resource_ids.is_empty())
	var items_before := _inventory_total(inventory)
	var gold_before := int(_game.get("gold"))
	chest.call(&"interact", _player)
	var loot: Array = chest.get("loot")
	_check("the chest opens", bool(chest.get("opened")))
	_check(
		"the chest pays its loot (%d item(s))" % loot.size(),
		_inventory_total(inventory) == items_before + loot.size()
	)
	_check("the chest pays gold (%d)" % (int(_game.get("gold")) - gold_before), int(_game.get("gold")) > gold_before)
	var items_after := _inventory_total(inventory)
	var gold_after := int(_game.get("gold"))
	chest.call(&"interact", _player)
	_check(
		"the chest cannot be opened twice",
		_inventory_total(inventory) == items_after and int(_game.get("gold")) == gold_after
	)

	# --- layer 1 -> layer 2 ------------------------------------------------
	var layer_one := forest
	descent.call(&"interact", _player)
	await _wait(12)
	var layer_two := _main.get_node_or_null("World") as Node3D
	_check(
		"the descent swaps the world",
		layer_two != null and layer_two.scene_file_path == FOREST_PATH and layer_two != layer_one
	)
	if layer_two == null:
		_finish()
		return
	_check("layer state is 2", int(_game.get("forest_layer")) == 2)
	_check("layer 2 builds a castle (%d)" % int(layer_two.get("structure_kind")),
		int(layer_two.get("structure_kind")) == 1)
	_check("the castle marker exists", layer_two.get_node_or_null("Props/Structure/Castle") != null)
	_check("the castle walls have collision (%d solids)" % _solid_count(layer_two),
		_solid_count(layer_two) >= 8)
	_check("biome follows layer 2 (%s)" % _game.get("current_biome"), _game.get("current_biome") == &"violet_hollows")
	_check(
		"the layer-2 caption follows (%s)" % str(layer_two.get("display_name")),
		str(layer_two.get("display_name")).contains("Layer 2")
	)
	_check(
		"deeper layers place more hazards (%d)" % int(layer_two.get("generated_hazards")),
		int(layer_two.get("generated_hazards")) >= 3
	)

	var scaled := false
	for enemy in _main.call(&"get_enemies"):
		if float((enemy as Node).get(&"max_hp")) > 60.0:
			scaled = true
	_check("deeper enemies are tougher", scaled)

	# --- back to town ------------------------------------------------------
	var back := layer_two.get_node_or_null("ReturnGate")
	_check("layer 2 has a return gate", back != null)
	if back == null:
		_finish()
		return
	back.call(&"interact", _player)
	await _wait(12)
	var town_again := _main.get_node_or_null("World") as Node3D
	_check(
		"the return gate goes to town",
		town_again != null and town_again.scene_file_path == TOWN_PATH
	)
	_check("layer state resets in town", int(_game.get("forest_layer")) == 0)

	# --- deeper layers build the dungeon ---------------------------------
	_game.set(&"forest_layer", 4)
	_check("layer 4 loads", bool(_main.call(&"enter_area", FOREST_PATH)))
	await _wait(12)
	var deep := _main.get_node_or_null("World") as Node3D
	_check("layer 4 builds a dungeon (%d)" % int(deep.get("structure_kind")) if deep != null else "missing",
		deep != null and int(deep.get("structure_kind")) == 2)
	_check("the dungeon marker exists",
		deep != null and deep.get_node_or_null("Props/Structure/Dungeon") != null)
	_check("the dungeon walls have collision (%d solids)" % _solid_count(deep),
		deep != null and _solid_count(deep) >= 6)
	if deep != null:
		var solids := deep.get_node("Props/Structure").find_children(
			"Solid_*", "StaticBody3D", true, false
		)
		_check("structure solids are world geometry",
			not solids.is_empty() and (solids[0] as StaticBody3D).collision_layer == 1)
	_finish()


func _solid_count(world: Node) -> int:
	if world == null:
		return 0
	var structure := world.get_node_or_null("Props/Structure")
	if structure == null:
		return 0
	return structure.find_children("Solid_*", "StaticBody3D", true, false).size()


func _flat_distance(point: Vector3) -> float:
	var delta := point - _player.global_position
	return Vector2(delta.x, delta.z).length()


func _inventory_total(inventory: Node) -> int:
	var total := 0
	var slots: Array = inventory.get("slots")
	for slot: Dictionary in slots:
		total += int(slot.get("count", 0))
	return total


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
		print("PASSED  all layered forest assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
