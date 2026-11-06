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
var _alert_left := 0.0
var _warned_low := false
var _warned_empty := false


func _ready() -> void:
	battery = battery_seconds
	_base_energy = light_energy
	on = false
	visible = false


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
			EventBus.disturbance_emitted.emit(global_position, alert_radius)
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
	if battery <= 0.0:
		EventBus.toast_requested.emit("The spore-lamp is dead")
		return
	on = not on
	visible = on
	# The switch itself is a small sound; the beam pulses while it stays on.
	EventBus.disturbance_emitted.emit(global_position, toggle_noise_radius)
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


func _ui_blocked() -> bool:
	var node := get_parent()
	while node != null:
		if "ui_blocking" in node:
			return bool(node.get(&"ui_blocking"))
		node = node.get_parent()
	return false
