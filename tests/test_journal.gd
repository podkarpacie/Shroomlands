extends SceneTree
## Found-journal test: five chapters, one per layer, each pointing at a faction.
## Crate1 in a layer carries that layer's page, looting it unlocks the chapter
## exactly once, the catalogue shows it, and the discoveries survive a save.

const TestEnv := preload("res://tests/test_env.gd")
const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const FOREST_PATH := "res://scenes/world/layered_forest.tscn"

var _failures := 0
var _discoveries := 0


func _initialize() -> void:
	TestEnv.isolate("test_journal")
	TestEnv.stash("user://plots.json")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	var lore: Node = root.get_node_or_null("Lore")
	var game: Node = root.get_node_or_null("Game")
	var bus: Node = root.get_node_or_null("EventBus")
	_check("autoloads exist", lore != null and game != null and bus != null)
	if lore == null or game == null or bus == null:
		_finish()
		return
	bus.connect(&"note_discovered", func(_id: String) -> void: _discoveries += 1)

	# --- data --------------------------------------------------------------
	var journal: Dictionary = lore.get_script().get_script_constant_map()["JOURNAL"]
	_check("there are five chapters (%d)" % journal.size(), journal.size() == 5)
	var layers := {}
	for id: String in journal:
		var note: Dictionary = journal[id]
		var chapter := int(note.get("chapter", 0))
		var layer := int(note.get("layer", 0))
		_check("%s is chapter %d in layer %d" % [id, chapter, layer],
			chapter >= 1 and chapter <= 5 and layer >= 1 and layer <= 5)
		layers[layer] = true
		_check("%s has a title and a body" % id,
			not str(note.get("title", "")).is_empty() and str(note.get("body", "")).length() > 80)
		_check("%s has a faction clue" % id,
			(lore.get_script().get_script_constant_map()["FACTIONS"] as Dictionary).has(
				str(note.get("faction", ""))
			) and not str(note.get("clue", "")).is_empty())
	_check("one chapter per layer (%d)" % layers.size(), layers.size() == 5)
	for layer: int in [1, 2, 3, 4, 5]:
		var expected := "page_%d" % layer
		_check("layer %d maps to %s" % [layer, expected],
			str(lore.call(&"note_for_layer", layer)) == expected)
	_check("a layer with no chapter maps to nothing",
		str(lore.call(&"note_for_layer", 0)).is_empty()
			and str(lore.call(&"note_for_layer", 6)).is_empty())

	# --- world -------------------------------------------------------------
	var main: Node = load(MAIN_SCENE_PATH).instantiate()
	root.add_child(main)
	await _wait(30)
	var player := get_first_node_in_group(&"player") as Node3D
	_check("a player was spawned", player != null)
	if player == null:
		_finish()
		return
	var town := main.get_node_or_null("World") as Node3D
	var gate := town.get_node_or_null("DescentGate") if town != null else null
	_check("the town has a descent gate", gate != null)
	if gate == null:
		_finish()
		return
	gate.call(&"interact", player)
	await _wait(12)
	var forest := main.get_node_or_null("World") as Node3D
	_check("layer 1 loaded", forest != null and forest.scene_file_path == FOREST_PATH)
	if forest == null:
		_finish()
		return
	var crate := forest.find_child("Crate1", true, false) as Node3D
	_check("the structure has Crate1", crate != null)
	if crate == null:
		_finish()
		return
	var loot: Array = crate.get("loot")
	_check("Crate1 carries the layer's chapter (%s)" % str(loot), loot.has("page_1"))
	_check("no other crate carries the same chapter",
		count_pages(forest, "page_1") == 1)

	# --- loot unlocks the chapter -----------------------------------------
	var inventory := player.get_node_or_null("InventorySystem")
	_check("the player has an inventory", inventory != null)
	if inventory == null:
		_finish()
		return
	player.global_position = crate.global_position + Vector3(1.2, 0.4, 0.0)
	crate.set(&"search_seconds", 0.15)
	await _wait(4)
	crate.call(&"interact", player)
	await _wait_seconds(0.6)
	_check("the crate opens", bool(crate.get("opened")))
	_check("the page is in the satchel (%d)" % int(inventory.call(&"count_item", &"page_1")),
		int(inventory.call(&"count_item", &"page_1")) == 1)
	_check("looting discovers the chapter", bool(game.call(&"has_note", "page_1")))
	_check("the discovery fires once (%d)" % _discoveries, _discoveries == 1)
	inventory.call(&"add_item", &"page_1", 1)
	_check("a duplicate page does not fire again (%d)" % _discoveries, _discoveries == 1)
	# Double-clicking a page must not eat it.
	var slot := _slot_of(inventory, &"page_1")
	_check("double-clicking a page keeps it", bool(inventory.call(&"use_slot", slot))
		and int(inventory.call(&"count_item", &"page_1")) >= 1)

	# --- catalogue ---------------------------------------------------------
	var menu: Node = main.get_node_or_null("PauseMenu")
	_check("Main has the pause menu", menu != null)
	if menu != null:
		menu.call(&"set_section", "journal")
		await process_frame
		var text := str(menu.call(&"get_journal_text"))
		print("journal page:\n", text)
		_check("the catalogue names the found chapter",
			text.contains("Ledger of the First Descent"))
		_check("it shows the faction clue", text.contains("Clue:")
			and text.contains("Verdant Covenant"))
		_check("unfound chapters stay hidden (Chapter 2)",
			text.contains("Chapter 2 - not found") and not text.contains("Field Notes, Second Descent"))

	# --- save round-trip ---------------------------------------------------
	var saves: Node = root.get_node_or_null("SaveSystem")
	_check("SaveSystem exists", saves != null)
	if saves != null:
		var state: Dictionary = saves.call(&"collect_state")
		_check("the save carries the notes block", state.get("notes") is Dictionary
			and (state.get("notes") as Dictionary).has("page_1"))
		(game.get(&"discovered_notes") as Dictionary).clear()
		saves.call(&"apply_state", state)
		_check("the chapter survives a load", bool(game.call(&"has_note", "page_1")))
		saves.call(&"apply_state", {"notes": {"page_1": true, "bogus": true}})
		_check("unknown note ids are ignored",
			bool(game.call(&"has_note", "page_1"))
				and not (game.get(&"discovered_notes") as Dictionary).has("bogus"))
	_finish()


func count_pages(world: Node, page: String) -> int:
	var count := 0
	for crate in world.find_children("Crate*", "", true, false):
		if (crate.get("loot") as Array).has(page):
			count += 1
	return count


func _slot_of(inventory: Node, id: StringName) -> int:
	var slots: Array = inventory.get(&"slots")
	for index in slots.size():
		var slot: Dictionary = slots[index]
		if not slot.is_empty() and StringName(slot.get("id", &"")) == id:
			return index
	return -1


func _wait(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _wait_seconds(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all journal assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
