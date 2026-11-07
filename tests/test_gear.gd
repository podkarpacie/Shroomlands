extends SceneTree
## Gear test: the six materials are sourced by the right structures, the four
## craftable items occupy real slots, and each effect changes the number it owns:
## armour reduces damage, the bright lamp lengthens the beam and battery, the
## boots quiet the voice and the pack quiets a crate search. The Workshop spends
## materials and gold, the save round-trips gear, and every slot is exclusive.

const TestEnv := preload("res://tests/test_env.gd")
const PLAYER_SCENE := "res://scenes/player/player.tscn"
const CRATE_SCENE := "res://scenes/world/searchable_crate.tscn"
const WORKSHOP_SCENE := "res://scenes/ui/workshop.tscn"

var _failures := 0
var _radius := -1.0


func _initialize() -> void:
	TestEnv.isolate("test_gear")
	TestEnv.stash("user://plots.json")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	var game: Node = root.get_node_or_null("Game")
	var bus: Node = root.get_node_or_null("EventBus")
	var lore: Node = root.get_node_or_null("Lore")
	_check("autoloads exist", game != null and bus != null and lore != null)
	if game == null or bus == null or lore == null:
		_finish()
		return

	# --- data --------------------------------------------------------------
	var slots := {}
	for id: String in ["quiet_boots", "muffled_pack", "bright_lamp", "mycelium_vest"]:
		var gear: Dictionary = lore.call(&"get_gear", id)
		_check("%s is a known gear item" % id, bool(lore.call(&"is_gear", id)) and not gear.is_empty())
		var slot := str(gear.get("slot", ""))
		_check("%s has a unique slot (%s)" % [id, slot], not slot.is_empty() and not slots.has(slot))
		slots[slot] = true
		var recipe: Dictionary = gear.get("recipe", {})
		_check("%s has a recipe with a fee" % id, recipe is Dictionary and int(recipe.get("fee", 0)) > 0)
		for resource_id: String in (recipe.get("resources", {}) as Dictionary):
			_check("%s uses a real resource (%s)" % [id, resource_id],
				(lore.get_script().get_script_constant_map()["RESOURCES"] as Dictionary).has(resource_id))

	# Every one of the six resources must drop somewhere: five from the three
	# structure tables, the ancient core from a layer-5 dungeon.
	var sourced := {}
	var constants: Dictionary = lore.get_script().get_script_constant_map()
	for kind: int in (constants["STRUCTURE_RESOURCES"] as Dictionary):
		for resource_id: String in (constants["STRUCTURE_RESOURCES"] as Dictionary)[kind]:
			sourced[resource_id] = true
	sourced["ancient_core"] = true
	var missing: Array[String] = []
	for resource_id: String in (constants["RESOURCES"] as Dictionary):
		if not sourced.has(resource_id):
			missing.append(resource_id)
	_check("all six resources are sourced (%d, missing %s)" % [sourced.size(), missing],
		missing.is_empty() and sourced.size() == 6)

	# --- player ------------------------------------------------------------
	var player: Node3D = load(PLAYER_SCENE).instantiate()
	root.add_child(player)
	await physics_frame
	var inventory: Node = player.get_node_or_null("InventorySystem")
	var stats: Node = player.get_node_or_null("Stats")
	var lamp: Node = player.get_node_or_null("SporeLamp")
	var voice: Node = player.get_node_or_null("VoiceInput")
	_check("the player has inventory, stats, lamp and voice",
		inventory != null and stats != null and lamp != null and voice != null)
	if inventory == null or stats == null or lamp == null or voice == null:
		_finish()
		return
	bus.connect(&"disturbance_emitted", func(_pos: Vector3, radius: float) -> void:
		_radius = radius)

	# --- slots -------------------------------------------------------------
	for id: String in slots:
		pass
	inventory.call(&"add_item", &"quiet_boots", 1)
	inventory.call(&"add_item", &"muffled_pack", 1)
	inventory.call(&"add_item", &"bright_lamp", 1)
	inventory.call(&"add_item", &"mycelium_vest", 1)
	_check("gear does not stack (%d)" % int(inventory.call(&"count_item", &"quiet_boots")),
		int(inventory.call(&"max_stack", &"quiet_boots")) == 1)
	_check("the boots equip", bool(inventory.call(&"equip_gear", &"quiet_boots")))
	_check("the boots occupy the feet slot (%s)" % inventory.get(&"equipped_gear"),
		StringName(inventory.call(&"gear_in_slot", "feet")) == &"quiet_boots")
	_check("the vest equips", bool(inventory.call(&"equip_gear", &"mycelium_vest")))
	_check("two slots can be worn at once (%d)" % (inventory.get(&"equipped_gear") as Dictionary).size(),
		(inventory.get(&"equipped_gear") as Dictionary).size() == 2)
	_check("gear multipliers read from the worn items (noise %.2f, armour %.2f)" % [
			float(inventory.call(&"gear_multiplier", "noise_mult")),
			float(inventory.call(&"gear_multiplier", "armor_mult")),
		],
		is_equal_approx(float(inventory.call(&"gear_multiplier", "noise_mult")), 0.6)
			and is_equal_approx(float(inventory.call(&"gear_multiplier", "armor_mult")), 0.85))
	inventory.call(&"unequip_gear", "feet")
	_check("unequipping frees the slot (%s)" % inventory.call(&"gear_in_slot", "feet"),
		StringName(inventory.call(&"gear_in_slot", "feet")) == &"")
	inventory.call(&"equip_gear", &"quiet_boots")

	# --- armour ------------------------------------------------------------
	stats.set("hp", 100.0)
	stats.call(&"take_damage", 20.0)
	_check("the vest turns 20 damage into 17 (hp %.1f)" % float(stats.get("hp")),
		is_equal_approx(float(stats.get("hp")), 83.0)
			and is_equal_approx(float(stats.call(&"incoming_damage_multiplier")), 0.85))
	inventory.call(&"unequip_gear", "body")
	stats.set("hp", 100.0)
	stats.call(&"take_damage", 20.0)
	_check("without the vest 20 damage is 20 (hp %.1f)" % float(stats.get("hp")),
		is_equal_approx(float(stats.get("hp")), 80.0))

	# --- bright lamp -------------------------------------------------------
	var base_range := float(lamp.get("spot_range"))
	var base_energy := float(lamp.get("light_energy"))
	var base_battery := float(lamp.get("battery_seconds"))
	_check("the base lamp is the scene's (%.1f m, %.1f)" % [base_range, base_energy],
		is_equal_approx(base_range, 22.0) and is_equal_approx(base_energy, 9.0))
	_check("the bright lamp equips", bool(inventory.call(&"equip_gear", &"bright_lamp")))
	_check("the bright lamp widens the beam (%.1f m)" % float(lamp.get("spot_range")),
		is_equal_approx(float(lamp.get("spot_range")), base_range * 1.35))
	_check("it brightens the beam (%.3f)" % float(lamp.get("light_energy")),
		is_equal_approx(float(lamp.get("light_energy")), base_energy * 1.25))
	_check("it grows the battery (%.1f s)" % float(lamp.get("battery_seconds")),
		is_equal_approx(float(lamp.get("battery_seconds")), base_battery * 1.25))
	inventory.call(&"unequip_gear", "light")
	_check("removing the lamp restores the base beam (%.1f m)" % float(lamp.get("spot_range")),
		is_equal_approx(float(lamp.get("spot_range")), base_range)
			and is_equal_approx(float(lamp.get("battery_seconds")), base_battery))

	# --- quiet boots and muffled pack -------------------------------------
	_radius = -1.0
	inventory.call(&"unequip_gear", "feet")
	var loud := float(voice.call(&"_emit"))
	var loud_radius := _radius
	_radius = -1.0
	inventory.call(&"equip_gear", &"quiet_boots")
	var quiet := float(voice.call(&"_emit"))
	_check("quiet boots shrink the shout (%.1f -> %.1f of %.1f)" % [loud, quiet, loud_radius],
		quiet < loud and is_equal_approx(quiet, loud * 0.6)
			and is_equal_approx(quiet, loud_radius * 0.6))

	var crate: Node3D = load(CRATE_SCENE).instantiate()
	crate.set(&"noise_radius", 14.0)
	crate.set(&"loot", [])
	crate.set(&"gold", 0)
	root.add_child(crate)
	await physics_frame
	_radius = -1.0
	crate.set(&"searching", true)
	crate.set(&"_searcher", player)
	crate.call(&"_complete")
	_check("an un-muffled search is heard at 14 m (%.1f)" % _radius, is_equal_approx(_radius, 14.0))
	var crate2: Node3D = load(CRATE_SCENE).instantiate()
	crate2.set(&"noise_radius", 14.0)
	crate2.set(&"loot", [])
	crate2.set(&"gold", 0)
	root.add_child(crate2)
	await physics_frame
	inventory.call(&"equip_gear", &"muffled_pack")
	_radius = -1.0
	crate2.set(&"searching", true)
	crate2.set(&"_searcher", player)
	crate2.call(&"_complete")
	_check("the muffled pack halves the search noise (%.1f)" % _radius,
		is_equal_approx(_radius, 7.0))
	crate.queue_free()
	crate2.queue_free()

	# --- save round-trip ---------------------------------------------------
	var packed: Dictionary = inventory.call(&"to_dict")
	_check("the save carries the worn gear (%s)" % packed.get("gear", {}),
		packed.get("gear") is Dictionary
			and (packed.get("gear") as Dictionary).get("back", "") == "muffled_pack")
	inventory.call(&"from_dict", {"slots": {}})
	_check("an empty bag clears the gear", (inventory.get(&"equipped_gear") as Dictionary).is_empty())
	inventory.call(&"from_dict", packed)
	_check("gear round-trips (back %s)" % inventory.call(&"gear_in_slot", "back"),
		StringName(inventory.call(&"gear_in_slot", "back")) == &"muffled_pack")

	# --- workshop ----------------------------------------------------------
	var workshop: Node = load(WORKSHOP_SCENE).instantiate()
	root.add_child(workshop)
	await process_frame
	_check("the workshop lists all four recipes (%d)" % (workshop.call(&"get_offered_ids") as Array).size(),
		(workshop.call(&"get_offered_ids") as Array).size() == 4)
	# Tools already in the bag; craft the two missing pieces from materials.
	inventory.call(&"from_dict", {})
	game.set(&"gold", 500)
	for resource_id: String in ["mycelium_fiber", "spore_crystals", "hardened_mycelium", "fossilized_caps"]:
		inventory.call(&"add_item", StringName(resource_id), 6)
	_check("crafting the bright lamp succeeds", bool(workshop.call(&"craft", "bright_lamp")))
	_check("the lamp is in the bag (%d)" % int(inventory.call(&"count_item", &"bright_lamp")),
		int(inventory.call(&"count_item", &"bright_lamp")) == 1)
	_check("crafting spends the crystals (6 -> %d)" % int(inventory.call(&"count_item", &"spore_crystals")),
		int(inventory.call(&"count_item", &"spore_crystals")) == 4)
	_check("crafting spends 30 g (500 -> %d)" % int(game.get(&"gold")),
		int(game.get(&"gold")) == 470)
	_check("crafting the same piece again is refused", not bool(workshop.call(&"craft", "bright_lamp")))
	_check("a refused craft spends no gold (%d)" % int(game.get(&"gold")), int(game.get(&"gold")) == 470)
	_check("crafting the vest succeeds", bool(workshop.call(&"craft", "mycelium_vest")))
	_check("the vest takes 3 hardened mycelium (6 -> %d)" % int(inventory.call(&"count_item", &"hardened_mycelium")),
		int(inventory.call(&"count_item", &"hardened_mycelium")) == 3)
	# A missing material refuses without spending.
	inventory.call(&"clear_slot", 47)
	for index: int in 48:
		var slot: Dictionary = (inventory.get(&"slots") as Array)[index]
		if not slot.is_empty() and str(slot.get("id", "")) == "fossilized_caps":
			inventory.call(&"clear_slot", index)
	var before_gold := int(game.get(&"gold"))
	_check("a missing material refuses the pack", not bool(workshop.call(&"craft", "muffled_pack")))
	_check("a refused craft keeps the gold (%d)" % int(game.get(&"gold")),
		int(game.get(&"gold")) == before_gold)
	workshop.queue_free()

	_finish()


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all gear assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
