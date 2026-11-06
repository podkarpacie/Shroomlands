extends SceneTree
func _initialize() -> void:
	_run()
func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://tests/_town_spawn.png")
	print("SAVED spawn")
	quit(0)
