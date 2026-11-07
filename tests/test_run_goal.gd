extends SceneTree
## Headless run-goal test: quota tracking from containers and mushrooms, death
## costing half of every stack, and the end-of-run summary panel on extraction.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const FOREST_PATH := "res://scenes/world/layered_forest.tscn"
const TOWN_PATH := "res://scenes/world/town.tscn"
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _main: Node = null
var _player: Node3D = null
var _game: Node = null
var _bus: Node = null
var _stats: Node = null
var _inventory: Node = null
var _summary: Dictionary = {}
var _summaries := 0


func _initialize() -> void:
	TestEnv.isolate("test_run_goal")
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
	_bus.connect(&"run_finished", Callable(self, "_on_run_finished"))
	_player = get_first_node_in_group(&"player") as Node3D
	_check("a player was spawned", _player != null)
	if _player == null:
		_finish()
		return
	_stats = _player.get_node_or_null("Stats")
	_inventory = _player.get_node_or_null("InventorySystem")
	_check("player has Stats and InventorySystem", _stats != null and _inventory != null)
	if _stats == null or _inventory == null:
		_finish()
		return

	# --- enter layer 1 and start a quota --------------------------------
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
	_check("the run starts on layer 1", int(_game.get(&"run_layer")) == 1)
	_check("the quota is layer-based (%.0f)" % float(_game.get(&"run_quota")),
		int(_game.get(&"run_quota")) == 60)
	_check("loot starts at zero", int(_game.get(&"run_gold")) == 0)
	var quota_label := _main.get_node_or_null("HUD/Root/Progression/QuotaLabel") as Label
	_check("the HUD has a quota label", quota_label != null)
	if quota_label != null:
		_check("the HUD shows the quota (%s)" % quota_label.text,
			quota_label.text.contains("0 / 60"))

	# --- containers and mushrooms feed the quota ------------------------
	_game.call(&"add_run_gold", 30)
	_check("container gold counts toward the quota", int(_game.get(&"run_gold")) == 30)
	_bus.emit_signal(&"mushroom_gathered", "konop", 2)
	_check("mushrooms count at shop value (%d)" % int(_game.get(&"run_gold")),
		int(_game.get(&"run_gold")) == 40 and int(_game.get(&"run_mushrooms")) == 2)
	_game.call(&"add_run_gold", 25)
	await _wait(2)
	_check("the quota is reached", int(_game.get(&"run_gold")) == 65)
	if quota_label != null:
		_check("the HUD follows the total (%s)" % quota_label.text,
			quota_label.text.contains("65 / 60"))

	# --- death costs half of every stack -------------------------------
	_inventory.call(&"add_item", &"konop", 10)
	_inventory.call(&"add_item", &"shitake", 1)
	var held := int(_inventory.call(&"count_item", &"konop"))
	_check("the test carries 10 konops", held == 10)
	_stats.call(&"take_damage", 999.0)
	await _wait(2)
	var left := int(_inventory.call(&"count_item", &"konop"))
	_check("death drops half the stack (%d -> %d)" % [held, left], left == held / 2)
	# Rounding down used to make a lone item a free death.
	_check("a lone item is still lost (1 -> %d)" % int(_inventory.call(&"count_item", &"shitake")),
		int(_inventory.call(&"count_item", &"shitake")) == 0)
	_check("the run records the death", int(_game.get(&"run_deaths")) == 1)
	_stats.call(&"respawn")
	await _wait(3)

	# --- extraction closes the run and shows the summary ---------------
	var gold_before := int(_game.get(&"gold"))
	var back := forest.get_node_or_null("ReturnGate")
	_check("the forest has a return gate", back != null)
	if back == null:
		_finish()
		return
	back.call(&"interact", _player)
	await _wait(12)
	var home := _main.get_node_or_null("World") as Node3D
	_check("the player is back in town", home != null and home.scene_file_path == TOWN_PATH)
	_check("the summary fired once", _summaries == 1)
	_check("extracting pays survival xp (%d)" % int(_game.call(&"skill_xp", "survival")),
		int(_game.call(&"skill_xp", "survival")) > 0)
	_check("the run met its quota", bool(_summary.get("met", false)))
	_check("the summary stores the loot (%d)" % int(_summary.get("gold", 0)),
		int(_summary.get("gold", 0)) == 65)
	_check("the summary stores the death", int(_summary.get("deaths", 0)) == 1)
	_check("meeting quota pays a bonus (%d g)" % (int(_game.get(&"gold")) - gold_before),
		int(_game.get(&"gold")) == gold_before + int(_summary.get("bonus", 0))
		and int(_summary.get("bonus", 0)) > 0)

	var panel := _main.get_node_or_null("RunSummary") as CanvasLayer
	_check("the summary panel exists", panel != null)
	if panel != null:
		_check("the summary panel is visible", panel.visible)
		var title := panel.get_node_or_null("Root/Center/Card/Margin/Content/Title") as Label
		var body := panel.get_node_or_null("Root/Center/Card/Margin/Content/Body") as Label
		_check("the title reports success (%s)" % (title.text if title != null else "missing"),
			title != null and title.text.contains("COMPLETE"))
		_check("the body shows the loot line (%s)" % (body.text if body != null else "missing"),
			body != null and body.text.contains("65 / 60"))
		var button := panel.get_node_or_null(
			"Root/Center/Card/Margin/Content/ContinueButton"
		) as Button
		_check("the summary has a continue button", button != null)
		if button != null:
			button.pressed.emit()
			_check("continue closes the panel", not panel.visible)

	# --- a second, empty run misses the quota --------------------------
	var town_again := _main.get_node_or_null("World") as Node3D
	var gate_again := town_again.get_node_or_null("DescentGate") if town_again != null else null
	_check("town still has a descent gate", gate_again != null)
	if gate_again != null:
		gate_again.call(&"interact", _player)
	await _wait(12)
	var plain := _main.get_node_or_null("World") as Node3D
	_check("layer 1 reloaded", plain != null and plain.scene_file_path == FOREST_PATH)
	_check("the new run resets the loot", int(_game.get(&"run_gold")) == 0)
	if plain != null:
		var back2 := plain.get_node_or_null("ReturnGate")
		if back2 != null:
			back2.call(&"interact", _player)
			await _wait(12)
	_check("the second summary fired", _summaries == 2)
	_check("an empty run misses the quota", not bool(_summary.get("met", true)))

	# --- descending closes the layer's book --------------------------------
	# The old `_swap_area` only finished a run when the target was *not* the
	# forest, so layers 1-4 never paid a summary or the quota bonus.
	var town_world2 := _main.get_node_or_null("World") as Node3D
	var gate2 := town_world2.get_node_or_null("DescentGate") if town_world2 != null else null
	if gate2 != null:
		gate2.call(&"interact", _player)
	await _wait(12)
	var before_descend := _summaries
	var summaries_before := _summary.duplicate()
	_main.call(&"_swap_area", FOREST_PATH, 2)
	await _wait(12)
	_check("descending finishes the previous layer (%d -> %d summaries)" % [
			before_descend, _summaries
		],
		_summaries == before_descend + 1)
	_check("the finished summary is layer 1 (%s)" % int(_summary.get("layer", 0)),
		int(_summary.get("layer", 0)) == 1)
	_check("the new run is layer 2 (%s)" % int(_game.get(&"run_layer")),
		int(_game.get(&"run_layer")) == 2)
	if panel != null:
		var title2 := panel.get_node_or_null("Root/Center/Card/Margin/Content/Title") as Label
		_check("the title reports the miss (%s)" % (title2.text if title2 != null else "missing"),
			title2 != null and title2.text.contains("MISSED"))
	_finish()


func _on_run_finished(summary: Dictionary) -> void:
	_summaries += 1
	_summary = summary


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
		print("PASSED  all run goal assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
