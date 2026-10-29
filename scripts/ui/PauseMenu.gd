extends CanvasLayer
## In-game pause menu: Esc opens this card, and a panel that is already open
## closes first (see `handle_escape`).
##
## Offline the menu pauses the SceneTree, so the world, the creatures and the
## player stop between swings. A networked peer never does that: SERVER and
## CLIENT keep running and only say "Paused (local)", because freezing this
## peer's tree would also freeze its own simulation while the server keeps
## stepping it, and the body would come back out of sync. The layer itself is
## `PROCESS_MODE_ALWAYS` — the pause it creates would otherwise freeze its own
## buttons — while every other node in the scene stays pausable.
##
## Options are the lobby's: this page and `LobbyUI` call the same
## `settings.cfg` helpers, so both views read and write one file with one set of
## ranges and defaults. Changes apply immediately.

const LOBBY_SCENE_PATH := "res://scenes/multiplayer/lobby.tscn"
## The lobby owns `settings.cfg`; reusing its helpers keeps the keys and the
## clamping in one place instead of a second copy that can drift.
const SettingsStore := preload("res://scripts/ui/LobbyUI.gd")
## Scene-tree metadata `ChatUI` reads to bind a body that spawns after it.
const SENSITIVITY_META := &"mouse_sensitivity"
## The roster arrives once a second; half of that keeps the list live without
## rebuilding its rows every frame.
const ROSTER_REFRESH_SECONDS := 0.5
const CLICK_VOLUME_DB := -8.0

const SECTION_NONE := ""
const SECTION_SETTINGS := "settings"
const SECTION_CONTROLS := "controls"
const SECTION_PLAYERS := "players"

## Grouped for the Controls page. The key names are read from `InputMap` when
## the page is built, so a rebind shows up without touching this file.
const CONTROL_GROUPS := [
	{
		"title": "Movement",
		"actions": [&"move_forward", &"move_back", &"move_left", &"move_right", &"sprint", &"jump"],
	},
	{
		"title": "Interaction",
		"actions": [&"interact", &"attack", &"build_toggle", &"vocation_menu"],
	},
	{
		"title": "UI",
		"actions": [&"toggle_inventory", &"toggle_chat", &"ui_cancel"],
	},
]
## Display names only; the bindings themselves always come from `InputMap`.
const ACTION_LABELS := {
	&"move_forward": "Forward",
	&"move_back": "Back",
	&"move_left": "Left",
	&"move_right": "Right",
	&"sprint": "Sprint",
	&"jump": "Jump",
	&"interact": "Interact",
	&"attack": "Attack",
	&"build_toggle": "Build mode",
	&"vocation_menu": "Vocation",
	&"toggle_inventory": "Satchel",
	&"toggle_chat": "Chat",
	&"ui_cancel": "Pause menu",
}

