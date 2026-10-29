extends SceneTree
## Headless check that the glTF models in `assets/models/` are what the scenes
## actually render: the player, the blightling, gatherable mushrooms and decor.
##
## `main.tscn` is loaded lazily for the same reason as in `test_player.gd`
## (autoload identifiers are not resolvable while `--script` compiles).

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const FOREST_SCENE_PATH := "res://scenes/world/verdant_bloom.tscn"
const MUSHROOM_SCENE_PATH := "res://scenes/world/mushroom_node.tscn"
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0


func _initialize() -> void:
	TestEnv.isolate("test_models")
	TestEnv.stash("user://plots.json")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	var packed := load(MAIN_SCENE_PATH) as PackedScene
	_check("main.tscn loads", packed != null)
	if packed == null:
		_finish()
		return
	var main := packed.instantiate()
	root.add_child(main)
	for _frame in 5:
		await physics_frame

	_check_player()
	await _check_enemies()
	await _check_mushroom_node()
	# The spawn world is the town now; the forest decor suite checks its own
	# fresh `verdant_bloom.tscn` instead of Main/World.
	var forest_packed := load(FOREST_SCENE_PATH) as PackedScene
	_check("verdant_bloom.tscn loads", forest_packed != null)
	if forest_packed != null:
		var forest := forest_packed.instantiate()
		root.add_child(forest)
		for _frame in 3:
			await physics_frame
		_check_decor(forest)
		forest.queue_free()
	_finish()


func _check_player() -> void:
	var players := get_nodes_in_group(&"player")
	_check("one player exists", players.size() == 1)
	if players.is_empty():
		return
	var player := players[0] as Node3D
	var model := player.get_node_or_null("Model") as Node3D
	_check("player keeps its Model node (the controller turns it)", model != null)
	if model == null:
		return
	_check("player Model holds the glTF (Model/Visual)", model.get_node_or_null("Visual") != null)
	_check(
		"the primitive Body and Cap are gone",
		model.get_node_or_null("Body") == null and model.get_node_or_null("Cap") == null
	)
	var meshes := model.find_children("*", "MeshInstance3D", true, false)
	# 21 cubes: the rigged body, chest, head, 2 eyes, 4 cap rings, 2 upper arms,
	# 2 lower arms, 2 hands, 2 upper legs, 2 lower legs and 2 feet.
	_check("player model has its 21 cube meshes (%d)" % meshes.size(), meshes.size() == 21)

	# Feet on the bottom of the 1.8 m capsule, head at the top: otherwise the
	# model floats or sinks and the whole camera rig reads wrong.
	var bounds := _world_bounds(model)
	var capsule_bottom := player.global_position.y - 0.9
	_check(
		"player feet sit on the capsule bottom (%.3f vs %.3f)" % [bounds.position.y, capsule_bottom],
		absf(bounds.position.y - capsule_bottom) < 0.05
	)
	_check("player model is 1.8 m tall (%.2f)" % bounds.size.y, absf(bounds.size.y - 1.8) < 0.05)

	# The controller faces the move direction with -Z, so the eyes (and the
	# front of the model) must be on the -Z side of the body.
	var eye := model.find_child("eye_l", true, false) as Node3D
	var torso := model.find_child("body_chest", true, false) as Node3D
	_check("player model has eye_l and body_chest nodes", eye != null and torso != null)
	if eye != null and torso != null:
		_check(
			"the eyes face -Z, the controller's forward",
			eye.global_position.z < torso.global_position.z
		)


func _check_enemies() -> void:
	var enemies := get_nodes_in_group(&"enemy")
	_check("the world spawns enemies (%d)" % enemies.size(), enemies.size() >= 2)
	if enemies.size() < 2:
		return
	var first := enemies[0] as Node3D
	var second := enemies[1] as Node3D
	var model := first.get_node_or_null("Model") as Node3D
	_check("enemy keeps its Model node (death shrink + hide use it)", model != null)
	if model == null:
		return
	_check("enemy Model holds the glTF (Model/Visual)", model.get_node_or_null("Visual") != null)
	var meshes := model.find_children("*", "MeshInstance3D", true, false)
	_check("enemy model has its 15 cube meshes (%d)" % meshes.size(), meshes.size() == 15)
	var bounds := _world_bounds(model)
	_check(
		"enemy stands on its origin (feet %.3f vs %.3f)" % [bounds.position.y, first.global_position.y],
		absf(bounds.position.y - first.global_position.y) < 0.05
	)

	var material := first.get("_material") as StandardMaterial3D
	var other_material := second.get("_material") as StandardMaterial3D
	_check("enemy owns a private material copy", material != null)
	_check(
		"two enemies never share a material (a flash stays on one)",
		material != null and other_material != null and material != other_material
	)
	var all_share := true
	for node in meshes:
		if (node as MeshInstance3D).material_override != material:
			all_share = false
	_check("every mesh of one enemy uses that single material", all_share)

	if material == null:
		return
	first.call(&"_flash")
	_check("a hit lights the creature up (emission on)", material.emission_enabled)
	_check(
		"the flash starts bright (%.2f)" % material.emission_energy_multiplier,
		material.emission_energy_multiplier > 1.0
	)
	await create_timer(0.4).timeout
	_check(
		"the flash fades back to normal (%.2f)" % material.emission_energy_multiplier,
		material.emission_energy_multiplier < 0.01
	)
	_check(
		"the other enemy was not tinted",
		other_material == null or not other_material.emission_enabled
	)


