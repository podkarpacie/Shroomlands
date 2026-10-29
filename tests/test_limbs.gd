extends SceneTree
## Headless procedural-limb test, on the body that still uses `LimbAnimator`:
## footfall signal, the gait swing, the transient bite pose and turn bank.
##
## The player is rigged and keyframed now (`PlayerAnimator` drives the clips in
## `player_rigged.gltf`), so the only procedural animator left in the game is the
## blightling's. The harness moves that body itself — the animator reads speed and
## heading from the body's own position deltas, so moving the body is the whole
## setup — and switches its AI off so the gait is deterministic.

const ENEMY_SCENE_PATH := "res://scenes/world/enemy.tscn"
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")
## Speed the harness walks the creature at, in m/s.
const DRIVE_SPEED := 3.0

var _failures := 0
var _enemy: CharacterBody3D = null
var _animator: Node = null
var _visual: Node3D = null
var _feet: Array[int] = []


func _initialize() -> void:
	TestEnv.isolate("test_limbs")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	_make_floor()
	var packed := load(ENEMY_SCENE_PATH) as PackedScene
	_check("enemy.tscn loads", packed != null)
	if packed == null:
		_finish()
		return
	_enemy = packed.instantiate() as CharacterBody3D
	_enemy.position = Vector3(0.0, 1.0, 0.0)
	root.add_child(_enemy)
	await physics_frame
	# The AI would chase its own wander target; the harness owns the movement.
	_enemy.set_physics_process(false)

	_animator = _enemy.get_node_or_null("Animator")
	_visual = _enemy.get_node_or_null("Model/Visual") as Node3D
	_check("the blightling has an Animator", _animator != null)
	_check("the blightling has Model/Visual", _visual != null)
	if _animator == null or _visual == null:
		_finish()
		return
	_check(
		"the blightling still runs the procedural LimbAnimator",
		_animator.get_script() != null
			and String(_animator.get_script().resource_path).ends_with("LimbAnimator.gd")
	)
	_check("the animator declares stepped(foot)", _animator.has_signal(&"stepped"))
	if not _animator.has_signal(&"stepped"):
		_finish()
		return
	_animator.connect(&"stepped", _on_stepped)

	await _check_footsteps()
	await _check_limb_swing()
	await _check_bite_pose()
	await _check_turn_bank()
	_finish()


func _on_stepped(foot: int) -> void:
	_feet.append(foot)


## Two steps per gait cycle while walking, and silence once the body stands.
func _check_footsteps() -> void:
	_feet.clear()
	await _drive(Vector3.RIGHT, DRIVE_SPEED, 2.0)
	var walked := _feet.size()
	_check("stepped fires while walking (%d events over 2 s)" % walked, walked >= 2)
	var alternates := walked >= 2
	for index in range(1, walked):
		if _feet[index] == _feet[index - 1]:
			alternates = false
	_check("the steps alternate feet (%s)" % str(_feet), alternates)

	await _settle()
	_feet.clear()
	var deadline := Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < deadline:
		await physics_frame
	_check("no footsteps while standing still (%d)" % _feet.size(), _feet.is_empty())
	await _settle()


## Both arms keep the full procedural swing: only the player's weapons arm was
## damped, and that body no longer carries a `LimbAnimator`.
func _check_limb_swing() -> void:
	var arm_l := _visual.find_child("arm_l", true, false) as Node3D
	var arm_r := _visual.find_child("arm_r", true, false) as Node3D
	_check("the model has arm_l and arm_r", arm_l != null and arm_r != null)
	if arm_l == null or arm_r == null:
		return

	var ranges: Array = await _swing_ranges(arm_l, arm_r, DRIVE_SPEED, 1.2)
	var left_range := float(ranges[0])
	var right_range := float(ranges[1])
	_check("the left arm swings while walking (%.2f rad)" % left_range, left_range > 0.3)
	_check("the right arm swings too (%.2f rad)" % right_range, right_range > 0.3)
	await _settle()


