extends CharacterBody3D
## Third-person mushroom controller: camera-relative WASD, sprint, jump, mouse
## look, an interaction ray and hook points for combat.
##
## Yaw lives on `CameraPivot` (independent of the body), while only `Model` turns
## to face the move direction. Rotating the body root instead would drag the
## camera around with every step change; keeping them separate means the view
## stays where the mouse put it and the silhouette still faces where it walks.

const PlayerStatsScript := preload("res://scripts/player/PlayerStats.gd")

signal jumped
## Emitted on touchdown with the downward speed at impact (m/s), for the landing
## squash and anything else that wants to react.
signal landed(impact_speed: float)

@export var walk_speed := 4.5
@export var sprint_speed := 7.5
@export var jump_velocity := 6.0
## Ground acceleration toward the target velocity (m/s^2). High on purpose: the
## character reaches walking speed in about a tenth of a second, so input feels
## direct instead of floaty.
@export var acceleration := 40.0
## Ground deceleration when no direction is held.
@export var friction := 50.0
## Share of `acceleration` available in the air.
@export var air_control := 0.35
## Drag while airborne with no input; low, so a jump keeps its momentum.
@export var air_friction := 1.5
## Reversing direction on the ground accelerates this much harder, so turning
## around is snappy instead of a slow slide through zero.
@export var turn_boost := 1.6
## A jump still works this long after walking off a ledge.
@export var coyote_time := 0.12
## A jump pressed this long before landing still fires on touchdown.
@export var jump_buffer_time := 0.14
## Falling gravity multiplier: a heavier fall makes jumps feel crisp, not floaty.
@export var fall_gravity_scale := 1.6
## Releasing jump while rising multiplies the upward speed by this (hold = high jump).
@export var jump_cut_scale := 0.5
@export var mouse_sensitivity := 0.0025
@export var min_pitch := -75.0
@export var max_pitch := 60.0
## The ray starts at the camera, which sits `camera_distance` behind the player,
## so a 3.5 m ray would stop at the player's own head and never reach a ground
## mushroom inside GatheringSystem's 3.5 m gather range. 8 m covers the camera
## offset plus one mushroom-height target in front of the player.
@export var interact_range := 8.0
@export var turn_rate := 14.0
## Distance the third-person camera sits behind the pivot. One knob for the
## scene's `SpringArm3D.spring_length`, applied on ready.
@export var camera_distance := 4.0
@export var base_fov := 75.0
## Extra field of view while sprinting; sells the speed without touching gameplay.
@export var sprint_fov_kick := 7.0
## Mouse-wheel zoom range and step for the third-person camera.
@export var zoom_min := 2.2
@export var zoom_max := 8.0
@export var zoom_step := 0.6

var is_sprinting: bool:
	get:
		return _is_sprinting

## Progression mirrors of the values `Stats` owns. `Game.set_vocation()` and
## `SaveSystem` read the node in group `player`, not its Stats child, so the
## level and XP have to be reachable from here (see the phase-12 TODO on
## `add_xp`).
var level: int:
	get:
		var stats := get_node_or_null(^"Stats")
		return int(stats.get(&"level")) if stats != null else 1
	set(value):
		var stats := get_node_or_null(^"Stats")
		if stats != null:
			stats.set(&"level", value)

var xp: int:
	get:
		var stats := get_node_or_null(^"Stats")
		return int(stats.get(&"xp")) if stats != null else 0
	set(value):
		var stats := get_node_or_null(^"Stats")
		if stats != null:
			stats.set(&"xp", value)

@onready var _stats: PlayerStatsScript = $Stats
@onready var _model: Node3D = $Model
@onready var _camera_pivot: Node3D = $CameraPivot
@onready var _spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var _camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var _interact_ray: RayCast3D = $InteractRay

