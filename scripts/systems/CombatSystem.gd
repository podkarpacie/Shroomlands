class_name CombatSystem
extends Node
## Melee swing for one player: cooldown, stamina cost, a real hitbox query that
## only sees enemy bodies and enemy hurtboxes, then a crit roll and the damage
## hand-off.
##
## Lives under the player body (`Player/CombatSystem`) and reads the body's aim
## instead of keeping a transform of its own. The `AttackHitbox` Area3D is the
## authored shape: a box in front of the chest, sized from the exports, queried
## synchronously on the swing so the hit lands on the same frame the animation
## starts.
##
## Multiplayer: the attacking peer evaluates the swing (the server does not
## re-simulate it for MVP) and asks the creature for damage; `Enemy.take_damage`
## forwards to the enemy's own authority when this peer does not own the body.

## Enemy bodies sit on layer 5 (bit 16); their hurtboxes on the next free layer
## (bit 32). The swing query sees both: a body without an authored hurtbox still
## works, while an enemy with one gets a more forgiving silhouette.
const ENEMY_LAYER := 16
const HURTBOX_LAYER := 32
## Anything in this group is a valid swing target but is not an `Enemy`: a
## Spore Bloom joins it so it can be destroyed at range before it bursts.
const HAZARD_GROUP := &"hazard"
const HIT_LIMIT := 16
## Damage multiplier once the weapon reaches 0 condition. Wear is deliberately
## coarse for this phase: a broken weapon still swings, it just hits softer.
const BROKEN_CONDITION_DAMAGE := 0.5

@export var attack_range := 2.6
@export var attack_cooldown := 0.55
@export var heavy_cooldown_scale := 1.5
@export var light_damage := 12.0
@export var heavy_damage := 22.0
## Bare-hand damage when no weapon item is equipped.
@export var unarmed_light_damage := 4.0
@export var unarmed_heavy_damage := 7.0
## Fraction of extra melee damage per level above 1.
const LEVEL_DAMAGE_STEP := 0.03
@export var crit_chance := 0.15
@export var crit_multiplier := 2.0
@export var attack_stamina_cost := 12.0
## Height above the body origin the hitbox travels at. The origin sits at the
## capsule centre, so this puts the box across the creature's torso.
@export var chest_height := 0.60
## Box hitbox dimensions. Depth is always `attack_range`, so the range knob stays
## the single source of truth. Heavy swings grow the box slightly.
@export var hitbox_width := 1.45
@export var hitbox_height := 1.55
@export var heavy_hitbox_scale := 1.16
@export var light_knockback := 2.0
@export var heavy_knockback := 4.8

## Number of enemies damaged by the last swing, for tests and tooling.
var last_hit_count := 0

var _body: CharacterBody3D = null
var _stats: Node = null
var _aim: Node3D = null
var _hitbox: Area3D = null
var _hitbox_shape: BoxShape3D = null
var _cooldown_left := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_body = get_parent() as CharacterBody3D
	if _body != null:
		_stats = _body.get_node_or_null("Stats")
		_aim = _body.get_node_or_null("CameraPivot") as Node3D
	_rng.randomize()
	_build_hitbox()


func _physics_process(delta: float) -> void:
	_cooldown_left = maxf(_cooldown_left - delta, 0.0)


## Seconds until the next swing is allowed; 0 when ready.
func cooldown_left() -> float:
	return _cooldown_left


## One swing. False while a cooldown runs, while a modal UI owns the keyboard,
## when the player is dead, or when stamina cannot pay for it.
func try_attack(heavy := false) -> bool:
	if _hitbox == null or _body == null or _stats == null:
		return false
	if _cooldown_left > 0.0:
		return false
	if _ui_blocked() or bool(_stats.call(&"is_dead")):
		return false
	if not bool(_stats.call(&"use_stamina", attack_stamina_cost)):
		return false
	_cooldown_left = attack_cooldown * (heavy_cooldown_scale if heavy else 1.0)
	_swing(heavy)
	return true