@onready var _dim: ColorRect = $Root/Dim
@onready var _card: PanelContainer = $Root/Center/Card
@onready var _title: Label = $Root/Center/Card/Margin/Content/Actions/Title
@onready var _subtitle: Label = $Root/Center/Card/Margin/Content/Actions/Subtitle
@onready var _local_hint: Label = $Root/Center/Card/Margin/Content/Actions/LocalHint
@onready var _resume_button: Button = $Root/Center/Card/Margin/Content/Actions/ResumeButton
@onready var _settings_button: Button = $Root/Center/Card/Margin/Content/Actions/SettingsButton
@onready var _controls_button: Button = $Root/Center/Card/Margin/Content/Actions/ControlsButton
@onready var _players_button: Button = $Root/Center/Card/Margin/Content/Actions/PlayersButton
@onready var _quit_to_menu_button: Button = (
	$Root/Center/Card/Margin/Content/Actions/QuitToMenuButton
)
@onready var _quit_game_button: Button = $Root/Center/Card/Margin/Content/Actions/QuitGameButton
@onready var _footer: Label = $Root/Center/Card/Margin/Content/Actions/Footer
@onready var _idle_hint: Label = $Root/Center/Card/Margin/Content/Sections/IdleHint
@onready var _settings_section: VBoxContainer = (
	$Root/Center/Card/Margin/Content/Sections/SettingsSection
)
@onready var _settings_title: Label = (
	$Root/Center/Card/Margin/Content/Sections/SettingsSection/SettingsTitle
)
@onready var _music_value: Label = (
	$Root/Center/Card/Margin/Content/Sections/SettingsSection/MusicHeader/MusicValue
)
@onready var _music_slider: HSlider = (
	$Root/Center/Card/Margin/Content/Sections/SettingsSection/MusicSlider
)
@onready var _sfx_value: Label = (
	$Root/Center/Card/Margin/Content/Sections/SettingsSection/SfxHeader/SfxValue
)
@onready var _sfx_slider: HSlider = (
	$Root/Center/Card/Margin/Content/Sections/SettingsSection/SfxSlider
)
@onready var _sensitivity_value: Label = (
	$Root/Center/Card/Margin/Content/Sections/SettingsSection/SensitivityHeader/SensitivityValue
)
@onready var _sensitivity_slider: HSlider = (
	$Root/Center/Card/Margin/Content/Sections/SettingsSection/SensitivitySlider
)
@onready var _fullscreen_toggle: CheckButton = (
	$Root/Center/Card/Margin/Content/Sections/SettingsSection/FullscreenToggle
)
@onready var _controls_section: VBoxContainer = (
	$Root/Center/Card/Margin/Content/Sections/ControlsSection
)
@onready var _controls_title: Label = (
	$Root/Center/Card/Margin/Content/Sections/ControlsSection/ControlsTitle
)
@onready var _controls_list: VBoxContainer = (
	$Root/Center/Card/Margin/Content/Sections/ControlsSection/ControlsScroll/ControlsMargin/ControlsList
)
@onready var _players_section: VBoxContainer = (
	$Root/Center/Card/Margin/Content/Sections/PlayersSection
)
@onready var _players_title: Label = (
	$Root/Center/Card/Margin/Content/Sections/PlayersSection/PlayersTitle
)
@onready var _players_list: VBoxContainer = (
	$Root/Center/Card/Margin/Content/Sections/PlayersSection/PlayersList
)

var _open := false
var _section := SECTION_NONE
var _music_volume := SettingsStore.DEFAULT_MUSIC_VOLUME
var _sfx_volume := SettingsStore.DEFAULT_SFX_VOLUME
var _sensitivity := SettingsStore.DEFAULT_SENSITIVITY
var _fullscreen := false
var _roster_left := 0.0


func _ready() -> void:
	UITheme.install(get_tree().root)
	visible = false
	_style()
	_sensitivity_slider.min_value = SettingsStore.MIN_SENSITIVITY
	_sensitivity_slider.max_value = SettingsStore.MAX_SENSITIVITY
	_sensitivity_slider.step = 0.0001
	_load_settings()
	_sync_settings_controls()
	_connect_buttons()
	_build_controls()
	set_section(SECTION_NONE)
	set_process(false)


func _exit_tree() -> void:
	# A scene change (or a quit) while the menu is open must not leave the next
	# scene paused.
	if get_tree() != null:
		get_tree().paused = false


func _process(delta: float) -> void:
	if not _open or _section != SECTION_PLAYERS:
		return
	_roster_left -= delta
	if _roster_left > 0.0:
		return
	_roster_left = ROSTER_REFRESH_SECONDS
	_refresh_players()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"ui_cancel"):
		return
	if handle_escape():
		get_viewport().set_input_as_handled()


# --- public API (the controls, the controller and the tests use it) ---------


## Escape priority, in one place: an open panel closes first and the menu never
## opens on top of it. Returns true when the key was consumed here.
func handle_escape() -> bool:
	if _open:
		close()
		return true
	var chat := _panel(&"ChatUI", &"set_open")
	if chat != null and bool(chat.call(&"is_open")):
		chat.call(&"set_open", false)
		return true
	var inventory := _panel(&"InventoryUI", &"set_open")
	if inventory != null and bool(inventory.call(&"is_open")):
		inventory.call(&"set_open", false)
		return true
	var build := _panel(&"BuildMode", &"set_active")
	if build != null and bool(build.call(&"is_active")):
		build.call(&"set_active", false)
		return true
	open()
	return true


