extends SceneTree
## Two-process multiplayer smoke test. Run one process with `--net-host` and another
## with `--net-join=127.0.0.1`; both load `main.tscn`, print a NET status line
## every second and a final NET_RESULT line. The client walks forward for one
## second so the server must receive a non-spawn position for its peer, then it
## steps next to a creature (the server's AI bites), adds three glowcaps through
## the real `InventorySystem`, and reports its HP/level/gold to the server.
##
## `--net-transport=enet|websocket` (default: one chosen by `Network`) selects
## the transport, `--net-port=N` (default 7777) the port. One server instance
## serves one transport; a desktop client can dial a websocket server by asking
## for it explicitly. `--net-observe` joins without playing, and
## `--net-expect-players=N` makes `--net-dedicated` wait for N remote bodies.
##
## The scene is loaded lazily (not preloaded) because the autoload identifiers
## used by Main.gd only exist after the `--script` main loop starts.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const PORT := 7777
const RUN_SECONDS := 12.0
const WALK_FRAMES := 60
const TICK_HZ := 60
## `Main.ENEMY_SPAWNS` places four creatures on the server; both peers must see
## all of them, otherwise a spawn or its replication is broken.
const MIN_ENEMIES := 4
## The client sends this once its body has spawned; the host must log receiving
## it, which is the networked chat proof `run_network_test.ps1` greps for.
const CHAT_TEXT := "hello from client"
## Items the client gathers after the walk; the host must log `INV_RECV` with
## this many glowcaps, which proves the inventory reached the server.
const LOOT_ID := &"glowcap"
const LOOT_COUNT := 3
## Frames to wait after the walk before stepping into a creature's reach, so the
## replicated position has settled before the server's AI looks at it.
const PROVOKE_DELAY := 10
## How far from the creature's origin the client stands while it is bitten.
const PROVOKE_OFFSET := Vector3(1.1, 0.0, 0.0)
## After the first bite the client steps this far away, past `aggro_range`, so it
## cannot die (and respawn back to full HP) before the run ends.
const RETREAT_DISTANCE := 16.0
## How far the passive `--net-observe` client steps aside, so it does not block
## the playing client's spawn marker.
const OBSERVE_STEP := Vector3(3.0, 0.0, 0.0)

var _mode := ""
var _join_ip := ""
var _port := PORT
var _transport := "auto"
var _expect_players := 0
var _main: Node = null
var _network: Node = null
var _server_mode := 1
var _client_mode := 2
var _local_player: Node3D = null
var _walk_from := Vector3.ZERO
var _walk_started := false
var _walk_proved := false
var _peak_players := 0
var _ever_walked := false
var _last_positions := ""
var _chat_sent := false
var _chat_received: Array[String] = []
## JOIN only: HP when the walk ended, and whether the first bite was reported.
var _hp_start := -1.0
var _hp_drop_reported := false
var _inventory_sent := false
var _provoke_frame := 0
## OBSERVE only: set once the body has been stepped off the spawn marker.
var _observed_stand := false


func _initialize() -> void:
	_run()


func _run() -> void:
	# `--script` compiles this file before autoload identifiers exist, and the
	# autoload nodes only enter the tree after the first frame; wait for them
	# before Network touches `multiplayer`.
	await process_frame
	_network = root.get_node_or_null("Network")
	if _network == null:
		print("NET_RESULT FAILED reason=network_autoload_missing")
		quit(1)
		return
	var constants: Dictionary = _network.get_script().get_script_constant_map()
	_server_mode = int(constants["SERVER"])
	_client_mode = int(constants["CLIENT"])
	var bus := root.get_node_or_null("EventBus")
	if bus != null:
		bus.connect(&"chat_message_received", _on_chat_message_received)
	if not _parse_args():
		quit(1)
		return
	if not _start_network():
		quit(1)
		return

	var packed := load(MAIN_SCENE_PATH) as PackedScene
	if packed == null:
		print("NET_RESULT FAILED reason=main_scene_missing")
		quit(1)
		return
	_main = packed.instantiate()
	root.add_child(_main)

	var walk_state := 0  # 0 = waiting for our player, 1 = walking, 2 = provoking.
	var walk_frames := 0
	var total_frames := int(RUN_SECONDS * TICK_HZ)
	for frame in total_frames:
		await physics_frame
		if _mode == "JOIN":
			match walk_state:
				0:
					_local_player = _find_local_player()
					if _local_player != null:
						_walk_from = _local_player.global_position
						_hp_start = _player_hp()
						Input.action_press(&"move_forward")
						walk_state = 1
						_walk_started = true
				1:
					walk_frames += 1
					if walk_frames >= WALK_FRAMES:
						Input.action_release(&"move_forward")
						_walk_proved = _walked_away()
						_send_chat()
						_send_loot()
						walk_state = 2
						_provoke_frame = 0
				2:
					_provoke_frame += 1
					if _provoke_frame == PROVOKE_DELAY:
						_provoke_enemy()
					_track_hp()
		elif _mode == "OBSERVE":
			_step_observe_aside()
		if (frame + 1) % TICK_HZ == 0:
			_print_status()

	Input.action_release(&"move_forward")
	_finish()


