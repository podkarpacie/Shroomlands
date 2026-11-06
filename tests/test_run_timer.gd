extends SceneTree
## Headless extraction-pressure test: entering the forest starts the run clock,
## the HUD shows it, expiring the run releases exactly one invincible Blight,
## and leaving the forest stops the clock.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const FOREST_PATH := "res://scenes/world/layered_forest.tscn"
const TOWN_PATH := "res://scenes/world/town.tscn"
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _main: Node = null
var _player: Node3D = null
var _game: Node = null
var _bus: Node = null
var _timer_events := 0
var _last_timer := -99.0
var _expired := 0


func _initialize() -> void:
	TestEnv.isolate("test_run_timer")
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
	_check("Game and EventBus autoloads exist", _game != null and _bus != null)
	if _game == null or _bus == null:
		_finish()
		return
	_bus.connect(&"run_timer_changed", Callable(self, "_on_timer"))
	_bus.connect(&"run_expired", Callable(self, "_on_expired"))
	_player = get_first_node_in_group(&"player") as Node3D
	_check("a player was spawned", _player != null)
	if _player == null:
		_finish()
		return

	var town := _main.get_node_or_null("World") as Node3D
	var gate := town.get_node_or_null("DescentGate") if town != null else null
	_check("town has a descent gate", gate != null)
	if gate == null:
		_finish()
		return
	gate.call(&"interact", _player)
	await _wait(12)
	var forest := _main.get_node_or_null("World") as Node3D
	_check("layer 1 loaded", forest != null and forest.scene_file_path == FOREST_PATH)
	if forest == null:
		_finish()
		return

	# --- clock and HUD -----------------------------------------------------
	var start := float(forest.get("run_seconds"))
	var left := float(forest.get("time_left"))
	_check("the run clock starts (%.0f of %.0f s)" % [left, start],
		start > 0.0 and left > 0.0 and left <= start)
	_check("the clock emits to the HUD", _timer_events > 0)
	var label := _main.get_node_or_null("HUD/Root/Progression/RunLabel") as Label
	_check("the HUD has a run label", label != null)
	if label != null:
		_check("the HUD shows the countdown (%s)" % label.text, label.text.begins_with("RUN"))

	# --- expiry releases one Blight ---------------------------------------
	var before := _expired
	forest.call(&"expire_run")
	await _wait(4)
	_check("expiry fires once", _expired == before + 1)
	var blight := forest.get_node_or_null("Blight") as Node3D
	_check("the Blight exists", blight != null)
	if blight != null:
		_check("the Blight joins the enemy group", blight.is_in_group(&"enemy"))
		_check("the Blight is effectively unkillable (%.0f hp)" % float(blight.get("max_hp")),
			float(blight.get("max_hp")) >= 1000.0)
		_check("the Blight hunts across the layer (%.0f m)" % float(blight.get("aggro_range")),
			float(blight.get("aggro_range")) >= 100.0)
		_check("the Blight is faster than a player (%.1f m/s)" % float(blight.get("move_speed")),
			float(blight.get("move_speed")) > 4.0)

	forest.call(&"expire_run")
	await _wait(3)
	var blights := 0
	for child in forest.get_children():
		if String(child.name) == "Blight":
			blights += 1
	_check("the Blight is released only once (%d)" % blights, blights == 1)

	# --- leaving stops the clock ------------------------------------------
	var back := forest.get_node_or_null("ReturnGate")
	_check("the forest has a return gate", back != null)
	if back == null:
		_finish()
		return
	back.call(&"interact", _player)
	await _wait(12)
	var home := _main.get_node_or_null("World") as Node3D
	_check("the leader returns to town", home != null and home.scene_file_path == TOWN_PATH)
	_check("leaving stops the clock (-1 sent)", _last_timer < 0.0)
	if label != null:
		_check("the HUD hides the clock in town (%s)" % label.text, label.text.is_empty())
	_finish()


func _on_timer(seconds_left: float) -> void:
	_timer_events += 1
	_last_timer = seconds_left


func _on_expired() -> void:
	_expired += 1


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
		print("PASSED  all run timer assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
