extends SceneTree
## Headless horror-search test: night layers are dark, the spore-lamp drains and
## recharges, searching a crate pays once and makes noise, and a creature walks
## toward a disturbance from outside its normal aggro range.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const FOREST_PATH := "res://scenes/world/layered_forest.tscn"
const CRATE_SCENE_PATH := "res://scenes/world/searchable_crate.tscn"
const ENEMY_SCENE_PATH := "res://scenes/world/enemy.tscn"
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _main: Node = null
var _player: Node3D = null
var _game: Node = null
var _bus: Node = null
var _disturbances := 0


func _initialize() -> void:
	TestEnv.isolate("test_horror_search")
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
	_bus = root.get_node_or_null("/root/EventBus")
	_check("Game and EventBus autoloads are available", _game != null and _bus != null)
	if _game == null or _bus == null:
		_finish()
		return
	_bus.connect(&"disturbance_emitted", Callable(self, "_count_disturbance"))
	_player = get_first_node_in_group(&"player") as Node3D
	_check("a player was spawned", _player != null)
	if _player == null:
		_finish()
		return

	# --- shallow layer is lit ---------------------------------------------
	var town := _main.get_node_or_null("World") as Node3D
	var gate := town.get_node_or_null("DescentGate") if town != null else null
	_check("town has a descent gate", gate != null)
	if gate == null:
		_finish()
		return
	gate.call(&"interact", _player)
	await _wait(12)
	var shallow := _main.get_node_or_null("World") as Node3D
	_check("layer 1 loaded", shallow != null and shallow.scene_file_path == FOREST_PATH)
	if shallow == null:
		_finish()
		return
	_check("layer 1 is lit", not bool(shallow.get("is_dark")))
	var shallow_sun := shallow.get_node_or_null("Sun") as DirectionalLight3D
	_check("layer 1 keeps sunlight", shallow_sun != null and shallow_sun.light_energy > 0.5)

	# --- layer 3 is a night run -------------------------------------------
	_game.set(&"forest_layer", 3)
	_check("a direct area load works", bool(_main.call(&"enter_area", FOREST_PATH)))
	await _wait(12)
	var night := _main.get_node_or_null("World") as Node3D
	_check("layer 3 is a different world", night != null and night != shallow)
	if night == null:
		_finish()
		return
	_check("layer 3 is dark", bool(night.get("is_dark")))
	_check("layer 3 uses the crimson biome (%s)" % _game.get("current_biome"),
		_game.get("current_biome") == &"crimson_rot")
	var sun := night.get_node_or_null("Sun") as DirectionalLight3D
	var world_env := night.get_node_or_null("WorldEnvironment") as WorldEnvironment
	_check("the night sun is down", sun != null and sun.light_energy <= 0.2)
	_check(
		"night ambient is low",
		world_env != null and world_env.environment != null
		and world_env.environment.ambient_light_energy < 0.4
	)
	_check("the hut has three searchable crates (%d)" % int(night.get("generated_crates")),
		int(night.get("generated_crates")) == 3)

	# --- spore-lamp --------------------------------------------------------
	var lamp := _player.get_node_or_null("SporeLamp")
	_check("the player has a spore-lamp", lamp != null)
	if lamp == null:
		_finish()
		return
	_check("the lamp starts off", not bool(lamp.call("is_on")))
	var battery_before := float(lamp.get("battery"))
	var disturbances_before := _disturbances
	lamp.call(&"toggle")
	_check("the lamp turns on", bool(lamp.call("is_on")) and (lamp as Node3D).visible)
	await _wait_time(1.3)
	_check("the lamp drains while on (%.1f)" % float(lamp.get("battery")),
		float(lamp.get("battery")) < battery_before)
	_check("a lit beam disturbs creatures (%d)" % _disturbances,
		_disturbances > disturbances_before)
	lamp.call(&"toggle")
	_check("the lamp turns off", not bool(lamp.call("is_on")))
	var low := float(lamp.get("battery"))
	await _wait_time(0.8)
	_check("the lamp recharges while off", float(lamp.get("battery")) > low)

	# --- searchable crate --------------------------------------------------
	var inventory := _player.get_node_or_null("InventorySystem")
	_check("the player has an inventory", inventory != null)
	if inventory == null:
		_finish()
		return
	var items_before := _inventory_total(inventory)
	var gold_before := int(_game.get("gold"))
	var crate := load(CRATE_SCENE_PATH).instantiate() as Node3D
	_check("searchable_crate.tscn loads", crate != null)
	if crate == null:
		_finish()
		return
	var loot: Array[String] = ["konop"]
	crate.set(&"loot", loot)
	crate.set(&"gold", 7)
	crate.set(&"search_seconds", 0.4)
	crate.position = _player.global_position + Vector3(1.5, 0.0, 0.0)
	root.add_child(crate)
	await _wait(2)

	var noise_before := _disturbances
	crate.call(&"interact", _player)
	_check("interacting starts the search", bool(crate.get("searching")))
	_check("the crate is not opened instantly", not bool(crate.get("opened")))
	await _wait_time(0.22)
	_check("the search is still running", not bool(crate.get("opened")))
	await _wait_time(0.4)
	_check("the crate opens after the search", bool(crate.get("opened")))
	_check("the crate pays its loot", _inventory_total(inventory) == items_before + 1)
	_check("the crate pays its gold", int(_game.get("gold")) == gold_before + 7)
	_check("searching makes noise (%d)" % _disturbances, _disturbances > noise_before)
	_check("opening a crate pays survival xp (%d)" % int(_game.call(&"skill_xp", "survival")),
		int(_game.call(&"skill_xp", "survival")) > 0)

	var items_after := _inventory_total(inventory)
	var gold_after := int(_game.get("gold"))
	crate.call(&"interact", _player)
	await _wait_time(0.2)
	_check("the crate cannot be searched twice",
		_inventory_total(inventory) == items_after and int(_game.get("gold")) == gold_after)

	# --- a creature hears the search --------------------------------------
	# 30 m away: outside its 12 m aggro range, but inside the 20 m radius of the
	# disturbance used here.
	var enemy := load(ENEMY_SCENE_PATH).instantiate() as Node3D
	enemy.position = _player.global_position + Vector3(30.0, 0.0, 0.0)
	root.add_child(enemy)
	await _wait(3)
	_check("a distant creature is not investigating yet", not bool(enemy.call("is_investigating")))
	_bus.emit_signal(
		&"disturbance_emitted",
		enemy.global_position + Vector3(3.0, 0.0, 0.0),
		20.0
	)
	await _wait(2)
	_check("the creature investigates the disturbance", bool(enemy.call("is_investigating")))

	enemy.queue_free()
	crate.queue_free()
	await _wait(2)
	_finish()


func _count_disturbance(_position: Vector3, _radius: float) -> void:
	_disturbances += 1


func _inventory_total(inventory: Node) -> int:
	var total := 0
	var slots: Array = inventory.get("slots")
	for slot: Dictionary in slots:
		total += int(slot.get("count", 0))
	return total


func _wait(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _wait_time(seconds: float) -> void:
	await create_timer(seconds).timeout


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all horror search assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
