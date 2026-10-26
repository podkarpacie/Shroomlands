extends Node3D
## Entry scene. Offline it spawns the local player at the world's `PlayerSpawn`
## marker; a Network session spawns players on the server through
## `PlayerSpawner`, and every peer receives the replicated copies.
##
## The enemy roster follows the same rule: one fixed spawn point per creature,
## instantiated locally offline and through `EnemySpawner` on the server, so a
## client ends up with the identical nodes and count.
##
## Session state that a spawner cannot carry lives here: the player roster
## (`{peer_id, name, hp, level, gold}`), the read-only inventory mirrors and the
## owner -> server progression reports. Transforms and vitals travel on the
## player's own synchronizers; this node only fills the gaps.

const PLAYER_SCENE := preload("res://scenes/player/player.tscn")
const ENEMY_SCENE := preload("res://scenes/world/enemy.tscn")
## `local` chat reaches only peers whose body is within this many metres of the
## sender. Global chat ignores distance.
const CHAT_LOCAL_RANGE := 25.0
## Offline autosave cadence; level-ups and a window close also save.
const AUTOSAVE_SECONDS := 60.0
## Fixed spawn ring for the placeholder fungal creatures: ~28 m out, past the
## starting clearing (and past every walk a test performs), so a fresh player is
## never ambushed at the spawn marker and has to head out to find them.
const ENEMY_SPAWNS: Array[Vector3] = [
	Vector3(-20.0, 0.0, -20.0),
	Vector3(20.0, 0.0, -20.0),
	Vector3(-20.0, 0.0, 20.0),
	Vector3(20.0, 0.0, 20.0),
]
## Slot count of one replicated inventory, matching `InventorySystem`.
const INVENTORY_SLOT_COUNT: int = Game.INVENTORY_COLS * Game.INVENTORY_ROWS
## Roster broadcast cadence. One reliable packet per second is enough for a
## line of names and values and also covers a join that races the first push.
const ROSTER_SECONDS := 1.0
## Ceiling for a client-reported gold balance: a hand-made packet must not be
## able to park a nonsense number in the roster.
const MAX_REPORTED_GOLD := 1_000_000
## How many discovered species one peer may report.
const MAX_REPORTED_DISCOVERIES := 64

## Vertical and horizontal sandbox limits for a restored position. The
## placeholder ground is 600 x 600 m, so anything beyond this is a corrupt or
## hand-edited save rather than an exploration record.
@export var world_extent := 280.0
@export var min_player_height := 1.2
@export var max_player_height := 200.0

@onready var _world: Node3D = $World
@onready var _players: Node3D = $Players
@onready var _player_spawner: MultiplayerSpawner = $PlayerSpawner
@onready var _enemies: Node3D = $Enemies
@onready var _enemy_spawner: MultiplayerSpawner = $EnemySpawner

var _player: Node3D = null
## Server view of every peer's latest inventory, and the mirror every peer keeps
## of the others'. `peer_id -> Array` of `InventorySystem` slots.
var _remote_inventories: Dictionary = {}
## Owner-reported progression per peer: `peer_id -> {gold, discovered, vocation}`.
## Only the owner writes its own entry; see `report_progress`.
var _peer_progress: Dictionary = {}
## Last roster snapshot: `[{peer_id, name, hp, level, gold}]` in peer order.
var _roster: Array[Dictionary] = []
## Set once this peer has pushed its own starting progression to the server.
var _own_state_sent := false
var _roster_timer: Timer = null


func _ready() -> void:
	_player_spawner.spawn_function = _make_player
	_enemy_spawner.spawn_function = _make_enemy
	match Network.mode:
		Network.OFFLINE:
			_spawn_player()
			_restore_offline_save()
			_spawn_enemies()
			_start_autosave()
		Network.SERVER:
			multiplayer.peer_connected.connect(_on_peer_connected)
			multiplayer.peer_disconnected.connect(_on_peer_disconnected)
			if not Network.is_dedicated:
				_player = _spawn_network_player(multiplayer.get_unique_id())
			_spawn_enemies()
			_start_roster_timer()
		Network.CLIENT:
			# Spawning is server-authoritative: this peer only receives the
			# replicated player and enemy nodes from the spawners. Spawning
			# locally here would create duplicates the server never knew about.
			_start_roster_timer()


