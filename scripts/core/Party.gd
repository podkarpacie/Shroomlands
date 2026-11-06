extends Node
## Expedition party state: who carries the spore-lamp.
##
## The objective is asymmetric: one player leads with the only working lamp, and
## the forest's return gates refuse the party until that leader is standing at
## the gate. Offline the local peer (1) is the leader; a session can set another
## peer with `set_leader`.

signal leader_changed(leader_id: int)

## Peer id of the leader. Peer 1 is the host, so the host leads by default.
var leader_id := 1


func set_leader(peer_id: int) -> void:
	if peer_id <= 0 or peer_id == leader_id:
		return
	match Network.mode:
		Network.CLIENT:
			request_leader.rpc_id(1, peer_id)
		Network.SERVER:
			_apply_leader(peer_id)
			apply_leader.rpc(peer_id)
		_:
			_apply_leader(peer_id)


## Client -> server: only the authority decides who leads.
@rpc("any_peer", "call_remote", "reliable")
func request_leader(peer_id: int) -> void:
	if Network.mode != Network.SERVER or peer_id <= 0:
		return
	var sender := multiplayer.get_remote_sender_id()
	# The current leader passes the lamp; the host may also correct the roster.
	if sender != leader_id and sender != 1:
		return
	_apply_leader(peer_id)
	apply_leader.rpc(peer_id)


## Server -> clients.
@rpc("authority", "call_remote", "reliable")
func apply_leader(peer_id: int) -> void:
	_apply_leader(peer_id)


## Sends the current leader to a peer that just joined.
func sync_to_peer(peer_id: int) -> void:
	if Network.mode != Network.SERVER or peer_id <= 0:
		return
	apply_leader.rpc_id(peer_id, leader_id)


func _apply_leader(peer_id: int) -> void:
	if peer_id <= 0 or peer_id == leader_id:
		return
	leader_id = peer_id
	leader_changed.emit(leader_id)


## Hands the lamp to the nearest other living player within `radius`.
## Returns the new leader's peer id, 0 when nobody is close enough, or -1 when
## the caller is not the leader. A client's `set_leader` forwards to the server,
## which validates that the sender is the current leader.
func pass_to_nearest(from: Node3D, radius := 8.0) -> int:
	if from == null or not is_leader(from):
		return -1
	var best: Node3D = null
	var best_distance := radius
	for node: Node in get_tree().get_nodes_in_group(&"player"):
		var body := node as Node3D
		if body == null or body == from:
			continue
		var stats := body.get_node_or_null("Stats")
		if stats != null and bool(stats.call(&"is_dead")):
			continue
		var offset := body.global_position - from.global_position
		var distance := Vector2(offset.x, offset.z).length()
		if distance <= best_distance:
			best = body
			best_distance = distance
	if best == null:
		return 0
	var target := best.get_multiplayer_authority()
	if target == leader_id:
		return 0
	set_leader(target)
	return target


func is_leader(player: Node) -> bool:
	if player == null:
		return false
	return player.get_multiplayer_authority() == leader_id


## The leader's body on this peer, or null when it is not present (a client that
## has not received the leader's node, or a test pointing at an absent peer).
func leader_node() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(&"player"):
		var body := node as Node3D
		if body == null:
			continue
		if body.get_multiplayer_authority() == leader_id:
			return body
	return null


## True when a living leader stands within `radius` of `position` (flat).
func leader_is_near(position: Vector3, radius: float) -> bool:
	var body := leader_node()
	if body == null:
		return false
	var stats := body.get_node_or_null("Stats")
	if stats != null and bool(stats.call(&"is_dead")):
		return false
	var delta := body.global_position - position
	return Vector2(delta.x, delta.z).length() <= radius


func local_is_leader() -> bool:
	return is_leader(Game.get_local_player())
