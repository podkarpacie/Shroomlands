extends SceneTree
## Headless lobby test: structure, entry-scene wiring, the menu-only guard and
## the persisted settings round trip.
##
## The lobby is loaded as a plain instantiated scene (the same way
## `tests/test_ui.gd` loads `main.tscn`); `run/main_scene` is asserted directly
## from `ProjectSettings`. `SHROOMLANDS_SAVE_PATH` points `SaveSystem` at a
## private `user://tests/` file (see tests/test_env.gd), so Continue and the
## offline world run exactly as in production without touching a real save.

const LOBBY_SCENE_PATH := "res://scenes/multiplayer/lobby.tscn"
const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "settings"
const PROBE_SENSITIVITY := 0.0075
const DEFAULT_SENSITIVITY := 0.0025
## Audio levels are linear 0..1 and the sliders show percent.
const PROBE_MUSIC_VOLUME := 0.35
const PROBE_SFX_VOLUME := 0.55
const DEFAULT_MUSIC_VOLUME := 0.2511886432
const DEFAULT_SFX_VOLUME := 0.6309573445
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _saves: Node = null
var _save_path := ""


func _initialize() -> void:
	TestEnv.isolate("test_lobby")
	_run()


func _run() -> void:
	# The Continue button reflects the save file, so point it at a private one
	# and start from an empty state.
	_saves = root.get_node_or_null("SaveSystem")
	_check("SaveSystem autoload is available", _saves != null)
	if _saves != null:
		_save_path = str(_saves.call(&"get_save_path"))
		_check("the suite writes to its own save path (%s)" % _save_path,
			_save_path.begins_with("user://tests/"))
		_check("the suite starts with no save", not bool(_saves.call(&"has_save")))

	var packed := load(LOBBY_SCENE_PATH) as PackedScene
	_check("lobby.tscn loads", packed != null)
	if packed == null:
		_finish()
		return
	var lobby := packed.instantiate()
	root.add_child(lobby)
	await _wait_physics(5)

	# --- structure ----------------------------------------------------------
	var host_button := lobby.get_node_or_null("Center/Panel/Margin/Content/HostButton") as Button
	var join_button := (
		lobby.get_node_or_null("Center/Panel/Margin/Content/JoinRow/JoinButton") as Button
	)
	var ip_field := lobby.get_node_or_null("Center/Panel/Margin/Content/JoinRow/IPField") as LineEdit
	var port_field := (
		lobby.get_node_or_null("Center/Panel/Margin/Content/JoinRow/PortField") as LineEdit
	)
	var transport_hint := (
		lobby.get_node_or_null("Center/Panel/Margin/Content/TransportHint") as Label
	)
	var settings_button := (
		lobby.get_node_or_null("Center/Panel/Margin/Content/SettingsButton") as Button
	)
	var quit_button := lobby.get_node_or_null("Center/Panel/Margin/Content/QuitButton") as Button
	var continue_button := (
		lobby.get_node_or_null("Center/Panel/Margin/Content/ContinueButton") as Button
	)
	var new_game_button := (
		lobby.get_node_or_null("Center/Panel/Margin/Content/NewGameButton") as Button
	)
	_check("lobby has a Host button", host_button != null)
	_check("lobby has a Join button", join_button != null)
	_check("lobby has an IP LineEdit", ip_field != null)
	_check("lobby has a Port LineEdit", port_field != null)
	_check("lobby has a transport hint", transport_hint != null)
	_check("lobby has a Settings button", settings_button != null)
	_check("lobby has a Quit button", quit_button != null)
	_check("lobby has a New Game button", new_game_button != null)
	_check("lobby has a Continue button", continue_button != null)
	_check(
		"Continue is hidden while there is no save",
		continue_button != null and not continue_button.visible
	)
	_check(
		"New Game is offered even without a save",
		new_game_button != null and new_game_button.visible
	)
	if ip_field != null:
		_check("the IP field defaults to 127.0.0.1 (%s)" % ip_field.text, ip_field.text == "127.0.0.1")
	if port_field != null:
		_check("the Port field defaults to 7777 (%s)" % port_field.text, port_field.text == "7777")
		_check("the Port field holds five digits at most (%d)" % port_field.max_length, port_field.max_length == 5)
	if transport_hint != null:
		var hint := transport_hint.text.to_lower()
		_check(
			"the transport hint names ENet/UDP (%s)" % transport_hint.text,
			hint.contains("enet/udp")
		)
		_check(
			"the transport hint names WebSocket/TCP (%s)" % transport_hint.text,
			hint.contains("websocket/tcp")
		)

	var title := lobby.get_node_or_null("Center/Panel/Margin/Content/Title") as Label
	_check("lobby has a title", title != null)
	if title != null:
		_check("the title is SHROOMLANDS (%s)" % title.text, title.text == "SHROOMLANDS")
	var subtitle := lobby.get_node_or_null("Center/Panel/Margin/Content/Subtitle") as Label
	if subtitle != null:
		_check("the subtitle is one line and not empty", not subtitle.text.is_empty() and not subtitle.text.contains("\n"))
	_check("lobby has a version label", lobby.get_node_or_null("Center/Panel/Margin/Content/VersionLabel") != null)

	var settings_layer := lobby.get_node_or_null("SettingsLayer") as Control
	var slider := (
		lobby.get_node_or_null(
			"SettingsLayer/Center/SettingsPanel/Margin/Content/SensitivitySlider"
		) as HSlider
	)
	var fullscreen := (
		lobby.get_node_or_null(
			"SettingsLayer/Center/SettingsPanel/Margin/Content/FullscreenToggle"
		) as CheckButton
	)
	var music_slider := (
		lobby.get_node_or_null(
			"SettingsLayer/Center/SettingsPanel/Margin/Content/MusicSlider"
		) as HSlider
	)
	var sfx_slider := (
		lobby.get_node_or_null(
			"SettingsLayer/Center/SettingsPanel/Margin/Content/SfxSlider"
		) as HSlider
	)
	_check("lobby has a settings layer", settings_layer != null)
	_check("the settings panel starts closed", settings_layer != null and not settings_layer.visible)
	_check("settings has a sensitivity slider", slider != null)
	_check("settings has a fullscreen toggle", fullscreen != null)
	_check("settings has a music volume slider", music_slider != null)
	_check("settings has an SFX volume slider", sfx_slider != null)
	if slider != null:
		_check(
			"sensitivity range is 0.0005..0.01 (%.4f..%.4f)" % [slider.min_value, slider.max_value],
			is_equal_approx(slider.min_value, 0.0005) and is_equal_approx(slider.max_value, 0.01)
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

	# --- port validation ----------------------------------------------------
	var network := root.get_node_or_null("Network")
	var status_label := lobby.get_node_or_null("Center/Panel/Margin/Content/StatusLabel") as Label
	_check("Network autoload is available", network != null)
	_check("lobby has a status label", status_label != null)
	_check("the lobby exposes parse_port", lobby.has_method(&"parse_port"))
	if lobby.has_method(&"parse_port"):
		_check("7777 parses", int(lobby.call(&"parse_port", "7777")) == 7777)
		_check("1024 is the lowest valid port", int(lobby.call(&"parse_port", "1024")) == 1024)
		_check("65535 is the highest valid port", int(lobby.call(&"parse_port", "65535")) == 65535)
		for bad: String in ["1023", "65536", "0", "-1", "abc", "", "80.0", "port"]:
			_check("port '%s' is rejected" % bad, int(lobby.call(&"parse_port", bad)) < 0)
	if port_field != null and status_label != null and network != null:
		var offline := int(network.get_script().get_script_constant_map()["OFFLINE"])
		port_field.text = "80"
		lobby.call(&"host_game")
		_check(
			"an out-of-range port shows an inline error (%s)" % status_label.text,
			status_label.text.contains("1024") and status_label.text.contains("65535")
		)
		_check("an invalid port never opens a session", int(network.get(&"mode")) == offline)
		port_field.text = "7777"
		_check("the Port field accepts 7777 again", int(lobby.call(&"read_port")) == 7777)

	# --- failed-join recovery ----------------------------------------------
	# A join that already handed over to the world unwinds to this menu with the
	# reason in Network.last_error; the fresh lobby shows it once.
	if network != null:
		network.set(&"last_error", "server disconnected")
		var recovered := packed.instantiate()
		root.add_child(recovered)
		await _wait_physics(2)
		var recovered_status := (
			recovered.get_node_or_null("Center/Panel/Margin/Content/StatusLabel") as Label
		)
		_check(
			"a failed join shows its reason in the menu (%s)" % (
				"" if recovered_status == null else recovered_status.text
			),
			recovered_status != null and recovered_status.text.contains("server disconnected")
		)
		_check("the join error is consumed", String(network.get(&"last_error")).is_empty())
		recovered.queue_free()
		await _wait_physics(2)

	# --- entry scene --------------------------------------------------------
	var entry := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	_check("run/main_scene is the lobby (%s)" % entry, entry == LOBBY_SCENE_PATH)

	# --- menu-only guard ----------------------------------------------------
	_check("the lobby has no node in group 'player'", get_nodes_in_group(&"player").is_empty())
	_check("the lobby does not instantiate the world", lobby.find_child("World", true, false) == null)
	_check("the lobby does not instantiate a Players container", lobby.find_child("Players", true, false) == null)
	_check(
		"the lobby does not instantiate a player body",
		lobby.find_child("Player", true, false) == null
	)
	var constants: Dictionary = lobby.get_script().get_script_constant_map()
	_check(
		"the lobby hands over to main.tscn (%s)" % constants.get("MAIN_SCENE_PATH", ""),
		String(constants.get("MAIN_SCENE_PATH", "")) == MAIN_SCENE_PATH
	)

	# --- settings persistence ----------------------------------------------
	lobby.call(&"set_mouse_sensitivity", PROBE_SENSITIVITY)
	_check(
		"the lobby applies the sensitivity to its own state",
		is_equal_approx(float(lobby.call(&"get_mouse_sensitivity")), PROBE_SENSITIVITY)
	)
	var config := ConfigFile.new()
	_check("settings.cfg was written", config.load(SETTINGS_PATH) == OK)
	_check(
		"settings.cfg holds the sensitivity (%.4f)" % float(
			config.get_value(SETTINGS_SECTION, "mouse_sensitivity", -1.0)
		),
		is_equal_approx(float(config.get_value(SETTINGS_SECTION, "mouse_sensitivity", -1.0)), PROBE_SENSITIVITY)
	)

	lobby.call(&"set_music_volume", PROBE_MUSIC_VOLUME)
	lobby.call(&"set_sfx_volume", PROBE_SFX_VOLUME)
	_check(
		"the lobby applies the music volume (%.2f)" % float(lobby.call(&"get_music_volume")),
		is_equal_approx(float(lobby.call(&"get_music_volume")), PROBE_MUSIC_VOLUME)
	)
	_check(
		"the lobby applies the SFX volume (%.2f)" % float(lobby.call(&"get_sfx_volume")),
		is_equal_approx(float(lobby.call(&"get_sfx_volume")), PROBE_SFX_VOLUME)
	)
	var sfx_bus := AudioServer.get_bus_index(&"SFX")
	_check("the project has an SFX bus (index %d)" % sfx_bus, sfx_bus >= 0)
	if sfx_bus >= 0:
		_check(
			"the SFX slider reaches the bus (%.1f dB)" % AudioServer.get_bus_volume_db(sfx_bus),
			is_equal_approx(
				AudioServer.get_bus_volume_db(sfx_bus), linear_to_db(PROBE_SFX_VOLUME)
			)
		)
	var audio_config := ConfigFile.new()
	_check("settings.cfg was rewritten", audio_config.load(SETTINGS_PATH) == OK)
	_check(
		"settings.cfg holds the music volume (%.2f)" % float(
			audio_config.get_value(SETTINGS_SECTION, "music_volume", -1.0)
		),
		is_equal_approx(
			float(audio_config.get_value(SETTINGS_SECTION, "music_volume", -1.0)), PROBE_MUSIC_VOLUME
		)
	)
	_check(
		"settings.cfg holds the SFX volume (%.2f)" % float(
			audio_config.get_value(SETTINGS_SECTION, "sfx_volume", -1.0)
		),
		is_equal_approx(
			float(audio_config.get_value(SETTINGS_SECTION, "sfx_volume", -1.0)), PROBE_SFX_VOLUME
		)
	)

	# Re-instantiate: a fresh lobby must read the file back.
	lobby.queue_free()
	await _wait_physics(2)
	# A save on disk is what makes Continue appear; the label is its summary.
	if _saves != null:
		_write_probe_save()
	var reloaded := packed.instantiate()
	root.add_child(reloaded)
	await _wait_physics(2)
	_check(
		"a fresh lobby restores the saved sensitivity (%.4f)" % float(
			reloaded.call(&"get_mouse_sensitivity")
		),
		is_equal_approx(float(reloaded.call(&"get_mouse_sensitivity")), PROBE_SENSITIVITY)
	)
	_check(
		"a fresh lobby restores the saved music volume (%.2f)" % float(
			reloaded.call(&"get_music_volume")
		),
		is_equal_approx(float(reloaded.call(&"get_music_volume")), PROBE_MUSIC_VOLUME)
	)
	_check(
		"a fresh lobby restores the saved SFX volume (%.2f)" % float(
			reloaded.call(&"get_sfx_volume")
		),
		is_equal_approx(float(reloaded.call(&"get_sfx_volume")), PROBE_SFX_VOLUME)
	)
	var reloaded_music := (
		reloaded.get_node_or_null(
			"SettingsLayer/Center/SettingsPanel/Margin/Content/MusicSlider"
		) as HSlider
	)
	var reloaded_sfx := (
		reloaded.get_node_or_null(
			"SettingsLayer/Center/SettingsPanel/Margin/Content/SfxSlider"
		) as HSlider
	)
	_check(
		"the music slider shows the saved level (%s)" % (
			"-" if reloaded_music == null else str(reloaded_music.value)
		),
		reloaded_music != null and is_equal_approx(reloaded_music.value, PROBE_MUSIC_VOLUME * 100.0)
	)
	_check(
		"the SFX slider shows the saved level (%s)" % (
			"-" if reloaded_sfx == null else str(reloaded_sfx.value)
		),
		reloaded_sfx != null and is_equal_approx(reloaded_sfx.value, PROBE_SFX_VOLUME * 100.0)
	)
	var reloaded_scene := root.get_node_or_null("Lobby")
	_check("the reloaded lobby is the live menu", reloaded_scene == reloaded)

	# --- Continue / New Game -------------------------------------------------
	var loaded_continue := (
		reloaded.get_node_or_null("Center/Panel/Margin/Content/ContinueButton") as Button
	)
	var loaded_new_game := (
		reloaded.get_node_or_null("Center/Panel/Margin/Content/NewGameButton") as Button
	)
	_check(
		"a save makes Continue visible",
		loaded_continue != null and loaded_continue.visible
	)
	_check(
		"Continue summarises the save (%s)" % ("" if loaded_continue == null else loaded_continue.text),
		loaded_continue != null
			and loaded_continue.text == "Continue — Lv 12 · Harvester · 340 g"
	)
	_check(
		"continue_label() matches the button",
		loaded_continue != null
			and String(reloaded.call(&"continue_label")) == loaded_continue.text
	)
	if loaded_continue != null:
		_check(
			"Continue carries the save time as a tooltip (%s)" % loaded_continue.tooltip_text,
			loaded_continue.tooltip_text.contains("2026-01-02 03:04:05")
		)
	_check(
		"the reloaded lobby still offers New Game",
		loaded_new_game != null and loaded_new_game.visible
	)

	# Leave the isolated path without our probe save.
	if _saves != null:
		_saves.call(&"delete_save")

	# Leave the user's settings as the project default.
	reloaded.call(&"set_music_volume", DEFAULT_MUSIC_VOLUME)
	reloaded.call(&"set_sfx_volume", DEFAULT_SFX_VOLUME)
	reloaded.call(&"set_mouse_sensitivity", DEFAULT_SENSITIVITY)
	var restored := ConfigFile.new()
	restored.load(SETTINGS_PATH)
	_check(
		"the settings file is restored (%.4f)" % float(
			restored.get_value(SETTINGS_SECTION, "mouse_sensitivity", -1.0)
		),
		is_equal_approx(float(restored.get_value(SETTINGS_SECTION, "mouse_sensitivity", -1.0)), DEFAULT_SENSITIVITY)
	)
	_check(
		"the music volume is restored (%.2f)" % float(
			restored.get_value(SETTINGS_SECTION, "music_volume", -1.0)
		),
		is_equal_approx(
			float(restored.get_value(SETTINGS_SECTION, "music_volume", -1.0)), DEFAULT_MUSIC_VOLUME
		)
	)
	_check(
		"the SFX volume is restored (%.2f)" % float(
			restored.get_value(SETTINGS_SECTION, "sfx_volume", -1.0)
		),
		is_equal_approx(
			float(restored.get_value(SETTINGS_SECTION, "sfx_volume", -1.0)), DEFAULT_SFX_VOLUME
		)
	)

	# --- Continue: save on disk -> offline world ---------------------------
	var game: Node = root.get_node_or_null("Game")
	_check("Game autoload is available", game != null)
	_write_probe_save()
	_check("the probe save lands at the isolated path (%s)" % _save_path,
		FileAccess.file_exists(_save_path))
	var continue_lobby := packed.instantiate()
	root.add_child(continue_lobby)
	await _wait_physics(2)
	continue_lobby.call(&"continue_game")
	await _wait_physics(20)
	var main := root.get_node_or_null("Main")
	_check("Continue changes the scene to main.tscn", main != null)
	var loaded := get_first_node_in_group(&"player") as Node3D
	_check("Continue spawns the local player", loaded != null)
	_check("Continue keeps the save file", bool(_saves.call(&"has_save")))
	if loaded != null:
		var stats := loaded.get_node_or_null("Stats")
		_check("Continue restores the level (%d)" % int(stats.get("level")),
			int(stats.get("level")) == 12)
		var position := loaded.global_position
		_check(
			"Continue restores the position (%.2f, %.2f, %.2f)" % [position.x, position.y, position.z],
			absf(position.x - 4.0) < 0.5 and absf(position.z + 6.0) < 0.5
		)
		_check("the loaded vocation bonus applies once (max_stamina %.0f)" % float(stats.get("max_stamina")),
			is_equal_approx(float(stats.get("max_stamina")), 125.0))
	if game != null:
		_check("Continue restores gold (%d)" % int(game.get(&"gold")), int(game.get(&"gold")) == 340)
		_check("Continue restores the vocation (%s)" % String(game.get(&"chosen_vocation")),
			StringName(game.get(&"chosen_vocation")) == &"harvester")
	if main != null:
		var hud := main.get_node_or_null("HUD")
		var level_label := hud.get_node_or_null("Root/Progression/LevelLabel") as Label
		_check(
			"the HUD shows the loaded vocation (%s)" % ("" if level_label == null else level_label.text),
			level_label != null and level_label.text == "Lv 12 · Harvester"
		)

	# --- New Game: delete the save and start fresh -------------------------
	# Close the offline world first: a lobby is only ever opened from the menu,
	# and the menu guard would otherwise remove the running player.
	var previous_world := root.get_node_or_null("Main")
	if previous_world != null:
		previous_world.queue_free()
		await _wait_physics(2)
	var new_game_lobby := packed.instantiate()
	root.add_child(new_game_lobby)
	await _wait_physics(2)
	new_game_lobby.call(&"new_game")
	await _wait_physics(20)
	_check("New Game deletes the save", not bool(_saves.call(&"has_save")))
	var players := get_nodes_in_group(&"player")
	_check("New Game leaves exactly one player (%d)" % players.size(), players.size() == 1)
	if not players.is_empty():
		var fresh_stats := (players[0] as Node).get_node_or_null("Stats")
		_check("New Game starts at Lv 1 (%d)" % int(fresh_stats.get("level")),
			int(fresh_stats.get("level")) == 1)
	if game != null:
		_check("New Game resets the gold (%d)" % int(game.get(&"gold")), int(game.get(&"gold")) == 50)
		_check("New Game clears the vocation", StringName(game.get(&"chosen_vocation")) == &"")

	_finish()


## A finished offline state: level 12 harvester with a bag and a position.
func _write_probe_save() -> void:
	_saves.call(&"save_player", {
		"version": 2,
		"level": 12,
		"xp": 40,
		"hp": 90.0,
		"stamina": 70.0,
		"gold": 340,
		"discovered_mushrooms": {"glowcap": true},
		"vocation": "harvester",
		"position": [4.0, 2.0, -6.0],
		"inventory": {"slots": {"0": ["glowcap", 3]}},
		"saved_at": "2026-01-02 03:04:05",
	})


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
		print("PASSED  all lobby assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
