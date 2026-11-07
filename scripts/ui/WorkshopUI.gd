extends StationPanelUI
## Workshop: turns the six materials found in the forest structures into one item
## per gear slot. Recipes and effects live in `Lore.GEAR`; this panel only checks
## the cost, spends it and puts the item in the satchel.
##
## Crafting is deliberately one-per-slot: the row says "Equipped" or "Owned" and
## refuses instead of quietly stacking duplicates.

var _offered: Array[String] = []


func panel_title() -> String:
	return "Workshop"


func panel_hint() -> String:
	return "Craft gear from what the huts, castles and dungeons drop. One item per slot; double-click it in the satchel to wear it."


func _refresh_content() -> void:
	clear_body()
	_offered.clear()
	var inventory := _inventory()
	if inventory == null:
		add_label(add_row(), "No satchel to craft with.", 13, UITheme.DIM)
		return
	for id: String in Lore.GEAR:
		_offered.append(id)
		_build_row(id, Lore.GEAR[id], inventory)


## Every gear id the panel lists (it always shows the full catalogue).
func get_offered_ids() -> Array[String]:
	return _offered.duplicate() if not _offered.is_empty() else _all_ids()


func _all_ids() -> Array[String]:
	var ids: Array[String] = []
	for id: String in Lore.GEAR:
		ids.append(id)
	return ids


func _build_row(id: String, gear: Dictionary, inventory: Node) -> void:
	var row := add_row()
	var name_label := add_label(row, str(gear.get("name", id)), 14, UITheme.ACCENT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_label(row, str(gear.get("slot", "")).capitalize(), 12, UITheme.DIM, false)
	var recipe: Dictionary = gear.get("recipe", {})
	var cost := _cost_text(recipe)
	var affordable := _can_afford(recipe, inventory)
	var cost_label := add_label(
		row, cost, 12, UITheme.GOLD if affordable else UITheme.DANGEROUS, false
	)
	cost_label.custom_minimum_size = Vector2(150.0, 0.0)
	cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	var owned := String(inventory.call(&"gear_in_slot", str(gear.get("slot", "")))) == id
	var carried := int(inventory.call(&"count_item", StringName(id))) > 0
	if owned or carried:
		var state := add_button(row, "Equipped" if owned else "Owned", false)
		state.disabled = true
		return
	var button := add_button(row, "Craft", true)
	button.disabled = not _can_afford(recipe, inventory)
	button.pressed.connect(craft.bind(id))


## Crafts one `id`. Returns false without changing anything when the recipe is
## unknown, the item is already owned, a material is missing, the fee is short,
## or the satchel cannot hold the result.
func craft(id: String) -> bool:
	var gear := Lore.get_gear(id)
	if gear.is_empty():
		return false
	var inventory := _inventory()
	if inventory == null:
		_set_status("No satchel to craft with.", UITheme.DANGEROUS)
		return false
	var slot := str(gear.get("slot", ""))
	if String(inventory.call(&"gear_in_slot", slot)) == id \
			or int(inventory.call(&"count_item", StringName(id))) > 0:
		_set_status("%s is already yours." % str(gear.get("name", id)), UITheme.DANGEROUS)
		return false
	var recipe: Dictionary = gear.get("recipe", {})
	var resources: Dictionary = recipe.get("resources", {})
	var fee := int(recipe.get("fee", 0))
	for resource_id: String in resources:
		var want := int(resources[resource_id])
		if int(inventory.call(&"count_item", StringName(resource_id))) < want:
			_set_status("Not enough %s." % Lore.item_display_name(resource_id), UITheme.DANGEROUS)
			return false
	if Game.gold < fee:
		_set_status("Not enough gold — crafting costs %d g." % fee, UITheme.DANGEROUS)
		_refresh_gold()
		return false
	if not Game.spend_gold(fee):
		_set_status("Not enough gold — crafting costs %d g." % fee, UITheme.DANGEROUS)
		return false
	var taken: Dictionary = {}
	for resource_id: String in resources:
		var got := int(inventory.call(&"remove_item", StringName(resource_id), int(resources[resource_id])))
		taken[resource_id] = got
	var leftover := int(inventory.call(&"add_item", StringName(id), 1))
	if leftover > 0:
		for resource_id: String in taken:
			inventory.call(&"add_item", StringName(resource_id), int(taken[resource_id]))
		Game.add_gold(fee)
		_set_status("Your satchel is full.", UITheme.DANGEROUS)
		_queue_refresh()
		return false
	_play_click()
	_set_status("Crafted %s for %d g." % [str(gear.get("name", id)), fee])
	_queue_refresh()
	return true


func _can_afford(recipe: Dictionary, inventory: Node) -> bool:
	var resources: Dictionary = recipe.get("resources", {})
	for resource_id: String in resources:
		if int(inventory.call(&"count_item", StringName(resource_id))) < int(resources[resource_id]):
			return false
	return Game.gold >= int(recipe.get("fee", 0))


func _cost_text(recipe: Dictionary) -> String:
	var parts: Array[String] = []
	var resources: Dictionary = recipe.get("resources", {})
	for resource_id: String in resources:
		parts.append("%s x%d" % [Lore.item_display_name(resource_id), int(resources[resource_id])])
	parts.append("%d g" % int(recipe.get("fee", 0)))
	return " · ".join(parts)
