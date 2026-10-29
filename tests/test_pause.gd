extends SceneTree
## Headless pause-menu test on the real `main.tscn`.
##
## Covers the UI contract only: the layer exists and starts hidden, Escape opens
## it (pausing an offline tree and blocking the player), `close()` reverses
## both, a SERVER peer never pauses, the option page round-trips through the
## lobby's `settings.cfg`, the Controls page lists the real `InputMap` bindings,
## the Players page mirrors `Main.get_roster()`, and Escape closes the satchel
## before the menu can open over it.
##
## `settings.cfg` and the save are stashed by tests/test_env.gd, so the
## developer's own files are never read or written.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "settings"
const PROBE_SENSITIVITY := 0.0075
const PROBE_MUSIC_VOLUME := 0.35
const PROBE_SFX_VOLUME := 0.55
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0


func _initialize() -> void:
	TestEnv.isolate("test_pause")
	TestEnv.stash("user://plots.json")
	TestEnv.stash(SETTINGS_PATH)
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	var packed := load(MAIN_SCENE_PATH) as PackedScene
	_check("main.tscn loads", packed != null)
	if packed == null:
		_finish()
		return
	var main := packed.instantiate()
	root.add_child(main)
	await _wait_physics(30)

	# --- structure ----------------------------------------------------------
	var menu := main.get_node_or_null("PauseMenu") as CanvasLayer
	_check("Main has a PauseMenu CanvasLayer", menu != null)
	if menu == null:
		_finish()
		return
	_check("the pause menu starts hidden", not menu.visible)
	_check("the pause menu reports itself closed", not bool(menu.call(&"is_open")))
	_check(
		"the menu keeps processing while the tree is paused (%d)" % menu.process_mode,
		menu.process_mode == Node.PROCESS_MODE_ALWAYS
	)
	for button_name: String in [
		"ResumeButton",
		"SettingsButton",
		"ControlsButton",
		"PlayersButton",
		"QuitToMenuButton",
		"QuitGameButton",
	]:
		_check(
			"the menu has a %s" % button_name,
			menu.get_node_or_null("Root/Center/Card/Margin/Content/Actions/%s" % button_name) != null
		)
	var hint := (
		menu.get_node_or_null("Root/Center/Card/Margin/Content/Actions/LocalHint") as Label
	)
	_check("the menu has a local-pause hint", hint != null)

	var player := get_first_node_in_group(&"player") as Node3D
	_check("a player was spawned", player != null)
	_check(
		"the player starts unblocked",
		player != null and not bool(player.get(&"ui_blocking"))
	)
	if player == null:
		_finish()
		return
	_check("the tree starts unpaused", not paused)

	# --- Escape opens the menu (OFFLINE) ------------------------------------
	_push_key(KEY_ESCAPE)
	await process_frame
	_check("Escape opens the pause menu", menu.visible and bool(menu.call(&"is_open")))
	_check("opening the menu pauses an offline tree", paused)
	_check("opening the menu UI-blocks the player", bool(player.get(&"ui_blocking")))

	# --- close() reverses everything, twice --------------------------------
	menu.call(&"close")
	await process_frame
	_check("close() hides the menu", not menu.visible)
	_check("close() unpauses the tree", not paused)
	_check("close() releases the player", not bool(player.get(&"ui_blocking")))
	menu.call(&"close")
	await process_frame
	_check(
		"close() is idempotent",
		not menu.visible and not paused and not bool(player.get(&"ui_blocking"))
	)

	# --- settings (same file as the lobby) ---------------------------------
	var settings_section := (
		menu.get_node_or_null("Root/Center/Card/Margin/Content/Sections/SettingsSection")
		as Control
	)
	var music_slider := (
		menu.get_node_or_null(
			"Root/Center/Card/Margin/Content/Sections/SettingsSection/MusicSlider"
		) as HSlider
	)
	var sfx_slider := (
		menu.get_node_or_null(
			"Root/Center/Card/Margin/Content/Sections/SettingsSection/SfxSlider"
		) as HSlider
	)
	var sensitivity_slider := (
		menu.get_node_or_null(
			"Root/Center/Card/Margin/Content/Sections/SettingsSection/SensitivitySlider"
		) as HSlider
	)
	var fullscreen_toggle := (
		menu.get_node_or_null(
			"Root/Center/Card/Margin/Content/Sections/SettingsSection/FullscreenToggle"
		) as CheckButton
	)
	_check("the menu has a settings section", settings_section != null)
	_check("settings has a music slider", music_slider != null)
	_check("settings has an SFX slider", sfx_slider != null)
	_check("settings has a sensitivity slider", sensitivity_slider != null)
	_check("settings has a fullscreen toggle", fullscreen_toggle != null)
	if sensitivity_slider != null:
		_check(
			"sensitivity matches the lobby's range (%.4f..%.4f)" % [
				sensitivity_slider.min_value, sensitivity_slider.max_value
			],
			is_equal_approx(sensitivity_slider.min_value, 0.0005)
				and is_equal_approx(sensitivity_slider.max_value, 0.01)
		)
	for audio_slider: HSlider in [music_slider, sfx_slider]:
		if audio_slider == null:
			continue
		_check(
			"the %s slider runs 0..100 (%.0f..%.0f)" % [
				audio_slider.name, audio_slider.min_value, audio_slider.max_value
			],
			is_equal_approx(audio_slider.min_value, 0.0)
				and is_equal_approx(audio_slider.max_value, 100.0)
		)

	menu.call(&"open")
	menu.call(&"set_section", "settings")
	await process_frame
	_check("the Settings page opens inline", settings_section != null and settings_section.visible)
	menu.call(&"set_music_volume", PROBE_MUSIC_VOLUME)
	menu.call(&"set_sfx_volume", PROBE_SFX_VOLUME)
	menu.call(&"set_mouse_sensitivity", PROBE_SENSITIVITY)
	menu.call(&"set_fullscreen", true)
	await process_frame

	var config := ConfigFile.new()
	_check("settings.cfg was written", config.load(SETTINGS_PATH) == OK)
	_check(
		"settings.cfg holds the music volume (%.2f)" % float(
			config.get_value(SETTINGS_SECTION, "music_volume", -1.0)
		),
		is_equal_approx(
			float(config.get_value(SETTINGS_SECTION, "music_volume", -1.0)), PROBE_MUSIC_VOLUME
		)
	)
	_check(
		"settings.cfg holds the SFX volume (%.2f)" % float(
			config.get_value(SETTINGS_SECTION, "sfx_volume", -1.0)
		),
		is_equal_approx(
			float(config.get_value(SETTINGS_SECTION, "sfx_volume", -1.0)), PROBE_SFX_VOLUME
		)
	)
	_check(
		"settings.cfg holds the sensitivity (%.4f)" % float(
			config.get_value(SETTINGS_SECTION, "mouse_sensitivity", -1.0)
		),
		is_equal_approx(
			float(config.get_value(SETTINGS_SECTION, "mouse_sensitivity", -1.0)),
			PROBE_SENSITIVITY
		)
	)
	_check(
		"settings.cfg holds the fullscreen flag",
		bool(config.get_value(SETTINGS_SECTION, "fullscreen", false))
	)

	var audio: Node = root.get_node_or_null("Audio")
	_check("Audio autoload is available", audio != null)
	if audio != null:
		_check(
			"the music slider reaches Audio (%.2f)" % float(audio.call(&"music_volume")),
			is_equal_approx(float(audio.call(&"music_volume")), PROBE_MUSIC_VOLUME)
		)
		_check(
			"the SFX slider reaches Audio (%.2f)" % float(audio.call(&"sfx_volume")),
			is_equal_approx(float(audio.call(&"sfx_volume")), PROBE_SFX_VOLUME)
		)
	_check(
		"the sensitivity reaches the player (%.4f)" % float(player.get(&"mouse_sensitivity")),
		is_equal_approx(float(player.get(&"mouse_sensitivity")), PROBE_SENSITIVITY)
	)
	if sensitivity_slider != null:
		_check(
			"the sensitivity slider follows the value (%.4f)" % sensitivity_slider.value,
			is_equal_approx(sensitivity_slider.value, PROBE_SENSITIVITY)
		)
	if music_slider != null:
		_check(
			"the music slider follows the value (%.0f)" % music_slider.value,
			is_equal_approx(music_slider.value, PROBE_MUSIC_VOLUME * 100.0)
		)
	if fullscreen_toggle != null:
		_check("the fullscreen toggle follows the value", fullscreen_toggle.button_pressed)

	# --- a SERVER peer keeps running ---------------------------------------
	menu.call(&"close")
	await process_frame
	var network: Node = root.get_node_or_null("Network")
	_check("Network autoload is available", network != null)
	if network != null:
		var constants: Dictionary = network.get_script().get_script_constant_map()
		var offline_mode := int(constants["OFFLINE"])
		network.set(&"mode", int(constants["SERVER"]))
		menu.call(&"open")
		await process_frame
		_check("a SERVER peer does not pause its tree", not paused)
		_check(
			"a SERVER peer shows the local-pause hint",
			hint != null and hint.visible and hint.text.contains("server keeps running")
		)
		menu.call(&"close")
		await process_frame
		network.set(&"mode", offline_mode)
		_check("the session is back to OFFLINE (%d)" % int(network.get(&"mode")),
			int(network.get(&"mode")) == offline_mode)

	# --- Controls read the live InputMap -----------------------------------
	menu.call(&"open")
	await process_frame
	_check("an OFFLINE menu hides the local-pause hint", hint == null or not hint.visible)
	menu.call(&"set_section", "controls")
	await process_frame
	var controls := String(menu.call(&"get_controls_text"))
	_check("the Controls page is not empty", not controls.is_empty())
	for action: StringName in [
		&"move_forward", &"move_back", &"move_left", &"move_right", &"sprint", &"jump",
		&"interact", &"build_toggle", &"vocation_menu", &"toggle_inventory",
		&"toggle_chat", &"ui_cancel",
	]:
		var key_text := _action_key_text(action)
		_check(
			"the Controls page lists %s (%s)" % [String(action), key_text],
			not key_text.is_empty() and controls.contains(key_text)
		)
	_check("the Controls page names the mouse attack (LMB)", controls.contains("LMB"))

	# --- Players mirrors Main.get_roster() ---------------------------------
	menu.call(&"set_section", "players")
	await process_frame
	var players_section := (
		menu.get_node_or_null("Root/Center/Card/Margin/Content/Sections/PlayersSection")
		as Control
	)
	var players_list := (
		menu.get_node_or_null(
			"Root/Center/Card/Margin/Content/Sections/PlayersSection/PlayersList"
		) as VBoxContainer
	)
	var roster: Array = main.call(&"get_roster")
	_check("offline the roster holds the local player (%d)" % roster.size(), roster.size() == 1)
	_check("the Players page opens", players_section != null and players_section.visible)
	_check("the Players page has a list", players_list != null)
	if players_list != null:
		_check(
			"the Players page shows one row per peer (%d/%d)" % [
				players_list.get_child_count(), roster.size()
			],
			players_list.get_child_count() == roster.size()
		)
		var row := players_list.get_child(0) as HBoxContainer
		_check("the roster row is a name + values line", row != null and row.get_child_count() >= 2)
		if row != null and row.get_child_count() >= 2:
			var name_text := (row.get_child(0) as Label).text
			var value_text := (row.get_child(1) as Label).text
			_check("the roster row names the player (%s)" % name_text, name_text.contains("Player"))
			_check(
				"the roster row shows level, HP and gold (%s)" % value_text,
				value_text.contains("Lv") and value_text.contains("HP") and value_text.contains("g")
			)

	# --- Escape priority: satchel first ------------------------------------
	menu.call(&"close")
	await process_frame
	var inventory_ui := main.get_node_or_null("InventoryUI")
	_check("Main has an InventoryUI layer", inventory_ui != null)
	if inventory_ui != null:
		inventory_ui.call(&"toggle")
		await process_frame
		_check("the satchel is open", bool(inventory_ui.call(&"is_open")))
		_push_key(KEY_ESCAPE)
		await process_frame
		_check("Escape closes the satchel", not bool(inventory_ui.call(&"is_open")))
		_check(
			"Escape does not open the pause menu over the satchel",
			not menu.visible and not paused
		)
		_check("the player is released with the satchel", not bool(player.get(&"ui_blocking")))

	# --- Escape closes the menu again --------------------------------------
	_push_key(KEY_ESCAPE)
	await process_frame
	_check("Escape opens the menu again", menu.visible)
	_push_key(KEY_ESCAPE)
	await process_frame
	_check("Escape closes the menu again", not menu.visible and not paused)

	# Leave the isolated settings file at its defaults, like test_lobby.
	menu.call(&"set_music_volume", 0.2511886432)
	menu.call(&"set_sfx_volume", 0.6309573445)
	menu.call(&"set_mouse_sensitivity", 0.0025)
	menu.call(&"set_fullscreen", false)

	main.queue_free()
	await _wait_physics(2)
	_finish()


## The key the project binds to `action`, straight from `InputMap`.
func _action_key_text(action: StringName) -> String:
	for event: InputEvent in InputMap.action_get_events(action):
		if event is InputEventKey:
			var key := event as InputEventKey
			var code := key.keycode if key.keycode != KEY_NONE else key.physical_keycode
			return OS.get_keycode_string(code)
	return ""


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
		print("PASSED  all pause-menu assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
