extends SceneTree
## Headless checks for how the player *moves*: acceleration and braking, the
## sprint-jump fix, coyote time, the jump buffer, variable jump height, camera
## zoom and the procedural limb animation.
##
## `test_movement_block.gd` covers "the body ignores input while a UI is open";
## this covers the feel of the body when it is not.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _player: CharacterBody3D = null


func _initialize() -> void:
	TestEnv.isolate("test_movement")
	TestEnv.stash("user://plots.json")
	_run()


func _finalize() -> void:
	_release_all()
	TestEnv.restore_all()


func _run() -> void:
	var packed := load(MAIN_SCENE_PATH) as PackedScene
	_check("main.tscn loads", packed != null)
	if packed == null:
		_finish()
		return
	root.add_child(packed.instantiate())
	for _frame in 5:
		await physics_frame
	# Creatures would interrupt a long scripted run.
	for enemy in get_nodes_in_group(&"enemy"):
		enemy.set_physics_process(false)

	var players := get_nodes_in_group(&"player")
	_player = players[0] as CharacterBody3D if players.size() == 1 else null
	_check("a player was spawned", _player != null)
	if _player == null:
		_finish()
		return
	await _settle()
	_check("the player starts grounded", _player.is_on_floor())

	await _check_ground_feel()
	await _check_sprint_jump()
	await _check_coyote_time()
	await _check_jump_buffer()
	await _check_variable_jump()
	await _check_camera()
	await _check_animation()
	_finish()


# --- scenarios -----------------------------------------------------------------

func _check_ground_feel() -> void:
	var walk := float(_player.get("walk_speed"))
	Input.action_press(&"move_forward")
	await _frames(15)  # 0.25 s
	var reached := _horizontal_speed()
	_check("reaches walking speed within 0.25 s (%.2f of %.2f)" % [reached, walk], reached > walk * 0.95)
	_check("never exceeds walking speed (%.2f)" % reached, reached < walk + 0.05)
	Input.action_release(&"move_forward")
	await _frames(12)  # 0.2 s
	var braked := _horizontal_speed()
	_check("brakes to a stop within 0.2 s (%.2f m/s)" % braked, braked < 0.1)
	await _settle()


## The bug this patch fixes: `_wants_sprint` required the floor, so a sprint jump
## dropped to walk speed in mid-air and every running jump stalled.
func _check_sprint_jump() -> void:
	var walk := float(_player.get("walk_speed"))
	var sprint := float(_player.get("sprint_speed"))
	Input.action_press(&"move_forward")
	Input.action_press(&"sprint")
	await _frames(40)
	var running := _horizontal_speed()
	_check("sprinting reaches sprint speed (%.2f of %.2f)" % [running, sprint], running > sprint * 0.95)

	await _tap_jump()
	var slowest := 99.0
	var airborne_frames := 0
	for _frame in 50:
		await physics_frame
		if not _player.is_on_floor():
			airborne_frames += 1
			slowest = minf(slowest, _horizontal_speed())
	_check("the jump left the ground (%d frames in the air)" % airborne_frames, airborne_frames > 15)
	_check(
		"a sprint jump keeps its speed in the air (slowest %.2f, walk is %.2f)" % [slowest, walk],
		slowest > sprint * 0.9
	)
	_release_all()
	await _settle()

	# Sprint cannot be *started* in the air.
	Input.action_press(&"move_forward")
	await _frames(30)
	await _tap_jump()
	await _frames(6)
	Input.action_press(&"sprint")
	await _frames(10)
	_check("sprint cannot be started mid-air", not bool(_player.get("is_sprinting")))
	_release_all()
	await _settle()


func _check_coyote_time() -> void:
	var coyote := float(_player.get("coyote_time"))
	var up := float(_player.get("jump_velocity"))

	# Just off a ledge: still allowed to jump.
	_lift(3.0)
	await _frames(4)  # ~0.07 s, inside the window
	_check("airborne after the lift", not _player.is_on_floor())
	await _tap_jump()
	await physics_frame
	_check(
		"a jump just after leaving the ground still works (vy %.2f)" % _player.velocity.y,
		_player.velocity.y > up * 0.7
	)
	await _settle()

	# Long after: no mid-air jump.
	_lift(6.0)
	await _frames(int(ceil(coyote * 60.0)) + 8)
	await _tap_jump()
	await physics_frame
	_check(
		"no jump once the coyote window has passed (vy %.2f)" % _player.velocity.y,
		_player.velocity.y < 0.0
	)
	await _settle()


func _check_jump_buffer() -> void:
	var up := float(_player.get("jump_velocity"))
	# Press jump slightly before landing, *after* the coyote window has closed, so
	# only the buffer can explain a jump: it fires on touchdown.
	_lift(0.5)
	await _frames(10)
	_check("still falling when the key is pressed", not _player.is_on_floor())
	Input.action_press(&"jump")
	await _frames(2)
	Input.action_release(&"jump")
	var best_vy := -99.0
	for _frame in 20:
		await physics_frame
		best_vy = maxf(best_vy, _player.velocity.y)
	_check(
		"a jump pressed just before landing fires on touchdown (best vy %.2f)" % best_vy,
		best_vy > up * 0.7
	)
	await _settle()

	# Without a press, landing does not jump.
	_lift(0.3)
	var no_jump := -99.0
	for _frame in 25:
		await physics_frame
		no_jump = maxf(no_jump, _player.velocity.y)
	_check("landing alone never jumps (best vy %.2f)" % no_jump, no_jump < 0.5)
	await _settle()