var _pitch := 0.0
var _zoom := 4.0
var _shake_left := 0.0
var _shake_duration := 0.0
var _shake_strength := 0.0
var _shake_rng := RandomNumberGenerator.new()
var _coyote_left := 0.0
var _jump_buffer_left := 0.0
var _jump_cut_ready := false
var _is_sprinting := false
var _sprint_blocked := false
## Set by GatheringSystem while a gather runs; sprint is the only lock.
var _gather_locked := false
var _gravity := Vector3.DOWN * 9.8
var _focus: Node = null
var _prompt := ""
## Set by modal UI (inventory panel) and text entry (chat): mouse look, attack,
## movement, sprint and jump stay off so dragging items cannot spin the camera
## and typing "wasd" cannot walk the body.
var ui_blocking := false
## Set by BuildMode: mouse look and attacks stay off (the cursor aims the ghost),
## while walking, sprinting and jumping keep working. Separate from `ui_blocking`,
## which also freezes movement.
var build_mode := false


func _ready() -> void:
	var gravity_direction: Vector3 = ProjectSettings.get_setting(
		&"physics/3d/default_gravity_vector", Vector3.DOWN
	)
	var gravity_strength := float(ProjectSettings.get_setting(&"physics/3d/default_gravity", 9.8))
	_gravity = gravity_direction.normalized() * gravity_strength
	_pitch = _spring_arm.rotation.x
	# The arm's pivot sits at y = 0.8, *inside* the player's own capsule (radius
	# 0.4, height 1.8, centred on the root). Exclude the body from the cast so a
	# hit on the player can never snap the arm to `margin`, i.e. inside the
	# model; `camera_distance` is the single tunable length.
	if is_instance_valid(_spring_arm):
		_spring_arm.add_excluded_object(get_rid())
		_spring_arm.spring_length = camera_distance
	_zoom = camera_distance
	_camera.fov = base_fov
	# Stay glued to slopes and small steps instead of skipping off them.
	floor_snap_length = 0.35
	floor_constant_speed = true
	_interact_ray.add_exception(self)
	_shake_rng.randomize()
	if not is_multiplayer_authority():
		# A replicated copy: MultiplayerSynchronizer drives its transform, so it
		# must neither read local input nor steal the camera from the owner.
		_camera.current = false
		return
	_capture_mouse()


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if ui_blocking or build_mode:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		_camera_pivot.rotate_y(-motion.relative.x * mouse_sensitivity)
		_pitch = clampf(
			_pitch - motion.relative.y * mouse_sensitivity,
			deg_to_rad(min_pitch),
			deg_to_rad(max_pitch)
		)
		_spring_arm.rotation.x = _pitch
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			_capture_mouse()
		elif button.pressed and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			if button.button_index == MOUSE_BUTTON_WHEEL_UP:
				_zoom = clampf(_zoom - zoom_step, zoom_min, zoom_max)
			elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_zoom = clampf(_zoom + zoom_step, zoom_min, zoom_max)


## Camera easing runs per rendered frame: the arm glides to the zoom target and
## the field of view widens while sprinting.
func _process(delta: float) -> void:
	if not is_multiplayer_authority() or not is_instance_valid(_spring_arm):
		return
	var ease_zoom := 1.0 - exp(-12.0 * delta)
	_spring_arm.spring_length = lerpf(_spring_arm.spring_length, _zoom, ease_zoom)
	var fov_target := base_fov + (sprint_fov_kick if _is_sprinting else 0.0)
	_camera.fov = lerpf(_camera.fov, fov_target, 1.0 - exp(-8.0 * delta))
	_update_shake(delta)


## A short, deterministic-decay camera kick on a connected hit. This is the
## local player's read-side feedback; it never touches the body transform.
func add_camera_shake(strength: float, duration := 0.18) -> void:
	if strength <= 0.0:
		return
	_shake_strength = maxf(_shake_strength, strength)
	_shake_duration = maxf(_shake_duration, duration)
	_shake_left = maxf(_shake_left, duration)


