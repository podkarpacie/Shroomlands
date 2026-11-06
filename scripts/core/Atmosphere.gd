extends Node
## Quiet, dynamic horror bed and the local danger meter.
##
## A random creak/whisper/drip every few seconds and a heartbeat that speeds up
## as HP falls or a creature closes in. The screen grade reads `danger_level()`
## so the vignette and the sound react to the same number. Audio output is off
## in headless runs, where `play_sfx` is a no-op; the danger math still runs.

const AMBIENT_CUES: Array[StringName] = [&"creak", &"whisper", &"drip"]

var _danger := 0.0
var _ambient_left := 8.0
var _heart_left := 0.0
var _poll_left := 0.0


func _ready() -> void:
	add_to_group(&"atmosphere")
	_ambient_left = randf_range(5.0, 10.0)


func _process(delta: float) -> void:
	_poll_left -= delta
	if _poll_left <= 0.0:
		_poll_left = 0.25
		_danger = _compute_danger()
		if Audio.has_method(&"set_ambient_danger"):
			Audio.set_ambient_danger(_danger)

	_ambient_left -= delta
	if _ambient_left <= 0.0:
		_ambient_left = _next_ambient_delay()
		var cue: StringName = AMBIENT_CUES[randi() % AMBIENT_CUES.size()]
		Audio.play_sfx(cue, 0.08, randf_range(-26.0, -18.0))

	if _danger > 0.22:
		_heart_left -= delta
		if _heart_left <= 0.0:
			_heart_left = lerpf(1.7, 0.55, clampf(_danger, 0.0, 1.0))
			Audio.play_sfx(&"heartbeat", 0.0, lerpf(-24.0, -10.0, _danger))
	else:
		_heart_left = 0.0


func danger_level() -> float:
	return _danger


## 0 = safe, 1 = a creature on top of the player or the health bar nearly empty.
func _compute_danger() -> float:
	var player := Game.get_local_player() as Node3D
	if player == null:
		return 0.0
	var stats := player.get_node_or_null("Stats")
	var hp_ratio := 1.0
	if stats != null:
		hp_ratio = clampf(
			float(stats.get(&"hp")) / maxf(float(stats.get(&"max_hp")), 1.0), 0.0, 1.0
		)
	var threat := 0.0
	for node: Node in get_tree().get_nodes_in_group(&"enemy"):
		var body := node as Node3D
		if body == null:
			continue
		var offset := body.global_position - player.global_position
		var distance := Vector2(offset.x, offset.z).length()
		threat = maxf(threat, clampf(1.0 - distance / 20.0, 0.0, 1.0))
	return clampf(maxf(1.0 - hp_ratio, threat), 0.0, 1.0)


func _next_ambient_delay() -> float:
	if Game.forest_layer > 0:
		return randf_range(6.0, 14.0)
	return randf_range(16.0, 30.0)
