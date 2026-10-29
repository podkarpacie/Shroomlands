class_name CraftingUI
extends MenuPanel
## Crafting panel (C): recipes on the left, the selected recipe on the right with
## live "have / need" ingredient counts, the brew time and a Craft button.
##
## A pure view over `CraftingSystem`: it asks `status()` why a recipe is blocked
## and calls `begin()` to brew, so the rules stay in one place.

var _crafting: Node = null
var _selected := ""
var _list: VBoxContainer = null
var _out_icon: TextureRect = null
var _out_name: Label = null
var _out_desc: Label = null
var _ingredients: VBoxContainer = null
var _info: Label = null
var _message: Label = null
var _craft_button: Button = null
var _progress: ProgressBar = null


func _init() -> void:
	toggle_action = &"craft_menu"
	panel_title = "Crafting"
	panel_size = Vector2(840, 500)


func _build_content(root: VBoxContainer) -> void:
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(300, 0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)

	var detail := PanelContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_theme_stylebox_override("panel", UITheme.line_style())
	body.add_child(detail)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	detail.add_child(column)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	column.add_child(head)
	_out_icon = TextureRect.new()
	_out_icon.custom_minimum_size = Vector2(64, 64)
	_out_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_out_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(_out_icon)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(titles)
	_out_name = _label("", 20, UITheme.TEXT)
	UITheme.style_heading(_out_name, 20, UITheme.TEXT)
	titles.add_child(_out_name)
	_out_desc = _label("", 13, UITheme.DIM)
	_out_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	titles.add_child(_out_desc)

	column.add_child(_label("Ingredients", 14, UITheme.ACCENT_SOFT))
	_ingredients = VBoxContainer.new()
	_ingredients.add_theme_constant_override("separation", 4)
	column.add_child(_ingredients)

	_info = _label("", 13, UITheme.DIM)
	column.add_child(_info)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer)

	_message = _label("", 13, UITheme.AMBER)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_message)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(0, 14)
	_progress.max_value = 1.0
	UITheme.style_bar(_progress, UITheme.AMBER)
	column.add_child(_progress)
	_craft_button = Button.new()
	_craft_button.text = "Craft"
	_craft_button.custom_minimum_size = Vector2(0, 40)
	UITheme.style_button(_craft_button, true)
	_craft_button.pressed.connect(_on_craft_pressed)
	column.add_child(_craft_button)

	_track(EventBus.inventory_changed, _refresh)
	_track(EventBus.skills_changed, _refresh)
	_track(EventBus.level_changed, func(_level: int) -> void: _refresh())
	_track(EventBus.craft_started, func(_id: String, _seconds: float) -> void: _refresh())
	_track(EventBus.craft_cancelled, func(_id: String) -> void: _refresh())
	_track(EventBus.item_crafted, func(_r: String, _i: String, _c: int) -> void: _refresh())
	_track(EventBus.craft_progress_changed, _on_progress)


func _on_opened() -> void:
	_crafting = _find_system()
	var ids := Lore.recipe_ids()
	if _selected.is_empty() or not Lore.RECIPES.has(_selected):
		_selected = ids[0] if not ids.is_empty() else ""
	_refresh()


## The recipe currently shown, for tests.
func selected_recipe() -> String:
	return _selected


func select_recipe(id: String) -> void:
	if Lore.RECIPES.has(id):
		_selected = id
		_refresh()


func _find_system() -> Node:
	var player := Game.get_local_player()
	return player.get_node_or_null("CraftingSystem") if player != null else null


func _refresh() -> void:
	if not visible or _list == null:
		return
	if _crafting == null or not is_instance_valid(_crafting):
		_crafting = _find_system()
	_rebuild_list()
	_show_selected()


func _rebuild_list() -> void:
	for child in _list.get_children():
		child.queue_free()
	for id in Lore.recipe_ids():
		var recipe := Lore.get_recipe(id)
		var output_id := str(recipe["output"]["id"])
		var verdict := _status(id)
		var craftable := bool(verdict.get("ok", false))
		var button := Button.new()
		button.text = "  %s" % Lore.item_display_name(output_id)
		button.icon = ItemVisuals.icon(StringName(output_id))
		button.expand_icon = true
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size = Vector2(0, 46)
		button.add_theme_constant_override("icon_max_width", 32)
		UITheme.style_button(button, id == _selected)
		if not craftable:
			button.add_theme_color_override("font_color", UITheme.DIM)
		button.tooltip_text = str(verdict.get("message", ""))
		button.pressed.connect(select_recipe.bind(id))
		_list.add_child(button)


func _show_selected() -> void:
	if _selected.is_empty():
		return
	var recipe := Lore.get_recipe(_selected)
	var output: Dictionary = recipe["output"]
	var output_id := str(output["id"])
	_out_icon.texture = ItemVisuals.icon(StringName(output_id))
	_out_name.text = "%s  x%d" % [Lore.item_display_name(output_id), int(output["count"])]
	_out_desc.text = ItemVisuals.description(output_id)

	var verdict := _status(_selected)
	for child in _ingredients.get_children():
		child.queue_free()
	for entry: Dictionary in verdict.get("inputs", []):
		var enough := int(entry["have"]) >= int(entry["need"])
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var icon := TextureRect.new()
		icon.texture = ItemVisuals.icon(StringName(str(entry["id"])))
		icon.custom_minimum_size = Vector2(26, 26)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(icon)
		var name_label := _label(Lore.item_display_name(str(entry["id"])), 14, UITheme.TEXT)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		row.add_child(
			_label(
				"%d / %d" % [int(entry["have"]), int(entry["need"])],
				14,
				UITheme.ACCENT if enough else UITheme.HP_BRIGHT
			)
		)
		_ingredients.add_child(row)

	var seconds := _brew_seconds(_selected)
	_info.text = (
		"Brew time %.1f s   ·   +%d XP   ·   Level %d"
		% [seconds, int(recipe.get("xp", 0)), int(recipe.get("level", 1))]
	)
	var busy := _crafting != null and bool(_crafting.call(&"is_crafting"))
	_message.text = "" if bool(verdict.get("ok", false)) or busy else str(verdict.get("message", ""))
	if bool(recipe.get("placeholder", false)):
		_message.text = (_message.text + "  (placeholder recipe)").strip_edges()
	_craft_button.disabled = not bool(verdict.get("ok", false))
	_craft_button.text = "Brewing..." if busy else "Craft"
	if not busy:
		_progress.value = 0.0


func _on_progress(current: float, total: float) -> void:
	if not visible:
		return
	_progress.max_value = maxf(total, 0.01)
	_progress.value = current


func _on_craft_pressed() -> void:
	if _crafting != null and not _selected.is_empty():
		_crafting.call(&"begin", _selected)


func _status(id: String) -> Dictionary:
	if _crafting == null or not is_instance_valid(_crafting):
		return {"ok": false, "message": "", "inputs": []}
	return _crafting.call(&"status", id)


func _brew_seconds(id: String) -> float:
	if _crafting != null and is_instance_valid(_crafting):
		return float(_crafting.call(&"brew_seconds", id))
	return float(Lore.get_recipe(id).get("seconds", 1.0))
