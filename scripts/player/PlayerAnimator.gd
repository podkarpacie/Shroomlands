extends Node
## Keyframed animation for the rigged player (`assets/models/player_rigged.gltf`).
##
## The imported glTF ships its own `AnimationPlayer` below `Model/Visual` with
## six authored clips: `idle`, `walk` and `run` are the gaits, while `attack`,
## `draw` and `holster` are one-shots that play over locomotion and hand control
## back when they finish. The rig is not skinned — every clip animates the bone
## nodes directly — so nothing here touches a mesh or a material.
##
## Speed comes from how far the body actually moved between physics ticks, not
## from `velocity`, exactly like the procedural `LimbAnimator` this replaces: a
## replicated body only receives a position, and still has to animate.
##
## Two one-shots are driven by replicated state instead of a local call, so the
## other peers see them too: `draw`/`holster` follow the `held_item` transitions
## (debounced, so scrolling the hotbar does not rattle the arm) and `attack`
## follows the `swing_seq` counter the attacker increments in `CombatSystem`.
##
## Footfalls are reported on `stepped` at fixed phases of the walk/run clip, so
## `AudioManager` keeps wiring the player's footsteps through the same signal the
## blightling's `LimbAnimator` emits.
##
## The node is still called `Animator` under the body: `CombatSystem` resolves
## that path to ask for a swing pose. A model without an `AnimationPlayer`, or
## missing a clip, warns once and disables itself instead of crashing.

## Emitted on every footfall while walking or running: alternating left (0) and
## right (1), two per gait cycle. Read-side only.
signal stepped(foot: int)

const IDLE := &"idle"
const WALK := &"walk"
const RUN := &"run"
const ATTACK := &"attack"
const DRAW := &"draw"
const HOLSTER := &"holster"
const CLIPS: Array[StringName] = [IDLE, WALK, RUN, ATTACK, DRAW, HOLSTER]
## The clips that loop; the exporter writes all six as one-shots.
const GAITS: Array[StringName] = [IDLE, WALK, RUN]
## Playback phase of the gait a footfall lands on.
const STEP_FRACTIONS: Array[float] = [0.25, 0.75]

@export var visual_path: NodePath = ^"../Model/Visual"
## Below this measured speed the body breathes in place.
@export var idle_speed := 0.15
## At or above this measured speed the body runs.
@export var run_speed := 6.0
## Crossfade between two gaits, in seconds.
@export var blend_time := 0.15
## Crossfade into and out of a one-shot, in seconds.
@export var one_shot_blend := 0.08
## A newer draw/holster is skipped when the previous one started less than this
## long ago, so scrolling the hotbar does not machine-gun the arm.
@export var hold_debounce_msec := 200

var _player: Node3D = null
var _player_animation: AnimationPlayer = null
var _disabled := false
## Clip last commanded to the player, so a repeated request is not a restart.
var _current: StringName = &""
## One-shot playing over locomotion; empty when the gaits own the rig.
var _one_shot: StringName = &""
## 0 = no swing, 1 = the attack one-shot. The same contract the procedural
## `LimbAnimator` exposed, so `CombatSystem`'s tooling can still ask.
var _attack_kind := 0

var _last_position := Vector3.ZERO
var _instant_speed := 0.0
var _instant_vy := 0.0
var _speed := 0.0
var _vy := 0.0
var _last_sequence := 0
var _had_item := false
var _hold_quiet_until_msec := 0
## Playback fraction of the gait clip last frame, for the footfall crossings.
var _last_fraction := 0.0
var _step_foot := 0


func _ready() -> void:
	_player = get_parent() as Node3D
	var visual := get_node_or_null(visual_path) as Node3D
	if _player == null or visual == null:
		_disable("no body or no '%s' below it" % visual_path)
		return
	_player_animation = visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _player_animation == null:
		_disable("no AnimationPlayer below '%s'" % visual_path)
		return
	var missing: PackedStringArray = []
	for clip in CLIPS:
		if not _player_animation.has_animation(clip):
			missing.append(String(clip))
	if not missing.is_empty():
		_disable("missing clip(s) %s" % ", ".join(missing))
		return
	# The loops are a property of the clip, not of the model, so they are set on
	# the loaded resource here; every instance writes the same value.
	for clip in GAITS:
		_player_animation.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	# A glTF with a single clip autoplays it; this one is driven frame by frame.
	_player_animation.stop()
	_player_animation.animation_finished.connect(_on_animation_finished)
	_last_position = _player.global_position
	_last_sequence = _read_sequence()
	_had_item = _read_holds_item()
	_play(IDLE, 0.0)


