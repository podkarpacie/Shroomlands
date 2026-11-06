class_name SporeBloom
extends StaticBody3D
## Spore Bloom hazard (`assets/models/hazards/spore_bloom.gltf`): a fat,
## veined mushroom that never drops loot.
##
## A player who comes within `trigger_radius` arms it; after `swell_seconds` it
## bursts into a toxic cloud that ticks damage on everyone still inside
## `cloud_radius` for `cloud_seconds`. Hitting it first destroys it harmlessly.
##
## Authority: the server runs the trigger and the cloud ticks, exactly like
## `Enemy` AI. It damages its own player directly and routes remote players to
## their owner through `PlayerStats.apply_damage_rpc`. Offline the local peer is
## the server, so the same path runs with no network.
##
## Physics layer 32 (the "hurtbox" layer) is deliberate: `CombatSystem` already
## queries 16 | 32, so a swing sees the bloom, while the player's movement mask
## (world only) means the hazard never blocks a path.

enum State { IDLE, SWELLING, BURST, DESTROYED }

const GROUP := &"hazard"
const PLAYER_GROUP := &"player"
const MODEL_PATH := "res://assets/models/hazards/spore_bloom.gltf"
## Reuses the species glow helper: the cap and veins are `cap*` nodes, so they
## are self-lit and readable in the fog like every other mushroom.
const ModelGlow := preload("res://scripts/world/ModelGlow.gd")
const LAYER := 32
const GLOW_ENERGY := 2.0

@export var max_hp := 20.0
## Flat distance at which the bloom arms itself.
@export var trigger_radius := 2.5
## Telegraph before the burst: long enough to back off, short enough to punish.
@export var swell_seconds := 0.6
@export var cloud_radius := 3.0
@export var cloud_seconds := 6.0
@export var tick_seconds := 0.75
@export var tick_damage := 3.0
## Visual swell; the burst itself hides the model and starts the cloud.
@export var swell_scale := 1.22

var hp := 0.0
## Replicated. The setter drives every visual, so a client that receives
## BURST/DESTROYED shows the same cloud or empty patch as the server without
## running any of the hazard logic.
var state := State.IDLE:
	set(value):
		if state == value:
			return
		state = value
		_apply_state_visuals()
## Replicated too: `CombatSystem` skips a destroyed bloom on a client as well.
var dead := false

var _swell_left := 0.0
var _cloud_left := 0.0
var _tick_left := 0.0
var _model: Node3D = null
var _cloud: CPUParticles3D = null
var _shell: MeshInstance3D = null
var _swell_tween: Tween = null

@onready var _collision: CollisionShape3D = $CollisionShape3D
@onready var _stem: MeshInstance3D = $Stem
@onready var _cap: MeshInstance3D = $Cap


func _ready() -> void:
	add_to_group(GROUP)
	collision_layer = LAYER
	collision_mask = 0
	hp = max_hp
	_install_model()
	_build_cloud()
	if not is_multiplayer_authority():
		set_physics_process(false)
	# A late state sync can arrive before `_ready` binds the nodes; reapply now.
	_apply_state_visuals()


func is_cloud_active() -> bool:
	return state == State.BURST


func is_armed() -> bool:
	return state == State.SWELLING


func _physics_process(delta: float) -> void:
	if dead or not is_multiplayer_authority():
		return
	match state:
		State.IDLE:
			if _player_within(trigger_radius):
				_begin_swell()
		State.SWELLING:
			_swell_left -= delta
			if _swell_left <= 0.0:
				_burst()
		State.BURST:
			_cloud_left -= delta
			_tick_left -= delta
			if _tick_left <= 0.0:
				_tick_left += tick_seconds
				_damage_players()
			if _cloud_left <= 0.0:
				_finish()


## Swaps the primitive fallback for the authored glTF when it is available.
func _install_model() -> void:
	if not ResourceLoader.exists(MODEL_PATH):
		return
	var scene := load(MODEL_PATH) as PackedScene
	if scene == null:
		return
	_model = scene.instantiate() as Node3D
	if _model == null:
		return
	_model.name = "Model"
	add_child(_model)
	ModelGlow.apply(_model, GLOW_ENERGY)
	_stem.visible = false
	_cap.visible = false


## The cloud is built in code so the scene stays a plain body + shape. CPUParticles
## (not GPU) matches the rest of the project and works on the Compatibility/WebGL2
## web build; the translucent shell gives the poison a readable radius.
func _build_cloud() -> void:
	_cloud = CPUParticles3D.new()
	_cloud.name = "Cloud"
	_cloud.emitting = false
	_cloud.amount = 76
	_cloud.lifetime = cloud_seconds
	_cloud.one_shot = false
	_cloud.explosiveness = 0.0
	_cloud.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_cloud.emission_sphere_radius = cloud_radius * 0.72
	_cloud.position = Vector3(0.0, 0.5, 0.0)
	_cloud.direction = Vector3.UP
	_cloud.spread = 180.0
	_cloud.gravity = Vector3(0.0, 0.12, 0.0)
	_cloud.initial_velocity_min = 0.10
	_cloud.initial_velocity_max = 0.45
	_cloud.scale_amount_min = 0.6
	_cloud.scale_amount_max = 1.4
	_cloud.color = Color(0.56, 0.86, 0.26, 0.42)
	var puff := SphereMesh.new()
	puff.radius = 0.13
	puff.height = 0.26
	puff.radial_segments = 8
	puff.rings = 4
	puff.material = _cloud_material(0.42)
	_cloud.mesh = puff
	add_child(_cloud)

	_shell = MeshInstance3D.new()
	_shell.name = "CloudShell"
	var sphere := SphereMesh.new()
	sphere.radius = cloud_radius
	sphere.height = cloud_radius * 0.9
	sphere.radial_segments = 16
	sphere.rings = 8
	sphere.material = _cloud_material(0.10)
	_shell.mesh = sphere
	_shell.position = Vector3(0.0, 0.45, 0.0)
	_shell.visible = false
	_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_shell)


