extends CanvasLayer
## Toggleable 6x8 inventory panel with drag-and-drop between slots and
## right-click dropping.
##
## The panel is a pure view: every mutation goes through `InventorySystem`, and
## the grid refreshes only when `EventBus.inventory_changed` fires. While open it
## shows the cursor and asks the player controller to ignore mouse look/attack so
## dragging items cannot spin the camera.

const COLUMNS := Game.INVENTORY_COLS
const ROWS := Game.INVENTORY_ROWS
const SLOT_SIZE := 56
const NAME_CHARS := 8
## Inner margin for slot labels so text never touches the slot border.
const SLOT_LABEL_MARGIN := 3

const PALETTE := {
	"panel": Color(0.04, 0.05, 0.04, 0.94),
	"panel_border": Color(0.38, 0.52, 0.30, 0.80),
	"slot": Color(0.08, 0.09, 0.07, 0.92),
	"slot_border": Color(0.30, 0.36, 0.24, 0.90),
	"text": Color(0.92, 0.94, 0.88),
	"text_dim": Color(0.66, 0.71, 0.60),
	"shadow": Color(0.0, 0.0, 0.0, 0.75),
}

## One grid cell. It only knows its index and forwards drag/drop intent to the
## panel, which owns the `InventorySystem` calls.
class Slot:
	extends PanelContainer

	var ui: Node = null
	var index := 0
	var name_label: Label
	var count_label: Label
	var style: StyleBoxFlat

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if ui == null:
			return null
		return ui.call(&"_make_drag_data", index, self)

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		return data is Dictionary and (data as Dictionary).has("from_slot")

	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		if ui == null:
			return
		ui.call(&"_drop_between", int((data as Dictionary)["from_slot"]), index)

	func _gui_input(event: InputEvent) -> void:
		if not (event is InputEventMouseButton):
			return
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_RIGHT and ui != null:
			ui.call(&"_drop_from_slot", index)
			accept_event()


@onready var _panel: PanelContainer = $Root/Center/Panel
@onready var _title: Label = $Root/Center/Panel/Margin/Content/Title
@onready var _hint: Label = $Root/Center/Panel/Margin/Content/Hint
@onready var _grid: GridContainer = $Root/Center/Panel/Margin/Content/Grid

var _player: Node = null
var _inventory: Node = null
var _slots: Array[Slot] = []
var _subscriptions: Array[Dictionary] = []


func _ready() -> void:
	visible = false
	_style_panel()
	_build_grid()
	_track(EventBus.inventory_changed, _refresh)
	_refresh()


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
	if not event.is_action_pressed(&"toggle_inventory"):
		return
	toggle()
	get_viewport().set_input_as_handled()


## Opens or closes the panel; `toggle_inventory` (Tab) and tests use this.
func toggle() -> void:
	set_open(not visible)


func set_open(value: bool) -> void:
	if visible == value:
		return
	visible = value
	if value:
		_bind_inventory()
		_refresh()
		_set_player_blocking(true)
		if DisplayServer.has_feature(DisplayServer.FEATURE_MOUSE):
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		_set_player_blocking(false)
		if DisplayServer.has_feature(DisplayServer.FEATURE_MOUSE):
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func is_open() -> bool:
	return visible


func _style_panel() -> void:
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = PALETTE["panel"]
	panel_style.border_color = PALETTE["panel_border"]
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(10)
	panel_style.content_margin_left = 20.0
	panel_style.content_margin_right = 20.0
	panel_style.content_margin_top = 16.0
	panel_style.content_margin_bottom = 16.0
	_panel.add_theme_stylebox_override("panel", panel_style)
	_title.add_theme_color_override("font_color", PALETTE["text"])
	_title.add_theme_color_override("font_outline_color", PALETTE["shadow"])
	_title.add_theme_constant_override("outline_size", 4)
	_title.add_theme_font_size_override("font_size", 22)
	_hint.add_theme_color_override("font_color", PALETTE["text_dim"])
	_hint.add_theme_font_size_override("font_size", 12)


