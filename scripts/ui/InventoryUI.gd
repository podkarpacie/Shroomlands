extends CanvasLayer
## Toggleable 6x8 satchel with icons, a live 3D item preview, tooltips, sorting,
## drag-and-drop and right-click dropping.
##
## The panel is a pure view: every mutation goes through `InventorySystem`, and
## the grid refreshes only when `EventBus.inventory_changed` fires. While open it
## shows the cursor and asks the player controller to ignore mouse look/attack so
## dragging items cannot spin the camera.

const COLUMNS := Game.INVENTORY_COLS
const ROWS := Game.INVENTORY_ROWS
const SLOT_SIZE := 56

## One grid cell. It only knows its index and forwards drag/drop intent to the
## panel, which owns the `InventorySystem` calls.
class Slot:
	extends PanelContainer

	var ui: Node = null
	var index := 0
	var icon: TextureRect
	var name_label: Label
	var count_label: Label
	var rarity: ColorRect
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
		if not button.pressed or ui == null:
			return
		if button.button_index == MOUSE_BUTTON_RIGHT:
			ui.call(&"_drop_from_slot", index)
			accept_event()
		elif button.button_index == MOUSE_BUTTON_LEFT:
			ui.call(&"_select_slot", index)


@onready var _dim: ColorRect = $Root/Dim
@onready var _panel: PanelContainer = $Root/Center/Panel
@onready var _title: Label = $Root/Center/Panel/Margin/Content/Header/Title
@onready var _capacity: Label = $Root/Center/Panel/Margin/Content/Header/Capacity
@onready var _sort_button: Button = $Root/Center/Panel/Margin/Content/Header/SortButton
@onready var _close_button: Button = $Root/Center/Panel/Margin/Content/Header/CloseButton
@onready var _hint: Label = $Root/Center/Panel/Margin/Content/Hint
@onready var _grid: GridContainer = $Root/Center/Panel/Margin/Content/Body/Grid
@onready var _detail_panel: PanelContainer = $Root/Center/Panel/Margin/Content/Body/Detail
@onready var _detail_name: Label = (
	$Root/Center/Panel/Margin/Content/Body/Detail/Margin/DetailContent/DetailName
)
@onready var _detail_kind: Label = (
	$Root/Center/Panel/Margin/Content/Body/Detail/Margin/DetailContent/DetailKind
)
@onready var _detail_desc: Label = (
	$Root/Center/Panel/Margin/Content/Body/Detail/Margin/DetailContent/DetailDesc
)
@onready var _detail_uses: Label = (
	$Root/Center/Panel/Margin/Content/Body/Detail/Margin/DetailContent/DetailUses
)
@onready var _detail_toxicity: Label = (
	$Root/Center/Panel/Margin/Content/Body/Detail/Margin/DetailContent/DetailToxicity
)
@onready var _detail_count: Label = (
	$Root/Center/Panel/Margin/Content/Body/Detail/Margin/DetailContent/DetailCount
)
@onready var _rarity_bar: ColorRect = (
	$Root/Center/Panel/Margin/Content/Body/Detail/Margin/DetailContent/RarityBar
)
@onready var _preview: Control = (
	$Root/Center/Panel/Margin/Content/Body/Detail/Margin/DetailContent/Preview
)
@onready var _footer_hint: Label = $Root/Center/Panel/Margin/Content/Footer/FooterHint
@onready var _gold_label: Label = $Root/Center/Panel/Margin/Content/Footer/GoldLabel

var _player: Node = null
var _inventory: Node = null
var _slots: Array[Slot] = []
var _subscriptions: Array[Dictionary] = []
var _selected := -1
var _hovered := -1


func _ready() -> void:
	UITheme.install(get_tree().root)
	visible = false
	_style_panel()
	_build_grid()
	_track(EventBus.inventory_changed, _refresh)
	_track(EventBus.hotbar_changed, _refresh)
	_track(EventBus.gold_changed, _on_gold_changed)
	_sort_button.pressed.connect(_sort_inventory)
	_close_button.pressed.connect(func() -> void: set_open(false))
	_dim.gui_input.connect(_on_dim_input)
	_gold_label.text = "Gold %d" % Game.gold
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
	# Escape closes an open satchel first, so the pause menu never opens on top
	# of it (see `PauseMenu.handle_escape` for the whole priority chain).
	if visible and event.is_action_pressed(&"ui_cancel"):
		set_open(false)
		get_viewport().set_input_as_handled()
		return
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
		_hovered = -1
		_set_player_blocking(false)
		if DisplayServer.has_feature(DisplayServer.FEATURE_MOUSE):
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func is_open() -> bool:
	return visible


func get_selected_index() -> int:
	return _selected


func _on_dim_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
		set_open(false)