func _cloud_material(alpha: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.52, 0.82, 0.22, alpha)
	material.emission_enabled = true
	material.emission = Color(0.50, 0.86, 0.18)
	material.emission_energy_multiplier = 1.1
	return material


func _begin_swell() -> void:
	if state != State.IDLE:
		return
	state = State.SWELLING
	_swell_left = swell_seconds


func _burst() -> void:
	state = State.BURST
	_cloud_left = cloud_seconds
	# First tick lands immediately: standing in the burst is meant to hurt.
	_tick_left = 0.0


## Damage everyone still inside the cloud radius. Same owner-authority split as
## `Enemy._try_bite`: our own body takes it here, a remote body's owner does.
func _damage_players() -> void:
	for node: Node in get_tree().get_nodes_in_group(PLAYER_GROUP):
		var body := node as Node3D
		if body == null or _flat_distance(body.global_position) > cloud_radius:
			continue
		var stats := body.get_node_or_null("Stats")
		if stats == null or not stats.has_method(&"take_damage"):
			continue
		_hurt(stats, body)


func _hurt(stats: Node, body: Node3D) -> void:
	if body.is_multiplayer_authority():
		stats.call(&"take_damage", tick_damage, self)
		return
	if Network.mode == Network.OFFLINE:
		return
	var owner_id := body.get_multiplayer_authority()
	if owner_id <= 0 or owner_id == multiplayer.get_unique_id():
		return
	stats.rpc_id(owner_id, &"apply_damage_rpc", tick_damage)


func _player_within(radius: float) -> bool:
	for node: Node in get_tree().get_nodes_in_group(PLAYER_GROUP):
		var body := node as Node3D
		if body == null or _flat_distance(body.global_position) > radius:
			continue
		var stats := body.get_node_or_null("Stats")
		if stats != null and bool(stats.call(&"is_dead")):
			continue
		return true
	return false


## Entry point for a swing. Before the burst this destroys the bloom harmlessly
## and drops nothing; after the burst it is already a cloud and cannot be hit.
func take_damage(
	amount: float,
	is_crit := false,
	attacker: Node = null,
	_hit_direction := Vector3.ZERO,
	_heavy := false
) -> void:
	if dead or state == State.BURST:
		return
	if not is_multiplayer_authority():
		if Network.mode != Network.OFFLINE:
			var path := NodePath()
			if attacker != null and attacker.is_inside_tree():
				path = attacker.get_path()
			_request_damage.rpc_id(1, amount, is_crit, path)
		return
	_apply_damage(amount, is_crit)


@rpc("any_peer", "call_remote", "reliable")
func _request_damage(amount: float, is_crit: bool, _attacker_path: NodePath) -> void:
	if not is_multiplayer_authority():
		return
	_apply_damage(amount, is_crit)


func _apply_damage(amount: float, is_crit: bool) -> void:
	hp = maxf(hp - amount, 0.0)
	EventBus.enemy_hit.emit(self, amount, is_crit)
	if hp <= 0.0:
		_destroy()


## Destroyed before the burst. The node stays in the scene (hidden and inert) so
## a scene-instanced hazard keeps the same path on every peer; freeing it would
## desync clients that still hold the instance.
func _destroy() -> void:
	dead = true
	state = State.DESTROYED
	set_physics_process(false)


## The cloud ran out: same hidden end state, no burst and no loot.
func _finish() -> void:
	dead = true
	state = State.DESTROYED
	set_physics_process(false)


## One place for the server and a synced client to turn `state` into visuals.
func _apply_state_visuals() -> void:
	match state:
		State.SWELLING:
			if _model == null:
				return
			_kill_swell_tween()
			_swell_tween = create_tween()
			_swell_tween.tween_property(
				_model, "scale", Vector3.ONE * swell_scale, swell_seconds
			).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
		State.BURST:
			if _model != null:
				_model.visible = false
			if _cloud != null:
				_cloud.emitting = true
			if _shell != null:
				_shell.visible = true
		State.DESTROYED:
			_kill_swell_tween()
			if _model != null:
				_model.visible = false
			if _stem != null:
				_stem.visible = false
			if _cap != null:
				_cap.visible = false
			if _cloud != null:
				_cloud.emitting = false
			if _shell != null:
				_shell.visible = false
			if _collision != null:
				_collision.set_deferred(&"disabled", true)
			remove_from_group(GROUP)


func _kill_swell_tween() -> void:
	if _swell_tween != null and _swell_tween.is_valid():
		_swell_tween.kill()
	_swell_tween = null


func _flat_distance(point: Vector3) -> float:
	var delta := global_position - point
	return Vector2(delta.x, delta.z).length()
