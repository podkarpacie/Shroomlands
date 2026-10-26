extends Node3D
## Placeholder Verdant Bloom biome: seeded decoration scatter plus the spawn
## registry that `Main` reads. Real gather nodes and enemies arrive in later
## phases; nothing here runs per frame.

const PROP_SCENE := preload("res://scenes/world/mushroom_prop.tscn")
## Props are decoration only: keep them clear of the spawn point and the
## third-person camera's reach (arm length 4 m) so nothing can block the view or
## the arm's cast when the game starts.
const SPAWN_CLEARING := 12.0
const SCATTER_RADIUS := 45.0

@export var scatter_seed := 1337
@export var decor_count := 24

var _spawn_points: Array[Marker3D] = []


func _ready() -> void:
	_register_spawn_points()
	_scatter_decor()


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
func _scatter_decor() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = scatter_seed
	for index in decor_count:
		var angle := rng.randf_range(0.0, TAU)
		var radius := rng.randf_range(SPAWN_CLEARING, SCATTER_RADIUS)
		var prop := PROP_SCENE.instantiate() as Node3D
		prop.name = "Decor%d" % index
		prop.position = Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		prop.rotation.y = rng.randf_range(0.0, TAU)
		var width := rng.randf_range(0.8, 1.6)
		prop.scale = Vector3(width, rng.randf_range(0.8, 1.4), width)
		add_child(prop)