func _build_hitbox() -> void:
	_hitbox_shape = BoxShape3D.new()
	_hitbox_shape.size = Vector3(hitbox_width, hitbox_height, attack_range)
	_hitbox = Area3D.new()
	_hitbox.name = "AttackHitbox"
	_hitbox.collision_layer = 0
	_hitbox.collision_mask = ENEMY_LAYER | HURTBOX_LAYER
	_hitbox.monitoring = false
	_hitbox.monitorable = false
	var collision := CollisionShape3D.new()
	collision.name = "Shape"
	collision.shape = _hitbox_shape
	_hitbox.add_child(collision)
	add_child(_hitbox)


func _swing(heavy: bool) -> void:
	last_hit_count = 0
	var weapon := _equipped_weapon()
	var armed := not weapon.is_empty()
	# Read the condition before the swing wears it, so the blow that takes the
	# blade to 0 still lands at full strength.
	var condition_scale := _condition_damage_scale() if armed else 1.0
	if armed:
		_wear_weapon()
	var forward := _facing()
	var scale := heavy_hitbox_scale if heavy else 1.0
	var depth := attack_range * scale
	_hitbox_shape.size = Vector3(hitbox_width * scale, hitbox_height * scale, depth)
	var centre := (
		_body.global_position
		+ Vector3.UP * chest_height
		+ forward * (depth * 0.5)
	)
	_hitbox.global_transform = Transform3D(Basis.looking_at(forward, Vector3.UP), centre)

	# The swing animation starts even on a miss; damage is resolved immediately
	# so the HP bar and the arm never lie about what happened.
	# The counter is what every other peer watches: `PlayerAnimator` plays
	# `attack` locally on this call, and from `swing_seq` everywhere else.
	if "swing_seq" in _body:
		_body.set(&"swing_seq", int(_body.get(&"swing_seq")) + 1)
	var animator := _body.get_node_or_null("Animator")
	if animator != null and animator.has_method(&"play_attack"):
		animator.call(&"play_attack", heavy)

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _hitbox_shape
	query.transform = _hitbox.global_transform
	query.collision_mask = ENEMY_LAYER | HURTBOX_LAYER
	query.collide_with_bodies = true
	query.collide_with_areas = true
	query.exclude = [_body.get_rid()]
	var results: Array[Dictionary] = []
	if _body.is_inside_tree():
		results = _body.get_world_3d().direct_space_state.intersect_shape(query, HIT_LIMIT)

	var struck := {}
	for result: Dictionary in results:
		var enemy := _damageable_from(result.get("collider") as Object)
		if enemy == null or bool(enemy.get("dead")):
			continue
		var id := enemy.get_instance_id()
		if struck.has(id):
			continue
		struck[id] = true
		var is_crit := _rng.randf() < crit_chance
		var amount := current_attack_damage(heavy) * (
			crit_multiplier if is_crit else 1.0
		) * _outgoing_damage_multiplier() * condition_scale
		if enemy.has_method(&"take_damage"):
			# The creature emits `EventBus.enemy_hit` when it applies the loss,
			# so a hit is reported exactly once whichever system caused it.
			enemy.call(
				&"take_damage",
				amount,
				is_crit,
				_body,
				forward,
				heavy
			)
		_spawn_hit_spark(enemy as Node3D, is_crit)
		last_hit_count += 1

	if last_hit_count > 0:
		if _body.has_method(&"add_camera_shake"):
			_body.call(&"add_camera_shake", 0.16 if heavy else 0.09)


## Base damage of the equipped weapon, or the bare-hand values, plus the level
## bonus. Public so the HUD/tests can show what a swing will do without
## simulating a hit.
func current_attack_damage(heavy := false) -> float:
	var weapon := _equipped_weapon()
	var base := (
		float(unarmed_heavy_damage if heavy else unarmed_light_damage)
		if weapon.is_empty()
		else float(
			weapon.get("heavy_damage", heavy_damage) if heavy
			else weapon.get("damage", light_damage)
		)
	)
	return base * level_damage_scale()


## Every level adds 3% melee damage, so XP and the vocation sink are not
## cosmetic. Level 1 is exactly the weapon's listed damage.
func level_damage_scale() -> float:
	if _stats == null:
		return 1.0
	var level := maxi(int(_stats.get(&"level")), 1)
	return 1.0 + LEVEL_DAMAGE_STEP * float(level - 1)


