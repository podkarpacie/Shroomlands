extends SceneTree
## Headless checks for the skill tree: the data in `SkillData.gd` is consistent,
## and `SkillSystem` enforces the rules (points, prerequisites, levels,
## vocations), applies and reverts its effects, charges for a respec and survives
## a save/load round trip, including a tampered file.
##
## Autoloads are reached through `root.get_node()` because `--script` compiles
## this file before the autoload identifiers exist; `main.tscn` is loaded lazily.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const TestEnv := preload("res://tests/test_env.gd")
const SkillData := preload("res://scripts/core/SkillData.gd")

const KNOWN_STATS: Array[String] = [
	"max_hp", "max_stamina", "stamina_regen", "walk_speed", "sprint_speed",
	"damage_mult", "crit_chance", "gather_speed", "gather_yield_chance",
	"craft_speed", "craft_save_chance", "craft_bonus_chance", "potion_potency",
]

var _failures := 0
var _game: Node = null
var _lore: Node = null
var _saves: Node = null
var _player: CharacterBody3D = null
var _stats: Node = null
var _skills: Node = null


func _initialize() -> void:
	TestEnv.isolate("test_skills")
	TestEnv.stash("user://plots.json")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	_game = root.get_node_or_null("Game")
	_lore = root.get_node_or_null("Lore")
	_saves = root.get_node_or_null("SaveSystem")
	_check("autoloads are available", _game != null and _lore != null and _saves != null)
	if _game == null or _lore == null or _saves == null:
		_finish()
		return

	_check_data()

	var packed := load(MAIN_SCENE_PATH) as PackedScene
	root.add_child(packed.instantiate())
	for _frame in 5:
		await physics_frame
	var players := get_nodes_in_group(&"player")
	_player = players[0] as CharacterBody3D if players.size() == 1 else null
	_check("a player was spawned", _player != null)
	if _player == null:
		_finish()
		return
	_stats = _player.get_node_or_null("Stats")
	_skills = _player.get_node_or_null("SkillSystem")
	_check("the player has a SkillSystem", _skills != null and _stats != null)
	if _skills == null or _stats == null:
		_finish()
		return
	for enemy in get_nodes_in_group(&"enemy"):
		enemy.set_physics_process(false)

	_check_points_and_rules()
	_check_vocation_gating()
	_check_effects()
	_check_respec()
	_check_saving()
	_check_system_hooks()
	_check_recipe_unlock()
	_finish()


# --- the data ------------------------------------------------------------------

func _check_data() -> void:
	var nodes: Dictionary = SkillData.NODES
	var trees: Dictionary = SkillData.TREES
	_check("there are skill nodes (%d) in trees (%d)" % [nodes.size(), trees.size()], nodes.size() >= 40 and trees.size() == 15)

	var order: Array[String] = SkillData.TREE_ORDER
	var every_tree_listed := order.size() == trees.size()
	for tree_id: String in trees:
		every_tree_listed = every_tree_listed and order.has(tree_id)
	_check("TREE_ORDER lists every tree exactly once", every_tree_listed)

	var problems: Array[String] = []
	for id: String in nodes:
		var node: Dictionary = nodes[id]
		if str(node.get("id", "")) != id:
			problems.append("%s: id field does not match its key" % id)
		if not trees.has(str(node.get("tree", ""))):
			problems.append("%s: unknown tree" % id)
		if int(node.get("max_rank", 0)) < 1:
			problems.append("%s: max_rank < 1" % id)
		if int(node.get("tier", 0)) < 1 or int(node.get("min_level", 0)) < 1:
			problems.append("%s: bad tier or level" % id)
		var effects: Dictionary = node.get("effects", {})
		var unlocks: Array = node.get("unlocks", [])
		if effects.is_empty() and unlocks.is_empty():
			problems.append("%s: does nothing" % id)
		for stat: String in effects:
			if not KNOWN_STATS.has(stat):
				problems.append("%s: unknown stat %s" % [id, stat])
		for recipe_id: String in unlocks:
			if not _lore.RECIPES.has(recipe_id):
				problems.append("%s: unlocks unknown recipe %s" % [id, recipe_id])
		for required: String in node.get("requires", []):
			if not nodes.has(required):
				problems.append("%s: unknown prerequisite %s" % [id, required])
				continue
			var parent: Dictionary = nodes[required]
			if str(parent["tree"]) != str(node["tree"]):
				problems.append("%s: prerequisite %s is in another tree" % [id, required])
			if int(parent["tier"]) >= int(node["tier"]):
				problems.append("%s: prerequisite %s is not above it" % [id, required])
			if int(parent["min_level"]) > int(node["min_level"]):
				problems.append("%s: needs a lower level than its prerequisite %s" % [id, required])
		if not SkillData.effect_text(effects).is_empty() == effects.is_empty():
			problems.append("%s: effect_text disagrees with its effects" % id)
	_check("every node is well formed %s" % ("" if problems.is_empty() else str(problems)), problems.is_empty())

	var empty_trees: Array[String] = []
	for tree_id: String in trees:
		if SkillData.tree_nodes(tree_id).is_empty():
			empty_trees.append(tree_id)
	_check("no tree is empty", empty_trees.is_empty())

	# The vocation trees must be the ones the lore names.
	var matches := true
	for vocation_id: String in _lore.VOCATIONS:
		var named: Array[String] = []
		for tree_name: String in _lore.VOCATIONS[vocation_id]["trees"]:
			named.append(tree_name)
		var present: Array[String] = []
		for tree_id: String in trees:
			if str(trees[tree_id]["vocation"]) == vocation_id:
				present.append(str(trees[tree_id]["name"]))
		named.sort()
		present.sort()
		matches = matches and named == present
	_check("each vocation has exactly the trees the lore names", matches)
	_check("shared trees are open to everyone (%d)" % SkillData.trees_for("").size(), SkillData.trees_for("").size() == 3)
	_check("a vocation adds its three (%d)" % SkillData.trees_for("knight").size(), SkillData.trees_for("knight").size() == 6)

	var ordered := true
	var last_tier := 0
	for id: String in SkillData.tree_nodes("crafting"):
		ordered = ordered and int(nodes[id]["tier"]) >= last_tier
		last_tier = int(nodes[id]["tier"])
	_check("tree_nodes comes back ordered by tier", ordered)


