extends CanvasLayer
## Chat: a bottom-left log plus a one-line input opened with `toggle_chat`.
##
## Like the HUD this is a pure view. The transport lives on `Main` (the chat RPCs
## and the server relay) and every rendered line arrives through
## `EventBus.chat_message_received`, so the log can be driven by a signal in
## tests. Channels: `global` reaches every peer; a leading `/l ` sends to `local`,
## which the server only forwards to peers within `Main.CHAT_LOCAL_RANGE`.

const MAX_LINES := 100
const LOCAL_PREFIX := "/l "
const TOGGLE_ACTION := &"toggle_chat"
## Scene-tree metadata written by the lobby; applied here because the lobby is
## gone before `main.tscn` spawns its player.
const SENSITIVITY_META := &"mouse_sensitivity"

const PALETTE := {
	"sender": Color(0.55, 0.85, 1.00),
	"own": Color(0.98, 0.83, 0.32),
	"text": Color(0.94, 0.95, 0.90),
	"dim": Color(0.66, 0.71, 0.60),
	"panel": Color(0.03, 0.04, 0.03, 0.72),
}

@onready var _log_panel: PanelContainer = $Root/LogPanel
@onready var _log_scroll: ScrollContainer = $Root/LogPanel/Margin/LogScroll
@onready var _log: RichTextLabel = $Root/LogPanel/Margin/LogScroll/Log
@onready var _input_panel: PanelContainer = $Root/InputPanel
@onready var _input: LineEdit = $Root/InputPanel/Margin/Input

var _lines: Array[String] = []
var _open := false
var _sensitivity_applied := false
var _subscriptions: Array[Dictionary] = []


func _ready() -> void:
	UITheme.install(get_tree().root)
	_style()
	_log_panel.visible = false
	_input_panel.visible = false
	_input.text_submitted.connect(_on_text_submitted)
	_input.gui_input.connect(_on_input_gui_input)
	_track(EventBus.chat_message_received, _on_chat_message_received)
	# `Main` spawns its player after this node is ready, and a client receives
	# its body even later, so watch for the body instead of binding once.
	get_tree().node_added.connect(_on_node_added)
	_bind_player()


func _exit_tree() -> void:
	var tree := get_tree()
	if tree != null and tree.node_added.is_connected(_on_node_added):
		tree.node_added.disconnect(_on_node_added)
	if not is_instance_valid(EventBus):
		return
	for entry: Dictionary in _subscriptions:
		var sig: Signal = entry["signal"]
		var handler: Callable = entry["handler"]
		if sig.is_connected(handler):
			sig.disconnect(handler)
	_subscriptions.clear()


func _unhandled_input(event: InputEvent) -> void:
	if _open:
		# The focused LineEdit owns the keyboard while the field is open.
		return
	if event.is_action_pressed(TOGGLE_ACTION):
		set_open(true)
		get_viewport().set_input_as_handled()


## Opens or closes the chat field; `toggle_chat` (Enter) and tests use this.
func set_open(value: bool) -> void:
	if _open == value:
		return
	_open = value
	_input_panel.visible = value
	_input.text = ""
	if value:
		_input.grab_focus()
		_set_mouse_captured(false)
	else:
		_input.release_focus()
		if not _inventory_open():
			_set_mouse_captured(true)
	_set_player_blocking(value)


func is_open() -> bool:
	return _open


## Splits the local-channel prefix from a raw input line.
func parse_channel(text: String) -> Dictionary:
	var body := text.strip_edges()
	if body.begins_with(LOCAL_PREFIX):
		return {
			"channel": "local",
			"text": body.substr(LOCAL_PREFIX.length()).strip_edges(),
		}
	return {"channel": "global", "text": body}


## Parses, then routes the line through the relay. Nothing is rendered here: the
## line comes back through `EventBus`, exactly like a remote message.
func send_text(text: String) -> void:
	var parsed := parse_channel(text)
	var body := String(parsed["text"])
	if body.is_empty():
		return
	var channel := String(parsed["channel"])
	var relay := _relay()
	if relay != null and relay.has_method(&"send_chat"):
		relay.call(&"send_chat", body, channel)
		return
	# No Main in the tree (chat used standalone): echo locally, never crash.
	EventBus.chat_message_received.emit(_local_sender(), body, channel)


func log_line_count() -> int:
	return _lines.size()