func open() -> void:
	if _open:
		return
	_open = true
	visible = true
	set_process(true)
	_roster_left = ROSTER_REFRESH_SECONDS
	_load_settings()
	_sync_settings_controls()
	_refresh_hint()
	# Re-applies the page that was open last time and refreshes its contents, so
	# a roster that changed while the menu was closed is current on the next open.
	set_section(_section)
	_set_player_blocking(true)
	_show_cursor()
	if Network.mode == Network.OFFLINE:
		get_tree().paused = true


func close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	set_process(false)
	if get_tree() != null:
		get_tree().paused = false
	_set_player_blocking(false)
	_recapture_mouse()


func is_open() -> bool:
	return _open


func toggle_section(id: String) -> void:
	set_section(SECTION_NONE if _section == id else id)


func set_section(id: String) -> void:
	if id != SECTION_NONE and id != SECTION_SETTINGS and id != SECTION_CONTROLS and id != SECTION_PLAYERS:
		return
	_section = id
	_settings_section.visible = id == SECTION_SETTINGS
	_controls_section.visible = id == SECTION_CONTROLS
	_players_section.visible = id == SECTION_PLAYERS
	_idle_hint.visible = id == SECTION_NONE
	_mark_section(_settings_button, id == SECTION_SETTINGS)
	_mark_section(_controls_button, id == SECTION_CONTROLS)
	_mark_section(_players_button, id == SECTION_PLAYERS)
	if id == SECTION_CONTROLS:
		# Rebuilt on every open, so a rebind made in the project settings is
		# reflected without reloading the scene.
		_build_controls()
	if id == SECTION_PLAYERS:
		# An empty roster hides the whole block instead of drawing an empty one.
		_players_section.visible = _refresh_players() > 0


func is_section_open(id: String) -> bool:
	return _section == id


## The Controls page as plain text, built from `InputMap`; the suite asserts the
## real bindings are listed rather than strings baked into this script.
func get_controls_text() -> String:
	var lines: Array[String] = []
	for child in _controls_list.get_children():
		if child is HBoxContainer:
			var row := child as HBoxContainer
			if row.get_child_count() >= 2:
				lines.append("%s  %s" % [
					(row.get_child(0) as Label).text, (row.get_child(1) as Label).text
				])
		elif child is Label:
			lines.append((child as Label).text)
	return "\n".join(lines)


func quit_to_menu() -> void:
	if Network.mode != Network.OFFLINE:
		Network.disconnect_peer()
	# No recapture here: the lobby is a menu and needs a visible cursor.
	_set_player_blocking(false)
	_show_cursor()
	_open = false
	visible = false
	set_process(false)
	if get_tree() != null:
		get_tree().paused = false
	var error := get_tree().change_scene_to_file(LOBBY_SCENE_PATH)
	if error != OK:
		push_warning("PauseMenu: cannot load the lobby: %s" % error_string(error))
		open()


func quit_game() -> void:
	# A networked session is server-authoritative, so its progress is not read
	# from this peer's file and saving here would overwrite an offline character.
	if Network.mode == Network.OFFLINE:
		SaveSystem.save_now()
	get_tree().quit()


# --- settings (shared with the lobby) --------------------------------------


## Linear 0..1. The slider is a percentage; the stored level is the audio level.
func set_music_volume(value: float) -> void:
	_music_volume = clampf(value, 0.0, 1.0)
	_sync_volume_controls()
	Audio.set_music_volume(_music_volume)
	_write_settings()


func set_sfx_volume(value: float) -> void:
	_sfx_volume = clampf(value, 0.0, 1.0)
	_sync_volume_controls()
	Audio.set_sfx_volume(_sfx_volume)
	_write_settings()


