extends SceneTree
## Single-process structural checks for the multiplayer vitals/inventory/roster
## layer. No socket is opened: the two-process proof lives in
## `tests/run_network_test.ps1`.
##
## Covered here:
##   * `player.tscn` replicates hp/stamina/level/xp through a second
##     `MultiplayerSynchronizer` rooted on `Stats`;
##   * `Main.validate_inventory_payload` accepts a well-formed payload and
##     rejects every malformed shape the client could send;
##   * a rejected payload never becomes a mirror, and an accepted one stays a
##     read-only mirror (the local inventory is untouched);
##   * `Main.get_roster()` returns `{peer_id, name, hp, level, gold}`;
##   * a progression report can only ever write the reporting peer's entry.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const PLAYER_SCENE_PATH := "res://scenes/player/player.tscn"
const VITALS := [".:hp", ".:stamina", ".:level", ".:xp"]
const ROSTER_KEYS := ["peer_id", "name", "hp", "level", "gold"]
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0


func _initialize() -> void:
	# Structural checks only: a private save path and a private plots file, so
	# this suite never reads or writes the developer's profile.
	TestEnv.isolate("test_sync")
	TestEnv.stash("user://plots.json")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	# `--script` compiles this file before autoload identifiers exist, so the
	# singletons are resolved at runtime instead of by name.
	var network := root.get_node_or_null("Network")
	var game := root.get_node_or_null("Game")
	_check("Network autoload is available", network != null)
	_check("Game autoload is available", game != null)
	if network == null or game == null:
		_finish()
		return
	var offline_mode := int(network.get(&"mode"))
	var constants: Dictionary = network.get_script().get_script_constant_map()
	_check("this suite runs OFFLINE", offline_mode == int(constants["OFFLINE"]))

	var packed := load(MAIN_SCENE_PATH) as PackedScene
	_check("main.tscn loads", packed != null)
	if packed == null:
		_finish()
		return
	var main := packed.instantiate()
	root.add_child(main)
	await _wait_physics(10)

	var player := game.call(&"get_local_player") as Node3D
	_check("the local player exists", player != null)
	if player == null:
		_finish()
		return
	var stats := player.get_node_or_null("Stats")
	var inventory := player.get_node_or_null("InventorySystem")
	_check("the local player has Stats", stats != null)
	_check("the local player has an InventorySystem", inventory != null)
	if stats == null or inventory == null:
		_finish()
		return

	_check_vitals_synchronizer(player, stats)
	# `InventorySystem` is a global class but referencing it here would compile
	# its script before the autoloads exist; read the constant off the instance.
	var max_stack := int(inventory.get_script().get_script_constant_map()["MAX_STACK"])
	_check_inventory_payload(main, inventory, max_stack)
	_check_roster(main, network, constants, stats, game)
	_check_roster_sovereignty(main, network, constants)
	_finish()


## --- 1. vitals replication ------------------------------------------------


func _check_vitals_synchronizer(player: Node3D, stats: Node) -> void:
	var synchronizers := player.find_children("*", "MultiplayerSynchronizer", true, false)
	_check("the player holds two synchronizers (%d)" % synchronizers.size(), synchronizers.size() == 2)
	var vitals := stats.get_node_or_null("MultiplayerSynchronizer") as MultiplayerSynchronizer
	_check("Stats carries its own MultiplayerSynchronizer", vitals != null)
	if vitals == null:
		return
	# `root_path` resolves against the synchronizer itself, so `..` from the
	# node under Stats is Stats — the node that owns hp/stamina/level/xp.
	_check("the vitals synchronizer is rooted on Stats (%s)" % vitals.root_path, vitals.root_path == NodePath(".."))
	_check("the vitals synchronizer is publicly visible", vitals.public_visibility)
	var config := vitals.replication_config
	_check("the vitals synchronizer has a replication config", config != null)
	if config != null:
		for property: String in VITALS:
			var path := NodePath(property)
			_check("vitals config covers %s" % property, config.has_property(path))
			_check(
				"vitals config always syncs %s" % property,
				config.property_get_replication_mode(path) == SceneReplicationConfig.REPLICATION_MODE_ALWAYS
			)
			_check("vitals config spawns %s" % property, config.property_get_spawn(path))

	var root_sync := player.get_node_or_null("MultiplayerSynchronizer") as MultiplayerSynchronizer
	_check("the transform synchronizer is unchanged", root_sync != null)
	if root_sync != null and root_sync.replication_config != null:
		var transform_config := root_sync.replication_config
		_check("the transform config still covers position", transform_config.has_property(^".:position"))
		_check("the transform config still covers rotation", transform_config.has_property(^".:rotation"))
		_check("the vitals are not duplicated on the player root", not transform_config.has_property(^".:hp"))


