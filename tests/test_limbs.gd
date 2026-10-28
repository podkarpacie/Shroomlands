extends SceneTree
## Headless limb-animation test: footfall signal, club carry pose and turn bank.
##
## The real player scene walks on a plain floor built here, so the gait runs on a
## known surface instead of world terrain. The animator reads speed and heading
## from the body's own position deltas, so moving the body is the whole setup.

const PLAYER_SCENE_PATH := "res://scenes/player/player.tscn"
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")
## The club-carrying arm keeps `carry_swing_scale` of the swing; the test allows
## some slack for the idle sway riding on top.
const CARRY_LIMIT := 0.7

var _failures := 0
var _player: CharacterBody3D = null
var _animator: Node = null
var _visual: Node3D = null
var _feet: Array[int] = []


func _initialize() -> void:
	TestEnv.isolate("test_limbs")
	_run()


func _finalize() -> void:
	_release_all()
	TestEnv.restore_all()


func _run() -> void:
	_make_floor()
	var packed := load(PLAYER_SCENE_PATH) as PackedScene
	_check("player.tscn loads", packed != null)
	if packed == null:
		_finish()
		return
	_player = packed.instantiate() as CharacterBody3D
	_player.position = Vector3(0.0, 1.0, 0.0)
	root.add_child(_player)
	await _settle()

	_animator = _player.get_node_or_null("Animator")
	_visual = _player.get_node_or_null("Model/Visual") as Node3D
	_check("the player has an Animator", _animator != null)
	_check("the player has Model/Visual", _visual != null)
	if _animator == null or _visual == null:
		_finish()
		return
	_check("the animator declares stepped(foot)", _animator.has_signal(&"stepped"))
	_check("the body starts grounded", _player.is_on_floor())
	if not _animator.has_signal(&"stepped"):
		_finish()
		return
	_animator.connect(&"stepped", _on_stepped)

	await _check_footsteps()
	await _check_carry_pose()
	await _check_turn_bank()
	_finish()


func _on_stepped(foot: int) -> void:
	_feet.append(foot)


## Two steps per gait cycle while walking, and silence once the body stands.
func _check_footsteps() -> void:
	_feet.clear()
	Input.action_press(&"move_forward")
	await create_timer(2.0).timeout
	Input.action_release(&"move_forward")
	var walked := _feet.size()
	_check("stepped fires while walking (%d events over 2 s)" % walked, walked >= 2)
	var alternates := walked >= 2
	for index in range(1, walked):
		if _feet[index] == _feet[index - 1]:
			alternates = false
	_check("the steps alternate feet (%s)" % str(_feet), alternates)

	await _settle()
	_feet.clear()
	await create_timer(1.0).timeout
	_check("no footsteps while standing still (%d)" % _feet.size(), _feet.is_empty())


## The club arm holds a carry angle and keeps ~40 % of the walk swing; the free
## arm keeps its full swing.
func _check_carry_pose() -> void:
	var arm_l := _visual.find_child("arm_l", true, false) as Node3D
	var arm_r := _visual.find_child("arm_r", true, false) as Node3D
	_check("the model has arm_l and arm_r", arm_l != null and arm_r != null)
	_check("the body carries the club (Weapon node)", _player.get_node_or_null("Weapon") != null)
	if arm_l == null or arm_r == null:
		return

	Input.action_press(&"move_forward")
	await create_timer(0.5).timeout
	var ranges: Array = await _swing_ranges(arm_l, arm_r, 1.2)
	Input.action_release(&"move_forward")
	var left_range := float(ranges[0])
	var right_range := float(ranges[1])
	_check("the free left arm swings while walking (%.2f rad)" % left_range, left_range > 0.3)
	_check(
		"the carrying right arm swings less (%.2f vs %.2f rad)" % [right_range, left_range],
		right_range > 0.05 and right_range < left_range * CARRY_LIMIT
	)
	await _settle()


## A heading change banks the visual and the bank levels out when it stops.
func _check_turn_bank() -> void:
	Input.action_press(&"move_forward")
	await create_timer(0.8).timeout
	Input.action_release(&"move_forward")
	Input.action_press(&"move_right")
	var peak := 0.0
	var deadline := Time.get_ticks_msec() + 600
	while Time.get_ticks_msec() < deadline:
		await process_frame
		peak = maxf(peak, absf(_visual.rotation.z))
	Input.action_release(&"move_right")
	_check("turning banks the visual (%.3f rad)" % peak, peak > deg_to_rad(1.0))

	await _settle()
	await create_timer(0.5).timeout
	_check(
		"the bank settles back to level (%.4f rad)" % absf(_visual.rotation.z),
		absf(_visual.rotation.z) < deg_to_rad(0.5)
	)


## Range (max - min) of both arms' X rotation over `seconds` of real frames.
func _swing_ranges(left: Node3D, right: Node3D, seconds: float) -> Array:
	var left_low := 99.0
	var left_high := -99.0
	var right_low := 99.0
	var right_high := -99.0
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var left_angle := left.transform.basis.get_euler().x
		var right_angle := right.transform.basis.get_euler().x
		left_low = minf(left_low, left_angle)
		left_high = maxf(left_high, left_angle)
		right_low = minf(right_low, right_angle)
		right_high = maxf(right_high, right_angle)
	return [left_high - left_low, right_high - right_low]


## A 200 m slab with its top at y = 0, so the walk never runs out of ground.
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


## Waits (releasing every key) until the body stands still on the floor.
func _settle() -> void:
	_release_all()
	for _frame in 120:
		await physics_frame
		if _player.is_on_floor() and _player.velocity.length() < 0.05:
			break
	for _frame in 3:
		await physics_frame


func _release_all() -> void:
	for action: StringName in [&"move_forward", &"move_back", &"move_left", &"move_right", &"sprint"]:
		if Input.is_action_pressed(action):
			Input.action_release(action)


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