func get_music_volume() -> float:
	return _music_volume


func get_sfx_volume() -> float:
	return _sfx_volume


func set_mouse_sensitivity(value: float) -> void:
	_sensitivity = clampf(value, SettingsStore.MIN_SENSITIVITY, SettingsStore.MAX_SENSITIVITY)
	_sync_sensitivity_controls()
	_apply_sensitivity()
	_write_settings()


func get_mouse_sensitivity() -> float:
	return _sensitivity


func set_fullscreen(value: bool) -> void:
	_fullscreen = value
	_sync_fullscreen_control()
	_apply_fullscreen()
	_write_settings()


func is_fullscreen() -> bool:
	return _fullscreen


# --- wiring ----------------------------------------------------------------


func _connect_buttons() -> void:
	# Every button clicks first; connecting the cue once keeps it out of each
	# handler, the same way the lobby does it.
	for button: Button in [
		_resume_button,
		_settings_button,
		_controls_button,
		_players_button,
		_quit_to_menu_button,
		_quit_game_button,
	]:
		button.pressed.connect(_play_click)
	_resume_button.pressed.connect(close)
	_settings_button.pressed.connect(toggle_section.bind(SECTION_SETTINGS))
	_controls_button.pressed.connect(toggle_section.bind(SECTION_CONTROLS))
	_players_button.pressed.connect(toggle_section.bind(SECTION_PLAYERS))
	_quit_to_menu_button.pressed.connect(quit_to_menu)
	_quit_game_button.pressed.connect(quit_game)
	_music_slider.value_changed.connect(_on_music_slider_changed)
	_sfx_slider.value_changed.connect(_on_sfx_slider_changed)
	_sensitivity_slider.value_changed.connect(_on_sensitivity_slider_changed)
	_fullscreen_toggle.toggled.connect(set_fullscreen)


func _play_click() -> void:
	Audio.play_sfx(&"ui_click", 0.04, CLICK_VOLUME_DB)


func _on_music_slider_changed(value: float) -> void:
	set_music_volume(value / 100.0)


func _on_sfx_slider_changed(value: float) -> void:
	set_sfx_volume(value / 100.0)


func _on_sensitivity_slider_changed(value: float) -> void:
	set_mouse_sensitivity(value)


## The multiplayer-only note. Offline the tree really is paused, so the hint
## would be wrong there.
func _refresh_hint() -> void:
	_local_hint.visible = Network.mode != Network.OFFLINE


func _refresh_players() -> int:
	_clear(_players_list)
	var roster: Array = []
	var main := get_parent()
	if main != null and main.has_method(&"get_roster"):
		var raw: Variant = main.call(&"get_roster")
		if raw is Array:
			roster = raw
	var local_id := multiplayer.get_unique_id()
	for entry: Dictionary in roster:
		_players_list.add_child(
			_player_row(entry, int(entry.get("peer_id", 0)) == local_id)
		)
	return roster.size()


func _player_row(entry: Dictionary, is_local: bool) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var player_name := str(entry.get("name", "Player"))
	var name_label := Label.new()
	name_label.text = ("%s (you)" % player_name) if is_local else player_name
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_label(name_label, 13, UITheme.ACCENT if is_local else UITheme.TEXT, 0)
	row.add_child(name_label)
	var values := Label.new()
	values.text = "Lv %d · %d HP · %d g" % [
		int(entry.get("level", 1)),
		roundi(float(entry.get("hp", 0.0))),
		int(entry.get("gold", 0)),
	]
	values.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UITheme.style_label(values, 12, UITheme.DIM, 0)
	row.add_child(values)
	return row


func _build_controls() -> void:
	_clear(_controls_list)
	var first_group := true
	for group: Dictionary in CONTROL_GROUPS:
		if not first_group:
			# A little air before each heading; without it "INTERACTION" reads
			# as another binding row.
			var spacer := Control.new()
			spacer.custom_minimum_size = Vector2(0.0, 6.0)
			_controls_list.add_child(spacer)
		first_group = false
		var heading := Label.new()
		heading.text = str(group.get("title", "")).to_upper()
		UITheme.style_label(heading, 11, UITheme.ACCENT_SOFT, 0)
		_controls_list.add_child(heading)
		for action: StringName in group.get("actions", []):
			_controls_list.add_child(_control_row(action))