## --- 2. inventory payloads ------------------------------------------------


func _check_inventory_payload(main: Node, inventory: Node, max_stack: int) -> void:
	inventory.call(&"add_item", &"glowcap", 3)
	var good: Array = inventory.call(&"to_sync_payload")
	_check("a payload holds one entry per slot (%d)" % good.size(), good.size() == 48)
	_check("a payload of the owner's own slots is accepted", bool(main.call(&"validate_inventory_payload", good)))
	_check("the payload carries the gathered stack", _count_glowcap(good) == 3)

	_check_rejects(main, good, "a truncated payload", func(payload: Array) -> void: payload.pop_back())
	_check_rejects(main, good, "an oversized payload", func(payload: Array) -> void: payload.append({}))
	_check_rejects(main, good, "a non-dictionary slot", func(payload: Array) -> void: payload[0] = "glowcap")
	_check_rejects(main, good, "a slot with no count", func(payload: Array) -> void: payload[0] = {"id": &"glowcap"})
	_check_rejects(main, good, "an id with no Lore entry", func(payload: Array) -> void: payload[0] = {"id": &"moonrock", "count": 1})
	_check_rejects(main, good, "a non-string id", func(payload: Array) -> void: payload[0] = {"id": 7, "count": 1})
	_check_rejects(main, good, "a negative count", func(payload: Array) -> void: payload[0] = {"id": &"glowcap", "count": -4})
	_check_rejects(main, good, "a non-numeric count", func(payload: Array) -> void: payload[0] = {"id": &"glowcap", "count": "many"})
	_check_rejects(main, good, "a count above MAX_STACK", func(payload: Array) -> void:
		payload[0] = {"id": &"glowcap", "count": max_stack + 1})

	# A rejected payload must leave nothing behind, an accepted one must become
	# a mirror — and neither may touch this peer's own inventory.
	var malformed: Array = good.duplicate(true)
	malformed[0] = {"id": &"moonrock", "count": 3}
	_check(
		"_accept_inventory refuses a malformed payload",
		not bool(main.call(&"_accept_inventory", 2, malformed))
	)
	_check("a refused payload creates no mirror", (main.call(&"get_remote_inventory", 2) as Array).is_empty())
	_check("_accept_inventory stores a valid payload", bool(main.call(&"_accept_inventory", 2, good)))
	var mirror: Array = main.call(&"get_remote_inventory", 2)
	_check("the mirror holds the same slot count (%d)" % mirror.size(), mirror.size() == 48)
	_check("the mirror holds the reported glowcaps", _count_glowcap(mirror) == 3)

	main.call(&"receive_inventory", 9, good)
	_check("a broadcast mirror is stored too", _count_glowcap(main.call(&"get_remote_inventory", 9) as Array) == 3)
	_check(
		"a remote mirror never enters the local inventory",
		int(inventory.call(&"count_item", &"glowcap")) == 3
	)
	_check("an unknown peer has no mirror", (main.call(&"get_remote_inventory", 77) as Array).is_empty())


func _check_rejects(main: Node, good: Array, label: String, mutate: Callable) -> void:
	var payload: Array = good.duplicate(true)
	mutate.call(payload)
	_check("%s is rejected" % label, not bool(main.call(&"validate_inventory_payload", payload)))


