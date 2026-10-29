extends SceneTree
## Headless test for the smooth scroll-wheel zoom and the first-person camera.
##
## The real player scene is driven on a plain floor. `PlayerController` eases the
## spring arm in `_process`, so the suite turns that process off and calls
## `advance_zoom()` by hand: a single step has to be inspectable, which a live
## per-frame ease is not. Everything asserted here is what a player sees: the
## clamped zoom range, the glide instead of a snap, the head/cap meshes that
## disappear exactly at the threshold and come back exactly as they were, the
## raised arms, the club and held prop still attached to the posed hands, and a
## third-person arm that still shortens against a wall.

const PLAYER_SCENE_PATH := "res://scenes/player/player.tscn"
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")
## One 60 Hz frame, for a deterministic dolly step.
const FRAME := 1.0 / 60.0
## Step used when the suite drives several frames at once; only the direction
## matters, the ease is exponential.
const STEP := 0.1
## The head meshes that would fill the lens in first person.
const HEAD_MESHES: Array[StringName] = [
	&"head_box", &"cap_rim", &"cap_mid", &"cap_top", &"cap_crown", &"eye_l", &"eye_r"
]

var _failures := 0
var _player: CharacterBody3D = null
var _arm: SpringArm3D = null
var _camera: Camera3D = null
var _visual: Node3D = null


func _initialize() -> void:
	TestEnv.isolate("test_fp_camera")
	_run()


func _finalize() -> void:
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
	await physics_frame
	await process_frame
	# The body stays put; the camera is the only thing under test.
	_player.set_physics_process(false)
	_player.set_process(false)
	_visual = _player.get_node_or_null("Model/Visual") as Node3D
	_arm = _player.get_node_or_null("CameraPivot/SpringArm3D") as SpringArm3D
	_camera = _player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
	_check("the player exposes its spring arm", _arm != null)
	_check("the player exposes its camera", _camera != null)
	if _arm == null or _camera == null or _visual == null:
		_finish()
		return
	# Let the animator settle into idle before any pose is sampled.
	await _wait(0.4)

	_check_zoom_bounds()
	await _check_zoom_easing()
	_check_input_map()
	await _check_head_visibility()
	await _check_arm_pose()
	await _check_attachments()
	await _check_spring_collision()
	_finish()


## The wheel target is clamped at both ends of the range and cannot be aimed
## past the eyes or past the widest third-person pull-back.
func _check_zoom_bounds() -> void:
	_player.call(&"set_zoom_target", 99.0)
	var far := float(_player.call(&"get_zoom_target"))
	_check(
		"the zoom target stops at zoom_max (%.2f m)" % far,
		is_equal_approx(far, float(_player.get("zoom_max")))
	)
	_player.call(&"set_zoom_target", -99.0)
	var near := float(_player.call(&"get_zoom_target"))
	_check(
		"the zoom target stops at first_person_distance (%.2f m)" % near,
		is_equal_approx(near, float(_player.get("first_person_distance")))
	)
	_check(
		"the range really reaches the eyes (near %.2f m)" % near,
		near <= 0.15 and float(_player.get("zoom_max")) >= 8.0
	)
	_player.call(&"set_zoom_target", 4.0)


## A wheel tick must glide: one step covers part of the gap, never all of it.
func _check_zoom_easing() -> void:
	var far := float(_player.get("zoom_max"))
	var near := float(_player.get("first_person_distance"))
	_arm.spring_length = 4.0
	_player.call(&"set_zoom_target", far)
	_player.call(&"advance_zoom", FRAME)
	var out := _arm.spring_length
	print("one 1/60 s step from 4.00 toward 8.00: %.4f" % out)
	_check("one step moves toward the target (%.3f m)" % out, out > 4.0)
	_check("one step does not snap to the target (%.3f m)" % out, out < far)
	_player.call(&"advance_zoom", FRAME)
	_check(
		"the next step keeps closing the gap (%.3f m)" % _arm.spring_length,
		_arm.spring_length > out and _arm.spring_length < far
	)

	var before := _arm.spring_length
	_player.call(&"set_zoom_target", near)
	_player.call(&"advance_zoom", FRAME)
	_check(
		"the same ease pulls in (%.3f m)" % _arm.spring_length,
		_arm.spring_length < before and _arm.spring_length > near
	)

	# Put the arm back at the default distance for the framing checks.
	_player.call(&"set_zoom_target", 4.0)
	_arm.spring_length = 4.0
	_player.call(&"advance_zoom", 0.0)


