extends SceneTree
## Headless lore integrity test. Autoloads are not available to `--script`
## runs, so the data script is preloaded and instantiated directly.

const LoreScript := preload("res://scripts/core/Lore.gd")
const MUSHROOM_MODEL_DIR := "res://assets/models/mushrooms/"
const RARITIES := ["common", "rare", "epic", "legendary"]

var _failures := 0


func _initialize() -> void:
	var lore := LoreScript.new()

	_check("5 biomes", lore.BIOMES.size() == 5)
	_check("4 vocations", lore.VOCATIONS.size() == 4)
	_check("11 mushrooms", lore.MUSHROOMS.size() == 11)
	_check("11 potions", lore.POTIONS.size() == 11)
	_check("5 depth layers", lore.DEPTH_LAYERS.size() == 5)
	_check("6 resources", lore.RESOURCES.size() == 6)
	_check("6 cities", lore.CITIES.size() == 6)
	_check("3 factions", lore.FACTIONS.size() == 3)
	_check("8 progression buckets", lore.PROGRESSION.size() == 8)

	for id: String in lore.MUSHROOMS:
		var mushroom: Dictionary = lore.MUSHROOMS[id]
		var rarity := str(mushroom.get("rarity", ""))
		_check("%s has a designed rarity (%s)" % [id, rarity], RARITIES.has(rarity))
		var layers: Variant = mushroom.get("layers")
		_check("%s has a layers array" % id, layers is Array and not (layers as Array).is_empty())
		if layers is Array:
			var in_range := true
			for layer: Variant in layers:
				in_range = in_range and int(layer) >= 1 and int(layer) <= 5
			_check("%s layers are within 1..5 (%s)" % [id, str(layers)], in_range)
		_check("%s regrow_seconds > 0" % id, float(mushroom.get("regrow_seconds", 0.0)) > 0.0)
		_check("%s toxicity >= 0" % id, int(mushroom.get("toxicity", -1)) >= 0)
		_check("%s has an eat Dictionary" % id, mushroom.get("eat") is Dictionary)
		_check("%s has a brew recipe" % id, mushroom.get("brew") is Dictionary)

		var model_path := "%s%s.gltf" % [MUSHROOM_MODEL_DIR, id]
		_check(
			"%s has a resolvable model file (%s)" % [id, model_path],
			FileAccess.file_exists(model_path) or ResourceLoader.exists(model_path)
		)

		var brew: Dictionary = mushroom.get("brew", {})
		var potion_id := str(brew.get("potion", ""))
		_check("%s brews a real potion (%s)" % [id, potion_id], lore.POTIONS.has(potion_id))
		_check("%s has a positive brew fee" % id, int(brew.get("fee", 0)) > 0)
		_check(
			"potion_for(%s) resolves the recipe (%s)" % [id, potion_id],
			lore.potion_for(id) == potion_id
		)
		_check("%s has a non-empty description" % id, not str(mushroom.get("description", "")).is_empty())

	for id: String in lore.POTIONS:
		var potion: Dictionary = lore.POTIONS[id]
		_check("%s has its own id" % id, str(potion.get("id", "")) == id)
		_check("%s has a display name" % id, not str(potion.get("name", "")).is_empty())
		var source := str(potion.get("from", ""))
		_check("%s is brewed from a real mushroom (%s)" % [id, source], lore.MUSHROOMS.has(source))
		_check("%s effect is a Dictionary" % id, potion.get("effect") is Dictionary)
		_check("%s has a non-negative fee" % id, int(potion.get("fee", -1)) >= 0)
		_check("%s has a description" % id, not str(potion.get("description", "")).is_empty())
		_check("is_potion(%s) is true" % id, lore.is_potion(id))
		_check("get_potion(%s) returns data" % id, not lore.get_potion(id).is_empty())
		_check(
			"item_display_name resolves potion '%s'" % id,
			lore.item_display_name(id) == str(potion["name"])
		)

	for key: String in lore.DEPTH_LAYERS:
		var layer: Dictionary = lore.DEPTH_LAYERS[key]
		var number := int(layer.get("id", 0))
		_check("layer '%s' has an id 1..5 (%d)" % [key, number], number >= 1 and number <= 5)
		_check("layer '%s' has a name" % key, not str(layer.get("name", "")).is_empty())
		var level_range: Variant = layer.get("level_range")
		_check(
			"layer '%s' level_range is [min, max]" % key,
			level_range is Array and (level_range as Array).size() == 2
				and int(level_range[0]) < int(level_range[1])
		)
		_check("layer '%s' has a danger note" % key, not str(layer.get("danger", "")).is_empty())
		var species: Variant = layer.get("species")
		_check("layer '%s' lists species" % key, species is Array and not (species as Array).is_empty())
		if species is Array:
			var derived := lore.mushrooms_in_layer(number)
			var listed: Array[String] = []
			for mushroom_id: Variant in species:
				listed.append(str(mushroom_id))
			listed.sort()
			derived.sort()
			_check(
				"layer '%s' species match the mushrooms' layers" % key,
				listed == derived
			)

	var starters := lore.mushrooms_in_layer(1)
	starters.sort()
	_check("layer 1 is the starter set", starters == ["konop", "motoko", "shitake"])
	_check("mushrooms_in_layer(9) is empty", lore.mushrooms_in_layer(9).is_empty())
	_check("Konop grows in every layer", lore.MUSHROOMS["konop"]["layers"].size() == 5)

	for rarity: String in RARITIES:
		_check("rarity_color(%s) is set" % rarity, lore.rarity_color(rarity) != Color.WHITE)
	_check("common is pale bone", lore.rarity_color("common") == Color("#cfd8d0"))
	_check("rare is cold blue", lore.rarity_color("rare") == Color("#4a86c8"))
	_check("epic is violet", lore.rarity_color("epic") == Color("#a25bd0"))
	_check("legendary is ember gold", lore.rarity_color("legendary") == Color("#e08a2e"))

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
	_check("get_potion('nope') returns an empty Dictionary", lore.get_potion("nope").is_empty())
	_check("is_potion('konop') is false", not lore.is_potion("konop"))
	_check("potion_for('nope') is empty", lore.potion_for("nope") == "")
	_check("item_display_name leaves unknown ids alone", lore.item_display_name("nope") == "nope")
	_check("item_rarity resolves a potion tier", lore.item_rarity("fury_draught") == "legendary")

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
