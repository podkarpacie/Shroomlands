class_name Enemy
extends CharacterBody3D
## Placeholder fungal stalker: a squat body with a violet cap and two glowing
## eyes, a three-state AI (wander -> chase -> bite), damage with a material
## flash and a respawn at its origin.
##
## Authority: the server (peer 1) runs the AI, owns HP and picks targets;
## everybody else only mirrors the transform and the `dead` flag through the
## `MultiplayerSynchronizer`. Offline the local peer *is* peer 1, so the exact
## same code path runs with no network at all.
##
## "Death" is a hidden, disabled body that leaves the `enemy` group and comes
## back after `respawn_seconds` rather than a freed node: every fixed spawn keeps
## one stable node, so no peer has to rebuild it (and the sync flag is enough to
## keep the clients in step).

enum State { IDLE, CHASE, ATTACK, DEAD }

const GROUP := &"enemy"
const PLAYER_GROUP := &"player"
## Physics layer 5 belongs to creatures alone; their mask is world (1) + players
## (8), so a body is stopped by terrain and by a player but never by decor.
const LAYER := 16
const MASK := 9
const FLASH_SECONDS := 0.18
const DEATH_SECONDS := 0.45
const FLASH_COLOR := Color(1.0, 0.82, 0.72, 1.0)

@export var max_hp := 60.0
@export var move_speed := 2.6
@export var acceleration := 12.0
@export var turn_rate := 8.0
@export var aggro_range := 12.0
@export var attack_range := 1.9
@export var attack_damage := 8.0
@export var attack_cooldown := 1.4
@export var xp_reward := 15
@export var respawn_seconds := 12.0
## Idle drift stays inside this radius of the spawn point.
@export var wander_radius := 6.0
@export var wander_speed_scale := 0.45

var hp := 0.0
var state := State.IDLE
## Replicated: the authority flips it on death and respawn, a client only mirrors
## the visuals and the group membership.
var dead := false:
	set(value):
		if dead == value:
			return
		dead = value
		_apply_dead_state()

var _origin := Vector3.ZERO
var _wander_target := Vector3.ZERO
var _wander_timer := 0.0
var _attack_timer := 0.0
var _gravity := Vector3.DOWN * 9.8
var _rng := RandomNumberGenerator.new()
var _flash_tween: Tween = null
var _death_tween: Tween = null
var _body_material: StandardMaterial3D = null
var _cap_material: StandardMaterial3D = null
var _eye_material: StandardMaterial3D = null
var _body_base := Color.WHITE
var _cap_base := Color.WHITE
var _eye_base := Color.WHITE

@onready var _model: Node3D = $Model
@onready var _collision: CollisionShape3D = $CollisionShape3D
@onready var _body_mesh: MeshInstance3D = $Model/Body
@onready var _cap_mesh: MeshInstance3D = $Model/Cap
@onready var _eye_meshes: Array[MeshInstance3D] = [$Model/EyeL, $Model/EyeR]
@onready var _respawn_timer: Timer = $RespawnTimer


func _ready() -> void:
	add_to_group(GROUP)
	collision_layer = LAYER
	collision_mask = MASK
	_origin = global_position
	hp = max_hp
	var gravity_direction: Vector3 = ProjectSettings.get_setting(
		&"physics/3d/default_gravity_vector", Vector3.DOWN
	)
	var gravity_strength := float(ProjectSettings.get_setting(&"physics/3d/default_gravity", 9.8))
	_gravity = gravity_direction.normalized() * gravity_strength
	_rng.randomize()
	_setup_materials()
	_respawn_timer.timeout.connect(_on_respawn_timeout)
	_pick_wander_target()
	if not is_multiplayer_authority():
		# A replicated copy takes its transform from the synchronizer; running
		# physics on it would fight the server's snapshots.
		set_physics_process(false)
	# A client can receive `dead = true` before `_ready` runs, when `_model` was
	# still unresolved; apply the state again now that the nodes are bound.
	_apply_dead_state()


func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		return
	_attack_timer = maxf(_attack_timer - delta, 0.0)
	_apply_gravity(delta)

	var target := _nearest_player()
	var distance := INF if target == null else _flat_distance(target.global_position)
	if target != null and distance <= attack_range:
		state = State.ATTACK
		_face(target.global_position, delta)
		_brake(delta)
		_try_bite(target)
	elif target != null and distance <= aggro_range:
		state = State.CHASE
		_face(target.global_position, delta)
		_steer_toward(target.global_position, move_speed, delta)
	else:
		state = State.IDLE
		_wander(delta)
	move_and_slide()