func _style_panel() -> void:
	_panel.add_theme_stylebox_override(
		"panel", UITheme.panel_style(UITheme.PANEL, UITheme.BORDER, 16, 2, 20)
	)
	_detail_panel.add_theme_stylebox_override(
		"panel", UITheme.panel_style(UITheme.PANEL_DEEP, UITheme.BORDER_DIM, 12, 1, 10)
	)
	UITheme.style_heading(_title, 28, UITheme.ACCENT)
	UITheme.style_label(_hint, 12, UITheme.DIM, 0)
	UITheme.style_label(_capacity, 12, UITheme.DIM, 0)
	UITheme.style_label(_footer_hint, 11, UITheme.FAINT, 0)
	UITheme.style_heading(_gold_label, 15, UITheme.GOLD)
	UITheme.style_button(_sort_button, false)
	UITheme.style_button(_close_button, false)
	UITheme.style_heading(_detail_name, 22, UITheme.TEXT)
	UITheme.style_label(_detail_kind, 11, UITheme.ACCENT_SOFT, 0)
	UITheme.style_label(_detail_desc, 12, UITheme.DIM, 0)
	UITheme.style_label(_detail_uses, 11, UITheme.DIM, 0)
	UITheme.style_label(_detail_toxicity, 11, UITheme.DANGEROUS, 0)
	UITheme.style_label(_detail_count, 11, UITheme.FAINT, 0)


func _build_grid() -> void:
	for index in COLUMNS * ROWS:
		var slot := Slot.new()
		slot.ui = self
		slot.index = index
		slot.name = "Slot%d" % index
		slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		var style := UITheme.slot_style()
		slot.add_theme_stylebox_override("panel", style)
		slot.style = style

		# Same overlay rule as the hotbar: PanelContainer would stretch every
		# direct child, which once turned the rarity bar into a full-cell wash.
		var overlay := Control.new()
		overlay.name = "Overlay"
		overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(overlay)

		var icon := TextureRect.new()
		icon.name = "Icon"
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 7.0
		icon.offset_top = 5.0
		icon.offset_right = -7.0
		icon.offset_bottom = -12.0
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.add_child(icon)

		var name_label := Label.new()
		name_label.name = "NameLabel"
		name_label.visible = false
		name_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.add_child(name_label)

		var count_label := Label.new()
		count_label.name = "CountLabel"
		count_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		count_label.offset_left = 14.0
		count_label.offset_top = 32.0
		count_label.offset_right = -4.0
		count_label.offset_bottom = -3.0
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		count_label.add_theme_font_override("font", UITheme.bold_font())
		count_label.add_theme_font_size_override("font_size", 11)
		count_label.add_theme_color_override("font_color", UITheme.TEXT)
		count_label.add_theme_color_override("font_outline_color", UITheme.SHADOW)
		count_label.add_theme_constant_override("outline_size", 3)
		overlay.add_child(count_label)

		var rarity := ColorRect.new()
		rarity.name = "RarityBar"
		rarity.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		rarity.offset_left = 5.0
		rarity.offset_top = -3.0
		rarity.offset_right = -5.0
		rarity.offset_bottom = -1.0
		rarity.color = Color(0, 0, 0, 0)
		rarity.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.add_child(rarity)
		overlay.move_child(rarity, 0)

		slot.icon = icon
		slot.name_label = name_label
		slot.count_label = count_label
		slot.rarity = rarity
		slot.mouse_entered.connect(_on_slot_hover.bind(index, true))
		slot.mouse_exited.connect(_on_slot_hover.bind(index, false))
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
	_update_capacity()
	if _selected < 0 or _slot_item_id(_selected) == &"":
		_selected = _first_filled()
	for slot: Slot in _slots:
		_update_slot(slot)
	_show_detail(_hovered if _hovered >= 0 else _selected)


func _update_slot(slot: Slot) -> void:
	var data: Dictionary = {}
	if _inventory != null and _inventory.has_method(&"get_slot"):
		data = _inventory.call(&"get_slot", slot.index)
	var id := StringName(data.get("id", &""))
	var count := int(data.get("count", 0))
	var filled := id != &"" and count > 0
	var selected := slot.index == _selected
	var hovered := slot.index == _hovered
	var rarity := ItemVisuals.color(String(id)) if filled else UITheme.BORDER_DIM
	slot.icon.texture = ItemVisuals.icon(id) if filled else null
	slot.icon.visible = filled
	slot.name_label.text = ItemVisuals.display_name(String(id)) if filled else ""
	slot.count_label.text = str(count) if filled else ""
	slot.rarity.color = rarity if filled else Color(0, 0, 0, 0)
	slot.tooltip_text = (
		"%s\n%s" % [ItemVisuals.display_name(String(id)), ItemVisuals.kind(String(id))]
		if filled else ""
	)
	slot.style.bg_color = (
		Color(0.15, 0.20, 0.11, 0.98) if selected
		else (Color(0.10, 0.13, 0.08, 0.96) if hovered else Color(0.065, 0.085, 0.060, 0.94))
	)
	slot.style.border_color = UITheme.ACCENT if selected else (rarity if filled else UITheme.BORDER_DIM)
	slot.style.set_border_width_all(2 if selected else 1)
	slot.style.shadow_color = Color(UITheme.ACCENT, 0.30) if selected else Color(0, 0, 0, 0)
	slot.style.shadow_size = 8 if selected else 0


