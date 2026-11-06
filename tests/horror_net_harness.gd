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
	var heard := await _wait_until(func() -> bool: return _disturbances > 0, WAIT_STEP)
	var town := await _wait_until(
		func() -> bool: return _world_path() == TOWN_PATH, WAIT_STEP
	)
	var hud := _leader_hud_text()
	var ok := two and leader and forest and heard and town
	print(
		"HORROR_HOST ok=%d players=%d leader=%d forest=%d heard=%d town=%d hud=%s" % [
			1 if ok else 0, _player_count(), int(_party.get(&"leader_id")),
			1 if forest else 0, 1 if heard else 0, 1 if town else 0, hud
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
	# Let the server receive this body's forest spawn before the return request.
	await _wait(40)
	if player != null:
		var voice := player.get_node_or_null("VoiceInput")
		if voice != null:
			voice.call(&"push_voice", 0.9)
	await _wait(20)

	var forest_world := _main.get_node_or_null("World") as Node3D
	var back := forest_world.get_node_or_null("ReturnGate") if forest_world != null else null

	var returned := false
	if back != null:
		back.call(&"interact", player)
		returned = await _wait_until(
			func() -> bool: return _world_path() == TOWN_PATH, WAIT_STEP
		)
	var ok := two and leader and local_leader and lamp_on and forest and returned
	print(
		"HORROR_CLIENT ok=%d players=%d leader=%d local_leader=%d lamp=%d forest=%d town=%d hud=%s" % [
			1 if ok else 0, _player_count(), int(_party.get(&"leader_id")),
			1 if local_leader else 0, 1 if lamp_on else 0,
			1 if forest else 0, 1 if returned else 0, hud
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


func _player_count() -> int:
	var players := _main.get_node_or_null("Players")
	return players.get_child_count() if players != null else 0


func _world_path() -> String:
	var world := _main.get_node_or_null("World") as Node3D
	return world.scene_file_path if world != null else ""


func _on_disturbance(_position: Vector3, _radius: float) -> void:
	_disturbances += 1


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