func _update_shake(delta: float) -> void:
	if _shake_left <= 0.0:
		if _camera.h_offset != 0.0 or _camera.v_offset != 0.0 or _camera.rotation.z != 0.0:
			_camera.h_offset = 0.0
			_camera.v_offset = 0.0
			_camera.rotation.z = 0.0
		return
	_shake_left = maxf(_shake_left - delta, 0.0)
	var falloff := clampf(_shake_left / maxf(_shake_duration, 0.0001), 0.0, 1.0)
	var amount := _shake_strength * falloff * falloff
	_camera.h_offset = _shake_rng.randf_range(-amount, amount)
	_camera.v_offset = _shake_rng.randf_range(-amount, amount)
	_camera.rotation.z = _shake_rng.randf_range(-amount, amount) * 0.18
	if _shake_left <= 0.0:
		_shake_strength = 0.0
		_shake_duration = 0.0


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	_move(delta)
	_update_interaction()
	if Input.is_action_just_pressed(&"interact"):
		_try_interact()
	if (
		Input.is_action_just_pressed(&"attack")
		and not ui_blocking
		and not build_mode
		and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	):
		_try_attack()


func _move(delta: float) -> void:
	var blocked := ui_blocking
	var input := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	if blocked:
		# A focused text field or a modal panel owns the keyboard: the body stops
		# dead instead of coasting. Gravity and the floor snap below still run, so
		# it stays planted rather than hovering.
		input = Vector2.ZERO
		velocity.x = 0.0
		velocity.z = 0.0
	var direction := _camera_relative(input)
	var on_floor := is_on_floor()
	if not Input.is_action_pressed(&"sprint"):
		_sprint_blocked = false
	elif _stats.stamina <= 0.0:
		# Release-to-recover, otherwise holding sprint stutters on the first
		# regenerated frame at zero stamina.
		_sprint_blocked = true
	_is_sprinting = (
		not blocked
		and _wants_sprint(input)
		and not _sprint_blocked
		and not _gather_locked
		and _stats.stamina > 0.0
	)
	_stats.set_sprinting(_is_sprinting)

	# --- horizontal: accelerate toward the target, brake with friction ---------
	var speed := sprint_speed if _is_sprinting else walk_speed
	var target := direction * speed
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	if direction != Vector3.ZERO:
		var accel := acceleration
		if horizontal.dot(target) < 0.0:
			accel *= turn_boost
		if not on_floor:
			accel *= air_control
		horizontal = horizontal.move_toward(target, accel * delta)
	else:
		horizontal = horizontal.move_toward(
			Vector3.ZERO, (friction if on_floor else air_friction) * delta
		)
	velocity.x = horizontal.x
	velocity.z = horizontal.z

	# --- vertical: coyote time, jump buffer, variable height, heavy fall -------
	if on_floor:
		_coyote_left = coyote_time
	else:
		_coyote_left = maxf(_coyote_left - delta, 0.0)
	if not blocked and Input.is_action_just_pressed(&"jump"):
		_jump_buffer_left = jump_buffer_time
	else:
		_jump_buffer_left = maxf(_jump_buffer_left - delta, 0.0)
	if blocked:
		_jump_buffer_left = 0.0

	var jumped_now := false
	if _jump_buffer_left > 0.0 and _coyote_left > 0.0:
		velocity.y = jump_velocity
		_jump_buffer_left = 0.0
		_coyote_left = 0.0
		# A jump buffered before touchdown may already be released: that is a full
		# jump. The cut only applies when the key is let go *after* takeoff.
		_jump_cut_ready = Input.is_action_pressed(&"jump")
		jumped_now = true
		jumped.emit()

	if jumped_now:
		pass
	elif on_floor:
		_jump_cut_ready = false
		if velocity.y < 0.0:
			velocity.y = 0.0
	else:
		if velocity.y > 0.0 and _jump_cut_ready and not Input.is_action_pressed(&"jump"):
			velocity.y *= jump_cut_scale
			_jump_cut_ready = false
		var gravity_scale := fall_gravity_scale if velocity.y < 0.0 else 1.0
		velocity += _gravity * gravity_scale * delta

	var fall_speed := -velocity.y
	move_and_slide()
	if not on_floor and is_on_floor() and fall_speed > 0.5:
		landed.emit(fall_speed)
	_face_direction(direction, delta)