func get_log_text() -> String:
	return _log.get_parsed_text()


func _on_text_submitted(text: String) -> void:
	send_text(text)
	set_open(false)


func _on_input_gui_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode != KEY_ESCAPE:
		return
	set_open(false)
	_input.accept_event()


func _on_chat_message_received(sender: String, text: String, channel: String) -> void:
	_lines.append(_format_line(sender, text, channel))
	while _lines.size() > MAX_LINES:
		_lines.remove_at(0)
	_refresh_log()


func _refresh_log() -> void:
	_log.text = "\n".join(_lines)
	_log_panel.visible = not _lines.is_empty()
	call_deferred(&"_scroll_to_bottom")


func _scroll_to_bottom() -> void:
	if not is_inside_tree():
		return
	_log_scroll.scroll_vertical = int(_log_scroll.get_v_scroll_bar().max_value)


func _format_line(sender: String, text: String, channel: String) -> String:
	var own := sender == _local_sender()
	var name_color: Color = PALETTE["own"] if own else PALETTE["sender"]
	var name := "you" if own else _escape_bbcode(sender)
	var prefix := ""
	if channel == "local":
		prefix = "[color=#%s](local)[/color] " % PALETTE["dim"].to_html(false)
	return "%s[color=#%s]%s[/color]: %s" % [
		prefix, name_color.to_html(false), name, _escape_bbcode(text)
	]


func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")


func _local_sender() -> String:
	return "Player %d" % multiplayer.get_unique_id()


func _relay() -> Node:
	return get_tree().get_first_node_in_group(&"main")


func _track(sig: Signal, handler: Callable) -> void:
	sig.connect(handler)
	_subscriptions.append({"signal": sig, "handler": handler})


func _bind_player() -> void:
	if _sensitivity_applied:
		return
	var player := Game.get_local_player()
	if player == null or not _has_property(player, &"mouse_sensitivity"):
		return
	_sensitivity_applied = true
	_apply_saved_sensitivity(player)


## Fires for every node entering the tree; only a player body matters here.
func _on_node_added(node: Node) -> void:
	if _sensitivity_applied or not node.is_in_group(&"player"):
		return
	_bind_player.call_deferred()


func _apply_saved_sensitivity(player: Node) -> void:
	var tree_root := get_tree().root
	if tree_root == null or not tree_root.has_meta(SENSITIVITY_META):
		return
	if not _has_property(player, &"mouse_sensitivity"):
		return
	player.set(&"mouse_sensitivity", float(tree_root.get_meta(SENSITIVITY_META)))


func _set_player_blocking(value: bool) -> void:
	var player := Game.get_local_player()
	if player == null:
		return
	if player.has_method(&"set_ui_blocking"):
		player.call(&"set_ui_blocking", value)
	elif _has_property(player, &"ui_blocking"):
		player.set(&"ui_blocking", value)


func _inventory_open() -> bool:
	var parent := get_parent()
	if parent == null:
		return false
	var panel := parent.get_node_or_null("InventoryUI")
	if panel == null or not panel.has_method(&"is_open"):
		return false
	return bool(panel.call(&"is_open"))


func _has_property(node: Object, property: StringName) -> bool:
	for entry: Dictionary in node.get_property_list():
		if StringName(entry.get("name", "")) == property:
			return true
	return false


func _set_mouse_captured(value: bool) -> void:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_MOUSE):
		return
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if value else Input.MOUSE_MODE_VISIBLE)


func _style() -> void:
	_log_panel.add_theme_stylebox_override(
		"panel", UITheme.panel_style(UITheme.PANEL_DEEP, UITheme.BORDER_DIM, 10, 1, 10)
	)
	_input_panel.add_theme_stylebox_override(
		"panel", UITheme.panel_style(UITheme.PANEL, UITheme.BORDER, 10, 1, 8)
	)
	_log.add_theme_font_override("normal_font", UITheme.regular_font())
	_log.add_theme_font_size_override("normal_font_size", 13)
	_log.add_theme_constant_override("line_separation", 3)
	_log.add_theme_color_override("default_color", UITheme.TEXT)
	_input.add_theme_font_override("font", UITheme.regular_font())
	_input.add_theme_font_size_override("font_size", 13)
	_input.add_theme_color_override("font_color", UITheme.TEXT)
	_input.add_theme_color_override("font_placeholder_color", UITheme.FAINT)
