extends SceneTree
## Headless gathering test on the real `main.tscn`: a timed gather fills the
## inventory, records the species and depletes the node; out-of-range, depleted,
## moved-away and damaged gathers all refuse or cancel cleanly.
##
## `main.tscn` is loaded lazily: autoload identifiers are only resolvable after
## the `--script` main loop starts (same constraint as test_player.gd).

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0


func _initialize() -> void:
	# Structural/behaviour run only: a private save and a private plots file,
	# so this suite never reads or writes the developer's profile.
	TestEnv.isolate("test_gathering")
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
	root.add_child(packed.instantiate())
	await _wait_physics(30)

	var players := get_nodes_in_group(&"player")
	_check("exactly one node is in group 'player'", players.size() == 1)
	if players.is_empty():
		_finish()
		return
	var player := players[0] as Node3D
	var gathering: Variant = player.get_node_or_null("GatheringSystem")
	var inventory: Variant = player.get_node_or_null("InventorySystem")
	var stats: Variant = player.get_node_or_null("Stats")
	_check("player has a GatheringSystem component", gathering != null)
	_check("player has an InventorySystem component", inventory != null)
	if gathering == null or inventory == null:
		_finish()
		return

	var mushrooms := _available_mushrooms()
	print("harvestable mushrooms: %d" % mushrooms.size())
	_check("world places 8-16 harvestable mushrooms", mushrooms.size() >= 8 and mushrooms.size() <= 16)
	if mushrooms.size() < 4:
		_finish()
		return

	var ray := player.find_children("*", "RayCast3D", true, false)
	if ray.is_empty():
		_check("player has an interact RayCast3D", false)
	else:
		var mask := int((ray[0] as RayCast3D).collision_mask)
		_check(
			"interact ray sees mushroom layer 3 (mask 0x%x)" % mask,
			(mask & 4) != 0
		)

	var bus: Variant = root.get_node_or_null("EventBus")
	var progress_totals: Array[float] = []
	var finished_ids: Array[String] = []
	var prompts: Array[String] = []
	if bus != null:
		bus.connect(
			&"gather_progress_changed",
			func(_current: float, total: float) -> void:
				if total > 0.0 and not progress_totals.has(total):
					progress_totals.append(total)
		)
		bus.connect(
			&"gather_finished",
			func(mushroom_id: String) -> void: finished_ids.append(mushroom_id)
		)
		bus.connect(
			&"interaction_prompt_changed",
			func(text: String) -> void: prompts.append(text)
		)

	# --- a full gather ------------------------------------------------------
	var node: Variant = mushrooms[0]
	var id := StringName(node.get(&"mushroom_id"))
	var harvest_seconds := float(node.get(&"harvest_seconds"))
	print("gather target: %s at %s (%s, %.2f s)" % [
		(node as Node).name, _vec((node as Node3D).global_position), id, harvest_seconds
	])

	var game: Variant = root.get_node_or_null("Game")
	if game != null:
		(game.get("discovered_mushrooms") as Dictionary).erase(String(id))

	_move_player_near(player, node, 1.5)
	await _wait_physics(5)
	var before := int(inventory.call(&"count_item", id))

	_check("begin() in range returns true", bool(gathering.call(&"begin", node)))
	_check("is_gathering() is true after begin", bool(gathering.call(&"is_gathering")))
	_check(
		"begin() on the same node while gathering returns false",
		not bool(gathering.call(&"begin", node))
	)
	var ratio := float(gathering.call(&"progress_ratio"))
	_check("progress_ratio() starts within 0..1 (%.3f)" % ratio, ratio >= 0.0 and ratio <= 1.0)

	var completed := await _wait_until(
		func() -> bool: return not bool(gathering.call(&"is_gathering")),
		int(harvest_seconds * 1000.0) + 10000
	)
	_check("gather completes (%.2f s)" % harvest_seconds, completed)
	await _wait_physics(3)

	var gained := int(inventory.call(&"count_item", id)) - before
	var last_yield := int(node.get(&"last_yield"))
	_check(
		"yield is within the exported range (%d, range %d..%d)" % [
			last_yield, int(node.get(&"yield_min")), int(node.get(&"yield_max"))
		],
		last_yield >= int(node.get(&"yield_min")) and last_yield <= int(node.get(&"yield_max"))
	)
	_check("inventory gained exactly the yield (%d)" % gained, gained == last_yield)
	_check(
		"progress total matches harvest_seconds (%.2f)" % harvest_seconds,
		progress_totals.has(harvest_seconds)
	)
	_check(
		"gather_finished fired with '%s'" % id,
		finished_ids.has(String(id))
	)
	if game != null:
		var discovered: Dictionary = game.get("discovered_mushrooms")
		_check("Game.discovered_mushrooms contains '%s'" % id, discovered.has(String(id)))
	_check("node reports is_available() == false", not bool(node.call(&"is_available")))
	var cooldown := float(node.call(&"seconds_until_ready"))
	_check("seconds_until_ready() > 0 (%.2f s)" % cooldown, cooldown > 0.0)
	_check(
		"depleted node refuses begin()",
		not bool(gathering.call(&"begin", node))
	)

	# --- out of range -------------------------------------------------------
	var other: Variant = mushrooms[1]
	var other_id := StringName(other.get(&"mushroom_id"))
	_move_player_near(player, other, 20.0)
	await _wait_physics(3)
	_check(
		"begin() out of range returns false",
		not bool(gathering.call(&"begin", other))
	)

	# --- cancel by walking away --------------------------------------------
	_move_player_near(player, other, 1.5)
	await _wait_physics(3)
	var other_before := int(inventory.call(&"count_item", other_id))
	_check("begin() on the second node returns true", bool(gathering.call(&"begin", other)))
	_check("second gather is running", bool(gathering.call(&"is_gathering")))
	await _wait_ms(250)
	_check(
		"progress advanced while gathering (%.3f)" % float(gathering.call(&"progress_ratio")),
		float(gathering.call(&"progress_ratio")) > 0.0
	)
	_move_player_near(player, other, 20.0)
	var cancelled := await _wait_until(
		func() -> bool: return not bool(gathering.call(&"is_gathering")),
		3000
	)
	_check("moving beyond 4 m cancels the gather", cancelled)
	_check(
		"cancelled gather leaves the inventory at %d for '%s'" % [other_before, other_id],
		int(inventory.call(&"count_item", other_id)) == other_before
	)
	_check("cancelled node is still available", bool(other.call(&"is_available")))

	# --- cancel on damage ---------------------------------------------------
	var third: Variant = mushrooms[2]
	var third_id := StringName(third.get(&"mushroom_id"))
	_move_player_near(player, third, 1.5)
	await _wait_physics(3)
	var third_before := int(inventory.call(&"count_item", third_id))
	_check("begin() on the third node returns true", bool(gathering.call(&"begin", third)))
	if stats != null:
		stats.call(&"take_damage", 5.0)
	_check("taking damage cancels the gather", not bool(gathering.call(&"is_gathering")))
	_check(
		"damaged gather leaves the inventory unchanged",
		int(inventory.call(&"count_item", third_id)) == third_before
	)
	_check("damaged node is still available", bool(third.call(&"is_available")))
	_move_player_near(player, third, 20.0)
	await _wait_physics(2)

	# --- interaction path + sprint lock ------------------------------------
	var fourth: Variant = mushrooms[3]
	_move_player_near(player, fourth, 1.5)
	await _wait_physics(3)
	var prompt := str(fourth.call(&"get_interaction_text"))
	_check(
		"interaction text reads 'Gather <species>  [E]' (%s)" % prompt,
		prompt.begins_with("Gather ") and prompt.ends_with("[E]")
	)
	fourth.call(&"interact", player)
	_check("MushroomNode.interact() starts the gather", bool(gathering.call(&"is_gathering")))
	gathering.call(&"cancel")
	await _wait_physics(2)
	_check("cancel() returns to idle", not bool(gathering.call(&"is_gathering")))
	_check("cancelled node stays available", bool(fourth.call(&"is_available")))

	# --- the real input path: camera ray -> prompt -> E -> gather ----------
	var aimed: Variant = mushrooms[4]
	player.global_position = (aimed as Node3D).global_position + Vector3(0.0, 0.9, 3.0)
	player.velocity = Vector3.ZERO
	player.reset_physics_interpolation()
	await _wait_physics(5)
	var focused := prompts[prompts.size() - 1] if not prompts.is_empty() else ""
	_check(
		"interact ray prompts for a nearby mushroom (%s)" % focused,
		focused.begins_with("Gather ") and focused.ends_with("[E]")
	)
	Input.action_press(&"interact")
	await _wait_physics(2)
	Input.action_release(&"interact")
	_check(
		"pressing interact starts the gather through the ray",
		bool(gathering.call(&"is_gathering"))
	)
	if bool(gathering.call(&"is_gathering")):
		gathering.call(&"cancel")
	await _wait_physics(2)

	var sprint_start := player.global_position
	player.call(&"set_gathering", true)
	Input.action_press(&"sprint")
	Input.action_press(&"move_forward")
	await _wait_physics(15)
	var sprinting := bool(player.get(&"is_sprinting"))
	Input.action_release(&"sprint")
	Input.action_release(&"move_forward")
	player.call(&"set_gathering", false)
	var walked := player.global_position.distance_to(sprint_start)
	_check("sprint is locked while gathering", not sprinting)
	_check("the player can still walk while gathering (%.2f m)" % walked, walked > 0.15)

	_finish()


func _available_mushrooms() -> Array:
	var found: Array = []
	for node: Node in get_nodes_in_group(&"interactable"):
		if node.has_method(&"is_available") and node.has_method(&"harvest"):
			if bool(node.call(&"is_available")):
				found.append(node)
	return found


func _move_player_near(player: Node3D, node: Variant, distance: float) -> void:
	var target := (node as Node3D).global_position
	player.global_position = target + Vector3(distance, 0.9, 0.0)
	player.velocity = Vector3.ZERO
	player.reset_physics_interpolation()


func _wait_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _wait_ms(milliseconds: int) -> void:
	var deadline := Time.get_ticks_msec() + milliseconds
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _wait_until(condition: Callable, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await process_frame
	return bool(condition.call())


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _vec(value: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [value.x, value.y, value.z]


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all gathering assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