## The wheel has to be a real input action rather than a raw button check, and
## first person has to widen the pitch clamp the third-person arm needs.
func _check_input_map() -> void:
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_WHEEL_UP
	up.pressed = true
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	down.pressed = true
	_check("wheel up is bound to the zoom_in action", InputMap.event_is_action(up, &"zoom_in"))
	_check("wheel down is bound to the zoom_out action", InputMap.event_is_action(down, &"zoom_out"))

	var low := float(_player.get("fp_min_pitch"))
	var high := float(_player.get("fp_max_pitch"))
	print("first-person pitch limits: %.0f..%.0f degrees" % [low, high])
	_check(
		"first person allows a wider pitch (%.0f..%.0f)" % [low, high],
		low <= -85.0 and high >= 85.0
	)
	_check(
		"the third-person cone is still the narrower one (%.0f..%.0f)" % [
			float(_player.get("min_pitch")), float(_player.get("max_pitch"))
		],
		float(_player.get("min_pitch")) > low and float(_player.get("max_pitch")) < high
	)


## Crossing the threshold hides every head/cap/eye mesh; leaving puts each one
## back at the visibility it had before, including a mesh that was already off.
func _check_head_visibility() -> void:
	var meshes := _head_meshes()
	_check(
		"the rig exposes all seven head meshes (%d)" % meshes.size(),
		meshes.size() == HEAD_MESHES.size()
	)
	if meshes.size() != HEAD_MESHES.size():
		return
	var before := {}
	for mesh in meshes:
		before[mesh] = mesh.visible
	# A mesh an artist hid is not a mesh the camera may switch back on.
	meshes[2].visible = false
	before[meshes[2]] = false

	await _enter_first_person()
	_check("the view is first person below the threshold", bool(_player.call(&"is_first_person")))
	_check(
		"the arm is inside the first-person threshold (%.2f m)" % _arm.spring_length,
		_arm.spring_length <= float(_player.get("first_person_threshold"))
	)
	for mesh in meshes:
		_check("%s is hidden in first person" % mesh.name, not mesh.visible)
	_check("the spring arm stops colliding in first person", _arm.collision_mask == 0)
	var head := _visual.find_child("head", true, false) as Node3D
	if head != null:
		var distance := _camera.global_position.distance_to(head.global_position)
		print("camera to head bone in first person: %.3f m" % distance)
		_check("the camera sits at the head (%.3f m)" % distance, distance < 0.35)

	await _leave_first_person()
	_check("the view is third person again", not bool(_player.call(&"is_first_person")))
	var exit_distance := (
		float(_player.get("first_person_threshold")) + float(_player.get("fp_exit_margin"))
	)
	_check(
		"the arm grew past the exit margin (%.2f m)" % _arm.spring_length,
		_arm.spring_length > exit_distance
	)
	_check("the spring arm collides again in third person", _arm.collision_mask != 0)
	for mesh in meshes:
		_check(
			"%s visibility is restored (%s)" % [mesh.name, mesh.visible],
			mesh.visible == bool(before[mesh])
		)
	meshes[2].visible = true


## The upper arms are raised while the view is first person and the animation
## takes them back when it leaves. This is the ordering the AnimationPlayer
## would win if the helper did not run after it.
func _check_arm_pose() -> void:
	var left := _visual.find_child("arm_upper_left2", true, false) as Node3D
	var right := _visual.find_child("arm_upper_right2", true, false) as Node3D
	var hand := _visual.find_child("hand_right2", true, false) as Node3D
	_check("the rig has both upper-arm bones", left != null and right != null)
	if left == null or right == null:
		return
	await _wait(0.3)
	var rest_left := left.rotation.x
	var rest_right := right.rotation.x

	await _enter_first_person()
	await _wait(0.5)
	var posed_left := left.rotation.x
	var posed_right := right.rotation.x
	print("upper arm pitch: third person %.2f / %.2f rad, first person %.2f / %.2f rad" % [
		rest_left, rest_right, posed_left, posed_right
	])
	_check(
		"the left arm is raised in first person (%.2f rad)" % posed_left,
		absf(posed_left - rest_left) > 0.5
	)
	_check(
		"the right arm is raised in first person (%.2f rad)" % posed_right,
		absf(posed_right - rest_right) > 0.5
	)
	if hand != null:
		_check(
			"the right wrist is rolled so the club points forward (%.2f rad)" % hand.rotation.z,
			absf(hand.rotation.z) > 0.5
		)

	await _leave_first_person()
	await _wait(0.5)
	var back_left := left.rotation.x
	var back_right := right.rotation.x
	print("upper arm pitch after leaving: %.2f / %.2f rad" % [back_left, back_right])
	_check(
		"the left arm returns to its clip pose (%.2f rad)" % back_left,
		absf(back_left - rest_left) < 0.15
	)
	_check(
		"the right arm returns to its clip pose (%.2f rad)" % back_right,
		absf(back_right - rest_right) < 0.15
	)


