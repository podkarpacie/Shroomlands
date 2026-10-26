extends CanvasLayer
## Modal vocation picker: one card per `Lore.VOCATIONS` entry, with the Polish
## lore text the rest of the game already uses.
##
## It opens by itself the first time the local player reaches
## `Game.VOCATION_UNLOCK_LEVEL` without a vocation, and afterwards from the HUD
## hint or the `vocation_menu` (V) action. Only Confirm and Later dismiss it, so
## while it is up the body is UI-blocked: mouse look, attacks, movement and
## sprint stop until a choice is made or postponed.
##
## The modal owns no state of its own beyond the highlighted card; the vocation
## itself lives in `Game`, and the stat bonus in `PlayerStats`.

## Vocation accents: steel-blue knight, green healer, amber harvester, violet
## ranger. The card border and text follow the accent.
const VOCATION_COLORS := {
	"knight": Color(0.42, 0.58, 0.82),
	"healer": Color(0.36, 0.74, 0.42),
	"harvester": Color(0.90, 0.68, 0.24),
	"ranger": Color(0.62, 0.45, 0.88),
}
## Card order is lore order. An explicit list keeps the layout stable even if
## `Lore.VOCATIONS` is reordered.
const VOCATION_ORDER: Array[String] = ["knight", "healer", "harvester", "ranger"]

const CARD_MIN_SIZE := Vector2(248.0, 320.0)
const CARD_BACKGROUND := Color(0.06, 0.08, 0.055, 0.98)
## A 3 px accent border is what "this card is armed" reads as at 150 % DPI.
const CARD_BORDER_IDLE := 1
const CARD_BORDER_SELECTED := 3
const CARD_PADDING := 14
## Keeps the three descriptions on a common baseline whatever their length.
const DESCRIPTION_MIN_HEIGHT := 118.0

const PALETTE := {
	"text": Color(0.92, 0.94, 0.88),
	"dim": Color(0.66, 0.71, 0.60),
	"error": Color(0.95, 0.45, 0.38),
	"panel": Color(0.05, 0.07, 0.045, 0.96),
	"border": Color(0.38, 0.52, 0.30, 0.85),
	"chip": Color(0.10, 0.14, 0.09, 0.95),
	"shadow": Color(0.0, 0.0, 0.0, 0.75),
}

@onready var _title: Label = $Root/Center/Panel/Margin/Content/Title
@onready var _hint: Label = $Root/Center/Panel/Margin/Content/Hint
@onready var _cards_row: HBoxContainer = $Root/Center/Panel/Margin/Content/Cards
@onready var _confirm_button: Button = $Root/Center/Panel/Margin/Content/Buttons/ConfirmButton
@onready var _later_button: Button = $Root/Center/Panel/Margin/Content/Buttons/LaterButton
@onready var _status: Label = $Root/Center/Panel/Margin/Content/Status

var _selected := ""
## Per-card styleboxes, so selection only repaints the border.
var _card_styles: Dictionary = {}
## Level the player already postponed at with "Later"; the next level-up
## brings the modal back, the same level does not.
var _dismissed_level := 0


func _ready() -> void:
	visible = false
	_build_cards()
	_style()
	_confirm_button.pressed.connect(confirm)
	_later_button.pressed.connect(dismiss)
	EventBus.level_changed.connect(_on_level_changed)
	# `Main` spawns the body after this UI is ready, so a save that already
	# sits at level 20 is only visible a frame later.
	_auto_open_if_eligible.call_deferred()


func _exit_tree() -> void:
	if not is_instance_valid(EventBus):
		return
	if EventBus.level_changed.is_connected(_on_level_changed):
		EventBus.level_changed.disconnect(_on_level_changed)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"vocation_menu"):
		return
	get_viewport().set_input_as_handled()
	# Only Confirm and Later dismiss the modal, so V while it is open is a no-op.
	if not visible:
		open()


# --- public API (tests and the HUD hint both go through it) -----------------