func _control_row(action: StringName) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var name_label := Label.new()
	name_label.text = str(ACTION_LABELS.get(action, String(action)))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_label(name_label, 13, UITheme.TEXT, 0)
	row.add_child(name_label)
	var keys := Label.new()
	keys.text = _action_keys(action)
	keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UITheme.style_label(keys, 12, UITheme.ACCENT, 0)
	row.add_child(keys)
	return row


## Every binding of `action` as one readable line, straight from `InputMap`.
func _action_keys(action: StringName) -> String:
	if not InputMap.has_action(action):
		return "unbound"
	var parts: Array[String] = []
	for event: InputEvent in InputMap.action_get_events(action):
		var text := _event_label(event)
		if not text.is_empty() and not parts.has(text):
			parts.append(text)
	return " / ".join(parts) if not parts.is_empty() else "unbound"


func _event_label(event: InputEvent) -> String:
	if event is InputEventKey:
		var key := event as InputEventKey
		var code := key.keycode if key.keycode != KEY_NONE else key.physical_keycode
		return OS.get_keycode_string(code)
	if event is InputEventMouseButton:
		return _mouse_button_label((event as InputEventMouseButton).button_index)
	var text := event.as_text()
	return text if not text.is_empty() else "unbound"


## The project binds the mouse in four actions; three-letter names read better
## in a list than "Left Mouse Button".
func _mouse_button_label(index: MouseButton) -> String:
	match index:
		MOUSE_BUTTON_LEFT:
			return "LMB"
		MOUSE_BUTTON_RIGHT:
			return "RMB"
		MOUSE_BUTTON_MIDDLE:
			return "MMB"
		MOUSE_BUTTON_WHEEL_UP:
			return "Wheel up"
		MOUSE_BUTTON_WHEEL_DOWN:
			return "Wheel down"
	return "Mouse %d" % int(index)


# --- player, cursor and pause state ----------------------------------------


func _set_player_blocking(value: bool) -> void:
	var player := Game.get_local_player()
	if player == null:
		return
	if player.has_method(&"set_ui_blocking"):
		player.call(&"set_ui_blocking", value)
	elif _has_property(player, &"ui_blocking"):
		player.set(&"ui_blocking", value)


func _show_cursor() -> void:
	if DisplayServer.has_feature(DisplayServer.FEATURE_MOUSE):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


## The controller owns mouse capture (it is also what the click-to-recapture
## path calls), so the menu asks it instead of keeping a second copy of the rule.
func _recapture_mouse() -> void:
	var player := Game.get_local_player()
	if player != null and player.has_method(&"_capture_mouse"):
		player.call(&"_capture_mouse")


## A panel of this scene by name, only when it exposes `method`.
func _panel(node_name: StringName, method: StringName) -> Node:
	var parent := get_parent()
	if parent == null:
		return null
	var panel := parent.get_node_or_null(NodePath(String(node_name)))
	if panel == null or not panel.has_method(method):
		return null
	return panel


func _mark_section(button: Button, active: bool) -> void:
	button.add_theme_color_override("font_color", UITheme.ACCENT if active else UITheme.TEXT)


func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


# --- settings plumbing -----------------------------------------------------


func _load_settings() -> void:
	var values := SettingsStore.read_settings()
	_music_volume = float(values.get("music_volume", SettingsStore.DEFAULT_MUSIC_VOLUME))
	_sfx_volume = float(values.get("sfx_volume", SettingsStore.DEFAULT_SFX_VOLUME))
	_sensitivity = float(values.get("mouse_sensitivity", SettingsStore.DEFAULT_SENSITIVITY))
	_fullscreen = bool(values.get("fullscreen", false))


