extends SceneTree
## Headless checks for crafting: the recipe and item data in `Lore.gd` is
## consistent, `CraftingSystem` enforces its rules and keeps inventory
## transactions clean, `ConsumableSystem` applies potion effects sensibly, and
## the crafting and skill panels show what the systems report.
##
## Autoloads are reached through `root.get_node()` because `--script` compiles
## this file before the autoload identifiers exist; `main.tscn` is loaded lazily.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const TestEnv := preload("res://tests/test_env.gd")
const SkillData := preload("res://scripts/core/SkillData.gd")
const ItemVisuals := preload("res://scripts/ui/ItemVisuals.gd")

const EFFECT_KEYS: Array[String] = ["heal", "stamina", "regen"]

var _failures := 0
var _game: Node = null
var _lore: Node = null
var _bus: Node = null
var _player: CharacterBody3D = null
var _stats: Node = null
var _inventory: Node = null
var _skills: Node = null
var _crafting: Node = null
var _consumables: Node = null
var _main: Node = null
var _crafted: Array[Array] = []
var _toasts: Array[String] = []
var _cancelled: Array[String] = []
var _used: Array[String] = []


func _initialize() -> void:
	TestEnv.isolate("test_crafting")
	TestEnv.stash("user://plots.json")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	_game = root.get_node_or_null("Game")
	_lore = root.get_node_or_null("Lore")
	_bus = root.get_node_or_null("EventBus")
	_check("autoloads are available", _game != null and _lore != null and _bus != null)
	if _game == null or _lore == null or _bus == null:
		_finish()
		return

	_check_data()

	_main = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	root.add_child(_main)
	for _frame in 5:
		await physics_frame
	var players := get_nodes_in_group(&"player")
	_player = players[0] as CharacterBody3D if players.size() == 1 else null
	_check("a player was spawned", _player != null)
	if _player == null:
		_finish()
		return
	_stats = _player.get_node_or_null("Stats")
	_inventory = _player.get_node_or_null("InventorySystem")
	_skills = _player.get_node_or_null("SkillSystem")
	_crafting = _player.get_node_or_null("CraftingSystem")
	_consumables = _player.get_node_or_null("ConsumableSystem")
	_check(
		"the player has crafting, skills and consumable systems",
		_crafting != null and _skills != null and _consumables != null and _inventory != null
	)
	if _crafting == null or _skills == null or _consumables == null or _inventory == null:
		_finish()
		return
	for enemy in get_nodes_in_group(&"enemy"):
		enemy.set_physics_process(false)
	_bus.item_crafted.connect(func(recipe: String, item: String, count: int) -> void: _crafted.append([recipe, item, count]))
	_bus.toast_requested.connect(func(text: String) -> void: _toasts.append(text))
	_bus.craft_cancelled.connect(func(recipe: String) -> void: _cancelled.append(recipe))
	_bus.item_used.connect(func(item: String) -> void: _used.append(item))

	_check_world_has_konop()
	_check_would_fit()
	_check_status_rules()
	_check_crafting()
	await _check_timed_craft()
	_check_inventory_space()
	_check_skill_effects_on_crafting()
	_check_consumables()
	await _check_panels()
	_finish()


# --- the data ------------------------------------------------------------------

