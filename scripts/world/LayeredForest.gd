class_name LayeredForest
extends Node3D
## One depth layer of the layered RNG forest, built at load time from a
## deterministic `ForestRun`.
##
## The layout is data (`ForestRun`), the dressing is here: ground, path strips,
## clearings, species-correct mushroom nodes, Spore Blooms on the spine, one
## structure with a loot chest, and the gates at the entry and the exit.
##
## `Game.forest_layer` selects the depth (1-5) before `Main.enter_area` swaps the
## world in, so the same scene serves every layer. Area travel is offline-only in
## this phase, which is why the dressing can be built locally without spawning
## replication.
##
## Safe start: hazards only sit at depth 2 or deeper, so the entry clearing and
## the 12 m radius around the spawn never contain a bloom.

const MUSHROOM_SCENE := preload("res://scenes/world/mushroom_node.tscn")
const BLOOM_SCENE := preload("res://scenes/world/spore_bloom.tscn")
const CHEST_SCENE := preload("res://scenes/world/loot_chest.tscn")
const CRATE_SCENE := preload("res://scenes/world/searchable_crate.tscn")
const GATE_SCENE := preload("res://scenes/world/area_gate.tscn")
const ForestRun := preload("res://scripts/world/ForestRun.gd")

const TOWN_PATH := "res://scenes/world/town.tscn"
const FOREST_PATH := "res://scenes/world/layered_forest.tscn"
const LAYER_COUNT := 5
const GROUND_SIZE := 240.0

## Per-layer fog/ambient tint: green shallows -> violet -> crimson -> deep blue ->
## pale crown.
const LAYER_TINTS: Array[Color] = [
	Color(0.62, 0.78, 0.72), Color(0.55, 0.42, 0.68), Color(0.60, 0.28, 0.24),
	Color(0.20, 0.28, 0.38), Color(0.82, 0.82, 0.70),
]

@export var display_name := "The Shallows"
@export var run_seed := 20261106
@export var layer := 1

## Counters for tests and tooling.
var generated_mushrooms := 0
var generated_hazards := 0
var generated_crates := 0
var structure_id := -1
## Layers 3-5 are night runs: the sun is down and only the spore-lamp helps.
var is_dark := false

var _run = null
var _props: Node3D = null
var _spawn: Marker3D = null
var _rng := RandomNumberGenerator.new()
var _path_material: StandardMaterial3D = null
var _ground_material: StandardMaterial3D = null
var _wood_material: StandardMaterial3D = null
var _roof_material: StandardMaterial3D = null

@onready var _sun: DirectionalLight3D = $Sun
@onready var _environment: WorldEnvironment = $WorldEnvironment


func _ready() -> void:
	layer = clampi(Game.forest_layer if Game.forest_layer > 0 else layer, 1, LAYER_COUNT)
	var info: Dictionary = Lore.DEPTH_LAYERS.get(str(layer), {})
	display_name = "%s - Layer %d" % [str(info.get("name", "The Shallows")), layer]
	_run = ForestRun.new()
	_run.generate(layer, run_seed)
	structure_id = _run.structure_id
	_rng.seed = run_seed + layer * 313
	_make_materials()
	_build_ground()
	_build_paths()
	_build_props()
	_build_spawn()
	_build_gates()
	_tint_environment()


## Called by `Main._area_spawn_point` like every other area.
func get_spawn_point() -> Marker3D:
	return _spawn


func get_run():
	return _run


func _make_materials() -> void:
	_ground_material = _material(Color(0.14, 0.23, 0.12))
	_path_material = _material(Color(0.31, 0.41, 0.22))
	_wood_material = _material(Color(0.33, 0.22, 0.13))
	_roof_material = _material(Color(0.22, 0.16, 0.10))


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	return material


func _build_ground() -> void:
	var body := StaticBody3D.new()
	body.name = "Ground"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(GROUND_SIZE, 1.0, GROUND_SIZE)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	body.add_child(shape)

	var plane := PlaneMesh.new()
	plane.size = Vector2(GROUND_SIZE, GROUND_SIZE)
	plane.material = _ground_material
	var mesh := MeshInstance3D.new()
	mesh.name = "GroundMesh"
	mesh.mesh = plane
	body.add_child(mesh)


