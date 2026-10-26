extends Control
## Main menu / lobby: the project's entry scene.
##
## Hosting and joining are delegated to `Network`; this scene only reacts to its
## signals and then hands over to `main.tscn`. It owns the persisted player
## options and never instantiates a player or the world itself — a menu that
## spawned either would run a second session behind the buttons.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "settings"
const SETTINGS_VERSION := 1

const MIN_SENSITIVITY := 0.0005
const MAX_SENSITIVITY := 0.01
const DEFAULT_SENSITIVITY := 0.0025
## Ports below 1024 are privileged and 65535 is the last valid TCP/UDP port.
const MIN_PORT := 1024
const MAX_PORT := 65535
const PORT_ERROR := "Enter a port between 1024 and 65535"
## One-line transport summary under the Join row.
const TRANSPORT_HINT := "Desktop: ENet/UDP · Browser: WebSocket/TCP"
const WEB_TRANSPORT_NOTE := "Server must run in websocket mode"
## The subtitle is one line, so the long lore blurb is cut on a word boundary.
const SUBTITLE_CHARS := 84
const RELEASE := "v0.1.0"
## Scene-tree metadata the gameplay scene reads to bind the saved sensitivity.
const SENSITIVITY_META := &"mouse_sensitivity"

const PALETTE := {
	"title": Color(0.86, 0.93, 0.72),
	"text": Color(0.92, 0.94, 0.88),
	"dim": Color(0.66, 0.71, 0.60),
	"error": Color(0.95, 0.45, 0.38),
	"panel": Color(0.05, 0.07, 0.045, 0.94),
	"panel_border": Color(0.38, 0.52, 0.30, 0.80),
}

@onready var _title: Label = $Center/Panel/Margin/Content/Title
@onready var _subtitle: Label = $Center/Panel/Margin/Content/Subtitle
@onready var _continue_button: Button = $Center/Panel/Margin/Content/ContinueButton
@onready var _new_game_button: Button = $Center/Panel/Margin/Content/NewGameButton
@onready var _host_button: Button = $Center/Panel/Margin/Content/HostButton
@onready var _ip_field: LineEdit = $Center/Panel/Margin/Content/JoinRow/IPField
@onready var _port_field: LineEdit = $Center/Panel/Margin/Content/JoinRow/PortField
@onready var _join_button: Button = $Center/Panel/Margin/Content/JoinRow/JoinButton
@onready var _transport_hint: Label = $Center/Panel/Margin/Content/TransportHint
@onready var _settings_button: Button = $Center/Panel/Margin/Content/SettingsButton
@onready var _quit_button: Button = $Center/Panel/Margin/Content/QuitButton
@onready var _status_label: Label = $Center/Panel/Margin/Content/StatusLabel
@onready var _version_label: Label = $Center/Panel/Margin/Content/VersionLabel
@onready var _settings_layer: Control = $SettingsLayer
@onready var _sensitivity_slider: HSlider = (
	$SettingsLayer/Center/SettingsPanel/Margin/Content/SensitivitySlider
)
@onready var _sensitivity_value: Label = (
	$SettingsLayer/Center/SettingsPanel/Margin/Content/SensitivityHeader/SensitivityValue
)
@onready var _fullscreen_toggle: CheckButton = (
	$SettingsLayer/Center/SettingsPanel/Margin/Content/FullscreenToggle
)
@onready var _settings_close_button: Button = (
	$SettingsLayer/Center/SettingsPanel/Margin/Content/SettingsCloseButton
)

var _sensitivity := DEFAULT_SENSITIVITY
var _fullscreen := false
var _entered_world := false


func _ready() -> void:
	_drop_stray_players()
	_style()
	_load_settings()
	_sync_controls()
	_apply_settings()
	_refresh_save_controls()
	_connect_buttons()
	Network.hosted.connect(_on_hosted)
	Network.joined.connect(_on_joined)
	Network.connection_failed.connect(_on_connection_failed)
	_set_settings_open(false)
	_set_status("")
	# A failed join that already handed over to the world lands back here.
	if not Network.last_error.is_empty():
		_set_status("Connection failed: %s" % Network.last_error, true)
		Network.last_error = ""


func _exit_tree() -> void:
	if not is_instance_valid(Network):
		return
	if Network.hosted.is_connected(_on_hosted):
		Network.hosted.disconnect(_on_hosted)
	if Network.joined.is_connected(_on_joined):
		Network.joined.disconnect(_on_joined)
	if Network.connection_failed.is_connected(_on_connection_failed):
		Network.connection_failed.disconnect(_on_connection_failed)


