class_name StationPanelUI
extends CanvasLayer
## Shared shell for the town's modal station panels (shop, alchemy, repair,
## plot board). The scene tree lives in `station_common.tscn`; this script owns
## the open/close contract, the blocking and mouse rules, the live gold label,
## and the row factories the subclasses fill.
##
## Every panel is a CanvasLayer named under `Main` and registered in the
## `station_panel` group, so `PauseMenu.handle_escape()` closes it before it
## opens the pause menu. While open it calls `PlayerController.set_ui_blocking`
## exactly like the satchel does.

const CLICK_VOLUME_DB := -8.0
const MAX_CONDITION := 100

@onready var _dim: ColorRect = $Station/Dim
@onready var _card: PanelContainer = $Station/Center/Card
@onready var _title: Label = $Station/Center/Card/Margin/Content/Header/Title
@onready var _gold_label: Label = $Station/Center/Card/Margin/Content/Header/GoldLabel
@onready var _close_button: Button = $Station/Center/Card/Margin/Content/Header/CloseButton
@onready var _hint: Label = $Station/Center/Card/Margin/Content/Hint
@onready var _tools: HBoxContainer = $Station/Center/Card/Margin/Content/Tools
@onready var _body: VBoxContainer = (
	$Station/Center/Card/Margin/Content/BodyScroll/BodyMargin/Body
)
@onready var _status: Label = $Station/Center/Card/Margin/Content/Footer/Status

var _open := false
var _refresh_queued := false
var _subscriptions: Array[Dictionary] = []


func _ready() -> void:
	UITheme.install(get_tree().root)
	add_to_group(&"station_panel")
	visible = false
	_style()
	_title.text = panel_title()
	_hint.text = panel_hint()
	_close_button.pressed.connect(_on_close_pressed)
	_dim.gui_input.connect(_on_dim_input)
	_track(EventBus.gold_changed, _on_gold_changed)
	_track(EventBus.inventory_changed, _on_inventory_changed)
	_refresh_gold()
	_setup()
	_refresh_content()


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
	# Escape closes the panel first; the pause menu checks the same group, so the
	# key never falls through to it (see `PauseMenu.handle_escape`).
	if visible and event.is_action_pressed(&"ui_cancel"):
		set_open(false)
		get_viewport().set_input_as_handled()


# --- subclass hooks ----------------------------------------------------------


func panel_title() -> String:
	return "Station"


func panel_hint() -> String:
	return ""


## Called once after the shell is built, before the first refresh.
func _setup() -> void:
	pass


## Rebuilds the rows. Subclasses clear `_body` through `clear_body()`.
func _refresh_content() -> void:
	pass


# --- open / close ------------------------------------------------------------


func set_open(value: bool) -> void:
	if visible == value:
		return
	visible = value
	_open = value
	if value:
		_refresh_gold()
		_refresh_content()
		_set_player_blocking(true)
		_show_cursor()
	else:
		_set_status("")
		_set_player_blocking(false)
		_recapture_mouse()


func is_open() -> bool:
	return _open


func close() -> void:
	set_open(false)


func toggle() -> void:
	set_open(not _open)


func _on_close_pressed() -> void:
	_play_click()
	set_open(false)


func _on_dim_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
		set_open(false)


# --- row and widget factories ------------------------------------------------


## One dark rounded row. Returns the HBox its children belong in.
func add_row() -> HBoxContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override(
		"panel", UITheme.line_style(UITheme.PANEL_DEEP, UITheme.BORDER_DIM)
	)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)
	_body.add_child(panel)
	return row


func add_label(
	row: HBoxContainer,
	text: String,
	size := 13,
	color := UITheme.TEXT,
	expand := true
) -> Label:
	var label := Label.new()
	label.text = text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL if expand else Control.SIZE_SHRINK_END
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UITheme.style_label(label, size, color, 0)
	row.add_child(label)
	return label


func add_button(row: HBoxContainer, text: String, accent := false) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(118, 32)
	button.size_flags_horizontal = Control.SIZE_SHRINK_END
	UITheme.style_button(button, accent)
	row.add_child(button)
	return button


func add_tool_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(104, 32)
	UITheme.style_button(button, false)
	button.pressed.connect(_play_click)
	_tools.add_child(button)
	return button


func clear_body() -> void:
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()


func _set_status(text: String, color := UITheme.ACCENT_SOFT) -> void:
	_status.text = text
	UITheme.style_label(_status, 12, color, 0)


func _queue_refresh() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	call_deferred(&"_run_queued_refresh")


func _run_queued_refresh() -> void:
	_refresh_queued = false
	if _open:
		_refresh_gold()
		_refresh_content()