func is_dead() -> bool:
	return dead


## Entry point for anything that hurts this creature. A peer that does not own
## the body forwards the hit to the server, the only place HP may change.
func take_damage(amount: float, is_crit := false, attacker: Node = null) -> void:
	if not is_multiplayer_authority():
		if Network.mode != Network.OFFLINE:
			var path := NodePath()
			if attacker != null and attacker.is_inside_tree():
				path = attacker.get_path()
			_request_damage.rpc_id(1, amount, is_crit, path)
		return
	_apply_damage(amount, is_crit, attacker)


## Client -> server leg of `take_damage`. `any_peer` lets the attacker call it,
## but only the authority acts on it.
@rpc("any_peer", "call_remote", "reliable")
func _request_damage(amount: float, is_crit: bool, attacker_path: NodePath) -> void:
	if not is_multiplayer_authority():
		return
	var attacker: Node = null
	if not attacker_path.is_empty():
		attacker = get_node_or_null(attacker_path)
	_apply_damage(amount, is_crit, attacker)


## Back to full HP at the spawn point. Called by the respawn timer and by tests.
func respawn() -> void:
	hp = max_hp
	state = State.IDLE
	velocity = Vector3.ZERO
	global_position = _origin
	_attack_timer = 0.0
	_pick_wander_target()
	dead = false


func _apply_damage(amount: float, is_crit: bool, attacker: Node) -> void:
	if dead or amount <= 0.0:
		return
	hp = maxf(hp - amount, 0.0)
	_flash()
	# Emitted where HP actually drops, so every damage source reports one hit
	# and the HUD flash always matches the health bar.
	EventBus.enemy_hit.emit(self, amount, is_crit)
	if hp <= 0.0:
		_die(attacker)


func _die(attacker: Node) -> void:
	state = State.DEAD
	hp = 0.0
	velocity = Vector3.ZERO
	dead = true
	_award_xp(attacker)
	_respawn_timer.start(maxf(respawn_seconds, 0.05))


func _award_xp(attacker: Node) -> void:
	if xp_reward <= 0:
		return
	var local := Game.get_local_player()
	if attacker == null or attacker == local:
		# `Game` is the documented XP funnel and forwards to the local player.
		Game.add_xp(xp_reward)
		return
	if attacker.has_method(&"add_xp"):
		attacker.call(&"add_xp", xp_reward)


func _on_respawn_timeout() -> void:
	respawn()


## --- AI helpers ---------------------------------------------------------


func _nearest_player() -> Node3D:
	var best: Node3D = null
	var best_distance := INF
	for node: Node in get_tree().get_nodes_in_group(PLAYER_GROUP):
		var body := node as Node3D
		if body == null:
			continue
		var stats := body.get_node_or_null("Stats")
		if stats != null and bool(stats.call(&"is_dead")):
			continue
		var distance := _flat_distance(body.global_position)
		if distance < best_distance:
			best = body
			best_distance = distance
	return best


func _try_bite(player: Node3D) -> void:
	if _attack_timer > 0.0:
		return
	_attack_timer = attack_cooldown
	var stats := player.get_node_or_null("Stats")
	if stats == null or not stats.has_method(&"take_damage"):
		return
	if player.is_multiplayer_authority():
		# Our own body (and every body offline): the hit applies right here.
		stats.call(&"take_damage", attack_damage, self)
		return
	# A remote player is authoritative over its own vitals, so the server routes
	# the bite to the owner instead of writing HP on a mirrored copy. The owner
	# takes the hit and its vitals synchronizer replicates the new HP back.
	if Network.mode == Network.OFFLINE:
		return
	var owner_id := player.get_multiplayer_authority()
	if owner_id <= 0 or owner_id == multiplayer.get_unique_id():
		return
	stats.rpc_id(owner_id, &"apply_damage_rpc", attack_damage)


func _wander(delta: float) -> void:
	_wander_timer -= delta
	if _wander_timer <= 0.0 or _flat_distance(_wander_target) < 0.4:
		_pick_wander_target()
	_steer_toward(_wander_target, move_speed * wander_speed_scale, delta)


func _pick_wander_target() -> void:
	var angle := _rng.randf_range(0.0, TAU)
	var radius := _rng.randf_range(0.0, wander_radius)
	_wander_target = _origin + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
	_wander_timer = _rng.randf_range(2.0, 4.0)


func _steer_toward(point: Vector3, speed: float, delta: float) -> void:
	var direction := _flat_direction(point)
	if direction.is_zero_approx():
		_brake(delta)
		return
	var horizontal := Vector3(velocity.x, 0.0, velocity.z).move_toward(
		direction * speed, acceleration * delta
	)
	velocity.x = horizontal.x
	velocity.z = horizontal.z