func _count_glowcap(payload: Array) -> int:
	var total := 0
	for entry: Variant in payload:
		if entry is Dictionary:
			var slot: Dictionary = entry
			if StringName(slot.get("id", &"")) == &"glowcap":
				total += int(slot.get("count", 0))
	return total


## --- 3. roster ------------------------------------------------------------


func _check_roster(main: Node, _network: Node, _constants: Dictionary, stats: Node, game: Node) -> void:
	var roster: Array = main.call(&"get_roster")
	_check("the offline roster holds exactly the local player (%d)" % roster.size(), roster.size() == 1)
	if roster.is_empty():
		return
	var entry: Dictionary = roster[0]
	for key: String in ROSTER_KEYS:
		_check("the roster entry has '%s'" % key, entry.has(key))
	_check("the roster entry is this peer (%d)" % int(entry.get("peer_id", 0)), int(entry.get("peer_id", 0)) == 1)
	_check(
		"the roster entry names the player (%s)" % String(entry.get("name", "")),
		String(entry.get("name", "")) != ""
	)
	_check(
		"the roster hp is the player's hp (%.1f)" % float(entry.get("hp", 0.0)),
		is_equal_approx(float(entry.get("hp", 0.0)), float(stats.get(&"hp")))
	)
	_check(
		"the roster level is the player's level (%d)" % int(entry.get("level", 0)),
		int(entry.get("level", 0)) == int(stats.get(&"level"))
	)
	_check(
		"the roster gold is the session gold (%d)" % int(entry.get("gold", -1)),
		int(entry.get("gold", -1)) == int(game.get(&"gold"))
	)


## --- 4. progression reports ----------------------------------------------


## The server records a report against the *connection* that sent it, never
## against an id in the payload, so no client can edit somebody else's entry.
func _check_roster_sovereignty(main: Node, network: Node, constants: Dictionary) -> void:
	main.call(&"_merge_progress", 2, 999, ["glowcap", "moonrock", "glowcap"], "knight")
	var reported: Dictionary = main.call(&"get_peer_progress", 2)
	_check("a report records the gold (999)", int(reported.get("gold", -1)) == 999)
	_check(
		"a report drops ids with no Lore entry",
		(reported.get("discovered", []) as Array) == ["glowcap"]
	)
	_check("a report records a known vocation", String(reported.get("vocation", "")) == "knight")

	main.call(&"_merge_progress", 3, -5, [], "not_a_vocation")
	var clamped: Dictionary = main.call(&"get_peer_progress", 3)
	_check("a negative gold report is clamped to 0", int(clamped.get("gold", -1)) == 0)
	_check("an unknown vocation is dropped", String(clamped.get("vocation", "x")) == "")

	# Even with the server mode forced on, a *local* call has no remote sender
	# and must not be able to write another peer's entry.
	var previous := int(network.get(&"mode"))
	network.set(&"mode", int(constants["SERVER"]))
	main.call(&"report_progress", 500, ["emberstem"], "ranger")
	network.set(&"mode", previous)
	var untouched: Dictionary = main.call(&"get_peer_progress", 2)
	_check("a local progression report is ignored", int(untouched.get("gold", -1)) == 999)
	_check("a local report cannot create another entry", (main.call(&"get_peer_progress", 1) as Dictionary).is_empty())

	# Structural half of the same rule: the wire payload has no peer id at all.
	var signature: Array = []
	for entry: Dictionary in main.get_method_list():
		if String(entry.get("name", "")) == "report_progress":
			for arg: Dictionary in entry.get("args", []):
				signature.append(String(arg.get("name", "")))
	_check("report_progress takes no peer id (%s)" % ", ".join(signature), not signature.has("peer_id"))
	_check(
		"report_progress reports the owner's own values only",
		signature.size() == 3 and not signature.has("peer")
	)


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
		print("PASSED  all sync structural assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
