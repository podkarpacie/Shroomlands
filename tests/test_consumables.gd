extends SceneTree
## Headless eating/brewing test: `InventorySystem.use_slot` consumes exactly one
## item, applies the Lore effect, charges toxicity, refuses empty/unknown slots
## and drives potions through the same path.
##
## Uses the real player scene so the inventory talks to its sibling `Stats`, the
## same wiring the hotbar/inventory double-click uses in game.

const PLAYER_SCENE_PATH := "res://scenes/player/player.tscn"
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _toasts: Array[String] = []


func _initialize() -> void:
	TestEnv.isolate("test_consumables")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	var bus: Node = root.get_node_or_null("EventBus")
	_check("EventBus autoload exists", bus != null)
	if bus == null:
		_finish()
		return
	bus.connect(&"toast_requested", func(text: String) -> void: _toasts.append(text))

	var packed := load(PLAYER_SCENE_PATH) as PackedScene
	_check("player.tscn loads", packed != null)
	if packed == null:
		_finish()
		return
	var player := packed.instantiate() as Node3D
	root.add_child(player)
	await physics_frame
	var inventory := player.get_node_or_null("InventorySystem")
	var stats := player.get_node_or_null("Stats")
	_check("the player has an InventorySystem", inventory != null)
	_check("the player has Stats", stats != null)
	if inventory == null or stats == null:
		_finish()
		return
	_check("InventorySystem exposes use_slot", inventory.has_method(&"use_slot"))
	_check("Stats exposes apply_effect", stats.has_method(&"apply_effect"))

	# --- an empty slot is not a snack ---------------------------------------
	_check("use_slot on an empty slot returns false", not bool(inventory.call(&"use_slot", 0)))
	_check("use_slot ignores an out-of-range index", not bool(inventory.call(&"use_slot", -1)))
	_check("use_slot ignores a past-the-end index", not bool(inventory.call(&"use_slot", 48)))

	# --- resources and unknown ids are refused -------------------------------
	inventory.call(&"set_slot", 0, &"mycelium_fiber", 2)
	_check("use_slot refuses a resource", not bool(inventory.call(&"use_slot", 0)))
	_check(
		"a refused resource keeps its stack (%d)" % int(inventory.call(&"count_item", &"mycelium_fiber")),
		int(inventory.call(&"count_item", &"mycelium_fiber")) == 2
	)
	_check("a refused item says so (%s)" % _last_toast(), _last_toast().contains("not edible"))

	inventory.call(&"set_slot", 0, &"mystery_fungus", 1)
	_check("use_slot refuses an unknown id", not bool(inventory.call(&"use_slot", 0)))
	_check(
		"an unknown id keeps its stack",
		int(inventory.call(&"count_item", &"mystery_fungus")) == 1
	)

	# --- a raw mushroom eats one, heals, and leaves the rest ---------------
	stats.set("hp", 50.0)
	inventory.call(&"set_slot", 1, &"konop", 2)
	var eaten := bool(inventory.call(&"use_slot", 1))
	_check("use_slot accepts a raw mushroom", eaten)
	_check(
		"Konop heals 15 (50 -> %.0f)" % float(stats.get("hp")),
		is_equal_approx(float(stats.get("hp")), 65.0)
	)
	_check(
		"exactly one Konop was consumed (%d)" % int(inventory.call(&"count_item", &"konop")),
		int(inventory.call(&"count_item", &"konop")) == 1
	)
	_check("the eat toast names the item (%s)" % _last_toast(), _last_toast() == "You eat Konop")

	_check("the second Konop is eaten too", bool(inventory.call(&"use_slot", 1)))
	_check("the stack is empty after the last bite", int(inventory.call(&"count_item", &"konop")) == 0)
	_check("the emptied slot is empty", (inventory.call(&"get_slot", 1) as Dictionary).is_empty())
	_check("a drained slot refuses a third use", not bool(inventory.call(&"use_slot", 1)))

	# --- a potion is consumed the same way ----------------------------------
	stats.set("hp", 10.0)
	inventory.call(&"set_slot", 2, &"konop_draught", 1)
	_check("use_slot accepts a potion", bool(inventory.call(&"use_slot", 2)))
	_check(
		"Konop Draught heals 45 (10 -> %.0f)" % float(stats.get("hp")),
		is_equal_approx(float(stats.get("hp")), 55.0)
	)
	_check("the potion stack is gone", int(inventory.call(&"count_item", &"konop_draught")) == 0)
	_check("the drink toast names the potion (%s)" % _last_toast(), _last_toast() == "You drink Konop Draught")

	# --- toxicity is a one-off HP cost on top of the eat effect -------------
	stats.set("hp", 100.0)
	inventory.call(&"set_slot", 3, &"kazar", 1)
	_check("a toxic mushroom still eats", bool(inventory.call(&"use_slot", 3)))
	_check(
		"Kazar costs 8 self-damage + 2 toxicity (100 -> %.0f)" % float(stats.get("hp")),
		is_equal_approx(float(stats.get("hp")), 90.0)
	)
	_check("the toxic toast is marked (%s)" % _last_toast(), _last_toast().contains("toxic"))

	# --- poison from a raw Bedak -------------------------------------------
	stats.set("hp", 100.0)
	inventory.call(&"set_slot", 4, &"bedak", 1)
	_check("a poisonous mushroom eats", bool(inventory.call(&"use_slot", 4)))
	_check("Bedak poisons the player", bool(stats.call(&"is_poisoned")))
	_check(
		"Bedak toxicity is paid immediately (100 -> %.0f)" % float(stats.get("hp")),
		is_equal_approx(float(stats.get("hp")), 96.0)
	)
	await _wait_seconds(1.15)
	_check(
		"the poison DoT ticks afterwards (%.1f)" % float(stats.get("hp")),
		float(stats.get("hp")) < 96.0
	)

	# --- a dead body refuses food ------------------------------------------
	stats.call(&"take_damage", 9999.0)
	_check("the test body is dead", bool(stats.call(&"is_dead")))
	inventory.call(&"set_slot", 5, &"konop", 1)
	_check("use_slot refuses a dead body", not bool(inventory.call(&"use_slot", 5)))
	_check(
		"a refused dead-body meal keeps the item",
		int(inventory.call(&"count_item", &"konop")) == 1
	)

	_finish()


func _last_toast() -> String:
	return _toasts[_toasts.size() - 1] if not _toasts.is_empty() else ""


func _wait_seconds(seconds: float) -> void:
	await create_timer(seconds).timeout


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all consumable assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