func get_player() -> Node3D:
	return _player


func _spawn_player() -> void:
	var spawn := _get_spawn_point()
	if spawn == null:
		push_warning("Main: world has no PlayerSpawn marker, spawning at the origin.")
	_player = PLAYER_SCENE.instantiate() as Node3D
	_player.name = "Player"
	add_child(_player)
	if spawn != null:
		_player.global_position = spawn.global_position


## Singleplayer continues where the last session stopped. Multiplayer never
## calls this: a session is server-authoritative, so the offline save must not
## leak into it.
func _restore_offline_save() -> void:
	if _player == null or not SaveSystem.has_save():
		return
	if not SaveSystem.load_now():
		return
	_clamp_player_position()


## A stored position can be stale or hand-edited; keep the body inside the
## playable ground instead of dropping it through the floor.
func _clamp_player_position() -> void:
	if _player == null:
		return
	var position := _player.global_position
	_player.global_position = Vector3(
		clampf(position.x, -world_extent, world_extent),
		clampf(position.y, min_player_height, max_player_height),
		clampf(position.z, -world_extent, world_extent)
	)


## Periodic save plus a save on every level-up, offline only. Both go through
## `SaveSystem`, which owns the file format.
func _start_autosave() -> void:
	var timer := Timer.new()
	timer.name = "AutosaveTimer"
	timer.wait_time = AUTOSAVE_SECONDS
	timer.autostart = true
	timer.timeout.connect(_autosave)
	add_child(timer)
	EventBus.level_changed.connect(_on_level_changed)


func _on_level_changed(_new_level: int) -> void:
	_autosave()


func _autosave() -> void:
	if Network.mode != Network.OFFLINE:
		return
	# With no body there is nothing worth writing, and a defaults-only snapshot
	# would erase real progress at shutdown.
	if Game.get_local_player() == null:
		return
	SaveSystem.save_now()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_autosave()


## Server-only: ask the spawner for `peer_id`'s player. The spawner replicates
## the node to every connected peer.
func _spawn_network_player(peer_id: int) -> Node3D:
	if peer_id == 0:
		return null
	var existing := _players.get_node_or_null(str(peer_id)) as Node3D
	if existing != null:
		return existing
	var spawned := _player_spawner.spawn(peer_id) as Node3D
	if spawned == null:
		push_warning("Main: player spawner rejected peer %d." % peer_id)
	return spawned


## MultiplayerSpawner spawn function. Runs on the server when it spawns and on
## every client when the spawn is replicated, so both sides build the same
## node with the same name and authority.
func _make_player(peer_id: int) -> Node3D:
	var player := PLAYER_SCENE.instantiate() as Node3D
	player.name = str(peer_id)
	player.set_multiplayer_authority(peer_id)
	var spawn := _get_spawn_point()
	if spawn != null:
		# The node is not in the tree yet, so global_position is unavailable;
		# convert the marker into the container's local space instead.
		player.position = _players.to_local(spawn.global_position)
	return player


func _on_peer_connected(peer_id: int) -> void:
	_spawn_network_player(peer_id)
	# Immediate roster push for the new peer (the 1 Hz tick is the safety net),
	# so a late joiner sees the player count and values without waiting.
	_refresh_roster()


func _on_peer_disconnected(peer_id: int) -> void:
	_remote_inventories.erase(peer_id)
	_peer_progress.erase(peer_id)
	var player := _players.get_node_or_null(str(peer_id))
	if player != null:
		# The spawner sees the tree_exiting and tells every client to despawn.
		player.queue_free()
	_refresh_roster()


## Offline adds the fixed roster directly; a server hands each index to the
## spawner so every peer builds the same node at the same point.
func _spawn_enemies() -> void:
	var offline := Network.mode == Network.OFFLINE
	for index in ENEMY_SPAWNS.size():
		if offline:
			_enemies.add_child(_make_enemy(index))
		else:
			var spawned := _enemy_spawner.spawn(index) as Node3D
			if spawned == null:
				push_warning("Main: enemy spawner rejected spawn point %d." % index)


