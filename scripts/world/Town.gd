extends Node3D
## The town hub: a walled fungal settlement around a central plaza, with the
## shop, alchemy table, repair bench and plot board as interactable stations. The
## plot district lies outside the north gate at z = 24..36, exactly where
## `PlotSystem` already puts it; the town itself is the 60 x 60 m plate south of
## that row.
##
## Everything here is built once in `_ready` from constants: ground plate and
## plot apron, paths, the fence ring with its north gate gap, six huts, glowing
## lantern caps and a kitchen garden. The result is static bodies and plain
## meshes, so after load there is no script running per frame. The stations and
## the two gates are separate scenes instanced by `town.tscn`.

const MUSHROOM_SCENE := preload("res://scenes/world/mushroom_node.tscn")

## Area identity for the HUD caption; `Main.get_area_name` reads it off the
## loaded scene, so the label lives with the area instead of a path table.
@export var display_name := "Mycoria"

const TOWN_SIZE := 60.0
const TOWN_CENTRE_Z := -6.0
## The plaza sits slightly north of the plate centre, which leaves the long
## south walk (movement tests, the garden approach) clear of the wall and puts
## the spawn a comfortable 20 m from the gate.
const PLAZA_CENTRE := Vector3(0.0, 0.0, 4.0)
const WALL_HEIGHT := 1.3
const WALL_THICKNESS := 0.45
## Half-width of the walkable gap in the north wall.
const GATE_HALF_WIDTH := 3.0

const GROUND_COLOR := Color(0.29, 0.38, 0.22)
const SOIL_COLOR := Color(0.24, 0.18, 0.12)
const PATH_COLOR := Color(0.56, 0.51, 0.37)
const WALL_COLOR := Color(0.42, 0.45, 0.34)
const HUT_BODY_COLOR := Color(0.70, 0.65, 0.50)

## Six huts: the four working buildings plus a storage shed and the west/east
## gatehouses. `door` is the outward normal of the door face; the counters stand
## in the clear space in front of them.
const HUTS := [
	{
		"name": "ShopHut",
		"centre": Vector3(-17.0, 0.0, 4.0),
		"size": Vector3(8.0, 4.5, 7.0),
		"cap": Color(0.55, 0.24, 0.18),
		"door": Vector3(1.0, 0.0, 0.0),
	},
	{
		"name": "AlchemyHut",
		"centre": Vector3(17.0, 0.0, 4.0),
		"size": Vector3(8.0, 4.5, 7.0),
		"cap": Color(0.30, 0.42, 0.58),
		"door": Vector3(-1.0, 0.0, 0.0),
	},
	{
		"name": "RepairHut",
		"centre": Vector3(-17.0, 0.0, -27.0),
		"size": Vector3(8.0, 4.5, 7.0),
		"cap": Color(0.58, 0.44, 0.20),
		"door": Vector3(0.0, 0.0, 1.0),
	},
	{
		"name": "StorageHut",
		"centre": Vector3(17.0, 0.0, -27.0),
		"size": Vector3(8.0, 4.5, 7.0),
		"cap": Color(0.44, 0.36, 0.28),
		"door": Vector3(0.0, 0.0, 1.0),
	},
	{
		"name": "WestGatehouse",
		"centre": Vector3(-15.0, 0.0, 17.0),
		"size": Vector3(7.0, 4.0, 6.0),
		"cap": Color(0.50, 0.32, 0.22),
		"door": Vector3(0.0, 0.0, -1.0),
	},
	{
		"name": "EastGatehouse",
		"centre": Vector3(15.0, 0.0, 17.0),
		"size": Vector3(7.0, 4.0, 6.0),
		"cap": Color(0.35, 0.46, 0.34),
		"door": Vector3(0.0, 0.0, -1.0),
	},
]

const LANTERN_SPOTS: Array[Vector3] = [
	Vector3(-8.0, 0.0, 9.0),
	Vector3(8.0, 0.0, 9.0),
	Vector3(-8.0, 0.0, -1.0),
	Vector3(8.0, 0.0, -1.0),
	Vector3(-3.5, 0.0, 14.0),
	Vector3(3.5, 0.0, 14.0),
]

## Ten kitchen-garden mushrooms, split across two beds south of the plaza. Kept
## inside the beds so the spawn clearing and the shopfronts stay walkable.
const MUSHROOM_SPOTS: Array[Vector3] = [
	Vector3(-7.5, 0.0, -27.0),
	Vector3(-5.5, 0.0, -28.5),
	Vector3(-3.5, 0.0, -27.0),
	Vector3(-6.5, 0.0, -26.5),
	Vector3(-2.5, 0.0, -29.0),
	Vector3(7.5, 0.0, -27.0),
	Vector3(5.5, 0.0, -28.5),
	Vector3(3.5, 0.0, -27.0),
	Vector3(6.5, 0.0, -26.5),
	Vector3(2.5, 0.0, -29.0),
]
const MUSHROOM_SPECIES: Array[StringName] = [
	&"konop", &"shitake", &"motoko", &"borowik", &"kazar",
]