# --- the rules -------------------------------------------------------------------

func _check_points_and_rules() -> void:
	_set_level(1)
	_check("level 1 has no skill points", int(_skills.call("points_total")) == 0)
	var refused: Dictionary = _skills.call("check_learn", "tough_cap")
	_check("learning with no points is refused (%s)" % refused["reason"], not bool(refused["ok"]) and refused["reason"] == "points")
	_check("learn() agrees", not bool(_skills.call("learn", "tough_cap")))

	_set_level(5)
	_check("level 5 has 4 points", int(_skills.call("points_total")) == 4)
	_check("an unknown skill is refused", str(_skills.call("check_learn", "no_such_skill")["reason"]) == "unknown")

	# Prerequisites.
	_set_level(10)
	_check("a skill needs its prerequisite", str(_skills.call("check_learn", "keen_eye")["reason"]) == "requires")
	_check("learn the root skill", bool(_skills.call("learn", "quick_hands")))
	_check("rank is tracked", int(_skills.call("rank", "quick_hands")) == 1)
	_check("the prerequisite now allows the next", bool(_skills.call("check_learn", "keen_eye")["ok"]))
	_set_level(2)
	_check(
		"a skill needs its level (%s)" % _skills.call("check_learn", "keen_eye")["reason"],
		str(_skills.call("check_learn", "keen_eye")["reason"]) == "level"
	)
	_check("points left = 1 - 1 = 0", int(_skills.call("points_available")) == 0)

	# Rank cap and point accounting.
	_skills.call("respec")
	_game.set("gold", 1000)
	_skills.call("respec")
	_set_level(20)
	for _rank in 5:
		_skills.call("learn", "tough_cap")
	_check("a skill can be ranked up to its cap", int(_skills.call("rank", "tough_cap")) == 5)
	_check("past the cap is refused", str(_skills.call("check_learn", "tough_cap")["reason"]) == "maxed")
	_check("5 points spent of 19", int(_skills.call("points_spent")) == 5 and int(_skills.call("points_available")) == 14)
	_game.set("gold", 5000)
	_skills.call("respec")


func _check_vocation_gating() -> void:
	_game.set("gold", 5000)
	_skills.call("respec")
	_set_level(25)
	_game.set("chosen_vocation", &"")
	_check(
		"a vocation tree is locked without a vocation (%s)" % _skills.call("check_learn", "savage_blows")["reason"],
		str(_skills.call("check_learn", "savage_blows")["reason"]) == "vocation"
	)
	_game.set("chosen_vocation", &"healer")
	_check("and for the wrong vocation", str(_skills.call("check_learn", "savage_blows")["reason"]) == "vocation")
	_check("but a healer's tree opens", bool(_skills.call("check_learn", "soothing_touch")["ok"]))
	_game.set("chosen_vocation", &"knight")
	_check("and a knight can learn a knight skill", bool(_skills.call("learn", "savage_blows")))
	_check("its bonus is readable", is_equal_approx(float(_skills.call("get_modifier", "damage_mult")), 0.06))
	_game.set("chosen_vocation", &"")
	_skills.call("respec")