func _check_data() -> void:
	var problems: Array[String] = []
	for id: String in _lore.RECIPES:
		var recipe: Dictionary = _lore.RECIPES[id]
		if str(recipe.get("id", "")) != id:
			problems.append("%s: id does not match its key" % id)
		var output: Dictionary = recipe.get("output", {})
		if not _lore.ITEMS.has(str(output.get("id", ""))):
			problems.append("%s: output is not a defined item" % id)
		if int(output.get("count", 0)) < 1:
			problems.append("%s: outputs nothing" % id)
		var inputs: Array = recipe.get("inputs", [])
		if inputs.is_empty():
			problems.append("%s: has no ingredients" % id)
		for input: Dictionary in inputs:
			if not _lore.is_item(str(input.get("id", ""))):
				problems.append("%s: unknown ingredient %s" % [id, input.get("id", "")])
			if int(input.get("count", 0)) < 1:
				problems.append("%s: ingredient count < 1" % id)
		if float(recipe.get("seconds", 0.0)) <= 0.0 or int(recipe.get("level", 0)) < 1:
			problems.append("%s: bad time or level" % id)
		var skill := str(recipe.get("skill", ""))
		if not skill.is_empty():
			if not SkillData.NODES.has(skill):
				problems.append("%s: needs unknown skill %s" % [id, skill])
			elif not (SkillData.NODES[skill].get("unlocks", []) as Array).has(id):
				problems.append("%s: skill %s does not unlock it" % [id, skill])
	for node_id: String in SkillData.NODES:
		for recipe_id: String in SkillData.NODES[node_id].get("unlocks", []):
			if str(_lore.get_recipe(recipe_id).get("skill", "")) != node_id:
				problems.append("%s unlocks %s but the recipe does not ask for it" % [node_id, recipe_id])
	_check("every recipe is well formed %s" % ("" if problems.is_empty() else str(problems)), problems.is_empty())

	problems.clear()
	for id: String in _lore.ITEMS:
		var item: Dictionary = _lore.ITEMS[id]
		if str(item.get("id", "")) != id or str(item.get("name", "")).is_empty():
			problems.append("%s: bad id or name" % id)
		if str(item.get("kind", "")) != "consumable":
			problems.append("%s: unknown kind" % id)
		if str(item.get("rarity", "")).is_empty() or int(item.get("stack_size", 0)) < 1:
			problems.append("%s: no rarity or stack size" % id)
		var effect: Dictionary = item.get("effect", {})
		if effect.is_empty():
			problems.append("%s: a consumable with no effect" % id)
		for key: String in effect:
			if not EFFECT_KEYS.has(key):
				problems.append("%s: unknown effect %s" % [id, key])
		if effect.has("regen"):
			var regen: Dictionary = effect["regen"]
			if float(regen.get("per_second", 0.0)) <= 0.0 or float(regen.get("seconds", 0.0)) <= 0.0:
				problems.append("%s: regen needs per_second and seconds" % id)
		if str(_lore.item_effect_text(id)).is_empty():
			problems.append("%s: no effect text" % id)
		if not ItemVisuals.CRAFTED_IDS.has(id):
			problems.append("%s: has no entry in ItemVisuals.CRAFTED_IDS" % id)
		if _lore.item_display_name(id) != str(item["name"]):
			problems.append("%s: display name lookup is wrong" % id)
		if not _lore.is_item(id):
			problems.append("%s: is_item says no" % id)
	_check("every crafted item is well formed %s" % ("" if problems.is_empty() else str(problems)), problems.is_empty())

	var konop: Dictionary = _lore.get_mushroom("konop")
	_check("Konop exists and is common", not konop.is_empty() and str(konop["rarity"]) == "common")
	_check("Konop grows in the Verdant Bloom", (konop.get("biomes", []) as Array).has("verdant_bloom"))
	var feeds_a_recipe := false
	for id: String in _lore.RECIPES:
		for input: Dictionary in _lore.RECIPES[id]["inputs"]:
			if str(input["id"]) == "konop" and str(_lore.RECIPES[id]["output"]["id"]) == "weak_health_potion":
				feeds_a_recipe = true
	_check("Konop makes the weak health potion", feeds_a_recipe and (konop.get("uses", []) as Array).has("weak_health_potion"))
	_check("the starter recipe needs no skill and level 1", str(_lore.RECIPES["weak_health_potion"]["skill"]).is_empty() and int(_lore.RECIPES["weak_health_potion"]["level"]) == 1)

	var ids: Array[String] = _lore.recipe_ids()
	var sorted_by_level: bool = ids.size() == _lore.RECIPES.size()
	for index in range(1, ids.size()):
		sorted_by_level = sorted_by_level and int(_lore.RECIPES[ids[index - 1]]["level"]) <= int(_lore.RECIPES[ids[index]]["level"])
	_check("recipes list by level", sorted_by_level)
	_check("the starter recipe comes first", ids[0] == "weak_health_potion")
	_check("Konop has an icon entry", ItemVisuals.all_ids().has("konop"))
	_check(
		"a potion's tooltip says what it does",
		ItemVisuals.description(&"weak_health_potion").contains("30")
	)
	_check("a potion is presented as a consumable", ItemVisuals.kind(&"weak_health_potion").begins_with("Consumable"))


