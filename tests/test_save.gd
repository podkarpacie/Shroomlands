extends SceneTree
## Headless save/load test: a full offline state must survive a JSON round trip,
## while an empty, garbled or older file must never crash the game.
##
## Autoloads are reached through `root.get_node_or_null()` because `--script`
## compiles this file before the autoload identifiers exist. `SHROOMLANDS_SAVE_PATH`
## points `SaveSystem` at a private `user://tests/` file (see tests/test_env.gd),
## so the suite starts with no save and can never touch a developer's progress
## while still exercising the production auto-load and close-save paths.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

const RICH_LEVEL := 7
const RICH_XP := 250
const RICH_HP := 70.0
const RICH_STAMINA := 33.0
const RICH_GOLD := 500
const RICH_POSITION := Vector3(4.0, 1.2, -6.0)

var _failures := 0
var _game: Node = null
var _saves: Node = null
var _player: Node3D = null
var _save_path := ""


func _initialize() -> void:
	TestEnv.isolate("test_save")
	_run()


func _run() -> void:
	_game = root.get_node_or_null("Game")
	_saves = root.get_node_or_null("SaveSystem")
	_check("Game autoload is available", _game != null)
	_check("SaveSystem autoload is available", _saves != null)
	if _game == null or _saves == null:
		_finish()
		return
	_save_path = str(_saves.call(&"get_save_path"))
	_check("the suite writes to its own save path (%s)" % _save_path,
		_save_path.begins_with("user://tests/"))
	_check("the suite starts with no save", not bool(_saves.call(&"has_save")))

	var packed := load(MAIN_SCENE_PATH) as PackedScene
	_check("main.tscn loads", packed != null)
	if packed == null:
		_finish()
		return
	var main := packed.instantiate() as Node3D
	root.add_child(main)
	await _wait_physics(20)
	_player = get_first_node_in_group(&"player") as Node3D
	var stats := _player.get_node_or_null("Stats") if _player != null else null
	var inventory := _player.get_node_or_null("InventorySystem") if _player != null else null
	_check("a player was spawned", _player != null)
	_check("the player has Stats", stats != null)
	_check("the player has an InventorySystem", inventory != null)
	if _player == null or stats == null or inventory == null:
		_finish()
		return

	# --- rich state --------------------------------------------------------
	stats.set("level", RICH_LEVEL)
	stats.set("xp", RICH_XP)
	stats.set("hp", RICH_HP)
	stats.set("stamina", RICH_STAMINA)
	_game.set(&"gold", RICH_GOLD)
	var discoveries: Dictionary = _game.get(&"discovered_mushrooms")
	discoveries.clear()
	for id: String in ["konop", "shitake", "celtus"]:
		discoveries[id] = true
	_game.set(&"chosen_vocation", &"ranger")
	inventory.call(&"add_item", &"konop", 5)
	inventory.call(&"add_item", &"shitake", 12)
	inventory.call(&"add_item", &"bedak", 3)
	var expected_inventory: Dictionary = inventory.call(&"to_dict")
	# Set last: physics would pull a body that is left standing in the air.
	_player.global_position = RICH_POSITION

	_check("save_now() writes the file", bool(_saves.call(&"save_now")))
	_check("has_save() is true after saving", bool(_saves.call(&"has_save")))

	# --- summary + raw JSON ------------------------------------------------
	var summary: Dictionary = _saves.call(&"save_summary")
	_check("save_summary() reports the level (%s)" % summary.get("level", "?"),
		int(summary.get("level", 0)) == RICH_LEVEL)
	_check("save_summary() reports the vocation name (%s)" % summary.get("vocation", "?"),
		str(summary.get("vocation", "")) == "Ranger")
	_check("save_summary() reports the gold (%d)" % int(summary.get("gold", 0)),
		int(summary.get("gold", 0)) == RICH_GOLD)
	_check("save_summary() reports a readable saved_at (%s)" % summary.get("saved_at", "?"),
		not str(summary.get("saved_at", "")).is_empty())

	var parsed := _parse_save_file()
	_check("the save file on disk is valid JSON", not parsed.is_empty())
	_check("the save file carries a version (%s)" % parsed.get("version", "?"),
		int(parsed.get("version", 0)) >= 2)
	_check("the save file carries hp and stamina",
		parsed.has("hp") and parsed.has("stamina"))
	_check("the save file carries the inventory", parsed.get("inventory") is Dictionary)
	_check("the saved position is an Array of 3 numbers",
		parsed.get("position") is Array and (parsed["position"] as Array).size() == 3)

	# --- wipe everything, then load back -----------------------------------
	stats.set("level", 1)
	stats.set("xp", 0)
	stats.set("hp", 100.0)
	stats.set("stamina", 100.0)
	_game.set(&"gold", 0)
	(_game.get(&"discovered_mushrooms") as Dictionary).clear()
	_game.set(&"chosen_vocation", &"")
	inventory.call(&"from_dict", {})
	_player.global_position = Vector3(0.0, 1.2, 0.0)

	_check("load_now() reads the file back", bool(_saves.call(&"load_now")))
	_check("level round-trips (%d)" % int(stats.get("level")), int(stats.get("level")) == RICH_LEVEL)
	_check("xp round-trips (%d)" % int(stats.get("xp")), int(stats.get("xp")) == RICH_XP)
	_check("hp round-trips (%.1f)" % float(stats.get("hp")),
		is_equal_approx(float(stats.get("hp")), RICH_HP))
	_check("stamina round-trips (%.1f)" % float(stats.get("stamina")),
		is_equal_approx(float(stats.get("stamina")), RICH_STAMINA))
	_check("gold round-trips (%d)" % int(_game.get(&"gold")), int(_game.get(&"gold")) == RICH_GOLD)
	_check("vocation round-trips (%s)" % String(_game.get(&"chosen_vocation")),
		StringName(_game.get(&"chosen_vocation")) == &"ranger")
	var loaded_discoveries: Dictionary = _game.get(&"discovered_mushrooms")
	_check("three discoveries round-trip (%d)" % loaded_discoveries.size(),
		loaded_discoveries.size() == 3
			and loaded_discoveries.has("konop")
			and loaded_discoveries.has("shitake")
			and loaded_discoveries.has("celtus"))
	_check("inventory round-trips exactly",
		(inventory.call(&"to_dict") as Dictionary) == expected_inventory)
	_check("the item stacks survive (konop %d, shitake %d, bedak %d)" % [
			int(inventory.call(&"count_item", &"konop")),
			int(inventory.call(&"count_item", &"shitake")),
			int(inventory.call(&"count_item", &"bedak")),
		],
		int(inventory.call(&"count_item", &"konop")) == 5
			and int(inventory.call(&"count_item", &"shitake")) == 12
			and int(inventory.call(&"count_item", &"bedak")) == 3)
	_check("position round-trips exactly (%s)" % _vec(_player.global_position),
		_player.global_position.is_equal_approx(RICH_POSITION))
	_check("the ranger bonus is applied once, not twice (walk %.2f)" % float(_player.get("walk_speed")),
		is_equal_approx(float(_player.get("walk_speed")), 5.3))

	# --- defensive parsing -------------------------------------------------
	var level_before := int(stats.get("level"))
	var gold_before := int(_game.get(&"gold"))
	_saves.call(&"apply_state", {})
	_check("apply_state({}) does not crash", true)
	_check("apply_state({}) leaves the level alone (%d)" % int(stats.get("level")),
		int(stats.get("level")) == level_before)
	_check("apply_state({}) leaves gold alone (%d)" % int(_game.get(&"gold")),
		int(_game.get(&"gold")) == gold_before)

	_saves.call(&"apply_state", {
		"version": "two",
		"level": "twenty",
		"xp": [250],
		"hp": "full",
		"stamina": {},
		"gold": "lots",
		"discovered_mushrooms": 7,
		"vocation": 42,
		"position": "nowhere",
		"inventory": "bad",
		"saved_at": {},
	})
	_check("garbage types do not crash apply_state()", true)
	_check("garbage level keeps the last good value (%d)" % int(stats.get("level")),
		int(stats.get("level")) == level_before)
	_check("garbage gold keeps the last good value (%d)" % int(_game.get(&"gold")),
		int(_game.get(&"gold")) == gold_before)
	_check("garbage vocation keeps the last good value (%s)" % String(_game.get(&"chosen_vocation")),
		StringName(_game.get(&"chosen_vocation")) == &"ranger")
	_check("garbage discoveries keep the last good set (%d)" % loaded_discoveries.size(),
		(_game.get(&"discovered_mushrooms") as Dictionary).size() == 3)
	_check("garbage inventory keeps the last good stacks (%d)" % int(inventory.call(&"count_item", &"konop")),
		int(inventory.call(&"count_item", &"konop")) == 5)
	_check("garbage position keeps the body where it was (%s)" % _vec(_player.global_position),
		_player.global_position.is_equal_approx(RICH_POSITION))

	# --- an older save with no inventory key -------------------------------
	_saves.call(&"apply_state", {
		"version": 1,
		"level": 3,
		"xp": 40,
		"hp": 80.0,
		"stamina": 50.0,
		"gold": 120,
		"discovered_mushrooms": {"konop": true},
		"vocation": "",
		"position": [0.0, 1.2, 0.0],
	})
	_check("an old save without 'inventory' loads", int(stats.get("level")) == 3)
	_check("an old save restores gold (%d)" % int(_game.get(&"gold")), int(_game.get(&"gold")) == 120)
	_check("a missing inventory key keeps the current bag",
		int(inventory.call(&"count_item", &"konop")) == 5)

	# --- a close request saves the session --------------------------------
	# The production path: `Main` registers autosave/close-save unconditionally,
	# and the write lands at the isolated path like any other save.
	_game.set(&"gold", 777)
	stats.set("level", 9)
	main.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	var closed := _parse_save_file()
	_check("WM_CLOSE_REQUEST writes a save (gold %s)" % closed.get("gold", "?"),
		int(closed.get("gold", 0)) == 777)
	_check("the close save carries the live level (%s)" % closed.get("level", "?"),
		int(closed.get("level", 0)) == 9)
	_check("the close save is at the isolated path (%s)" % _save_path,
		FileAccess.file_exists(_save_path))

	# --- delete + a save without a player ----------------------------------
	_check("delete_save() succeeds", bool(_saves.call(&"delete_save")))
	_check("has_save() is false after delete_save()", not bool(_saves.call(&"has_save")))
	_check("save_summary() is empty without a save", (_saves.call(&"save_summary") as Dictionary).is_empty())
	_check("delete_save() is safe to call twice", not bool(_saves.call(&"delete_save")))

	_player.queue_free()
	await _wait_physics(2)
	_check("the player is gone", get_first_node_in_group(&"player") == null)
	_check("save_now() works with no player", bool(_saves.call(&"save_now")))
	var fallback := _parse_save_file()
	_check("the player-less save is valid JSON (%d keys)" % fallback.size(), not fallback.is_empty())
	_check("the player-less save uses level 1 (%s)" % fallback.get("level", "?"),
		int(fallback.get("level", 0)) == 1)
	_check("the player-less save still carries an empty inventory",
		fallback.get("inventory") is Dictionary)
	# A closing window with no body must neither error nor overwrite progress
	# with defaults.
	main.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	_check("quitting with no player does not error", true)
	_check("quitting with no player leaves the file as it was",
		int(_parse_save_file().get("level", 0)) == 1)

	_finish()


func _parse_save_file() -> Dictionary:
	var file := FileAccess.open(_save_path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return {}
	return parsed


func _vec(v: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [v.x, v.y, v.z]


func _wait_physics(frames: int) -> void:
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
		print("PASSED  all save assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
