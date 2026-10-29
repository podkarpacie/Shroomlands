extends Node3D
## Verdant Bloom biome: seeded mushroom groves and giant landmarks, floating
## spores, and the spawn registry that `Main` reads. Real gather nodes and
## enemies are placed in the scene; the scenery here is built once at load.
##
## Scenery is drawn with `MultiMeshInstance3D`: every species model is merged
## into one mesh and instanced, so a hundred mushrooms cost a handful of draw
## calls instead of a thousand separate cubes. It has no collision, which is what
## it always had in practice (decor sat on a physics layer nothing used).

const ModelGlow := preload("res://scripts/world/ModelGlow.gd")
const DECOR_MODELS: Array[PackedScene] = [
	preload("res://assets/models/mushrooms/konop.gltf"),
	preload("res://assets/models/mushrooms/shitake.gltf"),
]
const DECOR_NAMES: Array[String] = ["Konop", "Shitake"]
const DECOR_GLOW := 1.4
## Props are decoration only: keep them clear of the spawn point and the
## third-person camera's reach (arm length up to 8 m when zoomed out) so nothing
## can block the view when the game starts.
const SPAWN_CLEARING := 12.0
const SCATTER_RADIUS := 45.0
const GROVE_COUNT := 9
const GROVE_SPREAD := 4.5
## Landmarks are giant mushrooms on the horizon: they give the flat plain a
## skyline and a sense of scale. They sit in the fog and cast no shadows.
const LANDMARK_MIN_RADIUS := 55.0
const LANDMARK_MAX_RADIUS := 150.0
const SPORE_BOX := Vector3(24.0, 2.8, 24.0)

@export var scatter_seed := 1337
@export var decor_count := 90
@export var landmark_count := 36
@export var spores_enabled := true

## Every scenery instance (decor and landmarks), for tools and tests.
var decor_transforms: Array[Transform3D] = []

var _spawn_points: Array[Marker3D] = []
var _spores: CPUParticles3D = null
var _follow: Node3D = null


func _ready() -> void:
	_register_spawn_points()
	_scatter_decor()
	if spores_enabled:
		_build_spores()


func _process(_delta: float) -> void:
	if _spores == null:
		return
	if not is_instance_valid(_follow):
		_follow = _find_local_player()
	if _follow != null:
		_spores.global_position = _follow.global_position + Vector3(0.0, SPORE_BOX.y, 0.0)


## Worlds can add extra spawn markers at runtime; the first `PlayerSpawn` wins.
func register_spawn_point(marker: Marker3D) -> void:
	if marker == null or _spawn_points.has(marker):
		return
	_spawn_points.append(marker)


func get_spawn_point() -> Marker3D:
	for marker in _spawn_points:
		if marker.name == &"PlayerSpawn":
			return marker
	return null


func _register_spawn_points() -> void:
	for child in get_children():
		if child is Marker3D and String(child.name).begins_with("PlayerSpawn"):
			register_spawn_point(child)


## Deterministic for a given seed, and always outside the 12 m spawn clearing.
## Groves of decor sit within the scatter radius; landmarks ring the horizon.
func _scatter_decor() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = scatter_seed
	var mounds := _mound_footprints()
	var groves: Array[Vector2] = []
	for _grove in GROVE_COUNT:
		var angle := rng.randf_range(0.0, TAU)
		var radius := rng.randf_range(SPAWN_CLEARING + GROVE_SPREAD, SCATTER_RADIUS - 6.0)
		groves.append(Vector2(cos(angle), sin(angle)) * radius)

	# [kind][model] -> transforms; kind 0 = decor (casts shadows), 1 = landmark.
	var buckets: Array = [[[], []], [[], []]]
	for _index in decor_count:
		var spot := _pick_spot(rng, mounds, groves, SPAWN_CLEARING, SCATTER_RADIUS)
		var width := rng.randf_range(1.6, 3.2)
		_add_instance(buckets[0], rng, spot, width, rng.randf_range(0.85, 1.25))
	for _index in landmark_count:
		var spot := _pick_spot(rng, mounds, [], LANDMARK_MIN_RADIUS, LANDMARK_MAX_RADIUS)
		var width := rng.randf_range(5.0, 10.0)
		_add_instance(buckets[1], rng, spot, width, rng.randf_range(0.9, 1.2))

	for kind in 2:
		for model_index in DECOR_MODELS.size():
			_build_multimesh(model_index, buckets[kind][model_index], kind == 1)