var _materials: Dictionary = {}


func _ready() -> void:
	_build_ground()
	_build_plaza_and_paths()
	_build_walls()
	_build_huts()
	_build_lanterns()
	_plant_gardens()


## `Main` and `PlayerStats` both resolve the spawn marker through this method.
func get_spawn_point() -> Marker3D:
	return get_node_or_null(^"PlayerSpawn") as Marker3D


# --- ground, paths and walls -------------------------------------------------


func _build_ground() -> void:
	_add_static_box(
		"Ground", Vector3(TOWN_SIZE, 1.0, TOWN_SIZE),
		Vector3(0.0, -0.5, TOWN_CENTRE_Z), _material(GROUND_COLOR)
	)
	# The plot row starts exactly at the north wall; this apron carries the player
	# from the gate across the district without a second area load.
	_add_static_box(
		"PlotApron", Vector3(84.0, 1.0, 17.0),
		Vector3(0.0, -0.49, 32.0), _material(GROUND_COLOR)
	)


func _build_plaza_and_paths() -> void:
	var root := Node3D.new()
	root.name = "Paths"
	add_child(root)
	var path := _material(PATH_COLOR, 0.0, 0.95)

	var plaza := MeshInstance3D.new()
	plaza.name = "Plaza"
	var disc := CylinderMesh.new()
	disc.top_radius = 9.0
	disc.bottom_radius = 9.0
	disc.height = 0.06
	disc.radial_segments = 32
	disc.material = path
	plaza.mesh = disc
	plaza.position = PLAZA_CENTRE + Vector3(0.0, 0.03, 0.0)
	root.add_child(plaza)

	_add_mesh_box(root, Vector3(4.0, 0.06, 20.0), Vector3(0.0, 0.03, 14.0), path)
	_add_mesh_box(root, Vector3(28.0, 0.06, 3.4), PLAZA_CENTRE + Vector3(0.0, 0.03, 0.0), path)
	_add_mesh_box(root, Vector3(3.4, 0.06, 18.0), Vector3(-13.0, 0.03, -14.5), path)
	_add_mesh_box(root, Vector3(3.4, 0.06, 18.0), Vector3(13.0, 0.03, -14.5), path)


## Low wall ring with a gap on the north side. The gap lines up with the gate
## scene and the plot row beyond it.
func _build_walls() -> void:
	var root := Node3D.new()
	root.name = "Walls"
	add_child(root)
	var wall := _material(WALL_COLOR)
	var half := TOWN_SIZE * 0.5
	var centre_z := TOWN_CENTRE_Z

	_add_static_box(
		"WallSouth", Vector3(TOWN_SIZE, WALL_HEIGHT, WALL_THICKNESS),
		Vector3(0.0, WALL_HEIGHT * 0.5, centre_z - half), wall, root
	)
	_add_static_box(
		"WallWest", Vector3(WALL_THICKNESS, WALL_HEIGHT, TOWN_SIZE),
		Vector3(-half, WALL_HEIGHT * 0.5, centre_z), wall, root
	)
	_add_static_box(
		"WallEast", Vector3(WALL_THICKNESS, WALL_HEIGHT, TOWN_SIZE),
		Vector3(half, WALL_HEIGHT * 0.5, centre_z), wall, root
	)

	var north_z := centre_z + half
	var side_width := half - GATE_HALF_WIDTH
	var side_x := GATE_HALF_WIDTH + side_width * 0.5
	_add_static_box(
		"WallNorthWest", Vector3(side_width, WALL_HEIGHT, WALL_THICKNESS),
		Vector3(-side_x, WALL_HEIGHT * 0.5, north_z), wall, root
	)
	_add_static_box(
		"WallNorthEast", Vector3(side_width, WALL_HEIGHT, WALL_THICKNESS),
		Vector3(side_x, WALL_HEIGHT * 0.5, north_z), wall, root
	)


# --- buildings ---------------------------------------------------------------


func _build_huts() -> void:
	var root := Node3D.new()
	root.name = "Buildings"
	add_child(root)
	for data: Dictionary in HUTS:
		_build_hut(root, data)