func _check_mushroom_node() -> void:
	var scene := load(MUSHROOM_SCENE_PATH) as PackedScene
	_check("mushroom_node.tscn loads", scene != null)
	if scene == null:
		return

	# Untyped on purpose: `class_name` types do not resolve under `--script`,
	# where `as MushroomNode` would silently give null.
	var konop: Node = scene.instantiate()
	_check("mushroom_node.tscn instantiates", konop != null)
	if konop == null:
		return
	konop.set(&"mushroom_id", &"konop")
	konop.name = "ModelKonop"
	root.add_child(konop)
	await physics_frame
	var model := konop.get_node_or_null("Model") as Node3D
	_check("konop uses assets/models/mushrooms/konop.gltf", model != null)
	_check(
		"konop hides its primitive stem and cap",
		not (konop.get_node("Stem") as Node3D).visible and not (konop.get_node("Cap") as Node3D).visible
	)
	_check("konop model is visible", model != null and model.visible)
	konop.call(&"harvest")
	_check("a harvested konop disappears", model != null and not model.visible)
	konop.call(&"_set_depleted", false)
	_check("a regrown konop is back", model != null and model.visible)
	konop.queue_free()

	# A species with no model keeps working with the primitive fallback.
	var unknown: Node = scene.instantiate()
	unknown.set(&"mushroom_id", &"species_without_a_model")
	unknown.name = "NoModel"
	root.add_child(unknown)
	await physics_frame
	_check("a species without a model has no Model node", unknown.get_node_or_null("Model") == null)
	_check(
		"it keeps the primitive stem and cap",
		(unknown.get_node("Stem") as Node3D).visible and (unknown.get_node("Cap") as Node3D).visible
	)
	unknown.call(&"harvest")
	_check(
		"a harvested fallback mushroom still disappears",
		not (unknown.get_node("Stem") as Node3D).visible and not (unknown.get_node("Cap") as Node3D).visible
	)
	unknown.queue_free()


func _check_decor(world: Node) -> void:
	_check("world exists", world != null)
	if world == null:
		return
	var decor_count := int(world.get("decor_count"))
	var landmark_count := int(world.get("landmark_count"))
	var transforms: Array = world.get("decor_transforms")
	_check(
		"scenery has decor + landmarks (%d of %d)" % [transforms.size(), decor_count + landmark_count],
		transforms.size() == decor_count + landmark_count and decor_count >= 60
	)

	# Nothing may grow inside the spawn clearing, or the start view is blocked.
	var clear := true
	for placed in transforms:
		if Vector2((placed as Transform3D).origin.x, (placed as Transform3D).origin.z).length() < 12.0:
			clear = false
	_check("nothing grows inside the 12 m spawn clearing", clear)

	# Drawn as a few instanced meshes, not one node (and 9+ draw calls) per mushroom.
	var multimeshes: Array[MultiMeshInstance3D] = []
	for child in world.get_children():
		if child is MultiMeshInstance3D:
			multimeshes.append(child as MultiMeshInstance3D)
	_check("scenery is instanced (%d MultiMeshInstance3D)" % multimeshes.size(), multimeshes.size() >= 2 and multimeshes.size() <= 4)
	var instances := 0
	var casts_ok := true
	var glows := true
	for node in multimeshes:
		instances += node.multimesh.instance_count
		var landmark := String(node.name).begins_with("Landmark")
		var shadow_off := node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if landmark != shadow_off:
			casts_ok = false
		var mesh := node.multimesh.mesh
		if mesh == null or mesh.get_surface_count() != 2:
			glows = false
		else:
			var cap_material := mesh.surface_get_material(1) as StandardMaterial3D
			glows = glows and cap_material != null and cap_material.emission_enabled
	_check("every instance is drawn (%d)" % instances, instances == transforms.size())
	_check("landmarks cast no shadows, decor does", casts_ok)
	_check("a merged model has a body surface and a glowing cap surface", glows)
	_check(
		"the primitive decor props are gone",
		world.get_node_or_null("Decor0") == null and world.get_node_or_null("Decor1") == null
	)


## World-space bounds of every mesh under `node`.
func _world_bounds(node: Node3D) -> AABB:
	var result := AABB()
	var first := true
	for mesh_node in node.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := mesh_node as MeshInstance3D
		var box := mesh_instance.global_transform * mesh_instance.get_aabb()
		if first:
			result = box
			first = false
		else:
			result = result.merge(box)
	return result


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all model assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