## Player swing. `CombatSystem` calls it on the attacker for zero-latency local
## feedback; every other peer picks the same swing up from `swing_seq`.
func play_attack(_heavy := false) -> void:
	# The caller has just incremented the counter: adopt it, so `_process` does
	# not replay the same swing on the next frame.
	_last_sequence = _read_sequence()
	_start_one_shot(ATTACK)


func _physics_process(delta: float) -> void:
	if _disabled or delta <= 0.0:
		return
	var moved := _player.global_position - _last_position
	_last_position = _player.global_position
	_instant_speed = Vector2(moved.x, moved.z).length() / delta
	_instant_vy = moved.y / delta


func _process(delta: float) -> void:
	if _disabled:
		return
	var follow := 1.0 - exp(-14.0 * delta)
	_speed = lerpf(_speed, _instant_speed, follow)
	_vy = lerpf(_vy, _instant_vy, follow)

	var sequence := _read_sequence()
	if sequence != _last_sequence:
		_last_sequence = sequence
		play_attack()
	_check_held_item()
	if _one_shot.is_empty():
		_play(_locomotion(), blend_time)
		_advance_steps()


## Gait for the current smoothed speed.
func _locomotion() -> StringName:
	if _speed < idle_speed:
		return IDLE
	if _speed < run_speed:
		return WALK
	return RUN


## A footfall every time playback crosses one of `STEP_FRACTIONS`, including the
## crossing the wrap back to zero hides.
func _advance_steps() -> void:
	if _current != WALK and _current != RUN:
		_last_fraction = 0.0
		return
	var fraction := _playback_fraction()
	if _is_airborne():
		# Airborne, but the clip keeps looping: swallow the crossings.
		_last_fraction = fraction
		return
	var previous := _last_fraction
	if fraction < previous:
		for phase in STEP_FRACTIONS:
			if previous < phase or phase <= fraction:
				_footfall()
	else:
		for phase in STEP_FRACTIONS:
			if previous < phase and fraction >= phase:
				_footfall()
	_last_fraction = fraction


func _footfall() -> void:
	stepped.emit(_step_foot)
	_step_foot = 1 - _step_foot


func _playback_fraction() -> float:
	var length := _player_animation.current_animation_length
	if length <= 0.0:
		return 0.0
	return clampf(_player_animation.current_animation_position / length, 0.0, 1.0)


## `draw` when a prop enters the hand, `holster` when it leaves. A change between
## two different props is not a transition: the hand never empties.
func _check_held_item() -> void:
	var holds := _read_holds_item()
	if holds == _had_item:
		return
	_had_item = holds
	if Time.get_ticks_msec() < _hold_quiet_until_msec:
		return
	_hold_quiet_until_msec = Time.get_ticks_msec() + hold_debounce_msec
	_start_one_shot(DRAW if holds else HOLSTER)


func _start_one_shot(clip: StringName) -> void:
	_one_shot = clip
	_attack_kind = 1 if clip == ATTACK else 0
	if clip == _current:
		# A repeated swing has to start again from the wind-up, and it has no
		# other pose to blend from.
		_player_animation.stop()
	_current = clip
	_player_animation.play(clip, one_shot_blend)


func _on_animation_finished(anim_name: StringName) -> void:
	if _disabled or anim_name != _one_shot:
		return
	_one_shot = &""
	_attack_kind = 0
	_play(_locomotion(), blend_time)


func _play(clip: StringName, blend: float) -> void:
	if _player_animation == null or clip.is_empty() or clip == _current:
		return
	_current = clip
	if clip in GAITS:
		# A fresh gait starts at its first frame, so the footfall phases line up.
		_last_fraction = 0.0
	_player_animation.play(clip, blend)


## True when the body carries a non-empty `held_item`. Read with `get()`, so a
## body without the property simply never draws.
func _read_holds_item() -> bool:
	var value: Variant = _player.get(&"held_item")
	return typeof(value) == TYPE_STRING_NAME and value != &""


## Swing counter, replicated from the attacker. A body without it never swings.
func _read_sequence() -> int:
	var value: Variant = _player.get(&"swing_seq")
	return int(value) if typeof(value) == TYPE_INT else 0


## Mirrors `LimbAnimator`: the owning peer can ask the floor, a replicated body
## can only infer the jump from the vertical part of its position deltas.
func _is_airborne() -> bool:
	var body := _player as CharacterBody3D
	if body != null and body.is_multiplayer_authority():
		return not body.is_on_floor() and absf(_vy) > 0.6
	return absf(_vy) > 0.8


## Warns once and goes quiet: a model without the rig must not crash a body.
func _disable(reason: String) -> void:
	if _disabled:
		return
	_disabled = true
	push_warning("PlayerAnimator: %s; animation disabled." % reason)
	set_process(false)
	set_physics_process(false)
