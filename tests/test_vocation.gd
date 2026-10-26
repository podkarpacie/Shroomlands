extends SceneTree
## Headless vocation test: the level-20 gate, the modal lifecycle, the "Later"
## path, the V binding and each of the four documented stat bonuses.
##
## `main.tscn` is loaded lazily and the autoloads are reached through
## `root.get_node_or_null()`, because `--script` compiles this file before the
## autoload identifiers exist (same constraint as test_player.gd).
## `SHROOMLANDS_SAVE_PATH` points `SaveSystem` at a private `user://tests/` file
## (see tests/test_env.gd), so "the player starts below level 20" also holds on
## a dev machine without touching the developer's save.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const PLAYER_SCENE_PATH := "res://scenes/player/player.tscn"
const CARD_IDS: Array[String] = ["knight", "healer", "harvester", "ranger"]
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _main: Node3D = null
var _player: Node3D = null
var _ui: CanvasLayer = null
var _game: Node = null
var _bus: Node = null
var _saves: Node = null
var _unlock_level := 20


func _initialize() -> void:
	TestEnv.isolate("test_vocation")
	_run()


func _run() -> void:
	_game = root.get_node_or_null("Game")
	_bus = root.get_node_or_null("EventBus")
	_saves = root.get_node_or_null("SaveSystem")
	_check("Game autoload is available", _game != null)
	_check("EventBus autoload is available", _bus != null)
	_check("SaveSystem autoload is available", _saves != null)
	if _game == null or _bus == null or _saves == null:
		_finish()
		return
	var game_constants: Dictionary = _game.get_script().get_script_constant_map()
	_unlock_level = int(game_constants.get("VOCATION_UNLOCK_LEVEL", 20))

	var packed := load(MAIN_SCENE_PATH) as PackedScene
	_check("main.tscn loads", packed != null)
	if packed == null:
		_finish()
		return
	_main = packed.instantiate() as Node3D
	root.add_child(_main)
	await _wait_physics(20)

	_ui = _main.get_node_or_null("VocationUI") as CanvasLayer
	_player = get_first_node_in_group(&"player") as Node3D
	_check("Main has a VocationUI layer", _ui != null)
	_check("a player was spawned", _player != null)
	if _ui == null or _player == null:
		_finish()
		return
	var stats := _player.get_node_or_null("Stats")
	_check("the player has a Stats component", stats != null)
	if stats == null:
		_finish()
		return

	# --- below the unlock level -------------------------------------------
	_check("vocation starts empty", _chosen() == &"")
	_check("the menu starts closed", not _ui.visible)
	_check(
		"the player starts below Lv %d (Lv %d)" % [_unlock_level, int(stats.get("level"))],
		int(stats.get("level")) < _unlock_level
	)
	_check("the modal does not auto-open below level 20", not _ui.visible)
	_check("Game.set_vocation('knight') is refused below level 20", not _set_vocation("knight"))
	_check("the refusal leaves the vocation empty", _chosen() == &"")
	_check("open() refuses below level 20", not bool(_ui.call(&"open")))
	_check("the menu stays closed after a refused open()", not _ui.visible)

	# --- the V binding -----------------------------------------------------
	_check("the vocation_menu action exists", InputMap.has_action(&"vocation_menu"))
	_check(
		"vocation_menu is bound to V (got %s)" % _key_name(_action_key(&"vocation_menu")),
		_action_key(&"vocation_menu") == KEY_V
	)
	_push_key(KEY_V)
	await process_frame
	_check("V does not open the modal below level 20", not _ui.visible)

	# --- level 20: auto-open, cards, confirm --------------------------------
	var chosen_events: Array[String] = []
	_bus.connect(&"vocation_chosen", func(id: String) -> void: chosen_events.append(id))

	_level_up(stats, _unlock_level)
	await process_frame
	_check("the modal opens automatically at level 20", _ui.visible)
	_check("the body is UI-blocked while the modal is open", bool(_player.get("ui_blocking")))

	var cards := _ui.get_node_or_null("Root/Center/Panel/Margin/Content/Cards") as HBoxContainer
	_check("the modal builds four cards", cards != null and cards.get_child_count() == 4)
	var rows_ok := cards != null
	if cards != null:
		for id: String in CARD_IDS:
			rows_ok = rows_ok and cards.get_node_or_null("Card_%s" % id) != null
	_check("there is one card per Lore vocation (knight, healer, harvester, ranger)", rows_ok)

	var knight_card: Node = cards.get_node_or_null("Card_knight") if cards != null else null
	var body := knight_card.get_node_or_null("Body") as VBoxContainer if knight_card != null else null
	_check("the knight card has a body", body != null)
	if body != null:
		_check("the card shows the English name (Knight)", _text_of(body, "Name") == "Knight")
		_check("the card shows the Polish name (Rycerz)", _text_of(body, "Polish") == "Rycerz")
		_check(
			"the card shows the role (%s)" % _text_of(body, "Role"),
			_text_of(body, "Role").contains("Tank")
		)
		_check(
			"the card shows the Polish description",
			_text_of(body, "Description").contains("grzybni")
		)
		_check(
			"the card shows the three skill trees as chips",
			body.get_node_or_null("Trees") != null and body.get_node("Trees").get_child_count() == 3
		)
		_check(
			"the card shows the primary stat (%s)" % _text_of(body, "PrimaryStat"),
			_text_of(body, "PrimaryStat").contains("vitality")
		)

	_ui.call(&"select_vocation", "knight")
	_check("selecting a card records it", String(_ui.call(&"get_selected_vocation")) == "knight")
	_check("Confirm accepts the choice", bool(_ui.call(&"confirm")))
	_check("chosen_vocation is knight", _chosen() == &"knight")
	_check(
		"vocation_chosen fired exactly once (got %s)" % [chosen_events],
		chosen_events.size() == 1 and chosen_events[0] == "knight"
	)
	_check("the modal closes after Confirm", not _ui.visible)
	_check("the body is released after Confirm", not bool(_player.get("ui_blocking")))
	_check(
		"knight raises max_hp by 20 (%.0f)" % float(stats.get("max_hp")),
		is_equal_approx(float(stats.get("max_hp")), 120.0)
	)
	_check(
		"knight heals to full (%.0f/%.0f)" % [float(stats.get("hp")), float(stats.get("max_hp"))],
		is_equal_approx(float(stats.get("hp")), float(stats.get("max_hp")))
	)
	_check("choosing twice is rejected", not _set_vocation("healer"))
	_check("the second choice did not change the vocation", _chosen() == &"knight")
	_check("the modal will not reopen after a choice", not bool(_ui.call(&"open")))

	# --- HUD reflection ----------------------------------------------------
	var hud := _main.get_node_or_null("HUD")
	var level_label := hud.get_node_or_null("Root/Progression/LevelLabel") as Label
	var hint := hud.get_node_or_null("Root/Progression/VocationButton") as Button
	_check(
		"the HUD shows the vocation next to the level (%s)" % _label_text(level_label),
		level_label != null and level_label.text == "Lv 20 · Knight"
	)
	_check("the HUD unlock hint is hidden once a vocation is chosen", hint != null and not hint.visible)

	# --- Later, then the next level-up ------------------------------------
	_game.set(&"chosen_vocation", &"")
	_level_up(stats, 20)
	await process_frame
	_check("an empty vocation reopens the modal at Lv 20", _ui.visible)
	if hint != null:
		_check("the HUD hint is visible again while a choice is pending", hint.visible)
	_ui.call(&"dismiss")
	_check("Later closes the modal", not _ui.visible)
	_check("Later leaves the vocation empty", _chosen() == &"")
	if hint != null:
		hint.pressed.emit()
		await process_frame
		_check("clicking the HUD hint opens the modal", _ui.visible)
		_ui.call(&"dismiss")
	_level_up(stats, 20)
	await process_frame
	_check("Later is respected at the same level", not _ui.visible)
	_ui.call(&"open")
	_check("open() still works after Later", _ui.visible)
	_push_key(KEY_V)
	await process_frame
	_check("V while the modal is open does not dismiss it", _ui.visible)
	_ui.call(&"dismiss")

	_level_up(stats, 21)
	await process_frame
	_check("the next level-up brings the modal back", _ui.visible)
	_ui.call(&"dismiss")

	# --- each vocation in isolation ---------------------------------------
	for id: String in CARD_IDS:
		_game.set(&"chosen_vocation", &"")
		var fresh := await _fresh_player()
		var fresh_stats := fresh.get_node_or_null("Stats")
		_check("%s: a fresh player has fresh stats" % id, fresh_stats != null)
		if fresh_stats == null:
			continue
		_level_up(fresh_stats, _unlock_level)
		_check("%s: accepted at Lv 20" % id, _set_vocation(id))
		fresh_stats.call(&"apply_vocation_bonus", id)
		var before := _bonus_snapshot(fresh, fresh_stats)
		match id:
			"knight":
				_check(
					"knight: max_hp 100 -> 120 (%.0f)" % float(fresh_stats.get("max_hp")),
					is_equal_approx(float(fresh_stats.get("max_hp")), 120.0)
				)
				_check(
					"knight: healed to full (%.0f)" % float(fresh_stats.get("hp")),
					is_equal_approx(float(fresh_stats.get("hp")), 120.0)
				)
			"healer":
				_check(
					"healer: stamina regen 18 -> 24 /s (%.1f)" % float(fresh_stats.get("stamina_regen")),
					is_equal_approx(float(fresh_stats.get("stamina_regen")), 24.0)
				)
				_check(
					"healer: max_hp untouched (%.0f)" % float(fresh_stats.get("max_hp")),
					is_equal_approx(float(fresh_stats.get("max_hp")), 100.0)
				)
			"harvester":
				_check(
					"harvester: max_stamina 100 -> 125 (%.0f)" % float(fresh_stats.get("max_stamina")),
					is_equal_approx(float(fresh_stats.get("max_stamina")), 125.0)
				)
			"ranger":
				_check(
					"ranger: walk_speed 4.5 -> 5.3 (%.2f)" % float(fresh.get("walk_speed")),
					is_equal_approx(float(fresh.get("walk_speed")), 5.3)
				)
				_check(
					"ranger: sprint_speed 7.5 -> 8.7 (%.2f)" % float(fresh.get("sprint_speed")),
					is_equal_approx(float(fresh.get("sprint_speed")), 8.7)
				)
		fresh_stats.call(&"apply_vocation_bonus", id)
		_check(
			"%s: the bonus is applied only once" % id,
			_bonus_snapshot(fresh, fresh_stats) == before
		)

	_finish()