## Shows the modal when a choice is still possible; false when it is not.
func open() -> bool:
	if visible:
		return true
	if Game.chosen_vocation != &"" or _player_level() < Game.VOCATION_UNLOCK_LEVEL:
		return false
	visible = true
	_set_status("")
	_refresh_hint()
	_set_player_blocking(true)
	if DisplayServer.has_feature(DisplayServer.FEATURE_MOUSE):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	return true


func is_open() -> bool:
	return visible


## Highlights one card. The choice is only recorded by `confirm()`.
func select_vocation(id: String) -> void:
	if not Lore.VOCATIONS.has(id):
		return
	_selected = id
	_set_status("")
	for card_id: String in _card_styles:
		_style_card(card_id, card_id == id)


func get_selected_vocation() -> String:
	return _selected


## Commits the highlighted card and applies its stat bonus. The modal stays open
## with a note when nothing is selected or the gate refuses the choice.
func confirm() -> bool:
	if not visible:
		return false
	if _selected.is_empty():
		_set_status("Select a vocation first.")
		return false
	if not Game.set_vocation(_selected):
		_set_status("A vocation cannot be chosen right now.")
		return false
	var stats := _stats()
	if stats != null and stats.has_method(&"apply_vocation_bonus"):
		stats.call(&"apply_vocation_bonus", _selected)
	close()
	return true


## "Later": dismisses without choosing. The next level-up asks again.
func dismiss() -> void:
	if not visible:
		return
	_dismissed_level = _player_level()
	close()


func close() -> void:
	if not visible:
		return
	visible = false
	_set_player_blocking(false)
	if DisplayServer.has_feature(DisplayServer.FEATURE_MOUSE):
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# --- eligibility -----------------------------------------------------------


func _auto_open_if_eligible() -> void:
	if visible or Game.chosen_vocation != &"":
		return
	var level := _player_level()
	if level < Game.VOCATION_UNLOCK_LEVEL or level == _dismissed_level:
		return
	open()


func _on_level_changed(new_level: int) -> void:
	if new_level < Game.VOCATION_UNLOCK_LEVEL:
		return
	if Game.chosen_vocation != &"" or new_level == _dismissed_level:
		return
	open()


func _player_level() -> int:
	var player := Game.get_local_player()
	if player == null:
		return 1
	var stats := _stats()
	if stats != null and "level" in stats:
		return int(stats.get("level"))
	if "level" in player:
		return int(player.get("level"))
	return 1


func _stats() -> Node:
	var player := Game.get_local_player()
	if player == null:
		return null
	return player.get_node_or_null("Stats")


func _set_player_blocking(value: bool) -> void:
	var player := Game.get_local_player()
	if player == null:
		return
	if player.has_method(&"set_ui_blocking"):
		player.call(&"set_ui_blocking", value)
	elif "ui_blocking" in player:
		player.set("ui_blocking", value)


# --- layout ----------------------------------------------------------------


func _build_cards() -> void:
	for id: String in VOCATION_ORDER:
		var vocation := Lore.get_vocation(id)
		if vocation.is_empty():
			continue
		_cards_row.add_child(_build_card(id, vocation))