func _write_settings() -> void:
	var error := SettingsStore.write_settings({
		"mouse_sensitivity": _sensitivity,
		"fullscreen": _fullscreen,
		"music_volume": _music_volume,
		"sfx_volume": _sfx_volume,
	})
	if error != OK:
		push_warning("PauseMenu: cannot save settings: %s" % error_string(error))


func _sync_settings_controls() -> void:
	_sync_volume_controls()
	_sync_sensitivity_controls()
	_sync_fullscreen_control()


## Both audio sliders show percent; the stored level is linear 0..1.
func _sync_volume_controls() -> void:
	_music_slider.set_value_no_signal(_music_volume * 100.0)
	_music_value.text = "%d%%" % int(round(_music_volume * 100.0))
	_sfx_slider.set_value_no_signal(_sfx_volume * 100.0)
	_sfx_value.text = "%d%%" % int(round(_sfx_volume * 100.0))


func _sync_sensitivity_controls() -> void:
	_sensitivity_slider.set_value_no_signal(_sensitivity)
	_sensitivity_value.text = "%.4f" % _sensitivity


func _sync_fullscreen_control() -> void:
	_fullscreen_toggle.set_pressed_no_signal(_fullscreen)


## The body exists here, but `ChatUI` binds a late-spawned one through the same
## scene-tree metadata, so both routes get the new value.
func _apply_sensitivity() -> void:
	get_tree().root.set_meta(SENSITIVITY_META, _sensitivity)
	var player := Game.get_local_player()
	if player != null and _has_property(player, &"mouse_sensitivity"):
		player.set(&"mouse_sensitivity", _sensitivity)


func _apply_fullscreen() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var mode := (
		DisplayServer.WINDOW_MODE_FULLSCREEN if _fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	)
	DisplayServer.window_set_mode(mode)


func _has_property(node: Object, property: StringName) -> bool:
	for entry: Dictionary in node.get_property_list():
		if StringName(entry.get("name", "")) == property:
			return true
	return false


# --- presentation ----------------------------------------------------------


func _style() -> void:
	_dim.color = UITheme.DIM_OVERLAY
	_card.add_theme_stylebox_override(
		"panel", UITheme.panel_style(UITheme.PANEL, UITheme.BORDER, 16, 2, 18)
	)
	UITheme.style_heading(_title, 26, UITheme.ACCENT)
	UITheme.style_label(_subtitle, 12, UITheme.DIM, 0)
	UITheme.style_label(_local_hint, 11, UITheme.AMBER, 0)
	UITheme.style_label(_footer, 11, UITheme.FAINT, 0)
	UITheme.style_label(_idle_hint, 12, UITheme.FAINT, 0)
	UITheme.style_button(_resume_button, true)
	for button: Button in [
		_settings_button,
		_controls_button,
		_players_button,
		_quit_to_menu_button,
		_quit_game_button,
	]:
		UITheme.style_button(button, false)
	UITheme.style_heading(_settings_title, 15, UITheme.ACCENT_SOFT)
	UITheme.style_heading(_controls_title, 15, UITheme.ACCENT_SOFT)
	UITheme.style_heading(_players_title, 15, UITheme.ACCENT_SOFT)
	for label: Label in [
		$Root/Center/Card/Margin/Content/Sections/SettingsSection/MusicHeader/MusicLabel,
		$Root/Center/Card/Margin/Content/Sections/SettingsSection/SfxHeader/SfxLabel,
		$Root/Center/Card/Margin/Content/Sections/SettingsSection/SensitivityHeader/SensitivityLabel,
	]:
		UITheme.style_label(label, 12, UITheme.TEXT, 0)
	for value_label: Label in [_music_value, _sfx_value, _sensitivity_value]:
		UITheme.style_label(value_label, 12, UITheme.ACCENT, 0)
	_fullscreen_toggle.add_theme_font_override("font", UITheme.regular_font())
	_fullscreen_toggle.add_theme_font_size_override("font_size", 12)
	_fullscreen_toggle.add_theme_color_override("font_color", UITheme.TEXT)