# --- public API (tests and the buttons both go through it) ------------------


## Hosts on the port in the Port field, then enters the world when `hosted`
## fires. The transport follows the platform: ENet on desktop, WebSocket in a
## browser (where listening is impossible, so this reports a real error).
func host_game() -> void:
	var port := read_port()
	if port < 0:
		return
	if Network.is_web():
		_set_status("A browser cannot host: run a server in websocket mode and Join it", true)
		return
	_set_status("Opening a session on port %d …" % port)
	if Network.host(port) == OK:
		return
	# A socket failure already emitted `connection_failed` with the real reason,
	# so only the "already in a session" refusal needs a message of its own.
	if Network.mode != Network.OFFLINE:
		_set_status("Cannot host: already in a session", true)


func join_game(ip: String) -> void:
	var port := read_port()
	if port < 0:
		return
	var address := ip.strip_edges()
	_set_status("Connecting to %s:%d …" % [address, port])
	# `return_to_lobby` is true: the world loads before the handshake finishes,
	# so Network must bring the menu back if this attempt fails.
	var error := Network.join(address, port, Network.TRANSPORT_AUTO, true)
	if error != OK:
		_set_status("Cannot join %s: %s" % [address, error_string(error)], true)
		return
	# Hand over now, not on `joined`: the server spawns this peer as soon as the
	# handshake completes, and those spawn packets need `main.tscn` to exist or
	# they arrive at `/root` with no spawner and the client gets no body.
	_enter_world()


## Port from the Port field, or -1 after showing the inline error. Host and Join
## share this, because the field is the only place a port is entered.
func read_port() -> int:
	var port := parse_port(_port_field.text)
	if port < 0:
		_set_status(PORT_ERROR, true)
		_port_field.grab_focus()
	return port


## Pure port validation, so the bounds are testable without opening a socket.
func parse_port(text: String) -> int:
	var trimmed := text.strip_edges()
	if not trimmed.is_valid_int():
		return -1
	var port := int(trimmed)
	if port < MIN_PORT or port > MAX_PORT:
		return -1
	return port


## Offline continuation. The save is read here so a corrupt file reports itself
## instead of dropping the player into a fresh world; `Main` applies it to the
## body it spawns.
func continue_game() -> void:
	if not SaveSystem.has_save():
		_set_status("No save to continue", true)
		return
	if not SaveSystem.load_now():
		_set_status("Cannot read the save file", true)
		return
	_enter_world()


## Offline fresh start: drop the save, reset the session and enter the world.
func new_game() -> void:
	SaveSystem.delete_save()
	Game.reset_session()
	_enter_world()


## "Continue — Lv 12 · Harvester · 340 g"; the vocation is left out below 20.
func continue_label() -> String:
	return _continue_label_for(SaveSystem.save_summary())


func set_mouse_sensitivity(value: float) -> void:
	_sensitivity = clampf(value, MIN_SENSITIVITY, MAX_SENSITIVITY)
	_sync_sensitivity_controls()
	_apply_sensitivity()
	save_settings()


func get_mouse_sensitivity() -> float:
	return _sensitivity


func set_fullscreen(value: bool) -> void:
	_fullscreen = value
	_sync_fullscreen_control()
	_apply_fullscreen()
	save_settings()


func is_fullscreen() -> bool:
	return _fullscreen


func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value(SETTINGS_SECTION, "version", SETTINGS_VERSION)
	config.set_value(SETTINGS_SECTION, "mouse_sensitivity", _sensitivity)
	config.set_value(SETTINGS_SECTION, "fullscreen", _fullscreen)
	var error := config.save(SETTINGS_PATH)
	if error != OK:
		_set_status("Cannot save settings: %s" % error_string(error), true)


# --- wiring ----------------------------------------------------------------


func _connect_buttons() -> void:
	_continue_button.pressed.connect(continue_game)
	_new_game_button.pressed.connect(new_game)
	_host_button.pressed.connect(host_game)
	_join_button.pressed.connect(_on_join_pressed)
	_ip_field.text_submitted.connect(_on_ip_submitted)
	_port_field.text_submitted.connect(_on_port_submitted)
	_settings_button.pressed.connect(_set_settings_open.bind(true))
	_settings_close_button.pressed.connect(_set_settings_open.bind(false))
	_quit_button.pressed.connect(_on_quit_pressed)
	_sensitivity_slider.value_changed.connect(_on_sensitivity_slider_changed)
	_fullscreen_toggle.toggled.connect(set_fullscreen)


