extends RefCounted
## Helpers shared by everything that shows a species' glTF: which parts glow, and
## how to merge a whole model into one mesh so scenery can be instanced cheaply.
##
## The imported models carry no emissive channel, so the glow is added here:
## cap pieces (mesh nodes named `cap*` or `glow*`) get their own copy of the
## material with the albedo texture also used as emission. That makes the caps
## self-lit, so they stay readable in shadow and bloom softly under the
## environment's glow. Stems and bodies keep the plain shared material.

const GLOW_PREFIXES := ["cap", "glow"]


static func is_glow_part(part_name: String) -> bool:
	var lower := part_name.to_lower()
	for prefix in GLOW_PREFIXES:
		if lower.begins_with(prefix):
			return true
	return false


## A glowing copy of `source`, or null when it is not a StandardMaterial3D.
static func glow_material(source: Material, energy: float) -> StandardMaterial3D:
	var standard := source as StandardMaterial3D
	if standard == null:
		return null
	var copy := standard.duplicate() as StandardMaterial3D
	copy.emission_enabled = true
	copy.emission_texture = copy.albedo_texture
	copy.emission_energy_multiplier = energy
	return copy


## Makes the cap pieces of an instanced model glow. One material copy is shared
## by all of its cap pieces.
static func apply(model_root: Node, energy: float) -> void:
	var material: StandardMaterial3D = null
	for node in model_root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null or not is_glow_part(String(mesh_instance.name)):
			continue
		if material == null:
			material = glow_material(mesh_instance.mesh.surface_get_material(0), energy)
			if material == null:
				return
		mesh_instance.material_override = material


## Merges every cube of a model into one `ArrayMesh`: surface 0 is the body, and
## surface 1 (when the model has cap pieces) is the glowing cap. A thousand
## separate cubes would be a thousand draw calls; this is two per species.
static func merge(model_scene: PackedScene, glow_energy: float) -> ArrayMesh:
	var root := model_scene.instantiate() as Node3D
	if root == null:
		return null
	var body := SurfaceTool.new()
	var cap := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	cap.begin(Mesh.PRIMITIVE_TRIANGLES)
	var body_material: Material = null
	var cap_material: Material = null
	var has_body := false
	var has_cap := false
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var to_root := _relative_transform(mesh_instance, root)
		var source := mesh_instance.mesh.surface_get_material(0)
		if is_glow_part(String(mesh_instance.name)):
			if cap_material == null:
				cap_material = glow_material(source, glow_energy)
				if cap_material == null:
					cap_material = source
			cap.append_from(mesh_instance.mesh, 0, to_root)
			has_cap = true
		else:
			if body_material == null:
				body_material = source
			body.append_from(mesh_instance.mesh, 0, to_root)
			has_body = true
	root.free()
	var merged := ArrayMesh.new()
	if has_body:
		body.set_material(body_material)
		body.commit(merged)
	if has_cap:
		cap.set_material(cap_material)
		cap.commit(merged)
	return merged if merged.get_surface_count() > 0 else null


static func _relative_transform(node: Node3D, root: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != root:
		result = (current as Node3D).transform * result
		current = current.get_parent()
	return result