func _equipped_weapon() -> Dictionary:
	if _body == null:
		return {}
	var inventory := _body.get_node_or_null("InventorySystem")
	if inventory == null:
		return {}
	var id: StringName = inventory.get(&"equipped_weapon")
	if id == &"":
		return {}
	return Lore.get_weapon(str(id))


## The attacking body's outgoing damage multiplier (Weapon Oil, Fury). A body
## without Stats still swings for its base damage.
func _outgoing_damage_multiplier() -> float:
	if _stats != null and _stats.has_method(&"damage_multiplier"):
		return maxf(float(_stats.call(&"damage_multiplier")), 0.0)
	return 1.0


## One point of wear per evaluated swing. A body without the property (an older
## scene, a test double) simply never wears out.
func _wear_weapon() -> void:
	if not ("weapon_condition" in _body):
		return
	_body.set(
		&"weapon_condition",
		maxi(int(_body.get(&"weapon_condition")) - 1, 0)
	)


## 1.0 with any condition left, `BROKEN_CONDITION_DAMAGE` at 0.
func _condition_damage_scale() -> float:
	if not ("weapon_condition" in _body):
		return 1.0
	return BROKEN_CONDITION_DAMAGE if int(_body.get(&"weapon_condition")) <= 0 else 1.0


## Walk up from a body or hurtbox to the node that owns the damage contract.
## Enemies and hazards both expose `dead` and `take_damage`.
func _damageable_from(collider: Object) -> Node:
	var node := collider as Node
	while node != null:
		if node.is_in_group(&"enemy") or node.is_in_group(HAZARD_GROUP):
			return node
		node = node.get_parent()
	return null


## The body root never yaws (only `Model` turns), so the camera pivot is the
## player's aim: flatten its forward onto the ground plane. Without a pivot the
## body's own forward is used, so the component still works standalone.
func _facing() -> Vector3:
	var basis := _aim.global_basis if _aim != null else _body.global_basis
	var forward := Vector3(-basis.z.x, 0.0, -basis.z.z)
	if forward.length_squared() < 0.0001:
		return Vector3.FORWARD
	return forward.normalized()


func _ui_blocked() -> bool:
	# The controller owns the flag; a body without one is never blocked.
	return "ui_blocking" in _body and bool(_body.get(&"ui_blocking"))


## A short additive burst at the wound. CPUParticles (rather than GPU) keeps it
## working on the Compatibility/WebGL2 web build too.
func _spawn_hit_spark(enemy: Node3D, is_crit: bool) -> void:
	if enemy == null or not enemy.is_inside_tree():
		return
	var world := _body.get_parent()
	if world == null:
		return
	var tint := Color(1.0, 0.58, 0.18) if is_crit else Color(0.98, 0.86, 0.42)
	var spark := CPUParticles3D.new()
	spark.name = "HitSpark"
	spark.one_shot = true
	spark.amount = 14 if is_crit else 9
	spark.lifetime = 0.34
	spark.explosiveness = 0.92
	spark.direction = Vector3.UP
	spark.spread = 180.0
	spark.initial_velocity_min = 1.3
	spark.initial_velocity_max = 3.4
	spark.gravity = Vector3(0.0, -5.0, 0.0)
	spark.scale_amount_min = 0.5
	spark.scale_amount_max = 1.25
	var fleck := SphereMesh.new()
	fleck.radius = 0.035
	fleck.height = 0.07
	fleck.radial_segments = 6
	fleck.rings = 3
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.albedo_color = tint
	material.emission_enabled = true
	material.emission = tint
	material.emission_energy_multiplier = 2.0
	fleck.material = material
	spark.mesh = fleck
	world.add_child(spark)
	spark.global_position = enemy.global_position + Vector3.UP * 0.78
	spark.emitting = true

	var flash := OmniLight3D.new()
	flash.name = "Flash"
	flash.light_color = tint
	flash.light_energy = 2.2
	flash.omni_range = 2.4
	spark.add_child(flash)
	var fade := spark.create_tween()
	fade.tween_property(flash, "light_energy", 0.0, 0.22)

	var timer := get_tree().create_timer(0.9)
	timer.timeout.connect(func() -> void:
		if is_instance_valid(spark):
			spark.queue_free()
	)