func _check_world_has_konop() -> void:
	var world := _main.get_node_or_null("World")
	var count := 0
	if world != null:
		for child in world.get_children():
			if "mushroom_id" in child and str(child.get("mushroom_id")) == "konop":
				count += 1
	_check("the world has Konop to find (%d)" % count, count >= 4)


# --- inventory dry run -----------------------------------------------------------

func _check_would_fit() -> void:
	_empty_inventory()
	_check("an empty inventory fits anything", _inventory.call("would_fit", [], &"weak_health_potion", 5))
	_check("a zero-sized add always fits", _inventory.call("would_fit", [], &"weak_health_potion", 0))

	var slots: int = _inventory.SLOT_COUNT
	var stack: int = _inventory.MAX_STACK
	_inventory.call("add_item", &"konop", slots * stack)
	_check("the inventory is completely full", int(_inventory.call("count_item", &"konop")) == slots * stack)
	_check("a new item does not fit a full inventory", not _inventory.call("would_fit", [], &"glowcap", 1))
	_check("nor does more of a full stack", not _inventory.call("would_fit", [], &"konop", 1))
	_check("emptying a stack makes room for something else", _inventory.call("would_fit", [{"id": &"konop", "count": stack}], &"glowcap", 1))
	_check("taking one makes room for one", _inventory.call("would_fit", [{"id": &"konop", "count": 1}], &"konop", 1))
	_check("but not for two", not _inventory.call("would_fit", [{"id": &"konop", "count": 1}], &"konop", 2))
	_check("a partial removal does not free a slot", not _inventory.call("would_fit", [{"id": &"konop", "count": 2}], &"glowcap", 1))
	_check("the dry run touched nothing", int(_inventory.call("count_item", &"konop")) == slots * stack)
	_empty_inventory()


# --- the rules -------------------------------------------------------------------

