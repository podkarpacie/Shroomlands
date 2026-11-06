extends SceneTree

func _initialize() -> void:
	_run()

func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(0.8).timeout
	var game: Node = root.get_node("/root/Game")
	game.set(&"forest_layer", 1)
	main.call(&"enter_area", "res://scenes/world/layered_forest.tscn")
	await create_timer(1.0).timeout
	var player := get_first_node_in_group(&"player") as Node3D
	var inventory := player.get_node("InventorySystem")
	await create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://tests/_weapon_equipped.png")
	print("SAVED equipped")
	# Unequip the club through the same double-click path the satchel uses.
	var slots: Array = inventory.get(&"slots")
	for index in slots.size():
		var slot: Dictionary = slots[index]
		if not slot.is_empty() and str(slot.get("id", "")) == "mycelium_club":
			inventory.call(&"use_slot", index)
			break
	await create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://tests/_weapon_empty.png")
	print("SAVED empty equipped=", inventory.get(&"equipped_weapon"))
	quit(0)
