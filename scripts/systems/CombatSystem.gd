class_name CombatSystem
extends Node
## Melee swing for one player: cooldown, stamina cost, a forward sphere cast that
## only sees enemy bodies, then a crit roll and the damage hand-off.
##
## Lives under the player body (`Player/CombatSystem`) and reads the body's aim
## instead of keeping a transform of its own. The cast shape is built in `_ready`
## from the exports, so `attack_range` stays a single knob.
##
## Multiplayer: the attacking peer evaluates the swing (the server does not
## re-simulate it for MVP) and asks the creature for damage; `Enemy.take_damage`
## forwards to the enemy's own authority when this peer does not own the body.

## Enemy bodies sit alone on physics layer 5 so a swing can never hit the
## swinger, another player or a world prop.
const ENEMY_LAYER := 16
const SWING_SPHERE_RADIUS := 0.45

@export var attack_range := 2.6
@export var attack_cooldown := 0.55
@export var heavy_cooldown_scale := 1.5
@export var light_damage := 12.0
@export var heavy_damage := 22.0
@export var crit_chance := 0.15
@export var crit_multiplier := 2.0
@export var attack_stamina_cost := 12.0
## Height above the body origin the swing travels at. The origin sits on the
## floor (the capsule's half-height is below it) and the placeholder creatures
## are squat, so the sphere sweeps at waist height and still overlaps them.
@export var chest_height := 0.5

var _body: CharacterBody3D = null
var _stats: Node = null
var _aim: Node3D = null
var _cast: ShapeCast3D = null
var _cooldown_left := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_body = get_parent() as CharacterBody3D
	if _body != null:
		_stats = _body.get_node_or_null("Stats")
		_aim = _body.get_node_or_null("CameraPivot") as Node3D
	_rng.randomize()
	_build_cast()


func _physics_process(delta: float) -> void:
	_cooldown_left = maxf(_cooldown_left - delta, 0.0)


## Seconds until the next swing is allowed; 0 when ready.
func cooldown_left() -> float:
	return _cooldown_left


## One swing. False while a cooldown runs, while a modal UI owns the keyboard,
## when the player is dead, or when stamina cannot pay for it.
func try_attack(heavy := false) -> bool:
	if _cast == null or _body == null or _stats == null:
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


func _build_cast() -> void:
	var sphere := SphereShape3D.new()
	sphere.radius = SWING_SPHERE_RADIUS
	_cast = ShapeCast3D.new()
	_cast.name = "SwingCast"
	_cast.shape = sphere
	_cast.collision_mask = ENEMY_LAYER
	_cast.collide_with_bodies = true
	_cast.collide_with_areas = false
	_cast.exclude_parent = false
	_cast.max_results = 8
	# Driven by `force_shapecast_update()` on each swing instead of every frame.
	_cast.enabled = false
	add_child(_cast)


func _swing(heavy: bool) -> void:
	var origin := _body.global_position + Vector3(0.0, chest_height, 0.0)
	_cast.global_transform = Transform3D(Basis.IDENTITY, origin)
	_cast.target_position = _facing() * attack_range
	_cast.force_shapecast_update()

	var base_damage := heavy_damage if heavy else light_damage
	var struck := {}
	for index in _cast.get_collision_count():
		var enemy := _cast.get_collider(index) as Node
		if enemy == null or not enemy.is_in_group(&"enemy"):
			continue
		var id := enemy.get_instance_id()
		if struck.has(id):
			continue
		struck[id] = true
		var is_crit := _rng.randf() < crit_chance
		var amount := base_damage * (crit_multiplier if is_crit else 1.0)
		if enemy.has_method(&"take_damage"):
			# The creature emits `EventBus.enemy_hit` when it applies the loss,
			# so a hit is reported exactly once whichever system caused it.
			enemy.call(&"take_damage", amount, is_crit, _body)


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