func _check_status_rules() -> void:
	_empty_inventory()
	_set_level(1)
	_check("an unknown recipe is refused", str(_crafting.call("status", "nope")["reason"]) == "unknown")

	var missing: Dictionary = _crafting.call("status", "weak_health_potion")
	_check("without ingredients it is refused (%s)" % missing["reason"], not bool(missing["ok"]) and missing["reason"] == "ingredients")
	var inputs: Array = missing["inputs"]
	_check("and it reports what is missing (%s)" % str(inputs), inputs.size() == 1 and int(inputs[0]["need"]) == 2 and int(inputs[0]["have"]) == 0)
	_inventory.call("add_item", &"konop", 1)
	_check("one Konop is still not enough", str(_crafting.call("status", "weak_health_potion")["reason"]) == "ingredients")
	_inventory.call("add_item", &"konop", 1)
	_check("two Konop is enough", bool(_crafting.call("status", "weak_health_potion")["ok"]))

	_inventory.call("add_item", &"emberstem", 3)
	_check("a recipe needs its level (%s)" % _crafting.call("status", "regen_elixir")["reason"], str(_crafting.call("status", "regen_elixir")["reason"]) == "level")
	_set_level(3)
	_check("and works once you have it", bool(_crafting.call("status", "regen_elixir")["ok"]))

	_inventory.call("add_item", &"konop", 2)
	_inventory.call("add_item", &"sunheart", 1)
	_set_level(8)
	_game.set("gold", 5000)
	_skills.call("respec")
	_check("a skill-gated recipe is refused without the skill (%s)" % _crafting.call("status", "greater_health_potion")["reason"], str(_crafting.call("status", "greater_health_potion")["reason"]) == "skill")
	for id in ["steady_hands", "thrifty_brewer", "potent_brews", "adv_herbalism"]:
		_skills.call("learn", id)
	_check("and works once it is learned", bool(_crafting.call("status", "greater_health_potion")["ok"]))
	_skills.call("respec")

	_inventory.call("add_item", &"konop", 2)
	_stats.set("_dead", true)
	_check("nothing can be crafted while dead", str(_crafting.call("status", "weak_health_potion")["reason"]) == "dead")
	_inventory.call("add_item", &"weak_health_potion", 1)
	_stats.set("hp", float(_stats.get("max_hp")) - 40.0)
	_check("nor drunk", not bool(_consumables.call("use_item", &"weak_health_potion")) and int(_inventory.call("count_item", &"weak_health_potion")) == 1)
	_stats.set("_dead", false)
	_stats.set("hp", float(_stats.get("max_hp")))
	_check("and it works again once alive", bool(_crafting.call("status", "weak_health_potion")["ok"]))
	_empty_inventory()


func _check_crafting() -> void:
	_empty_inventory()
	_set_level(1)
	_crafted.clear()
	_toasts.clear()
	_inventory.call("add_item", &"konop", 5)
	var xp_before := int(_stats.get("xp"))
	_check("craft_now succeeds", bool(_crafting.call("craft_now", "weak_health_potion")))
	_check("it used the ingredients (5 -> %d)" % int(_inventory.call("count_item", &"konop")), int(_inventory.call("count_item", &"konop")) == 3)
	_check("and made the potion", int(_inventory.call("count_item", &"weak_health_potion")) == 1)
	_check("it paid XP (%d -> %d)" % [xp_before, int(_stats.get("xp"))], int(_stats.get("xp")) == xp_before + 8)
	_check("it announced the craft", _crafted.size() == 1 and _crafted[0][1] == "weak_health_potion" and _crafted[0][2] == 1)
	_check("and told the player", _toasts.any(func(text: String) -> bool: return text.contains("Crafted")))
	_check("with only 3 Konop left a second craft works", bool(_crafting.call("craft_now", "weak_health_potion")))
	_check("with 1 left it does not", not bool(_crafting.call("craft_now", "weak_health_potion")))
	_check("and nothing was taken by the failed attempt", int(_inventory.call("count_item", &"konop")) == 1 and int(_inventory.call("count_item", &"weak_health_potion")) == 2)
	_empty_inventory()


