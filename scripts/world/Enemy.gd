class_name Enemy
extends CharacterBody3D
## Fungal stalker (`blightling.gltf`): a three-state AI (wander -> chase ->
## bite), damage with an emission flash and a respawn at its origin.
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
const HURTBOX_LAYER := 32
const FLASH_SECONDS := 0.18
const DEATH_SECONDS := 0.45
## The creature is a textured glTF, so the hit flash adds emission instead of
## tinting `albedo_color` (a near-white tint is invisible on a texture).
const FLASH_COLOR := Color(1.0, 0.45, 0.3, 1.0)
const FLASH_ENERGY := 2.5

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
## Brief hit-stun: knockback velocity is allowed to play out instead of being
## overwritten by the chase steering on the next physics tick.
var _stagger_left := 0.0
var _gravity := Vector3.DOWN * 9.8
var _rng := RandomNumberGenerator.new()
var _flash_tween: Tween = null
var _death_tween: Tween = null
## One private copy of the model's material, shared by every mesh of this
## creature, so a flash never tints its neighbours.
var _material: StandardMaterial3D = null

@onready var _model: Node3D = $Model
@onready var _collision: CollisionShape3D = $CollisionShape3D
@onready var _hurtbox: Area3D = $Hurtbox
@onready var _animator: Node = $Animator
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

	if _stagger_left > 0.0:
		# Let a heavy hit actually move the body before the AI reasserts itself.
		_stagger_left = maxf(_stagger_left - delta, 0.0)
		move_and_slide()
		return

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
func take_damage(
	amount: float,
	is_crit := false,
	attacker: Node = null,
	hit_direction := Vector3.ZERO,
	heavy := false
) -> void:
	if not is_multiplayer_authority():
		if Network.mode != Network.OFFLINE:
			var path := NodePath()
			if attacker != null and attacker.is_inside_tree():
				path = attacker.get_path()
			_request_damage.rpc_id(1, amount, is_crit, path, hit_direction, heavy)
		return
	_apply_damage(amount, is_crit, attacker, hit_direction, heavy)


## Client -> server leg of `take_damage`. `any_peer` lets the attacker call it,
## but only the authority acts on it.
@rpc("any_peer", "call_remote", "reliable")
func _request_damage(
	amount: float,
	is_crit: bool,
	attacker_path: NodePath,
	hit_direction: Vector3,
	heavy: bool
) -> void:
	if not is_multiplayer_authority():
		return
	var attacker: Node = null
	if not attacker_path.is_empty():
		attacker = get_node_or_null(attacker_path)
	_apply_damage(amount, is_crit, attacker, hit_direction, heavy)


## Back to full HP at the spawn point. Called by the respawn timer and by tests.
func respawn() -> void:
	hp = max_hp
	state = State.IDLE
	velocity = Vector3.ZERO
	global_position = _origin
	_attack_timer = 0.0
	_stagger_left = 0.0
	_pick_wander_target()
	dead = false


func _apply_damage(
	amount: float,
	is_crit: bool,
	attacker: Node,
	hit_direction := Vector3.ZERO,
	heavy := false
) -> void:
	if dead or amount <= 0.0:
		return
	hp = maxf(hp - amount, 0.0)
	_flash()
	_react_to_hit(hit_direction, heavy, is_crit)
	# Emitted where HP actually drops, so every damage source reports one hit
	# and the HUD flash always matches the health bar.
	EventBus.enemy_hit.emit(self, amount, is_crit)
	if hp <= 0.0:
		_die(attacker)


## Physical reaction: a stagger window, a shove away from the blow and a
## procedural flinch on the rigid glTF limbs.
func _react_to_hit(direction: Vector3, heavy: bool, is_crit: bool) -> void:
	if direction.length_squared() > 0.0001 and not dead:
		var shove := direction.normalized()
		var force := 5.0 if heavy else 2.2
		if is_crit:
			force *= 1.25
		velocity.x += shove.x * force
		velocity.z += shove.z * force
		_stagger_left = maxf(_stagger_left, 0.24 if heavy else 0.12)
	if _animator != null and _animator.has_method(&"play_hit"):
		_animator.call(&"play_hit", heavy or is_crit)


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


## Bite wind-up. The damage is applied on the same tick; the animation is purely
## read-side feedback, so clients and the server never disagree about HP.
func _animate_bite() -> void:
	if _animator != null and _animator.has_method(&"play_bite"):
		_animator.call(&"play_bite")


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
	_animate_bite()
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
	var meshes := _model.find_children("*", "MeshInstance3D", true, false)
	for node in meshes:
		var mesh_instance := node as MeshInstance3D
		if _material == null:
			_material = _local_material(mesh_instance)
		if _material != null:
			mesh_instance.material_override = _material
	_restore_materials()


## Duplicates the model's material so one creature's flash never tints its
## neighbours (imported materials are shared between instances).
func _local_material(mesh_instance: MeshInstance3D) -> StandardMaterial3D:
	if mesh_instance == null or mesh_instance.mesh == null:
		return null
	var source: Material = mesh_instance.mesh.surface_get_material(0)
	if not (source is StandardMaterial3D):
		return null
	return (source as StandardMaterial3D).duplicate() as StandardMaterial3D


func _flash() -> void:
	_kill_tween(_flash_tween)
	_flash_tween = null
	if _material == null:
		return
	_material.emission_enabled = true
	_material.emission = FLASH_COLOR
	_material.emission_energy_multiplier = FLASH_ENERGY
	_flash_tween = create_tween()
	_flash_tween.tween_property(_material, "emission_energy_multiplier", 0.0, FLASH_SECONDS)


func _apply_dead_state() -> void:
	if _model == null:
		# The flag arrived before the scene was ready; `_ready` re-applies it.
		return
	if _collision != null:
		_collision.set_deferred(&"disabled", dead)
	if _hurtbox != null:
		_hurtbox.set_deferred(&"monitorable", not dead)
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
	_restore_materials()
	_death_tween = create_tween()
	_death_tween.set_parallel(true)
	_death_tween.tween_property(_model, "scale", Vector3(0.05, 0.05, 0.05), DEATH_SECONDS)
	_death_tween.chain().tween_callback(_hide_model)


func _hide_model() -> void:
	if dead:
		_model.visible = false


func _restore_materials() -> void:
	if _material != null:
		_material.emission_enabled = false
		_material.emission_energy_multiplier = 0.0


func _kill_tween(tween: Tween) -> void:
	if tween != null and tween.is_valid():
		tween.kill()
