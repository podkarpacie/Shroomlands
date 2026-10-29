class_name MenuPanel
extends CanvasLayer
## Shared shell for the crafting and skill panels: a dimmed full-screen layer with
## one centred, themed panel, opened by a key and closed by the same key or the X.
##
## While open it shows the cursor and tells the player controller to ignore look
## and attack, exactly like the inventory. It will not open over another modal.

## The input action that toggles this panel.
@export var toggle_action: StringName = &""
@export var panel_title := ""
@export var panel_size := Vector2(780, 500)

var _content: VBoxContainer = null
var _subscriptions: Array[Dictionary] = []
var _title_label: Label = null


func _ready() -> void:
	layer = 20
	visible = false
	_build_shell()
	_build_content(_content)


func _exit_tree() -> void:
	if not is_instance_valid(EventBus):
		return
	for entry: Dictionary in _subscriptions:
		var sig: Signal = entry["signal"]
		var handler: Callable = entry["handler"]
		if sig.is_connected(handler):
			sig.disconnect(handler)
	_subscriptions.clear()


func _unhandled_input(event: InputEvent) -> void:
	if toggle_action == &"" or not event.is_action_pressed(toggle_action):
		return
	toggle()
	get_viewport().set_input_as_handled()


func toggle() -> void:
	set_open(not visible)


func is_open() -> bool:
	return visible


func set_open(value: bool) -> void:
	if visible == value:
		return
	if value and _another_modal_is_open():
		return
	visible = value
	_set_player_blocking(value)
	if DisplayServer.has_feature(DisplayServer.FEATURE_MOUSE):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if value else Input.MOUSE_MODE_CAPTURED)
	if value:
		_on_opened()


## Subclasses fill the panel here.
func _build_content(_root: VBoxContainer) -> void:
	pass


## Subclasses refresh here whenever the panel opens.
func _on_opened() -> void:
	pass


func _track(sig: Signal, handler: Callable) -> void:
	sig.connect(handler)
	_subscriptions.append({"signal": sig, "handler": handler})


func _build_shell() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.01, 0.018, 0.012, 0.58)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = panel_size
	panel.add_theme_stylebox_override("panel", UITheme.panel_style(UITheme.PANEL, UITheme.BORDER, 14, 1, 14))
	center.add_child(panel)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 10)
	panel.add_child(_content)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	_content.add_child(header)
	_title_label = Label.new()
	_title_label.text = panel_title
	UITheme.style_heading(_title_label, 24, UITheme.ACCENT)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title_label)
	_add_header_extras(header)
	var close := Button.new()
	close.text = "X"
	close.custom_minimum_size = Vector2(36, 32)
	UITheme.style_button(close)
	close.pressed.connect(func() -> void: set_open(false))
	header.add_child(close)


## Subclasses put extra widgets in the header, left of the close button.
func _add_header_extras(_header: HBoxContainer) -> void:
	pass


func _another_modal_is_open() -> bool:
	var player := Game.get_local_player()
	return player != null and "ui_blocking" in player and bool(player.get("ui_blocking"))


func _set_player_blocking(value: bool) -> void:
	var player := Game.get_local_player()
	if player == null:
		return
	if player.has_method(&"set_ui_blocking"):
		player.call(&"set_ui_blocking", value)
	elif "ui_blocking" in player:
		player.set(&"ui_blocking", value)


func _label(text: String, size := 14, color := UITheme.TEXT) -> Label:
	var label := Label.new()
	label.text = text
	UITheme.style_label(label, size, color, 0)
	return label