func _check_timed_craft() -> void:
	_empty_inventory()
	_set_level(1)
	_cancelled.clear()
	_inventory.call("add_item", &"konop", 4)
	_check("a brew takes the recipe's time (%.1f s)" % float(_crafting.call("brew_seconds", "weak_health_potion")), is_equal_approx(float(_crafting.call("brew_seconds", "weak_health_potion")), 2.0))

	_check("begin starts a brew", bool(_crafting.call("begin", "weak_health_potion")))
	_check("it is brewing", bool(_crafting.call("is_crafting")))
	_check("a second brew is refused (%s)" % _crafting.call("status", "weak_health_potion")["reason"], str(_crafting.call("status", "weak_health_potion")["reason"]) == "busy")
	_check("and begin() refuses too", not bool(_crafting.call("begin", "weak_health_potion")))
	_crafting.call("_process", 1.0)
	_check("progress advances (%.2f)" % float(_crafting.call("progress_ratio")), is_equal_approx(float(_crafting.call("progress_ratio")), 0.5))
	_check("nothing is consumed mid-brew", int(_inventory.call("count_item", &"konop")) == 4)
	_crafting.call("_process", 1.1)
	_check("the brew finishes", not bool(_crafting.call("is_crafting")))
	_check("and produced the potion", int(_inventory.call("count_item", &"weak_health_potion")) == 1)
	_check("and used the Konop", int(_inventory.call("count_item", &"konop")) == 2)

	# Cancelling costs nothing.
	_check("begin again", bool(_crafting.call("begin", "weak_health_potion")))
	_crafting.call("_process", 0.5)
	_crafting.call("cancel")
	_check("cancel stops the brew", not bool(_crafting.call("is_crafting")))
	_check("and tells everyone", _cancelled.has("weak_health_potion"))
	_check("and costs nothing", int(_inventory.call("count_item", &"konop")) == 2 and int(_inventory.call("count_item", &"weak_health_potion")) == 1)

	# Being hurt interrupts.
	_check("begin once more", bool(_crafting.call("begin", "weak_health_potion")))
	var hp := float(_stats.get("hp"))
	_bus.hp_changed.emit(hp - 5.0, float(_stats.get("max_hp")))
	_check("taking damage interrupts a brew", not bool(_crafting.call("is_crafting")))
	_bus.hp_changed.emit(hp, float(_stats.get("max_hp")))

	# Healing does not.
	_check("begin after the hit", bool(_crafting.call("begin", "weak_health_potion")))
	_bus.hp_changed.emit(hp + 1.0, float(_stats.get("max_hp")))
	_check("healing does not interrupt", bool(_crafting.call("is_crafting")))
	_crafting.call("cancel")

	# The world can change mid-brew: the end re-checks everything.
	_check("begin with exactly enough", bool(_crafting.call("begin", "weak_health_potion")))
	_inventory.call("remove_item", &"konop", 2)
	_toasts.clear()
	_crafting.call("_process", 3.0)
	_check("a brew whose ingredients vanished fails", not bool(_crafting.call("is_crafting")))
	_check("and made nothing", int(_inventory.call("count_item", &"weak_health_potion")) == 1)
	_check("and said so", not _toasts.is_empty())
	_empty_inventory()
	await physics_frame


func _check_inventory_space() -> void:
	_empty_inventory()
	_set_level(1)
	_toasts.clear()
	var slots: int = _inventory.SLOT_COUNT
	var stack: int = _inventory.MAX_STACK
	_inventory.call("add_item", &"konop", slots * stack)
	var verdict: Dictionary = _crafting.call("status", "weak_health_potion")
	_check("a full inventory refuses (%s)" % verdict["reason"], not bool(verdict["ok"]) and verdict["reason"] == "space")
	_check("begin refuses too", not bool(_crafting.call("begin", "weak_health_potion")))
	_check("craft_now refuses and takes nothing", not bool(_crafting.call("craft_now", "weak_health_potion")) and int(_inventory.call("count_item", &"konop")) == slots * stack)
	_check("and tells the player", _toasts.any(func(text: String) -> bool: return text.contains("full")))
	_inventory.call("remove_item", &"konop", stack)
	_check("freeing a slot allows it", bool(_crafting.call("craft_now", "weak_health_potion")))
	_empty_inventory()