func _update_capacity() -> void:
	var occupied := 0
	var total := 0
	if _inventory != null:
		for index in COLUMNS * ROWS:
			var data: Dictionary = _inventory.call(&"get_slot", index)
			if int(data.get("count", 0)) > 0:
				occupied += 1
				total += int(data.get("count", 0))
	_capacity.text = "%d / %d slots  ·  %d items" % [occupied, COLUMNS * ROWS, total]


func _first_filled() -> int:
	if _inventory == null:
		return -1
	for index in COLUMNS * ROWS:
		if _slot_item_id(index) != &"":
			return index
	return -1


func _slot_item_id(index: int) -> StringName:
	if index < 0 or _inventory == null or not _inventory.has_method(&"get_slot"):
		return &""
	var data: Dictionary = _inventory.call(&"get_slot", index)
	return StringName(data.get("id", &"")) if int(data.get("count", 0)) > 0 else &""


func _select_slot(index: int) -> void:
	_selected = index
	_hovered = -1
	for slot: Slot in _slots:
		_update_slot(slot)
	_show_detail(index)


func _on_slot_hover(index: int, entered: bool) -> void:
	if entered:
		_hovered = index
		_show_detail(index)
	elif _hovered == index:
		_hovered = -1
		_show_detail(_selected)


func _show_detail(index: int) -> void:
	var id := _slot_item_id(index)
	if id == &"":
		_preview.call(&"show_item", "")
		_detail_name.text = "Nothing selected"
		_detail_name.add_theme_color_override("font_color", UITheme.DIM)
		_detail_kind.text = "Empty slot"
		_detail_desc.text = "Gather mushrooms in the Verdant Bloom or move a stack here."
		_detail_uses.text = ""
		_detail_toxicity.text = ""
		_detail_count.text = ""
		_rarity_bar.color = Color(0.0, 0.0, 0.0, 0.0)
		return
	var count := 0
	if _inventory != null:
		var data: Dictionary = _inventory.call(&"get_slot", index)
		count = int(data.get("count", 0))
	var display := ItemVisuals.display_name(String(id))
	var colour := ItemVisuals.color(String(id))
	_preview.call(&"show_item", String(id))
	_detail_name.text = display
	_detail_name.add_theme_color_override("font_color", colour)
	_detail_kind.text = ItemVisuals.kind(String(id))
	_detail_desc.text = ItemVisuals.description(String(id))
	var uses := ItemVisuals.uses_text(String(id))
	_detail_uses.text = ("Uses  ·  %s" % uses) if not uses.is_empty() else ""
	var toxicity := ItemVisuals.toxicity(String(id))
	_detail_toxicity.text = ("Toxicity  %d" % toxicity) if toxicity > 0 else ""
	_detail_toxicity.add_theme_color_override(
		"font_color", UITheme.DANGEROUS if toxicity > 0 else UITheme.DIM
	)
	_detail_count.text = "In satchel  ·  %d" % count
	_rarity_bar.color = colour


func _make_drag_data(index: int, source: Control) -> Variant:
	_bind_inventory()
	if _inventory == null:
		return null
	var data: Dictionary = _inventory.call(&"get_slot", index)
	if data.is_empty():
		return null
	var id := StringName(data.get("id", &""))
	var preview := PanelContainer.new()
	preview.add_theme_stylebox_override(
		"panel", UITheme.pill_style(UITheme.PANEL_DEEP, ItemVisuals.color(String(id)), 10)
	)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	preview.add_child(row)
	var icon := TextureRect.new()
	icon.texture = ItemVisuals.icon(id)
	icon.custom_minimum_size = Vector2(38.0, 38.0)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(icon)
	var label := Label.new()
	label.text = "%s  ×%d" % [
		ItemVisuals.display_name(String(id)), int(data.get("count", 0))
	]
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UITheme.style_label(label, 12, ItemVisuals.color(String(id)), 3)
	row.add_child(label)
	source.set_drag_preview(preview)
	return {"from_slot": index}


func _drop_between(from: int, to: int) -> void:
	if from == to or _inventory == null:
		return
	_inventory.call(&"swap_slots", from, to)
	_selected = to
	_refresh()


func _drop_from_slot(index: int) -> void:
	_bind_inventory()
	if _inventory == null:
		return
	_inventory.call(&"drop_slot", index)
	_refresh()


func _sort_inventory() -> void:
	_bind_inventory()
	if _inventory == null or not _inventory.has_method(&"sort_slots"):
		return
	_inventory.call(&"sort_slots")
	_selected = _first_filled()
	_refresh()


func _on_gold_changed(amount: int) -> void:
	_gold_label.text = "Gold %d" % amount


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