func _check_effects() -> void:
	_game.set("gold", 5000)
	_skills.call("respec")
	_set_level(20)
	var hp_before := float(_stats.get("max_hp"))
	var stamina_before := float(_stats.get("max_stamina"))
	var regen_before := float(_stats.get("stamina_regen"))
	var walk_before := float(_player.get("walk_speed"))
	var sprint_before := float(_player.get("sprint_speed"))
	_stats.set("hp", hp_before)

	_skills.call("learn", "tough_cap")
	_check(
		"Tough Cap adds 10 max health (%.0f -> %.0f)" % [hp_before, float(_stats.get("max_hp"))],
		is_equal_approx(float(_stats.get("max_hp")), hp_before + 10.0)
	)
	_check("and heals for the same amount", is_equal_approx(float(_stats.get("hp")), hp_before + 10.0))
	_skills.call("learn", "second_wind")
	_check("Second Wind adds 10 max stamina", is_equal_approx(float(_stats.get("max_stamina")), stamina_before + 10.0))
	_skills.call("learn", "recovery")
	_check("Recovery speeds stamina regeneration", float(_stats.get("stamina_regen")) > regen_before)
	_set_level(20)
	_skills.call("learn", "light_step")
	_check("Light Step makes you walk faster", is_equal_approx(float(_player.get("walk_speed")), walk_before + 0.2))
	_check("and run faster", is_equal_approx(float(_player.get("sprint_speed")), sprint_before + 0.3))

	_skills.call("respec")
	_check("a respec returns max health exactly", is_equal_approx(float(_stats.get("max_hp")), hp_before))
	_check("and max stamina", is_equal_approx(float(_stats.get("max_stamina")), stamina_before))
	_check("and regeneration", is_equal_approx(float(_stats.get("stamina_regen")), regen_before))
	_check("and walk speed", is_equal_approx(float(_player.get("walk_speed")), walk_before))
	_check("and run speed", is_equal_approx(float(_player.get("sprint_speed")), sprint_before))
	_check("current health never exceeds the maximum", float(_stats.get("hp")) <= float(_stats.get("max_hp")))


func _check_respec() -> void:
	_set_level(20)
	_game.set("gold", 5000)
	_skills.call("respec")
	_check("nothing to respec when nothing is learned", not bool(_skills.call("respec")))
	for _rank in 3:
		_skills.call("learn", "tough_cap")
	var cost := int(_skills.call("respec_cost"))
	_check("a respec costs gold per point (%d)" % cost, cost == 3 * SkillData.RESPEC_GOLD_PER_POINT)

	_game.set("gold", cost - 1)
	_check("a respec you cannot afford is refused", not bool(_skills.call("respec")))
	_check("and keeps your skills", int(_skills.call("rank", "tough_cap")) == 3)
	_check("and your gold", int(_game.get("gold")) == cost - 1)

	_game.set("gold", cost + 7)
	_check("an affordable respec works", bool(_skills.call("respec")))
	_check("it charged the price", int(_game.get("gold")) == 7)
	_check("it refunded every point", int(_skills.call("points_spent")) == 0)
	_check("and cleared the ranks", int(_skills.call("rank", "tough_cap")) == 0)


