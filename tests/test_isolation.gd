extends SceneTree
## Headless check of `SaveSystem`'s save-path redirect.
##
## Every suite points `SHROOMLANDS_SAVE_PATH` at a private `user://tests/` file
## (see `tests/test_env.gd`), so this suite proves the redirect actually holds
## for every read/write/delete: the override is used, the developer's default
## `user://player_save.json` is never created or touched, and two overrides hold
## two independent saves.

const TestEnv := preload("res://tests/test_env.gd")
const DEFAULT_PATH := "user://player_save.json"
const FIRST_SUITE := "test_isolation_a"
const SECOND_SUITE := "test_isolation_b"

var _failures := 0
var _saves: Node = null
var _first_path := ""
var _second_path := ""
var _default_existed := false
var _default_text := ""


func _initialize() -> void:
	# This suite only talks to `SaveSystem`; the redirect is what it asserts.
	_run()


func _run() -> void:
	_saves = root.get_node_or_null("SaveSystem")
	_check("SaveSystem autoload is available", _saves != null)
	if _saves == null:
		_finish()
		return
	# Snapshot the developer's file, so "untouched" is provable byte for byte
	# both when it is absent and when a real save is sitting there.
	_default_existed = FileAccess.file_exists(DEFAULT_PATH)
	_default_text = _read(DEFAULT_PATH)

	# --- the override is what SaveSystem uses ------------------------------
	TestEnv.isolate(FIRST_SUITE)
	_first_path = str(_saves.call(&"get_save_path"))
	_check(
		"SHROOMLANDS_SAVE_PATH reaches SaveSystem (%s)" % _first_path,
		_first_path == "%s/%s_save.json" % [TestEnv.SAVE_DIR, FIRST_SUITE]
	)
	_check("the override is not the default path", _first_path != DEFAULT_PATH)
	_check("the override starts with no save", not bool(_saves.call(&"has_save")))

	_check(
		"save_player() writes the override",
		bool(_saves.call(&"save_player", {"level": 12, "gold": 340}))
	)
	_check("the override file exists", FileAccess.file_exists(_first_path))
	_check(
		"the default save is untouched by the write (existed=%s)" % _default_existed,
		FileAccess.file_exists(DEFAULT_PATH) == _default_existed and _read(DEFAULT_PATH) == _default_text
	)
	var loaded: Dictionary = _saves.call(&"load_player")
	_check("load_player() reads the override (level %s)" % loaded.get("level", "?"),
		int(loaded.get("level", 0)) == 12)

	# --- a second override is a second, independent file --------------------
	TestEnv.isolate(SECOND_SUITE)
	_second_path = str(_saves.call(&"get_save_path"))
	_check("a second override is a different file (%s)" % _second_path, _second_path != _first_path)
	_check("the second override starts with no save", not bool(_saves.call(&"has_save")))
	_check(
		"writing the second override succeeds",
		bool(_saves.call(&"save_player", {"level": 3, "gold": 7}))
	)
	_check("the first override is still on disk", FileAccess.file_exists(_first_path))

	TestEnv.redirect(_first_path)
	var first: Dictionary = _saves.call(&"load_player")
	_check("the first override still holds its own level (%s)" % first.get("level", "?"),
		int(first.get("level", 0)) == 12)
	_check("the first override keeps its own gold (%s)" % first.get("gold", "?"),
		int(first.get("gold", 0)) == 340)
	TestEnv.redirect(_second_path)
	var second: Dictionary = _saves.call(&"load_player")
	_check("the second override still holds its own level (%s)" % second.get("level", "?"),
		int(second.get("level", 0)) == 3)
	_check("the second override keeps its own gold (%s)" % second.get("gold", "?"),
		int(second.get("gold", 0)) == 7)

	# --- delete follows the redirect too -----------------------------------
	_check("delete_save() removes the active override", bool(_saves.call(&"delete_save")))
	_check("the second override file is gone", not FileAccess.file_exists(_second_path))
	_check("the first override is still there", FileAccess.file_exists(_first_path))
	TestEnv.redirect(_first_path)
	_check("delete_save() removes the other override", bool(_saves.call(&"delete_save")))
	_check("the first override file is gone", not FileAccess.file_exists(_first_path))

	_check(
		"the default save is untouched after the whole run (existed=%s)" % _default_existed,
		FileAccess.file_exists(DEFAULT_PATH) == _default_existed and _read(DEFAULT_PATH) == _default_text
	)
	_finish()


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all isolation assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
