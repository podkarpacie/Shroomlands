extends Node
## Local player save: a single JSON file in `user://` (IndexedDB on web).
## Writes go through a `.tmp` file so a crash mid-save cannot truncate the
## previous save.
##
## The file is `SAVE_PATH` unless `SHROOMLANDS_SAVE_PATH` (environment) or
## `--save-path=<path>` (command line) points somewhere else. The headless
## suites use that to read and write a private file; production never sets it.

const SAVE_PATH := "user://player_save.json"
## Redirects every read/write/delete; see "Tests" in README.md.
const SAVE_PATH_ENV := "SHROOMLANDS_SAVE_PATH"
const SAVE_PATH_FLAG := "--save-path="
## Bumped whenever a key changes shape. Readers stay compatible with older
## files (an old save simply has fewer keys, see `apply_state`).
const SAVE_VERSION := 2


## The file this process reads and writes. Resolved per call, so a suite that
## points the variable somewhere private first is always honoured.
func get_save_path() -> String:
	var override := OS.get_environment(SAVE_PATH_ENV).strip_edges()
	if not override.is_empty():
		return override
	override = _path_flag(OS.get_cmdline_user_args())
	if override.is_empty():
		override = _path_flag(OS.get_cmdline_args())
	return override if not override.is_empty() else SAVE_PATH