## A card is a Button (whole card clickable) with a mouse-transparent VBox on
## top, so the text never swallows the click that arms the card.
func _build_card(id: String, vocation: Dictionary) -> Button:
	var accent: Color = VOCATION_COLORS.get(id, PALETTE["text"])
	var card := Button.new()
	card.name = "Card_%s" % id
	card.custom_minimum_size = CARD_MIN_SIZE
	card.focus_mode = Control.FOCUS_NONE
	card.pressed.connect(select_vocation.bind(id))

	var base := StyleBoxFlat.new()
	base.bg_color = CARD_BACKGROUND
	base.border_color = accent.darkened(0.55)
	base.set_border_width_all(CARD_BORDER_IDLE)
	base.set_corner_radius_all(10)
	base.shadow_color = Color(0.0, 0.0, 0.0, 0.35)
	base.shadow_size = 6
	var hover := base.duplicate() as StyleBoxFlat
	hover.bg_color = CARD_BACKGROUND.lightened(0.08)
	card.add_theme_stylebox_override("normal", base)
	card.add_theme_stylebox_override("hover", hover)
	card.add_theme_stylebox_override("pressed", hover)
	card.add_theme_stylebox_override("focus", base)
	_card_styles[id] = {"base": base, "hover": hover}

	var body := VBoxContainer.new()
	body.name = "Body"
	body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	body.offset_left = CARD_PADDING
	body.offset_top = CARD_PADDING
	body.offset_right = -CARD_PADDING
	body.offset_bottom = -CARD_PADDING
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_theme_constant_override("separation", 6)
	card.add_child(body)

	body.add_child(_label(str(vocation.get("name", id)), accent, 19, "Name"))
	body.add_child(_label(str(vocation.get("polish", "")), PALETTE["dim"], 14, "Polish"))
	body.add_child(_label(str(vocation.get("role", "")), PALETTE["text"], 12, "Role"))
	var description := _label(
		str(vocation.get("description", "")), PALETTE["dim"], 12, "Description"
	)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.custom_minimum_size = Vector2(0.0, DESCRIPTION_MIN_HEIGHT)
	description.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(description)
	body.add_child(_trees_row(vocation, accent))
	body.add_child(
		_label(
			"Primary stat · %s" % str(vocation.get("primary_stat", "")),
			PALETTE["dim"],
			12,
			"PrimaryStat"
		)
	)
	return card


func _label(text: String, color: Color, size: int, node_name := "") -> Label:
	var label := Label.new()
	if not node_name.is_empty():
		label.name = node_name
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", PALETTE["shadow"])
	label.add_theme_constant_override("outline_size", 3)
	return label


## The three skill trees as chips; a flow container wraps them instead of
## squeezing long names like "Weapon Master".
func _trees_row(vocation: Dictionary, accent: Color) -> HFlowContainer:
	var row := HFlowContainer.new()
	row.name = "Trees"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("h_separation", 4)
	row.add_theme_constant_override("v_separation", 4)
	var trees: Array = vocation.get("trees", [])
	for index in trees.size():
		var chip := PanelContainer.new()
		chip.name = "Tree%d" % index
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxFlat.new()
		style.bg_color = PALETTE["chip"]
		style.border_color = Color(accent, 0.55)
		style.set_border_width_all(1)
		style.set_corner_radius_all(5)
		style.content_margin_left = 6
		style.content_margin_right = 6
		style.content_margin_top = 2
		style.content_margin_bottom = 3
		chip.add_theme_stylebox_override("panel", style)
		chip.add_child(_label(str(trees[index]), accent.lightened(0.25), 11))
		row.add_child(chip)
	return row


func _style_card(id: String, selected: bool) -> void:
	var styles: Dictionary = _card_styles.get(id, {})
	var accent: Color = VOCATION_COLORS.get(id, PALETTE["text"])
	for key: String in styles:
		var style := styles[key] as StyleBoxFlat
		style.border_color = accent if selected else accent.darkened(0.55)
		style.set_border_width_all(CARD_BORDER_SELECTED if selected else CARD_BORDER_IDLE)


func _style() -> void:
	var panel := $Root/Center/Panel as PanelContainer
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = PALETTE["panel"]
	panel_style.border_color = PALETTE["border"]
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(12)
	panel_style.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
	panel_style.shadow_size = 16
	panel.add_theme_stylebox_override("panel", panel_style)

	_title.text = "Choose your vocation"
	_title.add_theme_font_size_override("font_size", 26)
	_title.add_theme_color_override("font_color", PALETTE["text"])
	_title.add_theme_color_override("font_outline_color", PALETTE["shadow"])
	_title.add_theme_constant_override("outline_size", 5)
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", PALETTE["dim"])
	_status.add_theme_font_size_override("font_size", 12)
	_status.add_theme_color_override("font_color", PALETTE["dim"])
	_style_button(_confirm_button, true)
	_style_button(_later_button, false)


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
	button.add_theme_font_size_override("font_size", 15)


func _refresh_hint() -> void:
	_hint.text = "Lv %d · pick one vocation — the choice is permanent." % _player_level()


func _set_status(text: String) -> void:
	_status.text = text
	_status.add_theme_color_override(
		"font_color", PALETTE["error"] if not text.is_empty() else PALETTE["dim"]
	)
