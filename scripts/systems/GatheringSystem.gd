class_name GatheringSystem
extends Node
## Timed gather state machine for the local player: IDLE -> GATHERING -> IDLE,
## one target at a time. It owns the timer, the sprint lock and the inventory
## hand-off; MushroomNode owns the yield roll and the regrow cooldown.
##
## Cancel happens on: depleted/invalid target, walking beyond `cancel_range`,
## losing HP (any `hp_changed` decrease) or a second interact press. The second
## press is routed through PlayerController, so one key press never cancels and
## immediately restarts the gather.

@export var gather_range := 3.5
@export var cancel_range := 4.0

var _target: MushroomNode = null
var _elapsed := 0.0
var _total := 0.0
var _last_hp := -1.0


func _ready() -> void:
	_last_hp = _player_hp()
	EventBus.hp_changed.connect(_on_hp_changed)


## Starts gathering `target`. False when already gathering, the target is
## depleted/invalid, or the player is further than `gather_range`.
func begin(target: MushroomNode) -> bool:
	if is_gathering() or target == null or not is_instance_valid(target):
		return false
	if not target.is_available():
		return false
	if _distance_to(target) > gather_range:
		return false
	_target = target
	_elapsed = 0.0
	_total = maxf(target.harvest_seconds, 0.01)
	_last_hp = _player_hp()
	_set_sprint_lock(true)
	EventBus.gather_progress_changed.emit(0.0, _total)
	return true


func _process(delta: float) -> void:
	if _target == null:
		return
	if not is_instance_valid(_target) or not _target.is_available():
		cancel()
		return
	if _distance_to(_target) > cancel_range:
		cancel()
		return
	_elapsed += delta
	EventBus.gather_progress_changed.emit(minf(_elapsed, _total), _total)
	if _elapsed >= _total:
		_complete()


func is_gathering() -> bool:
	return _target != null


## 0.0..1.0 for the HUD bar; 0 when idle.
func progress_ratio() -> float:
	if _target == null or _total <= 0.0:
		return 0.0
	return clampf(_elapsed / _total, 0.0, 1.0)


## Stops the gather without touching the target or the inventory.
func cancel() -> void:
	if _target == null:
		return
	_reset()
	EventBus.gather_progress_changed.emit(0.0, 0.0)


func _complete() -> void:
	var node := _target
	var id := str(node.mushroom_id)
	node.harvest()
	var amount := node.last_yield
	var inventory := _inventory()
	if inventory != null and inventory.has_method(&"add_item"):
		var leftover := int(inventory.call(&"add_item", node.mushroom_id, amount))
		if leftover > 0:
			push_warning("GatheringSystem: inventory full, %d x %s could not be stored." % [leftover, id])
	_reset()
	EventBus.gather_finished.emit(id)


func _reset() -> void:
	_target = null
	_elapsed = 0.0
	_total = 0.0
	_set_sprint_lock(false)


func _on_hp_changed(current: float, _max_hp: float) -> void:
	if _target != null and _last_hp >= 0.0 and current < _last_hp:
		cancel()
	_last_hp = current


func _distance_to(target: Node3D) -> float:
	var player := _player_body()
	if player == null:
		return INF
	return player.global_position.distance_to(target.global_position)


func _player_body() -> Node3D:
	return get_parent() as Node3D


func _player_hp() -> float:
	var player := _player_body()
	if player == null:
		return -1.0
	var stats: Node = player.get_node_or_null("Stats")
	if stats == null:
		return -1.0
	return float(stats.get("hp"))


func _inventory() -> Node:
	var player := _player_body()
	if player == null:
		return null
	return player.get_node_or_null("InventorySystem")


func _set_sprint_lock(value: bool) -> void:
	var player := _player_body()
	if player != null and player.has_method(&"set_gathering"):
		player.call(&"set_gathering", value)