## MultiplayerSpawner spawn function for creatures: the spawn index is the only
## data on the wire, so every peer derives name and position from it.
func _make_enemy(index: int) -> Node3D:
	var enemy := ENEMY_SCENE.instantiate() as Node3D
	enemy.name = "Enemy%d" % index
	enemy.position = _enemies.to_local(ENEMY_SPAWNS[index])
	enemy.set_multiplayer_authority(1)
	return enemy


## Creatures currently spawned on this peer, in spawn order. Used by the network
## harness to prove both sides see the same roster.
func get_enemies() -> Array[Node3D]:
	var found: Array[Node3D] = []
	for child in _enemies.get_children():
		if child is Node3D and child.is_in_group(&"enemy"):
			found.append(child as Node3D)
	return found


## --- Session state: roster, inventory mirrors, progression reports --------


## Every player in the session as `{peer_id, name, hp, level, gold}`. The server
## builds it from the replicated bodies plus each owner's own report; a client
## keeps the last broadcast; offline there is only the local player.
func get_roster() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for entry: Dictionary in _roster:
		entries.append(entry.duplicate())
	if entries.is_empty() and Network.mode == Network.OFFLINE:
		var local := _local_roster_entry()
		if not local.is_empty():
			entries.append(local)
	return entries


## Server-side progression of one peer (`{gold, discovered, vocation}`); empty
## before that peer reports anything.
func get_peer_progress(peer_id: int) -> Dictionary:
	var stored: Variant = _peer_progress.get(peer_id, {})
	return (stored as Dictionary).duplicate() if stored is Dictionary else {}


## Read-only mirror of another peer's inventory, in `InventorySystem` slot
## shape. Empty until that peer's first report arrives.
func get_remote_inventory(peer_id: int) -> Array:
	var stored: Variant = _remote_inventories.get(peer_id, [])
	if not (stored is Array):
		return []
	return (stored as Array).duplicate(true)


func _start_roster_timer() -> void:
	_roster_timer = Timer.new()
	_roster_timer.name = "RosterTimer"
	_roster_timer.wait_time = ROSTER_SECONDS
	_roster_timer.autostart = true
	_roster_timer.timeout.connect(_on_roster_tick)
	add_child(_roster_timer)


func _on_roster_tick() -> void:
	_report_own_state()
	if Network.mode == Network.SERVER:
		_refresh_roster()


## Owner -> server: the first tick that finds this peer's body pushes the values
## only the owner knows (gold, discoveries, vocation, inventory), so a join never
## has to wait for a change signal. Later changes report themselves.
func _report_own_state() -> void:
	if _own_state_sent:
		return
	var body := Game.get_local_player()
	if body == null or not is_instance_valid(body):
		return
	_own_state_sent = true
	report_own_progress(Game.gold, Game.discovered_mushrooms.keys(), String(Game.chosen_vocation))
	var inventory := body.get_node_or_null("InventorySystem")
	if inventory != null and inventory.has_method(&"to_sync_payload"):
		report_inventory(inventory.call(&"to_sync_payload") as Array)


## Owner -> server inventory leg. The host merges its own copy directly; a
## client sends it over the wire, where only the sender id is trusted.
func report_inventory(slots: Array) -> void:
	match Network.mode:
		Network.SERVER:
			_accept_inventory(multiplayer.get_unique_id(), slots)
		Network.CLIENT:
			sync_inventory.rpc_id(1, slots)


## Client -> server inventory leg. The payload is validated before it becomes a
## mirror, so a malformed or hand-made packet is dropped instead of reaching any
## peer's copy of that player.
@rpc("any_peer", "call_remote", "reliable")
func sync_inventory(slots: Array) -> void:
	if Network.mode != Network.SERVER:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1:
		# Peer 1 is this server; a peer may only report its own inventory.
		return
	_accept_inventory(sender, slots)


## Server: stores one validated inventory mirror and fans it out. Returns false
## (and changes nothing) when the payload fails `validate_inventory_payload`.
func _accept_inventory(peer_id: int, slots: Array) -> bool:
	if peer_id <= 0 or not validate_inventory_payload(slots):
		return false
	_remote_inventories[peer_id] = slots.duplicate(true)
	print("INV_RECV peer=%d glowcap=%d" % [peer_id, _count_items(slots, &"glowcap")])
	if Network.mode == Network.SERVER:
		receive_inventory.rpc(peer_id, slots)
	return true