func _check_saving() -> void:
	_game.set("gold", 5000)
	_skills.call("respec")
	_set_level(20)
	for _rank in 3:
		_skills.call("learn", "tough_cap")
	for _rank in 2:
		_skills.call("learn", "quick_hands")
	_stats.set("hp", float(_stats.get("max_hp")) - 5.0)
	var max_hp_with_skills := float(_stats.get("max_hp"))
	var hp_with_skills := float(_stats.get("hp"))

	var state: Dictionary = _saves.call("collect_state")
	var saved: Dictionary = state["skills"]["learned"]
	_check("the save carries the skills", int(saved.get("tough_cap", 0)) == 3 and int(saved.get("quick_hands", 0)) == 2)
	_check("the save format is versioned (%d)" % int(state["version"]), int(state["version"]) >= 3)

	var round_trip: Variant = JSON.parse_string(JSON.stringify(state))
	_check("it survives a JSON round trip", round_trip is Dictionary)
	_skills.call("from_dict", {})
	_check("clearing really clears", int(_skills.call("rank", "tough_cap")) == 0)
	_check("and takes the bonus off", is_equal_approx(float(_stats.get("max_hp")), max_hp_with_skills - 30.0))

	_saves.call("apply_state", round_trip)
	_check("loading restores the ranks", int(_skills.call("rank", "tough_cap")) == 3 and int(_skills.call("rank", "quick_hands")) == 2)
	_check("and the bonus", is_equal_approx(float(_stats.get("max_hp")), max_hp_with_skills))
	_check(
		"and the saved health is not clamped away (%.0f of %.0f)" % [float(_stats.get("hp")), float(_stats.get("max_hp"))],
		is_equal_approx(float(_stats.get("hp")), hp_with_skills)
	)
	_saves.call("apply_state", round_trip)
	_check("loading twice does not stack the bonus", is_equal_approx(float(_stats.get("max_hp")), max_hp_with_skills))

	# A hand-edited or outdated save can never grant what the rules forbid.
	var tampered: Dictionary = (round_trip as Dictionary).duplicate(true)
	tampered["level"] = 5
	tampered["skills"] = {"learned": {"tough_cap": 99, "nonsense": 2, "keen_eye": 3, "quick_hands": "lots"}}
	_saves.call("apply_state", tampered)
	_check("a rank above the cap is clamped to what the points allow (%d)" % int(_skills.call("rank", "tough_cap")), int(_skills.call("rank", "tough_cap")) == 4)
	_check("an unknown skill is dropped", int(_skills.call("rank", "nonsense")) == 0)
	_check("a skill without its prerequisite is dropped", int(_skills.call("rank", "keen_eye")) == 0)
	_check("a rank that is not a number is dropped", int(_skills.call("rank", "quick_hands")) == 0)
	_check("never more spent than earned", int(_skills.call("points_spent")) <= int(_skills.call("points_total")))

	var before := int(_skills.call("rank", "tough_cap"))
	_saves.call("apply_state", {"skills": 5, "level": 5})
	_check("a garbled skills entry changes nothing", int(_skills.call("rank", "tough_cap")) == before)
	var old: Dictionary = (round_trip as Dictionary).duplicate(true)
	old.erase("skills")
	old["level"] = 5
	_saves.call("apply_state", old)
	_check("an older save without skills does not crash or wipe", int(_skills.call("rank", "tough_cap")) == before)

	_game.set("gold", 5000)
	_skills.call("respec")


func _check_system_hooks() -> void:
	_game.set("gold", 5000)
	_skills.call("respec")
	_set_level(30)
	_game.set("chosen_vocation", &"knight")
	_skills.call("learn", "savage_blows")
	_skills.call("learn", "quick_hands")
	_skills.call("learn", "keen_eye")
	var combat := _player.get_node_or_null("CombatSystem")
	var gathering := _player.get_node_or_null("GatheringSystem")
	_check(
		"combat reads the damage bonus (%.2f)" % float(combat.call("_skill_modifier", "damage_mult")),
		is_equal_approx(float(combat.call("_skill_modifier", "damage_mult")), 0.06)
	)
	_check(
		"gathering reads the harvest speed bonus",
		is_equal_approx(float(gathering.call("_skill_modifier", "gather_speed")), 0.08)
	)
	_check(
		"and the extra-mushroom chance",
		is_equal_approx(float(gathering.call("_skill_modifier", "gather_yield_chance")), 0.08)
	)
	_skills.call("respec")
	_check("a respec removes those bonuses too", is_zero_approx(float(combat.call("_skill_modifier", "damage_mult"))))
	_game.set("chosen_vocation", &"")


func _check_recipe_unlock() -> void:
	_game.set("gold", 5000)
	_skills.call("respec")
	_set_level(8)
	_check("a skill-gated recipe starts locked", not bool(_skills.call("is_recipe_unlocked", "greater_health_potion")))
	_check("an ungated recipe is open", bool(_skills.call("is_recipe_unlocked", "weak_health_potion")))
	for id in ["steady_hands", "thrifty_brewer", "potent_brews", "adv_herbalism"]:
		_check("learn %s" % id, bool(_skills.call("learn", id)))
	_check("Advanced Herbalism unlocks the Greater Health Potion", bool(_skills.call("is_recipe_unlocked", "greater_health_potion")))
	_skills.call("respec")
	_check("a respec locks it again", not bool(_skills.call("is_recipe_unlocked", "greater_health_potion")))


# --- helpers -------------------------------------------------------------------

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
		print("PASSED  all skill assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
