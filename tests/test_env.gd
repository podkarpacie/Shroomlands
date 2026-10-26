extends RefCounted
## Private `user://` state for the headless suites.
##
## `SaveSystem` resolves its file from `SHROOMLANDS_SAVE_PATH`, so `isolate()`
## points every write at a per-suite file under `user://tests/` and deletes a
## leftover first: a run starts with no save and never reads or writes the
## developer's `user://player_save.json`. The save path stays a real path, so
## autosave, Continue and the close-request save all run as in production.
##
## `stash()` covers the other `user://` files a scene reads directly (the plots
## file), and `restore_all()` puts them back exactly as they were found.

const SAVE_DIR := "user://tests"
const SAVE_PATH_ENV := "SHROOMLANDS_SAVE_PATH"

## path -> {"had": bool, "text": String}
static var _stash: Dictionary = {}


## Points `SaveSystem` at `user://tests/<suite>_save.json` and removes it, so
## the suite starts from zero. Call it in `_initialize()`, before the scene
## tree loads `main.tscn` or anything else touches `SaveSystem`.
static func isolate(suite: String) -> void:
	var path := "%s/%s_save.json" % [SAVE_DIR, suite]
	redirect(path)
	remove(path)
	remove(path + ".tmp")


## Points `SaveSystem` at an explicit path without touching the file.
static func redirect(path: String) -> void:
	OS.set_environment(SAVE_PATH_ENV, path)


## Reads one `user://` file into memory and deletes it. Calling this twice for
## the same path keeps the first snapshot, which is always the developer's file.
static func stash(path: String) -> void:
	if _stash.has(path):
		return
	var entry := {"had": false, "text": ""}
	if FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			entry["had"] = true
			entry["text"] = file.get_as_text()
			file.close()
	_stash[path] = entry
	remove(path)


## Removes everything this run wrote and puts every stashed file back exactly
## as it was found, including leaving a previously absent file absent.
static func restore_all() -> void:
	for path: String in _stash:
		remove(path)
		var entry: Dictionary = _stash[path]
		if not bool(entry.get("had", false)):
			continue
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			continue
		file.store_string(str(entry.get("text", "")))
		file.close()
	_stash.clear()


static func remove(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	DirAccess.remove_absolute(path)