## `play_bite` is the creature's transient pose: both arms thrown forward on top
## of the gait. Standing still, that has to read as a clear change of pose.
func _check_bite_pose() -> void:
	var arm_l := _visual.find_child("arm_l", true, false) as Node3D
	var arm_r := _visual.find_child("arm_r", true, false) as Node3D
	if arm_l == null or arm_r == null:
		return
	var rest_l := arm_l.rotation.x
	var rest_r := arm_r.rotation.x
	_check(
		"the creature can play its bite pose",
		_animator.has_method(&"play_bite")
	)
	if not _animator.has_method(&"play_bite"):
		return
	_animator.call(&"play_bite")
	var peak := 0.0
	var deadline := Time.get_ticks_msec() + 400
	while Time.get_ticks_msec() < deadline:
		await process_frame
		peak = maxf(peak, absf(arm_l.rotation.x - rest_l))
		peak = maxf(peak, absf(arm_r.rotation.x - rest_r))
	_check("the bite throws both arms forward (%.2f rad)" % peak, peak > 0.4)
	await _settle()


## A heading change banks the visual, and the bank levels out when it stops.
func _check_turn_bank() -> void:
	await _drive(Vector3.RIGHT, DRIVE_SPEED, 0.8)
	# A 90 degree turn into +Z, one physics tick at a time.
	var peak := 0.0
	var tick := 1.0 / float(Engine.physics_ticks_per_second)
	var deadline := Time.get_ticks_msec() + 700
	while Time.get_ticks_msec() < deadline:
		await physics_frame
		_enemy.global_position += Vector3.FORWARD * DRIVE_SPEED * tick
		peak = maxf(peak, absf(_visual.rotation.z))
	_check("turning banks the visual (%.3f rad)" % peak, peak > deg_to_rad(1.0))

	await _settle()
	_check(
		"the bank settles back to level (%.4f rad)" % absf(_visual.rotation.z),
		absf(_visual.rotation.z) < deg_to_rad(0.5)
	)
	await _settle()


## Range (max - min) of both arms' X rotation, while the body is driven forward.
func _swing_ranges(left: Node3D, right: Node3D, speed: float, seconds: float) -> Array:
	var tick := 1.0 / float(Engine.physics_ticks_per_second)
	var step := Vector3.RIGHT * speed * tick
	var left_low := 99.0
	var left_high := -99.0
	var right_low := 99.0
	var right_high := -99.0
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await physics_frame
		_enemy.global_position += step
		var left_angle := left.transform.basis.get_euler().x
		var right_angle := right.transform.basis.get_euler().x
		left_low = minf(left_low, left_angle)
		left_high = maxf(left_high, left_angle)
		right_low = minf(right_low, right_angle)
		right_high = maxf(right_high, right_angle)
	return [left_high - left_low, right_high - right_low]


## Moves the body `speed` m/s along `direction` for `seconds`, one physics tick at
## a time, so `LimbAnimator` sees a real position delta.
func _drive(direction: Vector3, speed: float, seconds: float) -> void:
	var tick := 1.0 / float(Engine.physics_ticks_per_second)
	var step := direction.normalized() * speed * tick
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await physics_frame
		_enemy.global_position += step


## A 200 m slab with its top at y = 0, so a drive never runs out of ground.
func _make_floor() -> void:
	var body := StaticBody3D.new()
	body.name = "TestFloor"
	body.collision_layer = 1
	body.position = Vector3(0.0, -0.5, 0.0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	shape.shape = box
	body.add_child(shape)
	root.add_child(body)


## Waits until the gait has decayed: the animator smooths speed over ~0.3 s.
func _settle() -> void:
	_feet.clear()
	var deadline := Time.get_ticks_msec() + 600
	while Time.get_ticks_msec() < deadline:
		await physics_frame
	_feet.clear()


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all limb-animation assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