## Flattens the camera basis to the ground plane; the pivot only yaws, the pitch
## lives on the spring arm, so vertical look never affects walking direction.
func _camera_relative(input: Vector2) -> Vector3:
	if input.is_zero_approx():
		return Vector3.ZERO
	var basis := _camera_pivot.global_basis
	var forward := Vector3(-basis.z.x, 0.0, -basis.z.z).normalized()
	var right := Vector3(basis.x.x, 0.0, basis.x.z).normalized()
	return (right * input.x - forward * input.y).normalized()


## Sprint can only be *started* on the ground, but a sprint jump stays a sprint
## until touchdown: dropping to walk speed mid-air made every running jump stall.
func _wants_sprint(input: Vector2) -> bool:
	if not Input.is_action_pressed(&"sprint"):
		return false
	if input.is_zero_approx():
		return false
	if not is_on_floor():
		return _is_sprinting
	return true


func _face_direction(direction: Vector3, delta: float) -> void:
	if direction.length_squared() < 0.0001:
		return
	var target_yaw := atan2(-direction.x, -direction.z)
	_model.rotation.y = lerp_angle(_model.rotation.y, target_yaw, clampf(turn_rate * delta, 0.0, 1.0))


## The ray is aimed from the camera each physics frame, so what the player sees
## is what they can interact with.
func _update_interaction() -> void:
	_interact_ray.global_transform = Transform3D(_camera.global_basis, _camera.global_position)
	_interact_ray.target_position = Vector3(0.0, 0.0, -interact_range)
	_interact_ray.force_raycast_update()
	_focus = _find_interactable()

	var text := ""
	if _focus != null and _focus.has_method(&"get_interaction_text"):
		text = str(_focus.call(&"get_interaction_text"))
	if text != _prompt:
		_prompt = text
		EventBus.interaction_prompt_changed.emit(text)


func _find_interactable() -> Node:
	var collider := _interact_ray.get_collider() as Node
	if collider == null:
		return null
	var node := collider
	while node != null:
		if node.is_in_group(&"interactable"):
			return node
		node = node.get_parent()
	return null


func _try_interact() -> void:
	# A second interact press aborts the gather instead of queueing another one.
	var gathering: Node = get_node_or_null("GatheringSystem")
	if (
		gathering != null
		and gathering.has_method(&"is_gathering")
		and bool(gathering.call(&"is_gathering"))
	):
		gathering.call(&"cancel")
		return
	if _focus == null or not _focus.has_method(&"interact"):
		return
	_focus.call(&"interact", self)


## Hook for GatheringSystem: while true the player cannot sprint. Everything
## else (walking, jumping, camera) stays under the player's control.
func set_gathering(value: bool) -> void:
	_gather_locked = value
	if value:
		_is_sprinting = false
		_stats.set_sprinting(false)


## Hook for modal UI (inventory panel) and text entry (chat): while true the
## mouse neither turns the camera nor attacks, and WASD / sprint / jump are
## ignored so typing cannot walk the body.
func set_ui_blocking(value: bool) -> void:
	ui_blocking = value


## Hook for BuildMode: attacks and mouse look stop (the cursor aims the ghost)
## while WASD, sprint and jump stay under the player's control.
func set_build_mode(value: bool) -> void:
	build_mode = value


## Vocation hook (ranger). `PlayerStats` applies the bonus once, so the speeds
## only ever move by the documented amount; both stay exported tunables.
func apply_vocation_speed_bonus(walk_bonus: float, sprint_bonus: float) -> void:
	walk_speed += walk_bonus
	sprint_speed += sprint_bonus


func _try_attack() -> void:
	var combat := get_node_or_null("CombatSystem")
	if combat == null or not combat.has_method(&"try_attack"):
		return
	# Shift + LMB is the heavy swing; `CombatSystem` owns the cooldown and cost.
	combat.call(&"try_attack", Input.is_action_pressed(&"sprint"))


func _capture_mouse() -> void:
	if DisplayServer.has_feature(DisplayServer.FEATURE_MOUSE):
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


## `Game.add_xp()` looks for this method on the node in group `player`; the
## Stats component owns the actual values. TODO(phase-12): forward `level`/`xp`
## properties here too, so SaveSystem and Game.set_vocation() can read them.
func add_xp(amount: int) -> void:
	_stats.add_xp(amount)
