extends SceneTree
## Action-skill test: every skill starts at 1, xp is earned by doing, thresholds
## escalate, the cap holds, and each perk actually changes a number the player
## feels (harvest size, brew fee, damage, lamp battery, search speed). Also the
## pause-menu page, the save round-trip and the gathering award.

const TestEnv := preload("res://tests/test_env.gd")
const MUSHROOM_SCENE := "res://scenes/world/mushroom_node.tscn"
const PAUSE_MENU := "res://scenes/ui/pause_menu.tscn"

var _failures := 0
var _level_events := 0
var _change_events := 0


func _initialize() -> void:
	TestEnv.isolate("test_skills")
	TestEnv.stash("user://plots.json")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	var game: Node = root.get_node_or_null("Game")
	var bus: Node = root.get_node_or_null("EventBus")
	_check("Game and EventBus exist", game != null and bus != null)
	if game == null or bus == null:
		_finish()
		return
	bus.connect(&"skill_level_up", func(_id: StringName, _level: int) -> void: _level_events += 1)
	bus.connect(&"skill_changed", func(_id: StringName, _l: int, _x: int, _n: int) -> void:
		_change_events += 1)

	# --- baseline ----------------------------------------------------------
	var expected := ["foraging", "alchemy", "combat", "survival"]
	for id: String in expected:
		_check("%s starts at level 1" % id, int(game.call(&"skill_level", id)) == 1)
		_check("%s starts at 0 xp" % id, int(game.call(&"skill_xp", id)) == 0)
	_check("the skill catalogue has four entries", (game.get(&"skills") as Dictionary).size() == 4)

	# --- thresholds --------------------------------------------------------
	game.call(&"add_skill_xp", &"alchemy", 59)
	_check("59 xp is still level 1", int(game.call(&"skill_level", "alchemy")) == 1)
	var gained := int(game.call(&"add_skill_xp", &"alchemy", 1))
	_check("60 xp reaches level 2 (+%d)" % gained,
		gained == 1 and int(game.call(&"skill_level", "alchemy")) == 2)
	_check("the level costs 60 more than the last (need %d)" % int(game.call(&"skill_xp_to_level", 2)),
		int(game.call(&"skill_xp_to_level", 2)) == 120)
	_check("the level-up signal fired (%d)" % _level_events, _level_events == 1)
	_check("the change signal fired (%d)" % _change_events, _change_events == 2)

	game.call(&"add_skill_xp", &"alchemy", 200)
	_check("200 more carries into level 3 with 80 left (Lv %d, %d xp)" % [
			int(game.call(&"skill_level", "alchemy")), int(game.call(&"skill_xp", "alchemy"))
		],
		int(game.call(&"skill_level", "alchemy")) == 3
			and int(game.call(&"skill_xp", "alchemy")) == 80)

	game.call(&"add_skill_xp", &"alchemy", 999999)
	_check("a maxed skill stops at 20", int(game.call(&"skill_level", "alchemy")) == 20)
	_check("a maxed skill reports MAX and holds no xp (%d)" % int(game.call(&"skill_xp", "alchemy")),
		int(game.call(&"skill_xp", "alchemy")) == 0)
	_check("further xp on a maxed skill is dropped",
		int(game.call(&"add_skill_xp", &"alchemy", 500)) == 0)
	_check("an unknown skill id is ignored",
		int(game.call(&"add_skill_xp", &"bogus", 50)) == 0
			and not (game.get(&"skills") as Dictionary).has("bogus"))

	# --- foraging perk -----------------------------------------------------
	for level: int in [1, 4, 5, 9, 10, 15, 20]:
		_set_skill_level(game, "foraging", level)
		var bonus := int(game.call(&"foraging_bonus"))
		var want := 0
		if level >= 5: want += 1
		if level >= 10: want += 1
		if level >= 15: want += 1
		_check("foraging level %d gives +%d (%d)" % [level, want, bonus], bonus == want)

	# A deterministic yield: 1..1 base + the bonus.
	_set_skill_level(game, "foraging", 10)
	var mushroom: Node3D = load(MUSHROOM_SCENE).instantiate()
	mushroom.set(&"mushroom_id", &"konop")
	mushroom.set(&"yield_min", 1)
	mushroom.set(&"yield_max", 1)
	root.add_child(mushroom)
	await physics_frame
	mushroom.call(&"harvest")
	_check("a level-10 forage picks 3 from a 1-yield node (%d)" % int(mushroom.get("last_yield")),
		int(mushroom.get("last_yield")) == 3)
	mushroom.queue_free()

	# --- alchemy perk ------------------------------------------------------
	_set_skill_level(game, "alchemy", 1)
	_check("a level-1 fee is unchanged (%d)" % int(game.call(&"alchemy_fee", 20)),
		int(game.call(&"alchemy_fee", 20)) == 20)
	_set_skill_level(game, "alchemy", 6)
	_check("alchemy 6 shaves 5 g off a 20 g recipe (%d)" % int(game.call(&"alchemy_fee", 20)),
		int(game.call(&"alchemy_fee", 20)) == 15)
	_check("a fee never goes below 1 g (%d)" % int(game.call(&"alchemy_fee", 5)),
		int(game.call(&"alchemy_fee", 5)) == 1)

	# --- combat perk -------------------------------------------------------
	_set_skill_level(game, "combat", 1)
	_check("combat 1 is a 1.0 damage scale (%.2f)" % float(game.call(&"combat_skill_scale")),
		is_equal_approx(float(game.call(&"combat_skill_scale")), 1.0))
	_set_skill_level(game, "combat", 6)
	_check("combat 6 is +10%% damage (%.2f)" % float(game.call(&"combat_skill_scale")),
		is_equal_approx(float(game.call(&"combat_skill_scale")), 1.10))

	# --- survival perks ----------------------------------------------------
	_set_skill_level(game, "survival", 1)
	_check("survival 1 keeps the 90 s lamp (%.1f)" % float(game.call(&"survival_lamp_scale")),
		is_equal_approx(float(game.call(&"survival_lamp_scale")), 1.0))
	_set_skill_level(game, "survival", 6)
	_check("survival 6 adds 25%% battery (%.2f)" % float(game.call(&"survival_lamp_scale")),
		is_equal_approx(float(game.call(&"survival_lamp_scale")), 1.25))
	_check("survival 6 searches 10%% faster (%.2f)" % float(game.call(&"survival_search_scale")),
		is_equal_approx(float(game.call(&"survival_search_scale")), 0.90))
	_set_skill_level(game, "survival", 20)
	_check("search time at max is 62%% (%.2f)" % float(game.call(&"survival_search_scale")),
		is_equal_approx(float(game.call(&"survival_search_scale")), 0.62))

	# --- gathering awards foraging ----------------------------------------
	_set_skill_level(game, "foraging", 1)
	game.set(&"skills", game.call(&"skills_snapshot"))
	(game.get(&"skills") as Dictionary)["foraging"] = {"level": 1, "xp": 0}
	bus.emit_signal(&"mushroom_gathered", "fury", 1)
	_check("gathering fury pays foraging xp (%d)" % int(game.call(&"skill_xp", "foraging")),
		int(game.call(&"skill_xp", "foraging")) == 15)

	# --- vocation affinity -------------------------------------------------
	game.set(&"chosen_vocation", &"ranger")
	game.call(&"apply_skills", {})
	game.call(&"add_skill_xp", &"survival", 40)
	_check("ranger affinity grants +25%% survival xp (40 -> %d)" % int(game.call(&"skill_xp", "survival")),
		int(game.call(&"skill_xp", "survival")) == 50)
	game.call(&"add_skill_xp", &"foraging", 40)
	_check("other skills get the plain amount (40 -> %d)" % int(game.call(&"skill_xp", "foraging")),
		int(game.call(&"skill_xp", "foraging")) == 40)
	_check("the affinity is reported (%s)" % str(game.call(&"vocation_affinity")),
		str(game.call(&"vocation_affinity")) == "survival")
	game.set(&"chosen_vocation", &"")

	# --- save round-trip ---------------------------------------------------
	_set_skill_level(game, "foraging", 7)
	_set_skill_level(game, "survival", 4)
	var saves: Node = root.get_node_or_null("SaveSystem")
	_check("SaveSystem exists", saves != null)
	if saves != null:
		var snapshot: Dictionary = game.call(&"skills_snapshot")
		game.call(&"apply_skills", {})
		_check("a wiped skill block drops to level 1", int(game.call(&"skill_level", "foraging")) == 1)
		game.call(&"apply_skills", snapshot)
		_check("skills round-trip (foraging %d, survival %d)" % [
				int(game.call(&"skill_level", "foraging")),
				int(game.call(&"skill_level", "survival")),
			],
			int(game.call(&"skill_level", "foraging")) == 7
				and int(game.call(&"skill_level", "survival")) == 4)
		game.call(&"apply_skills", {
			"foraging": {"level": 999, "xp": -5},
			"alchemy": "bad",
			"bogus": {"level": 3, "xp": 0},
		})
		_check("garbage skills clamp and ignore unknown ids (foraging %d)" % int(game.call(&"skill_level", "foraging")),
			int(game.call(&"skill_level", "foraging")) == 20
				and int(game.call(&"skill_xp", "foraging")) == 0
				and int(game.call(&"skill_level", "alchemy")) == 1
				and not (game.get(&"skills") as Dictionary).has("bogus"))
		var collected: Dictionary = saves.call(&"collect_state")
		_check("collect_state carries the skills block", collected.get("skills") is Dictionary
			and (collected.get("skills") as Dictionary).size() == 4)

	# --- pause-menu page ---------------------------------------------------
	_set_skill_level(game, "foraging", 3)
	_set_skill_level(game, "combat", 5)
	var menu: Node = load(PAUSE_MENU).instantiate()
	root.add_child(menu)
	await process_frame
	menu.call(&"set_section", "skills")
	await process_frame
	var text := str(menu.call(&"get_skills_text"))
	print("skills page:\n", text)
	_check("the pause menu has a Skills page (%s)" % text.substr(0, 40),
		text.contains("Foraging") and text.contains("Alchemy")
			and text.contains("Combat") and text.contains("Survival"))
	_check("the page shows the real levels (%s)" % text.replace("\\n", " / "),
		text.contains("Lv 3") and text.contains("Lv 5"))
	game.set(&"chosen_vocation", &"ranger")
	menu.call(&"set_section", "skills")
	await process_frame
	_check("the page marks the vocation affinity (%s)" % str(menu.call(&"get_skills_text")),
		str(menu.call(&"get_skills_text")).contains("Survival  (affinity)"))
	game.set(&"chosen_vocation", &"")
	menu.queue_free()
	_finish()


func _set_skill_level(game: Node, id: String, level: int) -> void:
	var skills: Dictionary = game.get(&"skills")
	skills[id] = {"level": clampi(level, 1, 20), "xp": 0}
	game.set(&"skills", skills)


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