## Clearings at every node plus a strip per edge. Visual only: the ground body
## under them already has the collision.
func _build_paths() -> void:
	var paths := Node3D.new()
	paths.name = "Paths"
	add_child(paths)

	for node in _run.nodes:
		var centre: Vector2 = node["pos"]
		var disc := CylinderMesh.new()
		disc.top_radius = 4.2
		disc.bottom_radius = 4.2
		disc.height = 0.06
		disc.radial_segments = 20
		disc.rings = 1
		disc.material = _path_material
		var mesh := MeshInstance3D.new()
		mesh.mesh = disc
		mesh.position = Vector3(centre.x, 0.03, centre.y)
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		paths.add_child(mesh)

	for node in _run.nodes:
		var id := int(node["id"])
		for other: int in node["links"]:
			if other <= id:
				continue
			_draw_strip(paths, _run.position_of(id), _run.position_of(other))


func _draw_strip(parent: Node3D, from: Vector2, to: Vector2) -> void:
	var delta := to - from
	var length := delta.length()
	if length < 0.1:
		return
	var strip := BoxMesh.new()
	strip.size = Vector3(3.4, 0.05, length)
	strip.material = _path_material
	var mesh := MeshInstance3D.new()
	mesh.mesh = strip
	mesh.position = Vector3((from.x + to.x) * 0.5, 0.025, (from.y + to.y) * 0.5)
	mesh.rotation.y = atan2(delta.x, delta.y)
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh)


func _build_props() -> void:
	_props = Node3D.new()
	_props.name = "Props"
	add_child(_props)

	var species: Array[String] = Lore.mushrooms_in_layer(layer)
	for node in _run.nodes:
		var id := int(node["id"])
		if id == _run.entry_id or id == _run.exit_id:
			continue
		if _run.hazard_ids.has(id) or id == structure_id:
			continue
		var kind := int(node["kind"])
		if kind != ForestRun.Kind.PATH and kind != ForestRun.Kind.JUNCTION \
				and kind != ForestRun.Kind.DEAD_END:
			continue
		_place_mushrooms(node, species)

	for id: int in _run.hazard_ids:
		var pos: Vector2 = _run.position_of(id)
		var bloom := BLOOM_SCENE.instantiate() as Node3D
		bloom.name = "SporeBloom%d" % id
		bloom.position = Vector3(pos.x, 0.0, pos.y)
		_props.add_child(bloom)
		generated_hazards += 1

	if structure_id >= 0:
		_build_structure(_run.position_of(structure_id))


func _place_mushrooms(node: Dictionary, species: Array[String]) -> void:
	if species.is_empty():
		return
	var centre: Vector2 = node["pos"]
	for index in 2:
		var angle := _rng.randf_range(0.0, TAU)
		var radius := _rng.randf_range(0.9, 1.6)
		var spot := centre + Vector2(cos(angle), sin(angle)) * radius
		var id := int(_rng.randi_range(0, species.size() - 1))
		var mushroom := MUSHROOM_SCENE.instantiate() as Node3D
		mushroom.name = "Mushroom_%d_%d" % [int(node["id"]), index]
		mushroom.position = Vector3(spot.x, 0.0, spot.y)
		mushroom.set(&"mushroom_id", StringName(species[id]))
		_props.add_child(mushroom)
		generated_mushrooms += 1