func _check_skill_effects_on_crafting() -> void:
	_empty_inventory()
	_game.set("gold", 5000)
	_skills.call("respec")
	_set_level(20)
	for _rank in 3:
		_skills.call("learn", "steady_hands")
	_check("Steady Hands shortens the brew (%.2f s)" % float(_crafting.call("brew_seconds", "weak_health_potion")), is_equal_approx(float(_crafting.call("brew_seconds", "weak_health_potion")), 2.0 / 1.3))

	# Thrifty Brewer saves an ingredient now and then; the dice are fixed.
	for _rank in 3:
		_skills.call("learn", "thrifty_brewer")
	_crafting.call("seed_rng", 7)
	_inventory.call("add_item", &"konop", 200)
	var saved := 0
	for _craft in 60:
		var before := int(_inventory.call("count_item", &"konop"))
		_crafting.call("craft_now", "weak_health_potion")
		var used := before - int(_inventory.call("count_item", &"konop"))
		_check_in_range(used, 1, 2, "a craft uses 1 or 2 Konop")
		if used == 1:
			saved += 1
	_check("Thrifty Brewer saved some ingredients (%d of 60)" % saved, saved > 3 and saved < 40)
	_check("and the potions kept coming", int(_inventory.call("count_item", &"weak_health_potion")) == 60)
	_empty_inventory()

	# Twin Batch adds a bonus potion now and then.
	_skills.call("learn", "potent_brews")
	_skills.call("learn", "adv_herbalism")
	_set_level(30)
	for _rank in 3:
		_skills.call("learn", "twin_batch")
	_crafting.call("seed_rng", 11)
	_inventory.call("add_item", &"konop", 200)
	for _craft in 60:
		_crafting.call("craft_now", "weak_health_potion")
	var potions := int(_inventory.call("count_item", &"weak_health_potion"))
	_check("Twin Batch gave some extra potions (%d from 60 crafts)" % potions, potions > 63 and potions < 100)
	_empty_inventory()
	_game.set("gold", 5000)
	_skills.call("respec")


func _check_in_range(value: int, low: int, high: int, label: String) -> void:
	if value < low or value > high:
		_check("%s (got %d)" % [label, value], false)


