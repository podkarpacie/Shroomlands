class_name SearchableCrate
extends StaticBody3D
## A crate in a forest structure that must be searched: stand close and hold
## the interact key for `search_seconds`. Searching is loud — it emits a
## disturbance that creatures investigate — and the crate never refills.
##
## Interact starts the search; walking beyond `cancel_range`, losing the
## searcher, or a second press is not needed: the crate cancels itself.

@export var loot: Array[String] = []
@export var gold := 0
@export var search_seconds := 1.2
## Noise radius for the creatures' hearing. Bigger than an enemy's 12 m aggro
## range, so searching a crate can pull something that had not seen you.
@export var noise_radius := 14.0
@export var cancel_range := 4.0

var opened := false
var searching := false

var _elapsed := 0.0
var _searcher: Node = null

@onready var _lid: MeshInstance3D = $Lid


func _ready() -> void:
	add_to_group(&"interactable")


func get_interaction_text() -> String:
	if opened:
		return "Empty crate"
	if searching:
		return "Searching…"
	return "Search crate  [E]"


func interact(player: Node) -> void:
	if opened or searching or player == null:
		return
	searching = true
	_elapsed = 0.0
	_searcher = player
	EventBus.toast_requested.emit("Searching the crate…")


func _process(delta: float) -> void:
	if not searching:
		return
	if _searcher == null or not is_instance_valid(_searcher):
		_cancel()
		return
	if _flat_distance(_searcher.global_position) > cancel_range:
		_cancel()
		return
	_elapsed += delta
	if _elapsed >= search_seconds * Game.survival_search_scale():
		_complete()


func _complete() -> void:
	if _searcher != null and _searcher.is_multiplayer_authority():
		# The searcher levels Survival; the server's copy of a client body does
		# not, so exactly one peer is paid.
		Game.add_skill_xp(&"survival", 10)
	if Network.mode == Network.CLIENT:
		# The server owns the contents and the opened state.
		searching = false
		_searcher = null
		request_open.rpc_id(1)
		return
	_apply_opened()
	_grant_local()
	if Network.mode == Network.SERVER:
		apply_opened.rpc()
	Network.report_disturbance(global_position, noise_radius)


## Server-side grant to its own player (offline or the host searched).
func _grant_local() -> void:
	var body := Game.get_local_player()
	var inventory := body.get_node_or_null("InventorySystem") if body != null else null
	var given := 0
	for id: String in loot:
		if inventory != null:
			given += int(inventory.call(&"add_item", StringName(id), 1))
	if gold > 0:
		Game.add_run_gold(gold)
	EventBus.toast_requested.emit("Crate: %d item(s), %d gold" % [given, gold])


## Client -> server. The server checks the sender is actually at this crate
## before paying out, then broadcasts the opened state.
@rpc("any_peer", "call_remote", "reliable")
func request_open() -> void:
	if Network.mode != Network.SERVER or opened:
		return
	var sender := multiplayer.get_remote_sender_id()
	var main := get_tree().get_first_node_in_group(&"main")
	if main == null or not main.has_method(&"get_player_for_peer"):
		return
	var body := main.call(&"get_player_for_peer", sender) as Node3D
	if body == null or _flat_distance(body.global_position) > cancel_range + 1.0:
		return
	_apply_opened()
	apply_opened.rpc()
	main.call(&"send_loot", sender, loot, gold)
	Network.report_disturbance(global_position, noise_radius)


@rpc("authority", "call_remote", "reliable")
func apply_opened() -> void:
	_apply_opened()


func _apply_opened() -> void:
	searching = false
	opened = true
	_searcher = null
	_open_lid()


func _cancel() -> void:
	if not searching:
		return
	searching = false
	_elapsed = 0.0
	_searcher = null
	EventBus.toast_requested.emit("Search interrupted")


func _open_lid() -> void:
	if _lid == null:
		return
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_lid, "rotation:x", -1.0, 0.3).set_trans(Tween.TRANS_BACK)
	tween.tween_property(_lid, "position:y", 0.82, 0.3)


func _flat_distance(point: Vector3) -> float:
	var delta := point - global_position
	return Vector2(delta.x, delta.z).length()