## A hut: floor, four posts, a roof and the loot chest inside. No collision on
## the hut itself, so a player can always reach the chest.
func _build_structure(centre: Vector2) -> void:
	var hut := Node3D.new()
	hut.name = "Structure"
	hut.position = Vector3(centre.x, 0.0, centre.y)
	_props.add_child(hut)

	_add_box(hut, Vector3(8.0, 0.2, 8.0), Vector3(0.0, 0.1, 0.0), _wood_material)
	for sx: float in [-3.4, 3.4]:
		for sz: float in [-3.4, 3.4]:
			_add_box(hut, Vector3(0.4, 3.0, 0.4), Vector3(sx, 1.5, sz), _wood_material)
	# Four-sided pyramid roof: a flat slab reads as a floating lid from the
	# overview camera.
	var roof := CylinderMesh.new()
	roof.top_radius = 0.0
	roof.bottom_radius = 6.6
	roof.height = 2.4
	roof.radial_segments = 4
	roof.rings = 1
	roof.material = _roof_material
	var roof_mesh := MeshInstance3D.new()
	roof_mesh.mesh = roof
	roof_mesh.position = Vector3(0.0, 4.2, 0.0)
	roof_mesh.rotation.y = PI * 0.25
	hut.add_child(roof_mesh)

	var species: Array[String] = Lore.mushrooms_in_layer(layer)
	var loot: Array[String] = []
	for _index in 2:
		if species.is_empty():
			break
		loot.append(species[_rng.randi_range(0, species.size() - 1)])

	var chest := CHEST_SCENE.instantiate() as Node3D
	chest.name = "Chest"
	chest.position = Vector3(0.0, 0.1, -1.0)
	chest.set(&"loot", loot)
	chest.set(&"gold", 10 + layer * 10)
	hut.add_child(chest)

	# Three searchable crates: quieter than the chest's big reward but each
	# search is loud enough to pull something in from outside aggro range.
	var spots: Array[Vector3] = [
		Vector3(-2.4, 0.2, -2.2), Vector3(2.6, 0.2, -2.4), Vector3(2.2, 0.2, 2.2),
	]
	for index in spots.size():
		var crate := CRATE_SCENE.instantiate() as Node3D
		crate.name = "Crate%d" % (index + 1)
		crate.position = spots[index]
		var crate_loot: Array[String] = []
		if not species.is_empty():
			crate_loot.append(species[_rng.randi_range(0, species.size() - 1)])
		crate.set(&"loot", crate_loot)
		crate.set(&"gold", 5 + layer * 3)
		hut.add_child(crate)
		generated_crates += 1


func _add_box(parent: Node3D, size: Vector3, position: Vector3, material: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = position
	parent.add_child(instance)


func _build_spawn() -> void:
	var entry: Vector2 = _run.position_of(_run.entry_id)
	_spawn = Marker3D.new()
	_spawn.name = "PlayerSpawn"
	# Same 1.2 m as the town marker: the body origin is the capsule centre, so a
	# marker on the floor would drop the player through the ground plane.
	_spawn.position = Vector3(entry.x, 1.2, entry.y)
	add_child(_spawn)


func _build_gates() -> void:
	var entry: Vector2 = _run.position_of(_run.entry_id)
	var return_gate := _make_gate(
		"ReturnGate", TOWN_PATH, "Mycoria", "Return to", 0,
		Vector3(entry.x, 0.0, entry.y + 4.0)
	)
	if return_gate == null:
		return
	return_gate.set(&"requires_leader", true)

	var exit: Vector2 = _run.position_of(_run.exit_id)
	if layer < LAYER_COUNT:
		var next_info: Dictionary = Lore.DEPTH_LAYERS.get(str(layer + 1), {})
		var label := "%s - Layer %d" % [str(next_info.get("name", "Deeper")), layer + 1]
		_make_gate("DescentGate", FOREST_PATH, label, "Descend to", layer + 1,
			Vector3(exit.x, 0.0, exit.y + 4.0))
	else:
		var exit_gate := _make_gate("ExitGate", TOWN_PATH, "Mycoria", "Return to", 0,
			Vector3(exit.x, 0.0, exit.y + 4.0))
		if exit_gate != null:
			exit_gate.set(&"requires_leader", true)


func _make_gate(
	node_name: String,
	target: String,
	label: String,
	prompt: String,
	target_layer: int,
	position: Vector3
) -> Node3D:
	var gate := GATE_SCENE.instantiate() as Node3D
	if gate == null:
		return null
	gate.name = node_name
	gate.set(&"target_scene", target)
	gate.set(&"target_label", label)
	gate.set(&"prompt", prompt)
	gate.set(&"target_layer", target_layer)
	gate.position = position
	add_child(gate)
	return gate


func _tint_environment() -> void:
	is_dark = layer >= 3
	var tint := LAYER_TINTS[clampi(layer - 1, 0, LAYER_TINTS.size() - 1)]
	if _environment != null and _environment.environment != null:
		var environment := _environment.environment
		environment.ambient_light_color = tint
		if is_dark:
			# Night run: a dark sky, almost no ambient, and the fog closes in.
			environment.ambient_light_energy = 0.26 - 0.05 * (layer - 3)
			environment.background_energy_multiplier = 0.10
			environment.fog_light_color = tint.darkened(0.72)
			environment.fog_density = 0.014 + 0.002 * layer
		else:
			environment.ambient_light_energy = 0.9
			environment.background_energy_multiplier = 1.0
			environment.fog_light_color = tint
			environment.fog_density = 0.004 + 0.0015 * layer
	if _sun != null:
		_sun.light_energy = 0.10 if is_dark else 1.25 - 0.07 * layer
