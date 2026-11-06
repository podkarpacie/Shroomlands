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
	leader_id = peer_id
	leader_changed.emit(leader_id)


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