# --- shared helpers ----------------------------------------------------------


func _play_click() -> void:
	Audio.play_sfx(&"ui_click", 0.04, CLICK_VOLUME_DB)


func _inventory() -> Node:
	var player := Game.get_local_player()
	if player == null or not is_instance_valid(player):
		return null
	return player.get_node_or_null(^"InventorySystem")


func _local_player() -> Node:
	var player := Game.get_local_player()
	if player == null or not is_instance_valid(player):
		return null
	return player


func _refresh_gold() -> void:
	_gold_label.text = "Gold %d g" % Game.gold


func _on_gold_changed(_gold: int) -> void:
	_refresh_gold()
	_queue_refresh()


func _on_inventory_changed() -> void:
	if _open:
		_queue_refresh()


## Human-readable summary of a `Lore.POTIONS[*].effect` dictionary, for the shop
## rows. Unknown keys are ignored rather than dumped raw.
func effect_summary(effect: Dictionary) -> String:
	var parts: Array[String] = []
	if effect.has("heal"):
		parts.append("Heal %d HP" % roundi(float(effect["heal"])))
	if bool(effect.get("heal_full", false)):
		parts.append("Full heal")
	if effect.has("heal_over_time"):
		var over_time: Dictionary = effect["heal_over_time"]
		parts.append("Heal %d over %ds" % [
			roundi(float(over_time.get("amount", 0.0))),
			roundi(float(over_time.get("duration", 0.0))),
		])
	if effect.has("stamina"):
		parts.append("Stamina +%d" % roundi(float(effect["stamina"])))
	if bool(effect.get("cleanse", false)):
		parts.append("Cleanse")
	if effect.has("poison"):
		var poison: Dictionary = effect["poison"]
		parts.append("Poison %d/%ds" % [
			roundi(float(poison.get("damage", 0.0))),
			roundi(float(poison.get("duration", 0.0))),
		])
	if effect.has("buff"):
		parts.append(_buff_summary(effect["buff"] as Dictionary))
	if effect.has("throwable"):
		parts.append("Throwable")
	if effect.has("repair_armor"):
		parts.append("Repairs armour %d%%" % roundi(float(effect["repair_armor"]) * 100.0))
	return ", ".join(parts) if not parts.is_empty() else "—"


func _buff_summary(buff: Dictionary) -> String:
	var parts: Array[String] = []
	if buff.has("max_hp_flat"):
		parts.append("+%d max HP" % roundi(float(buff["max_hp_flat"])))
	if buff.has("max_stamina_flat"):
		parts.append("+%d max stamina" % roundi(float(buff["max_stamina_flat"])))
	if buff.has("damage_mult"):
		parts.append("damage x%.1f" % float(buff["damage_mult"]))
	if buff.has("armor_mult"):
		parts.append("incoming damage x%.1f" % float(buff["armor_mult"]))
	if buff.has("vision"):
		parts.append("vision %+.1f" % float(buff["vision"]))
	var duration := roundi(float(buff.get("duration", 0.0)))
	var body := ", ".join(parts) if not parts.is_empty() else "buff"
	return "%s for %ds" % [body, duration] if duration > 0 else body


# --- player, cursor and tracking --------------------------------------------


func _set_player_blocking(value: bool) -> void:
	var player := Game.get_local_player()
	if player == null or not is_instance_valid(player):
		return
	if player.has_method(&"set_ui_blocking"):
		player.call(&"set_ui_blocking", value)


func _show_cursor() -> void:
	if DisplayServer.has_feature(DisplayServer.FEATURE_MOUSE):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _recapture_mouse() -> void:
	var player := Game.get_local_player()
	if player != null and is_instance_valid(player) and player.has_method(&"_capture_mouse"):
		player.call(&"_capture_mouse")


func _track(sig: Signal, handler: Callable) -> void:
	sig.connect(handler)
	_subscriptions.append({"signal": sig, "handler": handler})


# --- presentation ------------------------------------------------------------


func _style() -> void:
	_dim.color = UITheme.DIM_OVERLAY
	_card.add_theme_stylebox_override(
		"panel", UITheme.panel_style(UITheme.PANEL, UITheme.BORDER, 16, 2, 20)
	)
	UITheme.style_heading(_title, 26, UITheme.ACCENT)
	UITheme.style_label(_hint, 12, UITheme.DIM, 0)
	UITheme.style_heading(_gold_label, 16, UITheme.GOLD)
	UITheme.style_label(_status, 12, UITheme.ACCENT_SOFT, 0)
	UITheme.style_button(_close_button, false)