func _parse_args() -> bool:
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--net-host":
			_mode = "HOST"
		elif arg == "--net-dedicated":
			_mode = "DEDICATED"
		elif arg == "--net-observe":
			_mode = "OBSERVE"
		elif arg.begins_with("--net-join="):
			# The address flag does not pick the role: `--net-observe` may come
			# after it on the command line.
			_join_ip = arg.trim_prefix("--net-join=")
		elif arg.begins_with("--net-port="):
			_port = int(arg.trim_prefix("--net-port="))
		elif arg.begins_with("--net-transport="):
			_transport = arg.trim_prefix("--net-transport=").strip_edges().to_lower()
		elif arg.begins_with("--net-expect-players="):
			_expect_players = int(arg.trim_prefix("--net-expect-players="))
	if _mode.is_empty() and not _join_ip.is_empty():
		_mode = "JOIN"
	if _mode.is_empty():
		print("NET_RESULT FAILED reason=missing_mode")
		return false
	if _mode == "JOIN" and _join_ip.is_empty():
		print("NET_RESULT FAILED reason=missing_join_ip")
		return false
	if _port < 1 or _port > 65535:
		print("NET_RESULT FAILED reason=bad_port port=%d" % _port)
		return false
	return true


func _start_network() -> bool:
	var error := OK
	match _mode:
		"HOST":
			error = int(_network.call(&"host", _port, _transport))
		"JOIN", "OBSERVE":
			error = int(_network.call(&"join", _join_ip, _port, _transport))
		"DEDICATED":
			error = int(_network.call(&"start_dedicated", _port, _transport))
	if error != OK:
		print("NET_RESULT FAILED reason=network_start error=%d" % error)
		return false
	var expected_mode := _client_mode if _mode in ["JOIN", "OBSERVE"] else _server_mode
	if int(_network.get(&"mode")) != expected_mode:
		print("NET_RESULT FAILED reason=network_mode mode=%d" % int(_network.get(&"mode")))
		return false
	print("NET_TRANSPORT=%s port=%d mode=%s" % [
		String(_network.get(&"transport")), _port, _mode
	])
	return true


func _finish() -> void:
	var players := _player_nodes()
	var enemies := _enemy_nodes().size()
	var positions := _positions_string(players)
	var roster := _roster_string()
	if positions.is_empty():
		positions = _last_positions
	print("CHAT_RESULT sent=%d received=%d" % [1 if _chat_sent else 0, _chat_received.size()])
	# The client's selected slot holds the loot it just gathered, so the host's
	# line proves the replicated `held_item` reached the other peer.
	print("HELD_ITEMS %s" % _held_string(players))
	if _mode == "DEDICATED":
		# Boot check by default; with `--net-expect-players=N` it waits for the
		# clients and proves the server spawned one body per connected peer.
		var enough := _expect_players <= 0 or players.size() >= _expect_players
		print("NET_RESULT dedicated players=%d enemies=%d expected=%d roster=%s positions=%s" % [
			players.size(), enemies, _expect_players, roster, positions
		])
		if enough and _expect_players > 0:
			# Stay listening until the late client's own run ends; a server that
			# quits first looks like a crash to its clients.
			await create_timer(6.0).timeout
		quit(0 if enough else 1)
		return
	if _mode == "OBSERVE":
		# Passive client: only the replicated roster and creature count matter.
		# A peer may already have left, so the peak roster is the proof.
		var peak := maxi(players.size(), _peak_players)
		var seen := peak >= maxi(_expect_players, 2)
		print("NET_RESULT observe players=%d now=%d enemies=%d roster=%s" % [
			peak, players.size(), enemies, roster
		])
		quit(0 if seen and enemies >= MIN_ENEMIES else 1)
		return

	var walked_now := _walk_proof()
	var hp_ok := _mode != "JOIN" or _hp_drop_reported
	if players.size() == 2 and walked_now and enemies >= MIN_ENEMIES and hp_ok:
		print("NET_RESULT players=2 walked=1 enemies=%d hp_dropped=%d roster=%s positions=%s" % [
			enemies, 1 if _hp_drop_reported else 0, roster, positions
		])
		if _mode == "HOST":
			# The client process starts 2 s after the host and runs for the same
			# 12 s. Stay connected a little longer so the client's final snapshot
			# still sees both players; this host already has its result.
			await create_timer(3.0).timeout
		quit(0)
		return
	# Failure lines report the best state the session ever reached, so a client
	# whose server already exited can still show the 1 player it did receive.
	print("NET_RESULT FAILED players=%d walked=%d enemies=%d hp_dropped=%d roster=%s positions=%s" % [
		maxi(players.size(), _peak_players),
		1 if (walked_now or _ever_walked) else 0,
		enemies,
		1 if _hp_drop_reported else 0,
		roster,
		positions,
	])
	quit(1)


