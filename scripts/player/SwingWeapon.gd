extends Node3D
## The player's visible mycelium club. The rigged glTF character keeps its hands
## as plain bone nodes (no skin), so the club is a sibling of the model rather
## than a child of it: every frame it copies `hand_right2`'s world transform,
## which the `walk`/`run`/`attack` clips animate. That keeps the club out of the
## model's mesh count while still following the authored arm swing exactly.
##
## The club is the player's weapon, not an inventory item: it stays in the right
## hand whatever `held_item` says. An empty hotbar slot or a mushroom in the left
## hand must not remove it.

## The animated right-hand bone. Blockbench exports the bone node next to the
## cube it drives, so `hand_right` (the mesh) is its child; the bone is the one
## the clips target and the one that carries the hand's frame.
const HAND_NAME := &"hand_right2"

var _hand: Node3D = null
var _club: Node3D = null


func _ready() -> void:
	_hand = _find_hand()
	if _hand == null:
		visible = false
		set_process(false)
		return
	_build_club()


func _process(_delta: float) -> void:
	if _hand == null or not is_instance_valid(_hand):
		return
	# Held out to the side and angled down: the camera looks over the player's
	# back, so a club pointing straight up disappears into the cap.
	global_transform = _hand.global_transform * Transform3D(
		Basis(Vector3.BACK, -1.90).scaled(Vector3.ONE * 0.86),
		Vector3(0.0, -0.02, 0.0)
	)


func _find_hand() -> Node3D:
	var parent := get_parent()
	if parent == null:
		return null
	var visual := parent.get_node_or_null("Model/Visual") as Node3D
	if visual == null:
		return null
	return visual.find_child(String(HAND_NAME), true, false) as Node3D


func _build_club() -> void:
	_club = Node3D.new()
	_club.name = "Club"
	add_child(_club)

	var wood := Color(0.44, 0.29, 0.15)
	var cap := Color(0.26, 0.78, 0.62)
	var glow := Color(0.38, 1.0, 0.78)
	_club.add_child(_cylinder(0.034, 0.050, 0.58, wood, 7, Vector3(0.0, 0.29, 0.0)))
	_club.add_child(_cylinder(0.075, 0.075, 0.06, wood.lightened(0.20), 9, Vector3(0.0, 0.56, 0.0)))
	var head := _sphere(0.155, 0.21, cap, 12, 6, 0.9)
	head.position = Vector3(0.0, 0.66, 0.0)
	head.scale = Vector3(1.0, 0.78, 1.0)
	_club.add_child(head)
	for index in 3:
		var angle := TAU * float(index) / 3.0 + 0.3
		var spot := _sphere(0.030, 0.018, glow, 6, 3, 1.5)
		spot.position = Vector3(cos(angle) * 0.09, 0.73, sin(angle) * 0.09)
		_club.add_child(spot)

	# A ~30 cm caster held a metre above the ground is smaller than the sun's
	# soft-shadow penumbra (0.5° disc + blur), so the shadow map resolves it as
	# a salt-and-pepper dither instead of a soft blob. The club keeps its
	# lighting but casts nothing: the body shadow already darkens that patch of
	# ground, and a single texel-sized speckle there reads as a render bug.
	for part: GeometryInstance3D in _club.get_children():
		part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _mat(color: Color, emission := 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.78
	if emission > 0.0:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = emission
	return material


func _cylinder(
	top_radius: float,
	bottom_radius: float,
	height: float,
	color: Color,
	segments: int,
	position: Vector3
) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.height = height
	mesh.radial_segments = segments
	mesh.rings = 1
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = position
	instance.material_override = _mat(color)
	return instance


func _sphere(
	radius: float,
	height: float,
	color: Color,
	segments: int,
	rings: int,
	emission: float
) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.radial_segments = segments
	mesh.rings = rings
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _mat(color, emission)
	return instance