func _on_join_pressed() -> void:
	join_game(_ip_field.text)


func _on_ip_submitted(_text: String) -> void:
	_on_join_pressed()


## Enter in the Port field joins too, so the player never has to reach for the
## mouse after typing host:port.
func _on_port_submitted(_text: String) -> void:
	_on_join_pressed()


func _on_quit_pressed() -> void:
	get_tree().quit()


func _on_sensitivity_slider_changed(value: float) -> void:
	set_mouse_sensitivity(value)


func _set_settings_open(value: bool) -> void:
	_settings_layer.visible = value


func _set_status(message: String, is_error: bool = false) -> void:
	_status_label.text = message
	_status_label.add_theme_color_override(
		"font_color", PALETTE["error"] if is_error else PALETTE["dim"]
	)


## Continue only exists when there is a save to read; New Game is always the
## offline entry point.
func _refresh_save_controls() -> void:
	var summary := SaveSystem.save_summary()
	if summary.is_empty():
		_continue_button.visible = false
		_continue_button.tooltip_text = ""
		return
	_continue_button.visible = true
	_continue_button.text = _continue_label_for(summary)
	var saved_at := str(summary.get("saved_at", ""))
	_continue_button.tooltip_text = ("Saved %s" % saved_at) if not saved_at.is_empty() else ""


func _continue_label_for(summary: Dictionary) -> String:
	if summary.is_empty():
		return "Continue"
	var parts: Array[String] = ["Lv %d" % int(summary.get("level", 1))]
	var vocation := str(summary.get("vocation", ""))
	if not vocation.is_empty():
		parts.append(vocation)
	parts.append("%d g" % int(summary.get("gold", 0)))
	return "Continue — " + " · ".join(parts)


# --- network ---------------------------------------------------------------


func _on_hosted() -> void:
	_enter_world()


func _on_joined() -> void:
	_enter_world()


func _on_connection_failed(reason: String) -> void:
	_set_status("Connection failed: %s" % reason, true)


func _enter_world() -> void:
	if _entered_world:
		return
	_entered_world = true
	_set_status("")
	var error := get_tree().change_scene_to_file(MAIN_SCENE_PATH)
	if error != OK:
		_entered_world = false
		_set_status("Cannot load the world: %s" % error_string(error), true)


# --- settings --------------------------------------------------------------


func _load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		_sensitivity = DEFAULT_SENSITIVITY
		_fullscreen = false
		return
	_sensitivity = clampf(
		float(config.get_value(SETTINGS_SECTION, "mouse_sensitivity", DEFAULT_SENSITIVITY)),
		MIN_SENSITIVITY,
		MAX_SENSITIVITY
	)
	_fullscreen = bool(config.get_value(SETTINGS_SECTION, "fullscreen", false))


func _sync_controls() -> void:
	_sync_sensitivity_controls()
	_sync_fullscreen_control()
	_ip_field.text = "127.0.0.1" if _ip_field.text.is_empty() else _ip_field.text
	_port_field.text = str(Network.DEFAULT_PORT) if _port_field.text.is_empty() else _port_field.text
	_refresh_transport_hint()


## One line under the buttons: which transport each kind of client speaks. The
## browser also needs a server started in websocket mode.
func _refresh_transport_hint() -> void:
	var text := TRANSPORT_HINT
	if OS.has_feature("web"):
		text += " · " + WEB_TRANSPORT_NOTE
	_transport_hint.text = text


func _sync_sensitivity_controls() -> void:
	_sensitivity_slider.min_value = MIN_SENSITIVITY
	_sensitivity_slider.max_value = MAX_SENSITIVITY
	_sensitivity_slider.step = 0.0001
	_sensitivity_slider.set_value_no_signal(_sensitivity)
	_sensitivity_value.text = "%.4f" % _sensitivity


func _sync_fullscreen_control() -> void:
	_fullscreen_toggle.set_pressed_no_signal(_fullscreen)


func _apply_settings() -> void:
	_apply_sensitivity()
	_apply_fullscreen()


func _apply_sensitivity() -> void:
	# The player only exists in `main.tscn`, so the value also goes on the scene
	# tree root, where the gameplay UI binds it to the body it spawns.
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


## The lobby is a menu: anything in the player group here is a mistake, so it is
## removed instead of running a second session behind the buttons.
func _drop_stray_players() -> void:
	for node: Node in get_tree().get_nodes_in_group(&"player"):
		if node.is_queued_for_deletion():
			continue
		push_warning("LobbyUI: removing a stray player node from the menu.")
		node.queue_free()