func _print_status() -> void:
	var players := _player_nodes()
	var positions := _positions_string(players)
	_peak_players = maxi(_peak_players, players.size())
	_ever_walked = _ever_walked or _walk_proof()
	if not positions.is_empty():
		_last_positions = positions
	print("NET peer=%d mode=%s players=%d enemies=%d roster=%s positions=%s" % [
		int(_network.get(&"local_peer_id")),
		_mode_name(),
		players.size(),
		_enemy_nodes().size(),
		_roster_string(),
		positions,
	])


func _mode_name() -> String:
	match int(_network.get(&"mode")):
		_server_mode:
			return "SERVER"
		_client_mode:
			return "CLIENT"
		_:
			return "OFFLINE"


func _player_nodes() -> Array[Node]:
	var players: Array[Node] = []
	if _main == null:
		return players
	var container := _main.get_node_or_null("Players")
	if container == null:
		return players
	for child in container.get_children():
		if child is Node3D:
			players.append(child)
	players.sort_custom(
		func(a: Node, b: Node) -> bool:
			return String(a.name).to_int() < String(b.name).to_int()
	)
	return players


## Creatures this peer currently holds. Server and client must agree: 0 on a
## client means the spawner never replicated the roster.
func _enemy_nodes() -> Array[Node]:
	var enemies: Array[Node] = []
	if _main == null or not _main.has_method(&"get_enemies"):
		return enemies
	for node: Node3D in _main.call(&"get_enemies"):
		enemies.append(node)
	return enemies


func _positions_string(players: Array[Node]) -> String:
	var parts: PackedStringArray = []
	for player in players:
		var at := (player as Node3D).global_position
		parts.append("%.2f,%.2f,%.2f" % [at.x, at.y, at.z])
	return ";".join(parts)


## `peer:held_item` per body, `-` for an empty hand or an empty roster. The
## HOST's line is the proof that a remote client's selection replicated.
func _held_string(players: Array[Node]) -> String:
	var parts: PackedStringArray = []
	for player in players:
		var held := String(player.get(&"held_item"))
		parts.append("%s:%s" % [player.name, held if not held.is_empty() else "-"])
	return ";".join(parts) if not parts.is_empty() else "-"


func _find_local_player() -> Node3D:
	for node in get_nodes_in_group(&"player"):
		if node is Node3D and node.is_multiplayer_authority():
			return node as Node3D
	return null


## OBSERVE only: that client body spawns on the same marker as the playing
## client and would block its walk. Step aside once physics has placed it.
func _step_observe_aside() -> void:
	if _observed_stand:
		return
	var body := _find_local_player()
	if body == null:
		return
	_observed_stand = true
	_local_player = body
	body.global_position += OBSERVE_STEP
	body.velocity = Vector3.ZERO
	print("OBSERVE_STAND at=%.2f,%.2f,%.2f" % [
		body.global_position.x, body.global_position.y, body.global_position.z
	])


## JOIN only: send one chat line through the real `Main` relay once our body is
## spawned, so the host's log proves the client -> server -> peers hop.
func _send_chat() -> void:
	if _chat_sent:
		return
	if _main == null or not _main.has_method(&"send_chat"):
		print("CHAT_FAILED reason=main_has_no_send_chat")
		return
	print("CHAT_SEND text=%s" % CHAT_TEXT)
	_main.call(&"send_chat", CHAT_TEXT, "global")
	_chat_sent = true


## JOIN only: three glowcaps through the real `InventorySystem`, so the server's
## `INV_RECV` line proves an inventory change crossed the wire.
func _send_loot() -> void:
	if _inventory_sent or _local_player == null or not is_instance_valid(_local_player):
		return
	var inventory := _local_player.get_node_or_null("InventorySystem")
	if inventory == null or not inventory.has_method(&"add_item"):
		print("INV_FAILED reason=no_inventory")
		return
	_inventory_sent = true
	var leftover := int(inventory.call(&"add_item", LOOT_ID, LOOT_COUNT))
	print("INV_SEND id=%s count=%d leftover=%d" % [
		String(LOOT_ID), LOOT_COUNT - leftover, leftover
	])


