extends SceneTree
## Two-process proof for the multiplayer horror run.
##
## Host: headless server with a local body. Client: separate process. The host
## makes peer 2 the leader, the client walks the town DescentGate into the
## forest, its lamp/voice must reach the server as disturbances, and then it
## returns through the leader-gated gate. Both peers must build the same forest
## and end back in town.
##
## Run through `tests/run_horror_net_test.sh`; the raw invocation is:
##   godot4 --headless --path . --script res://tests/horror_net_harness.gd -- --horror-host
##   godot4 --headless --path . --script res://tests/horror_net_harness.gd -- --horror-join=127.0.0.1
##
## Prints exactly one HORROR_HOST / HORROR_CLIENT result line and exits 0 only
## when every check passed.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const FOREST_PATH := "res://scenes/world/layered_forest.tscn"
const TOWN_PATH := "res://scenes/world/town.tscn"
const PORT := 7788
const WAIT_PLAYERS := 12.0
const WAIT_STEP := 10.0

var _mode := ""
var _join_ip := ""
var _port := PORT
var _main: Node = null
var _network: Node = null
var _party: Node = null
var _bus: Node = null
var _game: Node = null
var _disturbances := 0
var _max_radius := 0.0


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	_network = root.get_node_or_null("Network")
	_party = root.get_node_or_null("Party")
	_bus = root.get_node_or_null("EventBus")
	_game = root.get_node_or_null("Game")
	if _network == null or _party == null or _bus == null or _game == null:
		print("HORROR_FAIL reason=autoloads")
		quit(1)
		return
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--horror-host":
			_mode = "HOST"
		elif arg.begins_with("--horror-join="):
			_join_ip = arg.trim_prefix("--horror-join=")
		elif arg.begins_with("--horror-port="):
			_port = int(arg.trim_prefix("--horror-port="))
	if _mode.is_empty():
		_mode = "CLIENT" if not _join_ip.is_empty() else ""
	if _mode.is_empty():
		print("HORROR_FAIL reason=mode")
		quit(1)
		return

	var error := OK
	if _mode == "HOST":
		error = int(_network.call(&"host", _port, "enet"))
	else:
		error = int(_network.call(&"join", _join_ip, _port, "enet"))
	if error != OK:
		print("HORROR_FAIL reason=network error=%d" % error)
		quit(1)
		return

	var packed := load(MAIN_SCENE_PATH) as PackedScene
	if packed == null:
		print("HORROR_FAIL reason=main_scene")
		quit(1)
		return
	_main = packed.instantiate()
	root.add_child(_main)
	_bus.connect(&"disturbance_emitted", _on_disturbance)
	await _wait(20)

	if _mode == "HOST":
		await _host()
	else:
		await _client()


func _host() -> void:
	var two := await _wait_until(func() -> bool: return _player_count() >= 2, WAIT_PLAYERS)
	var client_id := _other_peer()
	_party.call(&"set_leader", client_id)
	var leader := await _wait_until(
		func() -> bool: return int(_party.get(&"leader_id")) == client_id, 4.0
	)
	# The client triggers the descent; the server must swap and broadcast.
	var forest := await _wait_until(
		func() -> bool: return _world_path() == FOREST_PATH, WAIT_STEP
	)
	# The client searches Crate1; the server owns the open state and the loot.
	var crate := await _wait_until(
		func() -> bool:
			var world := _main.get_node_or_null("World")
			var node := world.find_child("Crate1", true, false) if world != null else null
			return node != null and bool(node.get(&"opened")),
		WAIT_STEP
	)
	var world := _main.get_node_or_null("World")
	if world != null and (world as Node3D).scene_file_path == FOREST_PATH:
		world.call(&"expire_run")
	var blight := await _wait_until(
		func() -> bool:
			var current := _main.get_node_or_null("World")
			return current != null and current.find_child("Blight", true, false) != null,
		WAIT_STEP
	)
	# The client (leader) passes the lamp to the host, then the host passes it
	# back; both are real RPCs validated by the server.
	var host_id := int(_network.get(&"local_peer_id"))
	var handoff := await _wait_until(
		func() -> bool: return int(_party.get(&"leader_id")) == host_id, 8.0
	)
	var back := false
	if handoff:
		var host_player := _game.call(&"get_local_player") as Node3D
		if host_player != null:
			_party.call(&"pass_to_nearest", host_player, 100.0)
			back = await _wait_until(
				func() -> bool: return int(_party.get(&"leader_id")) == client_id, 8.0
			)
	# A 22 m shout proves the client's voice reached the server; the crate's own
	# noise is only 14 m.
	var heard := await _wait_until(func() -> bool: return _max_radius >= 20.0, WAIT_STEP)
	var town := await _wait_until(
		func() -> bool: return _world_path() == TOWN_PATH, WAIT_STEP
	)
	var hud := _leader_hud_text()
	var ok := two and leader and forest and crate and blight and handoff and back and heard and town
	print(
		"HORROR_HOST ok=%d players=%d leader=%d forest=%d crate=%d blight=%d handoff=%d back=%d heard=%d max=%.0f town=%d hud=%s" % [
			1 if ok else 0, _player_count(), int(_party.get(&"leader_id")),
			1 if forest else 0, 1 if crate else 0, 1 if blight else 0,
			1 if handoff else 0, 1 if back else 0,
			1 if heard else 0, _max_radius, 1 if town else 0, hud
		]
	)
	quit(0 if ok else 1)