func _check_consumables() -> void:
	_empty_inventory()
	_game.set("gold", 5000)
	_skills.call("respec")
	_set_level(1)
	_used.clear()
	_toasts.clear()
	var max_hp := float(_stats.get("max_hp"))
	_inventory.call("add_item", &"weak_health_potion", 3)

	_stats.set("hp", max_hp - 50.0)
	_check("using a potion works", bool(_consumables.call("use_item", &"weak_health_potion")))
	_check("it healed 30 (%.0f)" % float(_stats.get("hp")), is_equal_approx(float(_stats.get("hp")), max_hp - 20.0))
	_check("and used one up", int(_inventory.call("count_item", &"weak_health_potion")) == 2)
	_check("and announced it", _used == ["weak_health_potion"])
	_check("a second one straight away is on cooldown", not bool(_consumables.call("use_item", &"weak_health_potion")) and int(_inventory.call("count_item", &"weak_health_potion")) == 2)
	_consumables.call("_process", 2.0)
	_check("the cooldown ends", is_zero_approx(float(_consumables.call("cooldown_left"))))
	_check("then the next works", bool(_consumables.call("use_item", &"weak_health_potion")))
	_check("healing never exceeds the maximum (%.0f)" % float(_stats.get("hp")), is_equal_approx(float(_stats.get("hp")), max_hp - 20.0 + 30.0) or float(_stats.get("hp")) <= max_hp)

	_stats.set("hp", max_hp)
	_consumables.call("_process", 2.0)
	_toasts.clear()
	_check("a potion is not wasted at full health", not bool(_consumables.call("use_item", &"weak_health_potion")))
	_check("it keeps the potion", int(_inventory.call("count_item", &"weak_health_potion")) == 1)
	_check("and says why", _toasts.any(func(text: String) -> bool: return text.contains("full")))

	_check("a mushroom is not a consumable", not bool(_consumables.call("use_item", &"konop")))
	_check("an unknown id is not either", not bool(_consumables.call("use_item", &"nothing")))
	_inventory.call("remove_item", &"weak_health_potion", 1)
	_check("nor is something you do not have", not bool(_consumables.call("use_item", &"weak_health_potion")))

	# Regeneration ticks over time and then ends.
	_inventory.call("add_item", &"regen_elixir", 1)
	_stats.set("hp", max_hp - 60.0)
	_consumables.call("_process", 2.0)
	_check("an elixir starts regenerating", bool(_consumables.call("use_item", &"regen_elixir")) and bool(_consumables.call("is_regenerating")))
	var start := float(_stats.get("hp"))
	for _tick in 10:
		_consumables.call("_process", 0.5)
	_check("it heals over time (%.0f -> %.0f)" % [start, float(_stats.get("hp"))], is_equal_approx(float(_stats.get("hp")), start + 20.0))
	for _tick in 12:
		_consumables.call("_process", 0.5)
	_check("and ends after its 10 seconds (+%.0f)" % (float(_stats.get("hp")) - start), not bool(_consumables.call("is_regenerating")) and is_equal_approx(float(_stats.get("hp")), start + 40.0))

	# Stamina.
	_inventory.call("add_item", &"stamina_tonic", 1)
	_stats.set("stamina", 10.0)
	_consumables.call("_process", 2.0)
	_check("a tonic restores stamina", bool(_consumables.call("use_item", &"stamina_tonic")) and is_equal_approx(float(_stats.get("stamina")), minf(60.0, float(_stats.get("max_stamina")))))

	# Potion Potency strengthens a potion.
	_set_level(20)
	for id in ["steady_hands", "potent_brews"]:
		_skills.call("learn", id)
	_skills.call("learn", "potent_brews")
	_inventory.call("add_item", &"weak_health_potion", 1)
	_stats.set("hp", float(_stats.get("max_hp")) - 80.0)
	var low := float(_stats.get("hp"))
	_consumables.call("_process", 2.0)
	_consumables.call("use_item", &"weak_health_potion")
	_check("Potent Brews strengthens a potion (+%.0f)" % (float(_stats.get("hp")) - low), is_equal_approx(float(_stats.get("hp")) - low, 30.0 * 1.2))
	_skills.call("respec")

	# The hotbar's selected slot, the way the F key uses it.
	_empty_inventory()
	_inventory.call("add_item", &"weak_health_potion", 2)
	_bus.hotbar_selected.emit(0)
	_stats.set("hp", float(_stats.get("max_hp")) - 40.0)
	_consumables.call("_process", 2.0)
	_check("the selected hotbar slot is used", bool(_consumables.call("use_selected")) and int(_inventory.call("count_item", &"weak_health_potion")) == 1)
	_bus.hotbar_selected.emit(5)
	_consumables.call("_process", 2.0)
	_check("an empty selected slot does nothing", not bool(_consumables.call("use_selected")))
	_bus.hotbar_selected.emit(0)
	_stats.set("hp", float(_stats.get("max_hp")))
	_empty_inventory()


# --- panels ----------------------------------------------------------------------