func _brake(delta: float) -> void:
	var horizontal := Vector3(velocity.x, 0.0, velocity.z).move_toward(
		Vector3.ZERO, acceleration * delta
	)
	velocity.x = horizontal.x
	velocity.z = horizontal.z


func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		if velocity.y < 0.0:
			velocity.y = 0.0
		return
	velocity.y += _gravity.y * delta


func _face(point: Vector3, delta: float) -> void:
	var direction := _flat_direction(point)
	if direction.is_zero_approx():
		return
	var target_yaw := atan2(-direction.x, -direction.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, clampf(turn_rate * delta, 0.0, 1.0))


func _flat_distance(point: Vector3) -> float:
	return Vector2(point.x - global_position.x, point.z - global_position.z).length()


func _flat_direction(point: Vector3) -> Vector3:
	var delta := point - global_position
	var flat := Vector3(delta.x, 0.0, delta.z)
	if flat.length_squared() < 0.0001:
		return Vector3.ZERO
	return flat.normalized()


## --- Visuals ------------------------------------------------------------


func _setup_materials() -> void:
	_body_material = _local_material(_body_mesh)
	_cap_material = _local_material(_cap_mesh)
	_eye_material = _local_material(_eye_meshes[0])
	if _eye_meshes.size() > 1:
		_eye_meshes[1].material_override = _eye_material
	if _body_material != null:
		_body_base = _body_material.albedo_color
	if _cap_material != null:
		_cap_base = _cap_material.albedo_color
	if _eye_material != null:
		_eye_base = _eye_material.albedo_color


## Duplicates the scene material so one creature's flash never tints its
## neighbours (scene resources are shared between instances by default).
func _local_material(mesh_instance: MeshInstance3D) -> StandardMaterial3D:
	if mesh_instance == null:
		return null
	var source: Material = mesh_instance.material_override
	if source == null and mesh_instance.mesh != null:
		source = mesh_instance.mesh.surface_get_material(0)
	if not (source is StandardMaterial3D):
		return null
	var local := (source as StandardMaterial3D).duplicate() as StandardMaterial3D
	mesh_instance.material_override = local
	return local


func _flash() -> void:
	_kill_tween(_flash_tween)
	_flash_tween = null
	if _body_material == null:
		return
	_body_material.albedo_color = FLASH_COLOR
	if _cap_material != null:
		_cap_material.albedo_color = FLASH_COLOR
	_flash_tween = create_tween()
	_flash_tween.set_parallel(true)
	if _body_material != null:
		_flash_tween.tween_property(_body_material, "albedo_color", _body_base, FLASH_SECONDS)
	if _cap_material != null:
		_flash_tween.tween_property(_cap_material, "albedo_color", _cap_base, FLASH_SECONDS)


func _apply_dead_state() -> void:
	if _model == null:
		# The flag arrived before the scene was ready; `_ready` re-applies it.
		return
	if _collision != null:
		_collision.set_deferred(&"disabled", dead)
	if dead:
		remove_from_group(GROUP)
		if is_multiplayer_authority():
			_play_death_visual()
		else:
			_model.visible = false
		return
	_kill_tween(_death_tween)
	_death_tween = null
	add_to_group(GROUP)
	_model.visible = true
	_model.scale = Vector3.ONE
	_restore_materials()


## Shrink away over `DEATH_SECONDS`; the placeholder has no death animation, so
## this is the whole "kill" feedback next to the material flash.
func _play_death_visual() -> void:
	_kill_tween(_flash_tween)
	_flash_tween = null
	_kill_tween(_death_tween)
	if _body_material != null:
		_body_material.albedo_color = _body_base
	if _cap_material != null:
		_cap_material.albedo_color = _cap_base
	_death_tween = create_tween()
	_death_tween.set_parallel(true)
	_death_tween.tween_property(_model, "scale", Vector3(0.05, 0.05, 0.05), DEATH_SECONDS)
	_death_tween.chain().tween_callback(_hide_model)


func _hide_model() -> void:
	if dead:
		_model.visible = false


func _restore_materials() -> void:
	if _body_material != null:
		_body_material.albedo_color = _body_base
	if _cap_material != null:
		_cap_material.albedo_color = _cap_base
	if _eye_material != null:
		_eye_material.albedo_color = _eye_base


func _kill_tween(tween: Tween) -> void:
	if tween != null and tween.is_valid():
		tween.kill()