## Picks a ground position outside the spawn clearing and off every mound. With
## `groves`, it clusters around a random grove centre; without, it is uniform.
func _pick_spot(
	rng: RandomNumberGenerator,
	mounds: Array,
	groves: Array,
	min_radius: float,
	max_radius: float
) -> Vector2:
	var spot := Vector2.ZERO
	for attempt in 24:
		if groves.is_empty():
			var angle := rng.randf_range(0.0, TAU)
			var radius := rng.randf_range(min_radius, max_radius)
			spot = Vector2(cos(angle), sin(angle)) * radius
		else:
			var centre: Vector2 = groves[rng.randi() % groves.size()]
			spot = centre + Vector2(rng.randfn(0.0, GROVE_SPREAD), rng.randfn(0.0, GROVE_SPREAD))
		var length := spot.length()
		if length < min_radius or length > max_radius:
			continue
		if not _on_mound(spot, mounds):
			return spot
	# Crowded: fall back to a clear ring position rather than drop the prop.
	var fallback_angle := rng.randf_range(0.0, TAU)
	return Vector2(cos(fallback_angle), sin(fallback_angle)) * (min_radius + 1.0)


func _add_instance(bucket: Array, rng: RandomNumberGenerator, spot: Vector2, width: float, height: float) -> void:
	var model_index := rng.randi() % DECOR_MODELS.size()
	var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(Vector3(width, width * height, width))
	var placed := Transform3D(basis, Vector3(spot.x, 0.0, spot.y))
	bucket[model_index].append(placed)
	decor_transforms.append(placed)


func _build_multimesh(model_index: int, transforms: Array, is_landmark: bool) -> void:
	if transforms.is_empty():
		return
	var mesh := ModelGlow.merge(DECOR_MODELS[model_index], DECOR_GLOW)
	if mesh == null:
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for index in transforms.size():
		multimesh.set_instance_transform(index, transforms[index])
	var instance := MultiMeshInstance3D.new()
	instance.name = "%s%s" % ["Landmark" if is_landmark else "Decor", DECOR_NAMES[model_index]]
	instance.multimesh = multimesh
	if is_landmark:
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


## Circle footprints (x, z, radius) of the mounds, so scenery never sinks into one.
func _mound_footprints() -> Array:
	var footprints: Array = []
	for child in get_children():
		if not String(child.name).begins_with("Mound"):
			continue
		var shape_node := child.get_node_or_null("CollisionShape3D") as CollisionShape3D
		var cylinder := shape_node.shape as CylinderShape3D if shape_node != null else null
		if cylinder == null:
			continue
		var origin := (child as Node3D).global_position
		footprints.append(Vector3(origin.x, origin.z, cylinder.radius + 1.0))
	return footprints


func _on_mound(spot: Vector2, mounds: Array) -> bool:
	for mound in mounds:
		if spot.distance_to(Vector2(mound.x, mound.y)) < mound.z:
			return true
	return false


## Soft, slow motes drifting through the air around the player. They are in world
## space, so walking through them stirs nothing; they just keep refilling around you.
func _build_spores() -> void:
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.2, 0.8, 1.0])
	fade.colors = PackedColorArray([
		Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)
	])
	var dot := Gradient.new()
	dot.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var dot_texture := GradientTexture2D.new()
	dot_texture.gradient = dot
	dot_texture.fill = GradientTexture2D.FILL_RADIAL
	dot_texture.fill_from = Vector2(0.5, 0.5)
	dot_texture.fill_to = Vector2(0.5, 0.0)
	dot_texture.width = 32
	dot_texture.height = 32

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Blend modes only apply once transparency is on; without it the soft dot
	# texture draws as a hard opaque square.
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = dot_texture
	material.albedo_color = Color(0.75, 1.0, 0.85, 0.75)
	material.disable_receive_shadows = true

	var quad := QuadMesh.new()
	quad.size = Vector2(0.09, 0.09)
	quad.material = material

	_spores = CPUParticles3D.new()
	_spores.name = "Spores"
	_spores.amount = 170
	_spores.lifetime = 11.0
	_spores.preprocess = 11.0
	_spores.local_coords = false
	_spores.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_spores.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_spores.emission_box_extents = SPORE_BOX
	_spores.direction = Vector3.UP
	_spores.spread = 180.0
	_spores.initial_velocity_min = 0.05
	_spores.initial_velocity_max = 0.3
	_spores.gravity = Vector3(0.0, 0.03, 0.0)
	_spores.scale_amount_min = 0.5
	_spores.scale_amount_max = 1.6
	_spores.color_ramp = fade
	_spores.mesh = quad
	add_child(_spores)


func _find_local_player() -> Node3D:
	for node in get_tree().get_nodes_in_group(&"player"):
		if node is Node3D and node.is_multiplayer_authority():
			return node as Node3D
	return null