func _client() -> void:
	var two := await _wait_until(func() -> bool: return _player_count() >= 2, WAIT_PLAYERS)
	var me := int(_network.get(&"local_peer_id"))
	# Replicated leadership: the host made this peer the leader.
	var leader := await _wait_until(
		func() -> bool: return int(_party.get(&"leader_id")) == me, WAIT_PLAYERS
	)
	var player := _game.call(&"get_local_player") as Node3D
	var local_leader := player != null and bool(_party.call(&"is_leader", player))
	var lamp_on := false
	if player != null:
		var lamp := player.get_node_or_null("SporeLamp")
		if lamp != null:
			lamp.call(&"toggle")
			lamp_on = bool(lamp.call(&"is_on"))
	var hud := _leader_hud_text()

	var town_world := _main.get_node_or_null("World") as Node3D
	var gate := town_world.get_node_or_null("DescentGate") if town_world != null else null
	if gate == null:
		print("HORROR_FAIL reason=descent_gate")
		quit(1)
		return
	gate.call(&"interact", player)
	var forest := await _wait_until(
		func() -> bool: return _world_path() == FOREST_PATH, WAIT_STEP
	)
	# Let the server receive this body's forest spawn before the search.
	await _wait(40)

	# Search Crate1: the server validates proximity, pays the loot to this owner
	# and broadcasts the opened state.
	var crate_opened := false
	var loot_received := false
	var forest_world := _main.get_node_or_null("World") as Node3D
	var crate := forest_world.find_child("Crate1", true, false) if forest_world != null else null
	if crate != null and player != null:
		var crate_3d := crate as Node3D
		player.global_position = crate_3d.global_position + Vector3(1.5, 1.2, 0.0)
		await _wait(40)
		crate.call(&"interact", player)
		await _wait(110)
		crate_opened = bool(crate.get(&"opened"))
		loot_received = _inventory_total(player) > 0

	if player != null:
		var voice := player.get_node_or_null("VoiceInput")
		if voice != null:
			voice.call(&"push_voice", 0.9)
	await _wait(20)

	var blight := await _wait_until(
		func() -> bool:
			var current := _main.get_node_or_null("World")
			return current != null and current.find_child("Blight", true, false) != null,
		WAIT_STEP
	)

	# Hand the lamp to the host, then wait for the host to hand it back.
	var host_id := _other_peer()
	var handoff := false
	if player != null:
		handoff = int(_party.call(&"pass_to_nearest", player, 100.0)) == host_id
	var lamp_back := await _wait_until(
		func() -> bool: return int(_party.get(&"leader_id")) == me, 10.0
	)

	forest_world = _main.get_node_or_null("World") as Node3D
	var back := forest_world.get_node_or_null("ReturnGate") if forest_world != null else null
	var returned := false
	if back != null and player != null:
		# Stand at the gate so the leader rule passes on both peers.
		player.global_position = (back as Node3D).global_position + Vector3(0.0, 1.2, -3.0)
		await _wait(30)
		back.call(&"interact", player)
		returned = await _wait_until(
			func() -> bool: return _world_path() == TOWN_PATH, WAIT_STEP
		)
	var ok := two and leader and local_leader and lamp_on and forest \
		and crate_opened and loot_received and blight and handoff and lamp_back and returned
	print(
		"HORROR_CLIENT ok=%d players=%d leader=%d local_leader=%d lamp=%d forest=%d crate=%d loot=%d blight=%d handoff=%d back=%d town=%d hud=%s" % [
			1 if ok else 0, _player_count(), int(_party.get(&"leader_id")),
			1 if local_leader else 0, 1 if lamp_on else 0,
			1 if forest else 0, 1 if crate_opened else 0,
			1 if loot_received else 0, 1 if blight else 0,
			1 if handoff else 0, 1 if lamp_back else 0,
			1 if returned else 0, hud
		]
	)
	quit(0 if ok else 1)


func _leader_hud_text() -> String:
	var label := _main.get_node_or_null("HUD/Root/Progression/LeaderLabel") as Label
	return label.text if label != null else "missing"


func _other_peer() -> int:
	var me := int(_network.get(&"local_peer_id"))
	var peers: Array = _network.call(&"get_peers")
	for peer_id: int in peers:
		if peer_id != me:
			return peer_id
	return 0


func _inventory_total(player: Node) -> int:
	var inventory := player.get_node_or_null("InventorySystem")
	if inventory == null:
		return 0
	var total := 0
	for slot: Dictionary in inventory.get(&"slots"):
		total += int(slot.get("count", 0))
	return total


func _player_count() -> int:
	var players := _main.get_node_or_null("Players")
	return players.get_child_count() if players != null else 0


func _world_path() -> String:
	var world := _main.get_node_or_null("World") as Node3D
	return world.scene_file_path if world != null else ""


func _on_disturbance(_position: Vector3, radius: float) -> void:
	_disturbances += 1
	_max_radius = maxf(_max_radius, radius)


func _wait(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _wait_until(predicate: Callable, seconds: float) -> bool:
	var frames := int(seconds * 60.0)
	for _frame in frames:
		await physics_frame
		if bool(predicate.call()):
			return true
	return false
