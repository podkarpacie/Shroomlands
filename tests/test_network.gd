extends SceneTree
## Single-process structural checks for the networked spawn/sync setup.
##
## This does not open sockets: the two-process proof lives in
## `tests/run_network_test.ps1`. Here we only assert that `main.tscn` has a
## correctly configured MultiplayerSpawner, that the player scene replicates
## position/rotation, and that authority gating keeps a replicated body from
## reading local input or stealing the camera.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const PLAYER_SCENE_PATH := "res://scenes/player/player.tscn"
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0


func _initialize() -> void:
	# Structural run only: a private save and a private plots file, so this
	# suite never reads or writes the developer's profile.
	TestEnv.isolate("test_network")
	TestEnv.stash("user://plots.json")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	# `--script` compiles this file before autoload identifiers exist, so the
	# Network singleton is resolved at runtime instead of by name.
	var network := root.get_node_or_null("Network")
	_check("Network autoload is available", network != null)
	if network == null:
		_finish()
		return
	var constants: Dictionary = network.get_script().get_script_constant_map()
	_check("Network starts OFFLINE", int(network.get(&"mode")) == int(constants["OFFLINE"]))
	_check("Network.local_peer_id is 0 while offline", int(network.get(&"local_peer_id")) == 0)
	_check("Network.is_dedicated is false while offline", not bool(network.get(&"is_dedicated")))
	_check("Network.get_peers() is empty while offline", (network.call(&"get_peers") as Array).is_empty())
	_check("Network exposes a dedicated-server entry point", network.has_method(&"start_dedicated"))

	var packed := load(MAIN_SCENE_PATH) as PackedScene
	_check("main.tscn loads", packed != null)
	if packed == null:
		_finish()
		return
	var main := packed.instantiate()
	root.add_child(main)
	await _wait_physics(5)

	var container := main.get_node_or_null("Players") as Node3D
	_check("Main has a Players Node3D", container != null)
	var spawner := main.get_node_or_null("PlayerSpawner") as MultiplayerSpawner
	_check("Main has a MultiplayerSpawner named PlayerSpawner", spawner != null)
	if spawner != null:
		_check("spawn_path points at Players (%s)" % spawner.spawn_path, spawner.spawn_path == NodePath("../Players"))
		_check("spawn_limit is MAX_PLAYERS (%d)" % spawner.spawn_limit, spawner.spawn_limit == int(constants["MAX_PLAYERS"]))
		_check("spawn_function is wired by Main.gd", spawner.spawn_function.is_valid())
		_check("the spawner still belongs to the server", spawner.get_multiplayer_authority() == 1)
		if spawner.spawn_function.is_valid():
			var made := spawner.spawn_function.call(7) as Node3D
			_check("spawn_function returns a player", made != null)
			if made != null:
				_check("spawn_function names the node after the peer (%s)" % made.name, made.name == "7")
				_check("spawn_function assigns peer authority", made.get_multiplayer_authority() == 7)
				var spawn := main.find_child("PlayerSpawn", true, false) as Node3D
				var expected := Vector3.ZERO
				if spawn != null and container != null:
					expected = container.to_local(spawn.global_position)
				_check(
					"spawn_function places the player on the spawn marker",
					spawn != null and made.position.distance_to(expected) < 0.01
				)
				made.free()

	var players := get_nodes_in_group(&"player")
	_check("OFFLINE still spawns exactly one player", players.size() == 1)
	if players.is_empty():
		_finish()
		return
	var player := players[0] as Node3D
	_check("the OFFLINE player is still Main/Player", main.get_node_or_null("Player") == player)
	_check("the OFFLINE player is not routed through the spawner", container != null and not container.has_node("Player"))

	# --- Game.get_local_player() -------------------------------------------
	# A client also receives the host's body in the same group, so the lookup
	# must prefer the authoritative body over "first node in the group".
	var game := root.get_node_or_null("Game")
	_check("Game autoload is available", game != null)
	if game != null:
		_check("get_local_player() returns the offline player", game.call(&"get_local_player") == player)
		var replica_packed := load(PLAYER_SCENE_PATH) as PackedScene
		var replica := replica_packed.instantiate() as Node3D
		replica.name = "2"
		replica.set_multiplayer_authority(2)
		# Put the replicated body first in the tree (and therefore first in the
		# group) so a "first node wins" lookup would now return it instead.
		main.add_child(replica)
		main.move_child(replica, 0)
		await _wait_physics(1)
		var grouped := get_nodes_in_group(&"player")
		var order := PackedStringArray()
		for node: Node in grouped:
			order.append(String(node.name))
		_check(
			"the group holds the local and a replicated body (%d: %s)" % [grouped.size(), ", ".join(order)],
			grouped.size() == 2
		)
		_check(
			"the replicated body is first in the group (%s)" % ", ".join(order),
			grouped.size() == 2 and grouped[0] == replica
		)
		_check(
			"get_local_player() still returns the authoritative body",
			game.call(&"get_local_player") == player
		)
		replica.queue_free()
		await _wait_physics(2)
		_check("get_local_player() survives the replica leaving", game.call(&"get_local_player") == player)

	var local_camera := player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
	_check("the OFFLINE player has a Camera3D", local_camera != null)

	var synchronizer := player.get_node_or_null("MultiplayerSynchronizer") as MultiplayerSynchronizer
	_check("the player has a MultiplayerSynchronizer", synchronizer != null)
	if synchronizer != null:
		_check("synchronizer root_path is the player (%s)" % synchronizer.root_path, synchronizer.root_path == NodePath(".."))
		_check("synchronizer is publicly visible", synchronizer.public_visibility)
		var config := synchronizer.replication_config
		_check("synchronizer has a replication config", config != null)
		if config != null:
			for property: NodePath in [^".:position", ^".:rotation"]:
				_check("config covers %s" % property, config.has_property(property))
				_check(
					"config always syncs %s" % property,
					config.property_get_replication_mode(property) == SceneReplicationConfig.REPLICATION_MODE_ALWAYS
				)
				_check("config spawns %s" % property, config.property_get_spawn(property))

	# A replicated copy must not run local input or own the camera. Unique id is
	# 1 offline, so authority over 2 makes this node a stand-in for a peer.
	var remote_packed := load(PLAYER_SCENE_PATH) as PackedScene
	var remote := remote_packed.instantiate() as Node3D
	remote.name = "remote_player_probe"
	remote.set_multiplayer_authority(2)
	var holder := Node3D.new()
	root.add_child(holder)
	holder.add_child(remote)
	await _wait_physics(2)
	var remote_camera := remote.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
	_check("a replicated player has a Camera3D", remote_camera != null)
	if remote_camera != null:
		_check("a replicated player's camera is not current", not remote_camera.current)
	if local_camera != null:
		_check("the local player's camera stays current", local_camera.current)

	var before := remote.global_position
	Input.action_press(&"move_forward")
	await _wait_physics(10)
	Input.action_release(&"move_forward")
	_check(
		"a replicated player ignores local movement input (moved %.3f m)" % remote.global_position.distance_to(before),
		remote.global_position.distance_to(before) < 0.01
	)

	holder.queue_free()
	await _wait_physics(2)
	_finish()


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
	Input.action_release(&"move_forward")
	if _failures == 0:
		print("PASSED  all network structural assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
