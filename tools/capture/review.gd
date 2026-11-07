extends SceneTree

func _initialize() -> void:
	_run()

func _capture(path: String) -> void:
	await create_timer(0.35).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(path)
	print("SAVED ", path)

func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(1.0).timeout
	var player := get_first_node_in_group(&"player") as Node3D
	var gate := (main.get_node("World") as Node3D).get_node_or_null("DescentGate")
	if gate != null:
		gate.call(&"interact", player)
	await create_timer(1.2).timeout
	# Walk into the layer so the shot is not the bare spawn clearing.
	Input.action_press(&"move_forward")
	await create_timer(2.4).timeout
	Input.action_release(&"move_forward")
	await _capture("res://tests/_review_layer1_walk.png")
	# Night layer with the lamp on: the beam the review could not see.
	main.call(&"_swap_area", "res://scenes/world/layered_forest.tscn", 3)
	await create_timer(1.0).timeout
	var lamp := player.get_node_or_null("SporeLamp")
	if lamp != null:
		lamp.call(&"toggle")
		await create_timer(0.6).timeout
	await _capture("res://tests/_review_layer3_lamp.png")
	main.call(&"_swap_area", "res://scenes/world/layered_forest.tscn", 4)
	await create_timer(0.8).timeout
	if lamp != null:
		lamp.call(&"toggle")
	await _capture("res://tests/_review_layer4_lamp.png")
	# Journal with a found chapter.
	var game := root.get_node("/root/Game")
	var inventory := player.get_node_or_null("InventorySystem")
	if inventory != null:
		inventory.call(&"add_item", &"page_1", 1)
		inventory.call(&"add_item", &"mycelium_fiber", 3)
		inventory.call(&"add_item", &"spore_crystals", 2)
		inventory.call(&"add_item", &"hardened_mycelium", 3)
		inventory.call(&"add_item", &"fossilized_caps", 1)
	game.set(&"gold", 500)
	var menu := main.get_node_or_null("PauseMenu")
	if menu != null:
		menu.call(&"open")
		menu.call(&"set_section", &"journal")
		await create_timer(0.4).timeout
		await _capture("res://tests/_review_journal2.png")
		menu.call(&"set_section", &"skills")
		await create_timer(0.3).timeout
		await _capture("res://tests/_review_skills2.png")
		menu.call(&"close")
	var workshop := main.get_node_or_null("WorkshopUI")
	if workshop != null:
		workshop.call(&"set_open", true)
		await create_timer(0.3).timeout
		await _capture("res://tests/_review_workshop2.png")
		workshop.call(&"set_open", false)
	var chat := main.get_node_or_null("ChatUI")
	if chat != null:
		chat.call(&"set_open", true)
		chat.call(&"send_text", "The lamp draws them. Keep it low.")
		await create_timer(0.3).timeout
		await _capture("res://tests/_review_chat2.png")
		chat.call(&"set_open", false)
	quit(0)