## Shape guard for a replicated inventory: exactly `INVENTORY_SLOT_COUNT` slots,
## each either `{}` or `{id, count}` with a known `Lore` id and a count inside
## `0..InventorySystem.MAX_STACK`.
func validate_inventory_payload(slots: Array) -> bool:
	if slots.size() != INVENTORY_SLOT_COUNT:
		return false
	for entry: Variant in slots:
		if not (entry is Dictionary):
			return false
		var slot: Dictionary = entry
		if slot.is_empty():
			continue
		var raw_id: Variant = slot.get("id", null)
		if not (raw_id is String or raw_id is StringName):
			return false
		if not Lore.is_mushroom(str(raw_id)) and not Lore.RESOURCES.has(str(raw_id)):
			return false
		var raw_count: Variant = slot.get("count", null)
		if not (raw_count is int or raw_count is float):
			return false
		var count := int(raw_count)
		if count < 0 or count > InventorySystem.MAX_STACK:
			return false
	return true


## Server -> peers: the authoritative mirror of one player's inventory. It is
## stored, never applied to a local `InventorySystem`, so another player's items
## can never leak into this peer's own inventory or HUD.
@rpc("authority", "call_local", "reliable")
func receive_inventory(peer_id: int, slots: Array) -> void:
	if not validate_inventory_payload(slots):
		return
	_remote_inventories[peer_id] = slots.duplicate(true)


## Owner -> server progression leg: gold, discoveries and the vocation are only
## known to the owner, so it reports them and the server records them against the
## reporting peer.
func report_own_progress(gold: int, discovered: Array, vocation: String) -> void:
	match Network.mode:
		Network.SERVER:
			_merge_progress(multiplayer.get_unique_id(), gold, discovered, vocation)
		Network.CLIENT:
			report_progress.rpc_id(1, gold, discovered, vocation)


## Client -> server leg of `report_own_progress`. The peer comes from the
## connection and is never part of the payload, so a client cannot write another
## player's entry.
@rpc("any_peer", "call_remote", "reliable")
func report_progress(gold: int, discovered: Array, vocation: String) -> void:
	if Network.mode != Network.SERVER:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1:
		# A local call (0) or the server itself (1) never arrives here.
		return
	_merge_progress(sender, gold, discovered, vocation)


## Records one peer's progression. Values are clamped and filtered against
## `Lore`, so a bad report costs that peer its numbers, never the session.
func _merge_progress(peer_id: int, gold: int, discovered: Array, vocation: String) -> void:
	if peer_id <= 0:
		return
	var known: Array = []
	for raw: Variant in discovered:
		var id := str(raw)
		if not Lore.is_mushroom(id) or known.has(id):
			continue
		known.append(id)
		if known.size() >= MAX_REPORTED_DISCOVERIES:
			break
	_peer_progress[peer_id] = {
		"gold": clampi(gold, 0, MAX_REPORTED_GOLD),
		"discovered": known,
		"vocation": vocation if Lore.VOCATIONS.has(vocation) else "",
	}


## Server: rebuilds the roster from the replicated bodies (HP and level arrive
## through each player's vitals synchronizer) plus each owner's gold report, then
## pushes the whole thing to every peer.
func _refresh_roster() -> void:
	if Network.mode != Network.SERVER:
		return
	var entries: Array[Dictionary] = []
	for peer_id: int in Network.get_peers():
		var body := _peer_player(peer_id)
		if body == null:
			continue
		var stats := body.get_node_or_null("Stats")
		var progress: Dictionary = _peer_progress.get(peer_id, {})
		entries.append({
			"peer_id": peer_id,
			"name": "Player %d" % peer_id,
			"hp": float(stats.get(&"hp")) if stats != null else 0.0,
			"level": int(stats.get(&"level")) if stats != null else 1,
			"gold": int(progress.get("gold", 0)),
		})
	_roster = entries
	var wire: Array = []
	wire.assign(entries)
	receive_roster.rpc(wire)


## Server -> peers: the whole roster. A client only ever reads it, which keeps
## its own entry from being overwritten by anything it sends.
@rpc("authority", "call_local", "reliable")
func receive_roster(entries: Array) -> void:
	if Network.mode != Network.SERVER and Network.mode != Network.CLIENT:
		return
	var parsed: Array[Dictionary] = []
	for entry: Variant in entries:
		if not (entry is Dictionary):
			continue
		var row: Dictionary = entry
		parsed.append({
			"peer_id": int(row.get("peer_id", 0)),
			"name": str(row.get("name", "")),
			"hp": float(row.get("hp", 0.0)),
			"level": int(row.get("level", 1)),
			"gold": int(row.get("gold", 0)),
		})
	_roster = parsed


