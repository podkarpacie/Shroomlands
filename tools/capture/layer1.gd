extends SceneTree
func _initialize() -> void:
	_run()
func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(1.0).timeout
	var player := get_first_node_in_group(&"player") as Node3D
	var gate := (main.get_node("World") as Node3D).get_node_or_null("DescentGate")
	gate.call(&"interact", player)
	await create_timer(1.4).timeout
	var world := main.get_node("World") as Node3D
	var structure := world.get_node_or_null("Props/Structure") as Node3D
	var hud := main.get_node_or_null("HUD") as CanvasLayer
	var cam := Camera3D.new()
	cam.fov = 55.0
	root.add_child(cam)
	cam.current = true
	if hud != null:
		hud.visible = false
	var focus := structure.global_position + Vector3(0.0, 1.4, 0.0) if structure != null else Vector3.ZERO
	cam.look_at_from_position(focus + Vector3(10.0, 6.0, 12.0), focus, Vector3.UP)
	await create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://tests/_review_layer1_structure.png")
	print("SAVED layer1 structure")
	if hud != null:
		hud.visible = true
	# A mushroom patch, close to the ground.
	var shroom := _first(world, "Mushroom*")
	if shroom != null:
		cam.look_at_from_position(
			shroom.global_position + Vector3(3.2, 2.2, 3.2),
			shroom.global_position + Vector3(0.0, 0.35, 0.0), Vector3.UP
		)
		await create_timer(0.3).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://tests/_review_layer1_mushrooms.png")
		print("SAVED layer1 mushrooms")
	quit(0)
func _first(root_node: Node, pattern: String) -> Node3D:
	for node in root_node.find_children(pattern, "", true, false):
		if node is Node3D:
			return node
	return null