func save_player(data: Dictionary) -> bool:
	var path := get_save_path()
	var tmp_path := path + ".tmp"
	if not _ensure_dir(path):
		return false
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_error("SaveSystem: cannot write %s (%s)" % [tmp_path, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()

	var dir := DirAccess.open(path.get_base_dir())
	if dir == null:
		push_error("SaveSystem: cannot open %s (%s)" % [path.get_base_dir(), error_string(DirAccess.get_open_error())])
		return false
	var err := dir.rename(tmp_path.get_file(), path.get_file())
	if err != OK and dir.file_exists(path.get_file()):
		# Some platforms refuse to rename over an existing file.
		dir.remove(path.get_file())
		err = dir.rename(tmp_path.get_file(), path.get_file())
	if err != OK:
		push_error("SaveSystem: cannot replace %s (%s)" % [path, error_string(err)])
		dir.remove(tmp_path.get_file())
		return false
	print("SaveSystem: saved %d keys to %s" % [data.size(), path])
	return true


func load_player() -> Dictionary:
	var path := get_save_path()
	if not has_save():
		print("SaveSystem: no save at %s" % path)
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		print("SaveSystem: cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		print("SaveSystem: ignoring corrupt save at %s" % path)
		return {}
	var data: Dictionary = parsed
	print("SaveSystem: loaded %d keys from %s" % [data.size(), path])
	return data


func has_save() -> bool:
	return FileAccess.file_exists(get_save_path())


func delete_save() -> bool:
	var path := get_save_path()
	if not has_save():
		return false
	var dir := DirAccess.open(path.get_base_dir())
	if dir == null:
		return false
	var err := dir.remove(path.get_file())
	if err != OK:
		push_error("SaveSystem: cannot delete %s (%s)" % [path, error_string(err)])
		return false
	print("SaveSystem: deleted %s" % path)
	return true


## Snapshot of the session and the local player's stats, ready for JSON. A save
## is always writable — quitting before the player exists must not error — so
## missing pieces keep their defaults.
func collect_state() -> Dictionary:
	var state := {
		"version": SAVE_VERSION,
		"level": 1,
		"xp": 0,
		"hp": 100.0,
		"stamina": 100.0,
		"gold": Game.gold,
		"discovered_mushrooms": Game.discovered_mushrooms.duplicate(),
		"vocation": String(Game.chosen_vocation),
		"position": [0.0, 0.0, 0.0],
		"inventory": {},
		"saved_at": _timestamp(),
	}
	var player := Game.get_local_player()
	if player == null:
		return state
	var stats := _stats_of(player)
	if stats != null:
		state["level"] = _as_int(stats.get("level"), 1)
		state["xp"] = _as_int(stats.get("xp"), 0)
		state["hp"] = _as_float(stats.get("hp"), 100.0)
		state["stamina"] = _as_float(stats.get("stamina"), 100.0)
	if player is Node3D:
		var position := (player as Node3D).global_position
		state["position"] = [position.x, position.y, position.z]
	var inventory := player.get_node_or_null("InventorySystem")
	if inventory != null and inventory.has_method(&"to_dict"):
		state["inventory"] = inventory.call(&"to_dict")
	return state


## Restores a snapshot. Unknown ids, wrong types and an older save without an
## `inventory` key are ignored, never fatal.
func apply_state(data: Dictionary) -> void:
	if data.is_empty():
		return

	Game.gold = maxi(_as_int(data.get("gold"), Game.gold), 0)
	EventBus.gold_changed.emit(Game.gold)

	var discovered: Variant = data.get("discovered_mushrooms")
	if discovered is Dictionary:
		Game.discovered_mushrooms = (discovered as Dictionary).duplicate()
	elif discovered is Array:
		Game.discovered_mushrooms.clear()
		for id: Variant in discovered:
			if id is String:
				Game.discovered_mushrooms[id] = true

	# Only a String is a vocation reference; anything else leaves the current
	# choice alone rather than wiping it.
	var vocation_value: Variant = data.get("vocation")
	if vocation_value is String:
		var vocation := vocation_value as String
		if vocation.is_empty():
			Game.chosen_vocation = &""
		elif Lore.VOCATIONS.has(vocation):
			Game.chosen_vocation = StringName(vocation)

	var player := Game.get_local_player()
	if player == null:
		return
	var stats := _stats_of(player)
	# The bonus runs before the saved vitals, so a loaded save keeps its own HP
	# instead of the knight's heal-to-full.
	if stats != null and Game.chosen_vocation != &"" and stats.has_method(&"apply_vocation_bonus"):
		stats.call(&"apply_vocation_bonus", String(Game.chosen_vocation))
	if stats != null:
		_restore_stats(stats, data)
	elif "level" in player:
		player.set("level", _as_int(data.get("level"), int(player.get("level"))))
		if "xp" in player:
			player.set("xp", _as_int(data.get("xp"), int(player.get("xp"))))
	if player is Node3D:
		var fallback := (player as Node3D).global_position
		(player as Node3D).global_position = _as_vector3(data.get("position"), fallback)
	var saved_inventory: Variant = data.get("inventory")
	if saved_inventory is Dictionary:
		var inventory := player.get_node_or_null("InventorySystem")
		if inventory != null and inventory.has_method(&"from_dict"):
			inventory.call(&"from_dict", saved_inventory)


## Digest for the lobby's Continue button; empty when there is no readable save.
func save_summary() -> Dictionary:
	var data := load_player()
	if data.is_empty():
		return {}
	var vocation_id := _as_string(data.get("vocation"), "")
	var vocation_name := ""
	if not vocation_id.is_empty() and Lore.VOCATIONS.has(vocation_id):
		vocation_name = str((Lore.VOCATIONS[vocation_id] as Dictionary).get("name", vocation_id))
	return {
		"level": clampi(_as_int(data.get("level"), 1), 1, Game.MAX_LEVEL),
		"vocation": vocation_name,
		"gold": maxi(_as_int(data.get("gold"), 0), 0),
		"saved_at": _readable_time(data.get("saved_at")),
	}


func save_now() -> bool:
	return save_player(collect_state())


func load_now() -> bool:
	var data := load_player()
	if data.is_empty():
		return false
	apply_state(data)
	return true


## First `<flag><path>` argument with a non-empty path, or "".
func _path_flag(args: PackedStringArray) -> String:
	for arg: String in args:
		if arg.begins_with(SAVE_PATH_FLAG):
			var path := arg.trim_prefix(SAVE_PATH_FLAG).strip_edges()
			if not path.is_empty():
				return path
	return ""


## A redirected path may name a directory that does not exist yet (`user://tests`
## on a clean profile); create it before the `.tmp` file is opened.
func _ensure_dir(path: String) -> bool:
	var dir_path := path.get_base_dir()
	if dir_path.is_empty() or DirAccess.dir_exists_absolute(dir_path):
		return true
	var err := DirAccess.make_dir_recursive_absolute(dir_path)
	if err != OK:
		push_error("SaveSystem: cannot create %s (%s)" % [dir_path, error_string(err)])
		return false
	return true


## Level/XP/HP/stamina live on the player's Stats child, not on the body.
func _stats_of(player: Node) -> Node:
	var stats := player.get_node_or_null("Stats")
	if stats == null or not ("hp" in stats):
		return null
	return stats


func _restore_stats(stats: Node, data: Dictionary) -> void:
	var level := clampi(_as_int(data.get("level"), int(stats.get("level"))), 1, Game.MAX_LEVEL)
	var xp := maxi(_as_int(data.get("xp"), int(stats.get("xp"))), 0)
	var hp_max := maxf(float(stats.get("max_hp")), 1.0)
	var stamina_max := maxf(float(stats.get("max_stamina")), 1.0)
	var hp := clampf(_as_float(data.get("hp"), float(stats.get("hp"))), 0.0, hp_max)
	var stamina := clampf(_as_float(data.get("stamina"), float(stats.get("stamina"))), 0.0, stamina_max)
	var level_moved := int(stats.get("level")) != level
	stats.set("level", level)
	stats.set("xp", xp)
	stats.set("hp", hp)
	stats.set("stamina", stamina)
	if level_moved:
		# Also the moment the HUD and the vocation modal learn about a loaded
		# level, since nothing else announces it.
		EventBus.level_changed.emit(level)
	EventBus.hp_changed.emit(hp, hp_max)
	EventBus.stamina_changed.emit(stamina, stamina_max)
	EventBus.xp_changed.emit(xp, Game.xp_to_level(level))


func _timestamp() -> String:
	return Time.get_datetime_string_from_system(false, true).replace("T", " ")


## Old saves stored a unix timestamp instead of the readable form.
func _readable_time(value: Variant) -> String:
	if value is String and not (value as String).is_empty():
		return value as String
	if value is int or value is float:
		var seconds := int(value)
		if seconds > 0:
			return Time.get_datetime_string_from_unix_time(seconds, true).replace("T", " ")
	return ""


func _as_int(value: Variant, fallback: int) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	return fallback


func _as_float(value: Variant, fallback: float) -> float:
	if value is float or value is int:
		return float(value)
	return fallback


func _as_string(value: Variant, fallback: String) -> String:
	if value is String:
		return value
	return fallback


func _as_vector3(value: Variant, fallback: Vector3) -> Vector3:
	if value is Vector3:
		return value
	if value is Array:
		var coords: Array = value
		if coords.size() == 3:
			var ok := true
			for coord: Variant in coords:
				if not (coord is int or coord is float):
					ok = false
					break
			if ok:
				return Vector3(float(coords[0]), float(coords[1]), float(coords[2]))
	return fallback
