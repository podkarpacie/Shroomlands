extends SceneTree
## Headless InventorySystem test: stacking, overflow, removal, hotbar, save shape
## and unknown ids. `InventorySystem.gd` is loaded lazily because autoload
## singletons (`Game`, `EventBus`, `Lore`) are only resolvable after the
## `--script` main loop has started — a `preload` at the top would compile the
## system too early.

const INVENTORY_SCRIPT_PATH := "res://scripts/systems/InventorySystem.gd"

var _failures := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	var script: GDScript = load(INVENTORY_SCRIPT_PATH) as GDScript
	_check("InventorySystem.gd loads", script != null)
	if script == null:
		_finish()
		return

	var constants: Dictionary = script.get_script_constant_map()
	var slot_count := int(constants.get("SLOT_COUNT", 0))
	var max_stack := int(constants.get("MAX_STACK", 0))
	_check("SLOT_COUNT is 6x8 = 48", slot_count == 48)
	_check("MAX_STACK is 64", max_stack == 64)

	# --- stacking -----------------------------------------------------------
	var inventory: Variant = _new_inventory(script)
	_check("a fresh inventory is empty", int(inventory.call(&"count_item", &"glowcap")) == 0)

	var leftover := int(inventory.call(&"add_item", &"glowcap", 10))
	_check("adding 10 returns no leftover", leftover == 0)
	_check("adding 10 stores 10", int(inventory.call(&"count_item", &"glowcap")) == 10)

	leftover = int(inventory.call(&"add_item", &"glowcap", 60))
	_check("adding 60 more returns no leftover", leftover == 0)
	_check("total is 70", int(inventory.call(&"count_item", &"glowcap")) == 70)

	var first: Dictionary = inventory.call(&"get_slot", 0)
	var second: Dictionary = inventory.call(&"get_slot", 1)
	_check(
		"first stack caps at 64 (%d)" % int(first.get("count", 0)),
		int(first.get("count", 0)) == max_stack
	)
	_check(
		"6 overflow into the second slot (%s x%d)" % [
			str(second.get("id", &"")), int(second.get("count", 0))
		],
		StringName(second.get("id", &"")) == &"glowcap" and int(second.get("count", 0)) == 6
	)

	# --- full inventory never loses items silently -------------------------
	var filled: Variant = _new_inventory(script)
	for index: int in slot_count:
		filled.call(&"set_slot", index, &"emberstem", max_stack)
	_check("48 full stacks read as is_full()", bool(filled.call(&"is_full")))
	var overflow := int(filled.call(&"add_item", &"sunheart", 5))
	_check("adding 5 to a full inventory returns all 5 (%d)" % overflow, overflow == 5)
	_check(
		"existing 48*64 items survive the failed add",
		int(filled.call(&"count_item", &"emberstem")) == slot_count * max_stack
	)
	_check("no sunheart slipped in", int(filled.call(&"count_item", &"sunheart")) == 0)

	# --- removal ------------------------------------------------------------
	var sparse: Variant = _new_inventory(script)
	sparse.call(&"add_item", &"glowcap", 10)
	var removed := int(sparse.call(&"remove_item", &"glowcap", 25))
	_check("removing 25 of 10 removes only 10 (%d)" % removed, removed == 10)
	_check("count after over-removal is 0", int(sparse.call(&"count_item", &"glowcap")) == 0)

	sparse.call(&"add_item", &"glowcap", 10)
	removed = int(sparse.call(&"remove_item", &"glowcap", 4))
	_check("removing 4 of 10 reports 4 (%d)" % removed, removed == 4)
	_check("count after removal is 6", int(sparse.call(&"count_item", &"glowcap")) == 6)

	# --- hotbar -------------------------------------------------------------
	var hotbar: Array = inventory.call(&"hotbar_ids")
	_check("hotbar_ids() has 8 entries (%d)" % hotbar.size(), hotbar.size() == 8)
	_check(
		"hotbar[0] is the first stack's id",
		hotbar.size() > 0 and StringName(hotbar[0]) == &"glowcap"
	)
	_check(
		"an empty hotbar slot reports &\"\"",
		hotbar.size() > 2 and StringName(hotbar[2]) == &""
	)

	# --- save round-trip ----------------------------------------------------
	var data: Dictionary = inventory.call(&"to_dict")
	var packed: Variant = data.get("slots", {})
	_check(
		"to_dict skips empty slots (2 occupied)",
		packed is Dictionary and (packed as Dictionary).size() == 2
	)
	var restored: Variant = _new_inventory(script)
	restored.call(&"from_dict", data)
	_check("to_dict/from_dict round-trips exactly", restored.call(&"to_dict") == data)
	var restored_second: Dictionary = restored.call(&"get_slot", 1)
	_check(
		"round-trip keeps slot index and count",
		StringName(restored_second.get("id", &"")) == &"glowcap"
			and int(restored_second.get("count", 0)) == 6
	)

	# --- EventBus -----------------------------------------------------------
	var bus: Variant = root.get_node_or_null("EventBus")
	var added_chunks: Array = []
	if bus != null:
		bus.connect(
			&"item_added",
			func(id: String, count: int) -> void: added_chunks.append([id, count])
		)
	var signalled: Variant = _new_inventory(script)
	signalled.call(&"add_item", &"glowcap", 70)
	if bus != null:
		var total := 0
		for chunk: Array in added_chunks:
			total += int(chunk[1])
		_check("item_added fires once per accepted stack chunk (2)", added_chunks.size() == 2)
		_check("item_added chunks sum to 70 (%d)" % total, total == 70)
	else:
		_check("EventBus autoload is available", false)

	# --- unknown ids --------------------------------------------------------
	var odd: Variant = _new_inventory(script)
	var odd_leftover := int(odd.call(&"add_item", &"mystery_fungus", 3))
	_check("unknown id is accepted without a crash", odd_leftover == 0)
	_check(
		"unknown id counts like any other item",
		int(odd.call(&"count_item", &"mystery_fungus")) == 3
	)
	odd.call(&"from_dict", {"slots": {"nonsense": ["x", 1], "9000": ["y", 1]}})
	_check("from_dict ignores malformed slots", int(odd.call(&"count_item", &"mystery_fungus")) == 0)

	# --- sorting ------------------------------------------------------------
	var sortable: Variant = _new_inventory(script)
	sortable.call(&"add_item", &"sunheart", 1)
	sortable.call(&"add_item", &"glowcap", 2)
	sortable.call(&"add_item", &"emberstem", 3)
	sortable.call(&"sort_slots")
	var sorted_first: Dictionary = sortable.call(&"get_slot", 0)
	var sorted_second: Dictionary = sortable.call(&"get_slot", 1)
	var sorted_third: Dictionary = sortable.call(&"get_slot", 2)
	_check(
		"sort_slots orders common mushrooms before a very rare one",
		StringName(sorted_first.get("id", &"")) == &"emberstem"
		and StringName(sorted_second.get("id", &"")) == &"glowcap"
		and StringName(sorted_third.get("id", &"")) == &"sunheart"
	)
	_check(
		"sort_slots compacts the stacks into the first slots",
		not sorted_first.is_empty() and not sorted_second.is_empty()
		and not sorted_third.is_empty()
		and (sortable.call(&"get_slot", 3) as Dictionary).is_empty()
	)

	_finish()


func _new_inventory(script: GDScript) -> Variant:
	var inventory: Variant = script.new()
	root.add_child(inventory)
	return inventory


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all inventory assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