## Bonus values a second `apply_vocation_bonus` must not touch.
func _bonus_snapshot(body: Node, stats: Node) -> Array[float]:
	return [
		float(stats.get("max_hp")),
		float(stats.get("max_stamina")),
		float(stats.get("stamina_regen")),
		float(body.get("walk_speed")),
		float(body.get("sprint_speed")),
	]


func _chosen() -> StringName:
	return StringName(_game.get(&"chosen_vocation"))


func _set_vocation(id: String) -> bool:
	return bool(_game.call(&"set_vocation", id))


## New Stats always start at level 1; emit the signal so every listener follows.
func _level_up(stats: Node, level: int) -> void:
	stats.set("level", level)
	_bus.emit_signal(&"level_changed", level)


func _fresh_player() -> Node3D:
	if _player != null and is_instance_valid(_player):
		_player.queue_free()
		await _wait_physics(2)
	var packed := load(PLAYER_SCENE_PATH) as PackedScene
	_player = packed.instantiate() as Node3D
	_player.name = "Player"
	_main.add_child(_player)
	await _wait_physics(2)
	return _player


func _text_of(parent: Node, child_name: String) -> String:
	var label := parent.get_node_or_null(child_name) as Label
	return "" if label == null else label.text


func _label_text(label: Label) -> String:
	return "" if label == null else label.text


func _action_key(action: StringName) -> int:
	for event: InputEvent in InputMap.action_get_events(action):
		if event is InputEventKey:
			var key := event as InputEventKey
			return int(key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode)
	return KEY_NONE


func _key_name(code: int) -> String:
	return OS.get_keycode_string(code) if code != KEY_NONE else "<none>"


## Real input path: the event goes through the viewport exactly like a keypress.
func _push_key(code: int) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	root.push_input(event)


func _wait_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all vocation assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