# --- presentation ----------------------------------------------------------


func _style() -> void:
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = PALETTE["panel"]
	panel_style.border_color = PALETTE["panel_border"]
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(12)
	panel_style.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
	panel_style.shadow_size = 14
	var panel := $Center/Panel as PanelContainer
	panel.add_theme_stylebox_override("panel", panel_style)
	var settings_panel := $SettingsLayer/Center/SettingsPanel as PanelContainer
	settings_panel.add_theme_stylebox_override("panel", panel_style)

	_title.text = "SHROOMLANDS"
	_title.add_theme_color_override("font_color", PALETTE["title"])
	_title.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.75))
	_title.add_theme_constant_override("outline_size", 6)
	_title.add_theme_font_size_override("font_size", 52)
	_subtitle.text = _one_line(Lore.WORLD_DESCRIPTION, SUBTITLE_CHARS)
	_subtitle.add_theme_color_override("font_color", PALETTE["dim"])
	_subtitle.add_theme_font_size_override("font_size", 13)
	_version_label.text = "%s · Godot %s" % [RELEASE, Engine.get_version_info().get("string", "")]
	_version_label.add_theme_color_override("font_color", PALETTE["dim"])
	_version_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", PALETTE["dim"])
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.7))
	_status_label.add_theme_constant_override("outline_size", 3)
	_transport_hint.add_theme_color_override("font_color", PALETTE["dim"])
	_transport_hint.add_theme_font_size_override("font_size", 11)
	_sensitivity_value.add_theme_color_override("font_color", PALETTE["text"])
	var settings_title := $SettingsLayer/Center/SettingsPanel/Margin/Content/SettingsTitle as Label
	settings_title.add_theme_color_override("font_color", PALETTE["text"])
	settings_title.add_theme_font_size_override("font_size", 20)
	for button: Button in [
		_continue_button,
		_new_game_button,
		_host_button,
		_join_button,
		_settings_button,
		_quit_button,
		_settings_close_button,
	]:
		button.add_theme_font_size_override("font_size", 15)
	_style_button(_continue_button, true)
	_style_button(_host_button, true)
	_style_button(_join_button, true)
	for button: Button in [_new_game_button, _settings_button, _quit_button, _settings_close_button]:
		_style_button(button, false)
	_style_field()


func _style_button(button: Button, accent: bool) -> void:
	var base := Color(0.24, 0.42, 0.20, 0.95) if accent else Color(0.10, 0.15, 0.09, 0.95)
	var border := Color(0.55, 0.78, 0.42, 0.9) if accent else Color(0.32, 0.45, 0.26, 0.9)
	for state: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		var style := StyleBoxFlat.new()
		style.set_corner_radius_all(8)
		style.set_border_width_all(1)
		style.border_color = border
		style.bg_color = base
		if state == "hover":
			style.bg_color = base.lightened(0.12)
		elif state == "pressed":
			style.bg_color = base.darkened(0.2)
		elif state == "disabled":
			style.bg_color = base.darkened(0.4)
		button.add_theme_stylebox_override(state, style)
	button.add_theme_color_override("font_color", PALETTE["text"])
	button.add_theme_color_override("font_hover_color", Color.WHITE)


func _style_field() -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.06, 0.09, 0.055, 1.0)
	normal.border_color = Color(0.30, 0.42, 0.25, 0.9)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(6)
	normal.set_content_margin_all(8)
	var focus := normal.duplicate() as StyleBoxFlat
	focus.border_color = PALETTE["title"]
	for field: LineEdit in [_ip_field, _port_field]:
		field.add_theme_stylebox_override("normal", normal)
		field.add_theme_stylebox_override("focus", focus)
		field.add_theme_color_override("font_color", PALETTE["text"])
		field.add_theme_color_override("font_placeholder_color", PALETTE["dim"])


## One line, cut on a word boundary, so the label never wraps or overflows.
func _one_line(text: String, max_chars: int) -> String:
	var flat := text.replace("\n", " ").strip_edges()
	if flat.length() <= max_chars:
		return flat
	var cut := flat.substr(0, max_chars - 1)
	var last_space := cut.rfind(" ")
	if last_space > max_chars / 2:
		cut = cut.substr(0, last_space)
	return cut.strip_edges() + "…"


func _has_property(node: Object, property: StringName) -> bool:
	for entry: Dictionary in node.get_property_list():
		if StringName(entry.get("name", "")) == property:
			return true
	return false