## JOIN only: the client owns its body, so it can step it into a creature's
## reach. The server's AI sees the replicated position and bites, which is the
## only route through the real server -> owner -> synchronizer damage path.
func _provoke_enemy() -> void:
	if _local_player == null or not is_instance_valid(_local_player):
		return
	var enemies := _enemy_nodes()
	if enemies.is_empty():
		print("HP_FAILED reason=no_enemies")
		return
	var target := enemies[0] as Node3D
	if target == null:
		return
	_local_player.global_position = target.global_position + PROVOKE_OFFSET
	_local_player.velocity = Vector3.ZERO
	print("HP_PROVOKE enemy=%s at=%.2f,%.2f,%.2f" % [
		target.name,
		_local_player.global_position.x,
		_local_player.global_position.y,
		_local_player.global_position.z,
	])


## JOIN only: reports the first HP drop this peer takes, next to the HP the HUD
## shows so a client-side-only value cannot fake it. The body then steps back
## out of reach, so the rest of the run proves the client stays connected
## instead of dying.
func _track_hp() -> void:
	if _hp_drop_reported or _local_player == null or not is_instance_valid(_local_player):
		return
	var current := _player_hp()
	if current < 0.0 or _hp_start < 0.0 or current >= _hp_start:
		return
	_hp_drop_reported = true
	print("HP_DROP from=%d to=%d hud=%s" % [roundi(_hp_start), roundi(current), _hud_hp_text()])
	_retreat()


func _player_hp() -> float:
	if _local_player == null or not is_instance_valid(_local_player):
		return -1.0
	var stats := _local_player.get_node_or_null("Stats")
	return -1.0 if stats == null else float(stats.get(&"hp"))


## Steps the body far enough away that the creature loses interest; the client
## still owns its transform, so the server follows the retreat.
func _retreat() -> void:
	if _local_player == null or not is_instance_valid(_local_player):
		return
	_local_player.global_position += Vector3(RETREAT_DISTANCE, 0.0, 0.0)
	_local_player.velocity = Vector3.ZERO
	print("HP_RETREAT to=%.2f,%.2f,%.2f" % [
		_local_player.global_position.x,
		_local_player.global_position.y,
		_local_player.global_position.z,
	])


func _hud_hp_text() -> String:
	if _main == null:
		return ""
	var hud := _main.get_node_or_null("HUD")
	if hud == null:
		return ""
	var label := hud.get_node_or_null("Root/Vitals/HPLabel") as Label
	return "" if label == null else label.text


## `peer:hp/level/gold` per entry, `;`-joined; `-` when nobody is in the roster.
func _roster_string() -> String:
	if _main == null or not _main.has_method(&"get_roster"):
		return "-"
	var parts := PackedStringArray()
	for entry: Variant in _main.call(&"get_roster"):
		if not (entry is Dictionary):
			continue
		var row: Dictionary = entry
		parts.append("%d:%.1f/%d/%d" % [
			int(row.get("peer_id", 0)),
			float(row.get("hp", 0.0)),
			int(row.get("level", 1)),
			int(row.get("gold", 0)),
		])
	return ";".join(parts) if not parts.is_empty() else "-"


func _on_chat_message_received(sender: String, text: String, channel: String) -> void:
	_chat_received.append(text)
	print("CHAT_RECV sender=%s text=%s channel=%s" % [sender, text, channel])


## JOIN: our own body must have moved away from where it spawned. The result is
## latched when the walk ends, because the HP provocation below teleports the
## body and would make a live comparison trivially true.
func _walk_proof() -> bool:
	if _mode == "JOIN":
		if _walk_proved:
			return true
		if not _walk_started or _local_player == null or not is_instance_valid(_local_player):
			return false
		return _walked_away()
	var spawn := _main.find_child("PlayerSpawn", true, false) as Node3D
	if spawn == null:
		return false
	var container := _main.get_node_or_null("Players")
	if container == null:
		return false
	var peers: Array = _network.call(&"get_peers")
	var local_id := int(_network.get(&"local_peer_id"))
	for peer_id: int in peers:
		if peer_id == local_id:
			continue
		var remote := container.get_node_or_null(str(peer_id)) as Node3D
		if remote == null:
			continue
		var moved := remote.global_position - spawn.global_position
		if Vector2(moved.x, moved.z).length() > 0.5:
			return true
	return false


func _walked_away() -> bool:
	if _local_player == null or not is_instance_valid(_local_player):
		return false
	var walked := _local_player.global_position - _walk_from
	return Vector2(walked.x, walked.z).length() > 0.5
