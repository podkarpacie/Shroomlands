extends SceneTree
func _initialize() -> void:
	_run()
func _run() -> void:
	var lobby: Node = load("res://scenes/multiplayer/lobby.tscn").instantiate()
	root.add_child(lobby)
	await create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://tests/_review_lobby.png")
	print("SAVED lobby")
	quit(0)