func _check_variable_jump() -> void:
	var held := await _jump_peak(40)
	await _settle()
	var tapped := await _jump_peak(2)
	await _settle()
	_check("holding jump jumps higher than tapping it (%.2f vs %.2f m)" % [held, tapped], held > tapped + 0.4)
	_check("a held jump clears a 1 m mound (%.2f m)" % held, held > 1.2)
	_check("a tap is still a real hop (%.2f m)" % tapped, tapped > 0.25)


func _check_camera() -> void:
	var arm := _player.find_child("SpringArm3D", true, false) as SpringArm3D
	_check("camera arm exists", arm != null)
	if arm == null:
		return
	var zoom_min := float(_player.get("zoom_min"))
	var zoom_max := float(_player.get("zoom_max"))
	_check("zoom range is sane (%.1f to %.1f)" % [zoom_min, zoom_max], zoom_min >= 2.0 and zoom_max > zoom_min + 2.0)
	_player.set(&"_zoom", zoom_max)
	await _frames(40)
	_check("the camera arm eases out to the zoom target (%.2f)" % arm.spring_length, absf(arm.spring_length - zoom_max) < 0.2)
	_player.set(&"_zoom", 4.0)
	await _frames(40)
	_check("and back again (%.2f)" % arm.spring_length, absf(arm.spring_length - 4.0) < 0.2)

	var camera := arm.get_child(0) as Camera3D
	var base := float(_player.get("base_fov"))
	await _frames(20)
	_check("normal field of view when walking (%.1f)" % camera.fov, absf(camera.fov - base) < 0.5)
	Input.action_press(&"move_forward")
	Input.action_press(&"sprint")
	await _frames(70)
	var kicked := camera.fov
	_release_all()
	_check("sprinting widens the field of view (%.1f vs %.1f)" % [kicked, base], kicked > base + 3.0)
	await _settle()
	await _frames(60)
	_check("and it settles back (%.1f)" % camera.fov, absf(camera.fov - base) < 1.0)


func _check_animation() -> void:
	var leg := _player.find_child("leg_l", true, false) as Node3D
	var arm := _player.find_child("arm_l", true, false) as Node3D
	_check("the model has leg_l and arm_l", leg != null and arm != null)
	if leg == null or arm == null:
		return
	await _frames(30)
	var idle_range := await _swing_range(leg, 40)
	_check("legs are still when standing (%.3f rad)" % idle_range, idle_range < 0.06)
	Input.action_press(&"move_forward")
	await _frames(20)
	var walk_range := await _swing_range(leg, 90)
	var arm_range := await _swing_range(arm, 90)
	_release_all()
	_check("legs swing when walking (%.2f rad)" % walk_range, walk_range > 0.6)
	_check("arms swing too (%.2f rad)" % arm_range, arm_range > 0.4)
	await _settle()


# --- helpers -------------------------------------------------------------------

## Peak height above the start of a jump held for `hold_frames` physics frames.
func _jump_peak(hold_frames: int) -> float:
	var start := _player.global_position.y
	var peak := start
	Input.action_press(&"jump")
	for frame in 80:
		if frame == hold_frames:
			Input.action_release(&"jump")
		await physics_frame
		peak = maxf(peak, _player.global_position.y)
	Input.action_release(&"jump")
	return peak - start


## Range (max - min) of a node's X rotation over `frames` rendered frames.
func _swing_range(node: Node3D, frames: int) -> float:
	var lowest := 99.0
	var highest := -99.0
	for _frame in frames:
		await process_frame
		var angle := node.transform.basis.get_euler().x
		lowest = minf(lowest, angle)
		highest = maxf(highest, angle)
	return highest - lowest


func _horizontal_speed() -> float:
	return Vector2(_player.velocity.x, _player.velocity.z).length()


## Teleports the body straight up so it is airborne and falling.
func _lift(height: float) -> void:
	_player.global_position += Vector3(0.0, height, 0.0)
	_player.velocity = Vector3.ZERO


func _tap_jump() -> void:
	Input.action_press(&"jump")
	await physics_frame
	Input.action_release(&"jump")


## Waits (releasing every key) until the body is standing still on the floor.
func _settle() -> void:
	_release_all()
	for _frame in 120:
		await physics_frame
		if _player.is_on_floor() and _player.velocity.length() < 0.05:
			break
	await _frames(3)


func _frames(count: int) -> void:
	for _frame in count:
		await physics_frame


func _release_all() -> void:
	for action in [&"move_forward", &"move_back", &"move_left", &"move_right", &"sprint", &"jump"]:
		Input.action_release(action)


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	_release_all()
	if _failures == 0:
		print("PASSED  all movement assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
