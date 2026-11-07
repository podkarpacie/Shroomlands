class_name SporeLamp
extends SpotLight3D
## The player's hand lamp: the answer to the dark lower layers, and the reason
## the dark is dangerous. Toggled with `F`, it drains a battery, recharges while
## off, and pulses a `disturbance_emitted` signal while lit so creatures can
## notice the beam from outside their normal aggro range.
##
## The node hangs off `CameraPivot`, so it points wherever the camera looks.

@export var battery_seconds := 90.0
@export var drain_per_second := 1.0
@export var recharge_per_second := 0.35
## Flat radius creatures can notice the lit beam from. Larger than an enemy's
## 12 m aggro range on purpose: using the lamp is a real risk.
@export var alert_radius := 16.0
@export var alert_interval := 1.2
@export var toggle_noise_radius := 5.0

var battery := 0.0
var on := false

var _base_energy := 7.0
var _base_range := 22.0
var _base_battery := 90.0
var _alert_left := 0.0
var _warned_low := false
var _warned_empty := false


func _ready() -> void:
	# Remember the exported values: Survival and the Bright Lamp scale them, and
	# the numbers must be re-derived when gear changes rather than multiplied
	# into the scene defaults again.
	_base_energy = light_energy
	_base_range = spot_range
	_base_battery = battery_seconds
	_apply_gear()
	battery = battery_seconds
	on = false
	visible = false
	Party.leader_changed.connect(_on_leader_changed)
	if not EventBus.gear_changed.is_connected(_apply_gear):
		EventBus.gear_changed.connect(_apply_gear)
	_apply_role()


## Survival levels and the Bright Lamp both scale the beam and the battery.
func _apply_gear() -> void:
	var inventory := _inventory()
	var range_mult := 1.0
	var energy_mult := 1.0
	var battery_mult := 1.0
	if inventory != null and inventory.has_method(&"gear_multiplier"):
		range_mult = float(inventory.call(&"gear_multiplier", "lamp_range_mult"))
		energy_mult = float(inventory.call(&"gear_multiplier", "lamp_energy_mult"))
		battery_mult = float(inventory.call(&"gear_multiplier", "battery_mult"))
	spot_range = _base_range * range_mult
	light_energy = _base_energy * energy_mult
	battery_seconds = _base_battery * Game.survival_lamp_scale() * battery_mult
	battery = minf(battery, battery_seconds) if battery > 0.0 else battery_seconds


## Gear that muffles the wearer (`quiet_boots`).
func _noise_scale() -> float:
	var inventory := _inventory()
	if inventory == null or not inventory.has_method(&"gear_multiplier"):
		return 1.0
	return float(inventory.call(&"gear_multiplier", "noise_mult"))


func _inventory() -> Node:
	var body := _body()
	return body.get_node_or_null("InventorySystem") if body != null else null


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"flashlight"):
		return
	if _ui_blocked():
		return
	toggle()


func _process(delta: float) -> void:
	if on:
		battery = maxf(battery - drain_per_second * delta, 0.0)
		_alert_left -= delta
		if _alert_left <= 0.0:
			_alert_left = alert_interval
			Network.report_disturbance(global_position, alert_radius * _noise_scale())
		if battery <= 0.0:
			on = false
			visible = false
			light_energy = _base_energy
			EventBus.toast_requested.emit("The spore-lamp dies")
			return
		if battery_ratio() <= 0.10 and not _warned_empty:
			_warned_empty = true
			EventBus.toast_requested.emit("Spore-lamp: 10%")
		elif battery_ratio() <= 0.30 and not _warned_low:
			_warned_low = true
			EventBus.toast_requested.emit("Spore-lamp: 30%")
		_flicker()
	else:
		battery = minf(battery + recharge_per_second * delta, battery_seconds)
		light_energy = _base_energy
		if battery_ratio() > 0.35:
			_warned_low = false
		if battery_ratio() > 0.15:
			_warned_empty = false


func toggle() -> void:
	if not Party.is_leader(_body()):
		EventBus.toast_requested.emit("Only the leader carries the spore-lamp")
		return
	if battery <= 0.0:
		EventBus.toast_requested.emit("The spore-lamp is dead")
		return
	on = not on
	visible = on
	# The switch itself is a small sound; the beam pulses while it stays on.
	Network.report_disturbance(global_position, toggle_noise_radius * _noise_scale())
	EventBus.toast_requested.emit(
		"Spore-lamp %s (%d%%)" % ["on" if on else "off", roundi(battery_ratio() * 100.0)]
	)


func is_on() -> bool:
	return on


func battery_ratio() -> float:
	return clampf(battery / maxf(battery_seconds, 0.01), 0.0, 1.0)


## Near-empty stutter, so "the battery is going" is visible without a HUD bar.
func _flicker() -> void:
	if battery_ratio() > 0.20:
		light_energy = _base_energy
		return
	var t := Time.get_ticks_msec() / 1000.0
	light_energy = _base_energy * (0.55 + 0.45 * absf(sin(t * 9.0)))


## A non-leader's lamp is inert: no toggle, no drain, no beam.
func _apply_role() -> void:
	var body := _body()
	if body == null:
		return
	if Party.is_leader(body):
		set_process(true)
		return
	if on:
		on = false
		visible = false
		light_energy = _base_energy
	set_process(false)


func _on_leader_changed(_peer_id: int) -> void:
	_apply_role()


func _body() -> Node3D:
	var node := get_parent()
	while node != null:
		if node.is_in_group(&"player"):
			return node as Node3D
		node = node.get_parent()
	return null


func _ui_blocked() -> bool:
	var body := _body()
	return body != null and "ui_blocking" in body and bool(body.get(&"ui_blocking"))