## The club and the held prop copy the hand bones, so they have to stay visible
## and stay welded to the posed hand in first person.
func _check_attachments() -> void:
	_player.set(&"held_item", &"konop")
	await _wait(0.3)
	var weapon := _player.get_node_or_null("Weapon") as Node3D
	var held := _player.get_node_or_null("HeldItem") as Node3D
	var club: Node3D = null
	if weapon != null:
		club = weapon.get_node_or_null("Club") as Node3D
	var hand := _visual.find_child("hand_right2", true, false) as Node3D
	var left_hand := _visual.find_child("hand_left2", true, false) as Node3D
	_check("the club is built", club != null)
	_check("the held prop is drawn", held != null and held.get_child_count() > 0)
	if club == null or held == null or hand == null or left_hand == null:
		return

	await _enter_first_person()
	await _wait(0.4)
	_check("the club stays visible in first person", club.is_visible_in_tree())
	_check("the held prop stays visible in first person", held.is_visible_in_tree())
	var club_gap := club.global_position.distance_to(hand.global_position)
	var held_gap := held.global_position.distance_to(left_hand.global_position)
	print("club-to-right-hand %.3f m, held-to-left-hand %.3f m" % [club_gap, held_gap])
	_check("the club follows the posed right hand (%.3f m)" % club_gap, club_gap < 0.2)
	_check("the held prop follows the posed left hand (%.3f m)" % held_gap, held_gap < 0.25)

	await _leave_first_person()
	_player.set(&"held_item", &"")
	await _wait(0.2)


## Third-person framing keeps the spring arm's collision: a wall behind the
## player still pulls the camera in, even though the zoom can now reach the eyes.
func _check_spring_collision() -> void:
	var far := float(_player.get("zoom_max"))
	_player.call(&"set_zoom_target", far)
	_arm.spring_length = far
	_player.call(&"advance_zoom", 0.0)
	_check("a wheel at the far end stays third person", not bool(_player.call(&"is_first_person")))

	# Look straight down the arm so the wall behind the player is what it hits.
	var pivot := _player.get_node_or_null("CameraPivot") as Node3D
	if pivot == null:
		_check("the player has a camera pivot", false)
		return
	pivot.rotation.y = 0.0
	_arm.rotation.x = 0.0
	_player.set(&"_pitch", 0.0)

	var wall := StaticBody3D.new()
	wall.name = "TestWall"
	wall.collision_layer = 1
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 4.0, 0.2)
	shape.shape = box
	wall.add_child(shape)
	root.add_child(wall)
	wall.global_position = _player.global_position + Vector3(0.0, 1.5, 2.5)
	await _wait(0.2)

	var hit := _arm.get_hit_length()
	print("spring_length=%.3f m, hit_length=%.3f m" % [_arm.spring_length, hit])
	_check(
		"a wall behind the player shortens the arm (%.2f of %.2f m)" % [hit, _arm.spring_length],
		hit < _arm.spring_length - 0.5
	)
	_check("the wall is where the test put it (%.2f m)" % hit, hit > 1.0 and hit < 3.0)
	var camera_gap := _camera.global_position.distance_to(pivot.global_position)
	_check(
		"the camera is pulled inside the wall (%.2f m from the pivot)" % camera_gap,
		camera_gap < 3.0
	)
	wall.queue_free()
	await _wait(0.1)


func _head_meshes() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for name in HEAD_MESHES:
		for node: Node in _visual.find_children(String(name), "MeshInstance3D", true, false):
			var mesh := node as MeshInstance3D
			if mesh != null:
				result.append(mesh)
	return result


## Drives the dolly to the near end, through the same `advance_zoom` seam the
## `_process` callback uses.
func _enter_first_person() -> void:
	var near := float(_player.get("first_person_distance"))
	_player.call(&"set_zoom_target", near)
	for _step in 200:
		_player.call(&"advance_zoom", STEP)
		if _arm.spring_length <= near + 0.01:
			break
	await _wait(0.05)


func _leave_first_person() -> void:
	_player.call(&"set_zoom_target", float(_player.get("zoom_max")))
	for _step in 200:
		_player.call(&"advance_zoom", STEP)
		if not bool(_player.call(&"is_first_person")):
			break
	await _wait(0.05)


## A 200 m slab with its top at y = 0, so nothing falls out of the world.
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


func _wait(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all first-person camera assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
