extends Node
## The leader's "pass the lamp" key. It only works for the current leader and
## only when another living body is close; the server re-checks both.

const PASS_RADIUS := 8.0


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"pass_lamp"):
		return
	var player := Game.get_local_player() as Node3D
	if player == null:
		return
	if "ui_blocking" in player and bool(player.get(&"ui_blocking")):
		return
	if not Party.is_leader(player):
		EventBus.toast_requested.emit("Only the leader can pass the lamp")
		return
	var target := Party.pass_to_nearest(player, PASS_RADIUS)
	if target < 0:
		EventBus.toast_requested.emit("Only the leader can pass the lamp")
	elif target == 0:
		EventBus.toast_requested.emit("No other forager is close enough")
	else:
		EventBus.toast_requested.emit("Lamp passed - follow the new leader")
