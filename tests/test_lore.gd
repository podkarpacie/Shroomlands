extends SceneTree
## Headless lore integrity test. Autoloads are not available to `--script`
## runs, so the data script is preloaded and instantiated directly.

const LoreScript := preload("res://scripts/core/Lore.gd")

var _failures := 0


func _initialize() -> void:
	var lore := LoreScript.new()

	_check("5 biomes", lore.BIOMES.size() == 5)
	_check("4 vocations", lore.VOCATIONS.size() == 4)
	_check("6 mushrooms", lore.MUSHROOMS.size() == 6)
	_check("6 resources", lore.RESOURCES.size() == 6)
	_check("6 cities", lore.CITIES.size() == 6)
	_check("3 factions", lore.FACTIONS.size() == 3)
	_check("8 progression buckets", lore.PROGRESSION.size() == 8)

	for id: String in lore.MUSHROOMS:
		var mushroom: Dictionary = lore.MUSHROOMS[id]
		var biomes: Variant = mushroom.get("biomes")
		_check("%s has a biomes array" % id, biomes is Array)
		if biomes is Array:
			for biome_id: Variant in biomes:
				_check("%s biomes entry '%s' exists" % [id, str(biome_id)], biome_id is String and lore.BIOMES.has(biome_id))
		_check("%s regrow_seconds > 0" % id, float(mushroom.get("regrow_seconds", 0.0)) > 0.0)
		_check("%s toxicity >= 0" % id, int(mushroom.get("toxicity", -1)) >= 0)

	for id: String in lore.VOCATIONS:
		var vocation: Dictionary = lore.VOCATIONS[id]
		var trees: Variant = vocation.get("trees")
		_check("%s has exactly 3 trees" % id, trees is Array and (trees as Array).size() == 3)
		_check("%s has a primary_stat" % id, not str(vocation.get("primary_stat", "")).is_empty())

	for id: String in lore.BIOMES:
		var biome: Dictionary = lore.BIOMES[id]
		var level_range: Variant = biome.get("level_range")
		var range_ok := level_range is Array and (level_range as Array).size() == 2
		_check("%s level_range is [min, max] with min < max" % id, range_ok and int(level_range[0]) < int(level_range[1]))
		_check("%s danger is 1..9" % id, int(biome.get("danger", 0)) >= 1 and int(biome.get("danger", 0)) <= 9)

	for id: String in lore.MUSHROOMS:
		_check("item_display_name resolves mushroom '%s'" % id, lore.item_display_name(id) == str(lore.MUSHROOMS[id]["name"]))
	for id: String in lore.RESOURCES:
		_check("item_display_name resolves resource '%s'" % id, lore.item_display_name(id) == str(lore.RESOURCES[id]["name"]))

	var unknown: Dictionary = lore.get_mushroom("nope")
	_check("get_mushroom('nope') returns an empty Dictionary", unknown.is_empty())

	lore.free()
	if _failures == 0:
		print("PASSED  all lore assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)