func _build_grid() -> void:
	for index in COLUMNS * ROWS:
		var slot := Slot.new()
		slot.ui = self
		slot.index = index
		slot.name = "Slot%d" % index
		slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		var style := StyleBoxFlat.new()
		style.bg_color = PALETTE["slot"]
		style.border_color = PALETTE["slot_border"]
		style.set_border_width_all(1)
		style.set_corner_radius_all(6)
		slot.add_theme_stylebox_override("panel", style)
		slot.style = style

		var overlay := Control.new()
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		slot.add_child(overlay)

		var name_margin := MarginContainer.new()
		name_margin.name = "NameMargin"
		name_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		name_margin.offset_bottom = -14.0
		name_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_margin.add_theme_constant_override("margin_left", SLOT_LABEL_MARGIN)
		name_margin.add_theme_constant_override("margin_right", SLOT_LABEL_MARGIN)
		name_margin.add_theme_constant_override("margin_top", 3)
		overlay.add_child(name_margin)

		# `clip_text` stays off: a centered name one pixel wider than its box
		# would otherwise lose part of its first glyph on the left (Venomveil
		# rendered as "/enomve…"). The margin keeps the text off the border.
		var name_label := Label.new()
		name_label.name = "NameLabel"
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.clip_text = false
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.add_theme_font_size_override("font_size", 10)
		name_label.add_theme_color_override("font_color", PALETTE["text"])
		name_margin.add_child(name_label)

		var count_label := Label.new()
		count_label.name = "CountLabel"
		count_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		count_label.offset_left = 12.0
		count_label.offset_top = 24.0
		count_label.offset_right = -4.0
		count_label.offset_bottom = -3.0
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		count_label.add_theme_font_size_override("font_size", 10)
		count_label.add_theme_color_override("font_color", PALETTE["text_dim"])
		overlay.add_child(count_label)

		slot.name_label = name_label
		slot.count_label = count_label
		_slots.append(slot)
		_grid.add_child(slot)


func _track(sig: Signal, handler: Callable) -> void:
	sig.connect(handler)
	_subscriptions.append({"signal": sig, "handler": handler})


func _bind_inventory() -> void:
	if _inventory != null and is_instance_valid(_inventory):
		return
	var player := Game.get_local_player()
	if player == null:
		return
	_player = player
	_inventory = player.get_node_or_null("InventorySystem")


func _refresh() -> void:
	_bind_inventory()
	for slot: Slot in _slots:
		_update_slot(slot)


func _update_slot(slot: Slot) -> void:
	var data: Dictionary = {}
	if _inventory != null and _inventory.has_method(&"get_slot"):
		data = _inventory.call(&"get_slot", slot.index)
	var id := StringName(data.get("id", &""))
	var count := int(data.get("count", 0))
	if id == &"" or count <= 0:
		slot.name_label.text = ""
		slot.count_label.text = ""
		slot.style.border_color = PALETTE["slot_border"]
		return
	slot.name_label.text = _short_name(id)
	slot.count_label.text = str(count)
	slot.name_label.add_theme_color_override("font_color", _item_color(id))
	slot.style.border_color = PALETTE["slot_border"]


func _make_drag_data(index: int, source: Control) -> Variant:
	_bind_inventory()
	if _inventory == null:
		return null
	var data: Dictionary = _inventory.call(&"get_slot", index)
	if data.is_empty():
		return null
	var id := StringName(data.get("id", &""))
	var preview := PanelContainer.new()
	var preview_style := StyleBoxFlat.new()
	preview_style.bg_color = PALETTE["panel"]
	preview_style.border_color = _item_color(id)
	preview_style.set_border_width_all(1)
	preview_style.set_corner_radius_all(6)
	preview.add_theme_stylebox_override("panel", preview_style)
	var label := Label.new()
	label.text = "%s x%d" % [Lore.item_display_name(String(id)), int(data.get("count", 0))]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", _item_color(id))
	preview.add_child(label)
	source.set_drag_preview(preview)
	return {"from_slot": index}


func _drop_between(from: int, to: int) -> void:
	if from == to or _inventory == null:
		return
	_inventory.call(&"swap_slots", from, to)


func _drop_from_slot(index: int) -> void:
	_bind_inventory()
	if _inventory == null:
		return
	_inventory.call(&"drop_slot", index)


func _set_player_blocking(value: bool) -> void:
	var player := _player
	if player == null or not is_instance_valid(player):
		player = Game.get_local_player()
	if player == null:
		return
	if player.has_method(&"set_ui_blocking"):
		player.call(&"set_ui_blocking", value)
	elif _has_property(player, &"ui_blocking"):
		player.set(&"ui_blocking", value)


func _has_property(node: Object, property: StringName) -> bool:
	for entry: Dictionary in node.get_property_list():
		if StringName(entry.get("name", "")) == property:
			return true
	return false


func _short_name(id: StringName) -> String:
	var display := Lore.item_display_name(String(id))
	if display.length() <= NAME_CHARS:
		return display
	return display.substr(0, NAME_CHARS - 1) + "…"


func _item_color(id: StringName) -> Color:
	var mushroom := Lore.get_mushroom(String(id))
	if mushroom.is_empty():
		return PALETTE["text"]
	return Lore.rarity_color(str(mushroom.get("rarity", "")))
