extends SceneTree
## Windowed stills for the town phase, run WITHOUT `--headless`:
##   Godot_v4.7.2-stable_win64.exe --path . --script res://tests/capture_town.gd
##
## Saves three PNGs: the town from the spawn marker looking north at the gate,
## and the shop and alchemy panels open over the frozen street. Every path is
## printed absolute, and each card's rect is checked against the viewport so a
## clipped panel cannot pass silently.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const TOWN_CAPTURE_PATH := "res://tests/_capture_town.png"
const SHOP_CAPTURE_PATH := "res://tests/_capture_shop.png"
const ALCHEMY_CAPTURE_PATH := "res://tests/_capture_alchemy.png"
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _main: Node = null
var _player: Node3D = null


func _initialize() -> void:
	TestEnv.isolate("capture_town")
	TestEnv.stash("user://plots.json")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	var packed := load(MAIN_SCENE_PATH) as PackedScene
	if packed == null:
		print("FAIL  main.tscn could not be loaded")
		quit(1)
		return
	_main = packed.instantiate()
	root.add_child(_main)
	await _wait_physics(30)

	_player = get_first_node_in_group(&"player") as Node3D
	if _player == null:
		print("FAIL  no player was spawned")
		quit(1)
		return
	_player.set(&"weapon_condition", 72)
	# A stocked satchel, so both station panels have real rows to draw.
	var inventory := _player.get_node_or_null("InventorySystem")
	if inventory != null:
		for entry: Array in [
			[&"konop", 4], [&"shitake", 3], [&"motoko", 2],
			[&"kazar", 2], [&"borowik", 1], [&"celtus", 1], [&"kora", 1],
		]:
			inventory.call(&"add_item", entry[0], entry[1])
	var game: Variant = root.get_node_or_null("Game")
	if game != null and int(game.get("gold")) < 420:
		game.call(&"add_gold", 420 - int(game.get("gold")))

	# --- the town from the spawn, looking north-west across the plaza --------
	# The diagonal puts the shop counter on the left edge, the west gatehouse in
	# the middle and the gate/plot board on the right, all from the spawn marker.
	var pivot := _player.get_node_or_null("CameraPivot") as Node3D
	if pivot != null:
		pivot.rotation.y = PI + 0.75
	if _player.has_method(&"set_zoom_target"):
		_player.call(&"set_zoom_target", 6.0)
	var arm := _player.find_child("SpringArm3D", true, false) as SpringArm3D
	if arm != null:
		arm.spring_length = 6.0
	await _wait_physics(12)
	await _save(TOWN_CAPTURE_PATH)

	# --- shop panel ---------------------------------------------------------
	var shop := _main.get_node_or_null("ShopUI") as CanvasLayer
	_check("Main has a ShopUI", shop != null)
	if shop != null:
		shop.call(&"set_open", true)
		await _wait_physics(3)
		_check("the shop is visible for its capture", shop.visible)
		_check_card_fits(shop, "shop")
		await _save(SHOP_CAPTURE_PATH)
		shop.call(&"set_open", false)
		await process_frame

	# --- alchemy panel ------------------------------------------------------
	var alchemy := _main.get_node_or_null("AlchemyUI") as CanvasLayer
	_check("Main has an AlchemyUI", alchemy != null)
	if alchemy != null:
		alchemy.call(&"set_open", true)
		await _wait_physics(3)
		_check("the alchemy panel is visible for its capture", alchemy.visible)
		_check_card_fits(alchemy, "alchemy")
		await _save(ALCHEMY_CAPTURE_PATH)
		alchemy.call(&"set_open", false)

	print("\ncapture files:")
	print("  town:    %s" % ProjectSettings.globalize_path(TOWN_CAPTURE_PATH))
	print("  shop:    %s" % ProjectSettings.globalize_path(SHOP_CAPTURE_PATH))
	print("  alchemy: %s" % ProjectSettings.globalize_path(ALCHEMY_CAPTURE_PATH))
	if _failures == 0:
		print("PASSED  all town captures")
		quit(0)
	else:
		print("FAILED  %d capture assertion(s)" % _failures)
		quit(1)


func _check_card_fits(panel: CanvasLayer, label: String) -> void:
	var card := panel.get_node_or_null("Station/Center/Card") as Control
	var viewport_size := root.get_visible_rect().size
	_check("the %s card exists" % label, card != null)
	if card == null:
		return
	var rect := card.get_global_rect()
	print("%s card rect %s -> %s inside viewport %s" % [
		label, rect.position, rect.end, viewport_size
	])
	_check(
		"the %s card fits the viewport (%s)" % [label, rect.size],
		rect.position.x >= 0.0 and rect.position.y >= 0.0
			and rect.end.x <= viewport_size.x and rect.end.y <= viewport_size.y
	)


func _save(path: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var error := image.save_png(path)
	print("saved %s (%dx%d, error=%d), absolute: %s" % [
		path, image.get_width(), image.get_height(), error, ProjectSettings.globalize_path(path)
	])
	var lit := 0
	var samples := 0
	for y in range(0, image.get_height(), 32):
		for x in range(0, image.get_width(), 32):
			samples += 1
			var colour := image.get_pixel(x, y)
			if maxf(colour.r, maxf(colour.g, colour.b)) > 0.02:
				lit += 1
	print("non-black samples: %d / %d" % [lit, samples])
	_check("capture is a rendered frame, not black", lit > samples / 10)


func _wait_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)