func _build_hut(root: Node3D, data: Dictionary) -> void:
	var centre: Vector3 = data["centre"]
	var size: Vector3 = data["size"]
	var body := _add_static_box(
		String(data["name"]), size,
		centre + Vector3(0.0, size.y * 0.5, 0.0),
		_material(HUT_BODY_COLOR), root
	)
	var door: Vector3 = data["door"]
	var face := Vector3(door.x * size.x * 0.5, 0.0, door.z * size.z * 0.5)
	var door_size := (
		Vector3(0.10, 2.3, 1.5) if absf(door.x) > 0.5
		else Vector3(1.5, 2.3, 0.10)
	)
	_add_mesh_box(
		body, door_size,
		Vector3(face.x, -size.y * 0.5 + 1.15, face.z),
		_material(Color(0.20, 0.15, 0.10))
	)
	# A warm window beside the door, on the same face.
	var window_offset := (
		Vector3(face.x, -size.y * 0.5 + 2.7, face.z + 1.9) if absf(door.x) > 0.5
		else Vector3(face.x + 1.9, -size.y * 0.5 + 2.7, face.z)
	)
	_add_mesh_box(
		body, Vector3(0.08, 0.8, 0.8) if absf(door.x) > 0.5 else Vector3(0.8, 0.8, 0.08),
		window_offset, _material(Color(0.95, 0.72, 0.32), 1.6)
	)

	# The cap roof: a wide, squashed mushroom cap overhanging every wall.
	var cap := MeshInstance3D.new()
	cap.name = "Cap"
	var cap_mesh := CylinderMesh.new()
	var radius := maxf(size.x, size.z) * 0.70
	cap_mesh.top_radius = radius * 0.48
	cap_mesh.bottom_radius = radius
	cap_mesh.height = 1.5
	cap_mesh.radial_segments = 24
	cap_mesh.material = _material(Color(data["cap"]), 0.12)
	cap.mesh = cap_mesh
	cap.position = Vector3(0.0, size.y * 0.5 + 0.75, 0.0)
	body.add_child(cap)


# --- lanterns and gardens ----------------------------------------------------


func _build_lanterns() -> void:
	var root := Node3D.new()
	root.name = "Lanterns"
	add_child(root)
	var stem := _material(Color(0.88, 0.85, 0.72))
	var glow := _material(Color(0.62, 1.0, 0.70), 2.4)
	for spot: Vector3 in LANTERN_SPOTS:
		var lantern := Node3D.new()
		lantern.position = spot
		root.add_child(lantern)

		var stem_mesh := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.07
		cylinder.bottom_radius = 0.12
		cylinder.height = 0.62
		cylinder.material = stem
		stem_mesh.mesh = cylinder
		stem_mesh.position = Vector3(0.0, 0.31, 0.0)
		lantern.add_child(stem_mesh)

		var cap := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.42
		sphere.height = 0.34
		sphere.radial_segments = 16
		sphere.rings = 8
		sphere.material = glow
		cap.mesh = sphere
		cap.position = Vector3(0.0, 0.74, 0.0)
		lantern.add_child(cap)

		var light := OmniLight3D.new()
		light.light_color = Color(0.62, 1.0, 0.72)
		light.light_energy = 1.1
		light.omni_range = 7.5
		light.shadow_enabled = false
		light.position = Vector3(0.0, 0.9, 0.0)
		lantern.add_child(light)


## Two soil beds plus the harvestable nodes. They use the same scene as the
## forest, so gathering, regrowth and discovery work unchanged in town.
func _plant_gardens() -> void:
	var root := Node3D.new()
	root.name = "Gardens"
	add_child(root)
	var soil := _material(SOIL_COLOR)
	_add_mesh_box(root, Vector3(9.0, 0.12, 5.0), Vector3(-5.0, 0.06, -28.0), soil)
	_add_mesh_box(root, Vector3(9.0, 0.12, 5.0), Vector3(5.0, 0.06, -28.0), soil)

	for index in MUSHROOM_SPOTS.size():
		var node := MUSHROOM_SCENE.instantiate() as Node3D
		node.name = "GardenMushroom%d" % (index + 1)
		node.position = MUSHROOM_SPOTS[index] + Vector3(0.0, 0.12, 0.0)
		node.set(&"mushroom_id", MUSHROOM_SPECIES[index % MUSHROOM_SPECIES.size()])
		root.add_child(node)


# --- mesh helpers ------------------------------------------------------------


func _add_static_box(
	node_name: String,
	size: Vector3,
	centre: Vector3,
	material: StandardMaterial3D,
	parent: Node3D = null
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = centre
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	collision.shape = shape
	body.add_child(collision)
	_add_mesh_box(body, size, Vector3.ZERO, material)
	(parent if parent != null else self).add_child(body)
	return body


func _add_mesh_box(
	parent: Node3D,
	size: Vector3,
	centre: Vector3,
	material: StandardMaterial3D
) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = centre
	parent.add_child(instance)
	return instance


func _material(tint: Color, emission := 0.0, roughness := 1.0) -> StandardMaterial3D:
	var key := "%s|%.2f|%.2f" % [tint.to_html(), emission, roughness]
	var cached: Variant = _materials.get(key, null)
	if cached is StandardMaterial3D:
		return cached as StandardMaterial3D
	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	material.roughness = roughness
	if emission > 0.0:
		material.emission_enabled = true
		material.emission = tint
		material.emission_energy_multiplier = emission
	_materials[key] = material
	return material