func _local_roster_entry() -> Dictionary:
	var body := Game.get_local_player()
	if body == null or not is_instance_valid(body):
		return {}
	var peer_id := multiplayer.get_unique_id()
	var stats := body.get_node_or_null("Stats")
	var progress: Dictionary = _peer_progress.get(peer_id, {})
	return {
		"peer_id": peer_id,
		"name": "Player %d" % peer_id,
		"hp": float(stats.get(&"hp")) if stats != null else 0.0,
		"level": int(stats.get(&"level")) if stats != null else 1,
		"gold": int(progress.get("gold", Game.gold)),
	}


func _count_items(slots: Array, id: StringName) -> int:
	var total := 0
	for entry: Variant in slots:
		if not (entry is Dictionary):
			continue
		var slot: Dictionary = entry
		if StringName(slot.get("id", &"")) == id:
			total += int(slot.get("count", 0))
	return total


## Chat entry point used by `ChatUI`. Offline the message only echoes locally,
## a client asks the server to relay it, and the host fans it out itself.
func send_chat(text: String, channel: String = "global") -> void:
	var body := text.strip_edges()
	if body.is_empty():
		return
	if Network.mode == Network.CLIENT:
		submit_chat.rpc_id(1, body, channel)
		return
	_deliver_chat(multiplayer.get_unique_id(), body, channel)


## Client -> server leg. `any_peer` lets a client call it, but only the server
## acts on it, so no client can address another client directly.
@rpc("any_peer", "call_local", "reliable")
func submit_chat(text: String, channel: String) -> void:
	if Network.mode != Network.SERVER:
		return
	var sender_peer := multiplayer.get_remote_sender_id()
	if sender_peer == 0:
		sender_peer = multiplayer.get_unique_id()
	_deliver_chat(sender_peer, text, channel)


## Server -> peers leg, and the only place a chat line becomes an `EventBus`
## signal. Called locally for this peer's own copy, by id for the others.
@rpc("authority", "call_local", "reliable")
func receive_chat(sender_peer: int, text: String, channel: String) -> void:
	EventBus.chat_message_received.emit("Player %d" % sender_peer, text, channel)


func _deliver_chat(sender_peer: int, text: String, channel: String) -> void:
	if Network.mode != Network.SERVER:
		# Offline: there is nobody else to send this to.
		receive_chat(sender_peer, text, channel)
		return
	var local_id := multiplayer.get_unique_id()
	for peer_id: int in _chat_recipients(sender_peer, channel):
		if peer_id == local_id:
			receive_chat(sender_peer, text, channel)
		else:
			receive_chat.rpc_id(peer_id, sender_peer, text, channel)


func _chat_recipients(sender_peer: int, channel: String) -> Array[int]:
	var recipients: Array[int] = []
	for peer_id: int in Network.get_peers():
		if channel == "local" and not _in_local_chat_range(sender_peer, peer_id):
			continue
		recipients.append(peer_id)
	return recipients


## Local chat is distance-gated on the server, which is the only peer that knows
## every body's position. An unknown body is treated as in range so a message is
## never silently dropped.
func _in_local_chat_range(sender_peer: int, receiver_peer: int) -> bool:
	if sender_peer == receiver_peer:
		return true
	var sender := _peer_player(sender_peer)
	var receiver := _peer_player(receiver_peer)
	if sender == null or receiver == null:
		return true
	return sender.global_position.distance_to(receiver.global_position) <= CHAT_LOCAL_RANGE


func _peer_player(peer_id: int) -> Node3D:
	if peer_id == multiplayer.get_unique_id() and _player != null and is_instance_valid(_player):
		return _player
	return _players.get_node_or_null(str(peer_id)) as Node3D


func _get_spawn_point() -> Marker3D:
	if _world != null and _world.has_method(&"get_spawn_point"):
		var point: Variant = _world.call(&"get_spawn_point")
		if point is Marker3D:
			return point as Marker3D
	return null