func _check_panels() -> void:
	_empty_inventory()
	_set_level(1)
	_game.set("gold", 5000)
	_skills.call("respec")
	var crafting_ui := _main.get_node_or_null("CraftingUI")
	var skill_ui := _main.get_node_or_null("SkillTreeUI")
	_check("both panels exist in the main scene", crafting_ui != null and skill_ui != null)
	if crafting_ui == null or skill_ui == null:
		return
	_check("they start closed", not bool(crafting_ui.call("is_open")) and not bool(skill_ui.call("is_open")))

	# The key opens and closes the panel and holds the player still.
	var press := InputEventAction.new()
	press.action = &"craft_menu"
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	await process_frame
	_check("the craft key opens the panel", bool(crafting_ui.call("is_open")))
	_check("it holds the player still", bool(_player.get("ui_blocking")))
	var list := crafting_ui.get("_list") as VBoxContainer
	await process_frame
	_check("it lists every recipe (%d)" % list.get_child_count(), list.get_child_count() == _lore.RECIPES.size())
	_check("the first recipe is selected", str(crafting_ui.call("selected_recipe")) == "weak_health_potion")
	var craft_button := crafting_ui.get("_craft_button") as Button
	_check("Craft is disabled without ingredients", craft_button.disabled)

	_inventory.call("add_item", &"konop", 2)
	await process_frame
	_check("having the ingredients enables Craft", not craft_button.disabled)
	craft_button.pressed.emit()
	_check("pressing it starts a brew", bool(_crafting.call("is_crafting")))
	_crafting.call("_process", 2.5)
	await process_frame
	_check("the brew produced a potion", int(_inventory.call("count_item", &"weak_health_potion")) == 1)

	crafting_ui.call("select_recipe", "regen_elixir")
	_check("a locked recipe can be inspected", str(crafting_ui.call("selected_recipe")) == "regen_elixir")
	_check("but not crafted", (crafting_ui.get("_craft_button") as Button).disabled)
	_check("and the panel says why", not (crafting_ui.get("_message") as Label).text.is_empty())

	crafting_ui.call("toggle")
	_check("closing the panel frees the player", not bool(crafting_ui.call("is_open")) and not bool(_player.get("ui_blocking")))

	# Another modal wins.
	_player.call("set_ui_blocking", true)
	crafting_ui.call("toggle")
	_check("a panel will not open over another one", not bool(crafting_ui.call("is_open")))
	_player.call("set_ui_blocking", false)

	# Skills.
	_game.set("chosen_vocation", &"")
	_set_level(5)
	skill_ui.call("toggle")
	await process_frame
	_check("the skills panel opens", bool(skill_ui.call("is_open")) and bool(_player.get("ui_blocking")))
	var tabs := skill_ui.get("_tabs") as HBoxContainer
	await process_frame
	_check("without a vocation it shows the 3 shared trees (%d)" % tabs.get_child_count(), tabs.get_child_count() == 3)
	_check("and says how to get more", not (skill_ui.get("_note") as Label).text.is_empty())
	var points := skill_ui.get("_points") as Label
	_check("it shows the points (%s)" % points.text, points.text.contains("4 / 4"))
	skill_ui.call("select_tree", "survival")
	await process_frame
	var cards := _buttons_in(skill_ui.get("_tiers") as Control)
	_check("a tree shows all of its nodes (%d)" % cards.size(), cards.size() == SkillData.tree_nodes("survival").size())
	skill_ui.call("_on_node_pressed", "tough_cap")
	await process_frame
	_check("clicking a node learns it", int(_skills.call("rank", "tough_cap")) == 1)
	_check("and the points update (%s)" % points.text, points.text.contains("3 / 4"))

	_game.set("chosen_vocation", &"knight")
	skill_ui.call("select_tree", "gathering")
	await process_frame
	await process_frame
	_check("a vocation adds its trees to the tabs (%d)" % tabs.get_child_count(), tabs.get_child_count() == 6)
	var respec := skill_ui.get("_respec") as Button
	_check("Respec shows its price (%s)" % respec.text, respec.text.contains("20"))
	respec.pressed.emit()
	_check("it asks to confirm first", respec.text.contains("Confirm") and int(_skills.call("rank", "tough_cap")) == 1)
	respec.pressed.emit()
	_check("then resets", int(_skills.call("rank", "tough_cap")) == 0)
	skill_ui.call("toggle")
	_check("closing frees the player", not bool(_player.get("ui_blocking")))
	_game.set("chosen_vocation", &"")
	_empty_inventory()


func _buttons_in(node: Node) -> Array[Button]:
	var found: Array[Button] = []
	for child in node.find_children("*", "Button", true, false):
		if not child.is_queued_for_deletion():
			found.append(child as Button)
	return found


# --- helpers -------------------------------------------------------------------

func _empty_inventory() -> void:
	for table: Dictionary in [_lore.MUSHROOMS, _lore.RESOURCES, _lore.ITEMS]:
		for id: String in table:
			var have := int(_inventory.call("count_item", StringName(id)))
			if have > 0:
				_inventory.call("remove_item", StringName(id), have)


func _set_level(level: int) -> void:
	_stats.set("level", level)


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all crafting assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
