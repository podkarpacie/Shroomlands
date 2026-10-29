extends "res://scripts/ui/StationPanelUI.gd"
## Alchemy Table: for every mushroom the player owns that has a `Lore` brew
## recipe, one row with the output potion, the fee and a Brew button. Brewing
## consumes exactly one mushroom and the fee, then grants one potion.
##
## Rows are rebuilt from the live inventory, so brewing the last mushroom removes
## the row. An unaffordable fee disables the button and prints the shortfall.

## Potions whose effect needs a system this phase does not have: there is no
## armour to repair and no darkness to see through. The recipe stays, the row is
## tagged and Brew refuses, so a fee never buys nothing. Keep in sync with
## `ShopUI.GATED_POTIONS` (both panels are views over the same `Lore` data).
const GATED_POTIONS := {
	"armour_patch": {
		"tag": "(needs equipment)",
		"reason": "There is no armour system to repair yet.",
	},
	"nighteye_draught": {
		"tag": "(needs darkness)",
		"reason": "There is no darkness to see through yet.",
	},
}

var _offered: Array[String] = []


func panel_title() -> String:
	return "Alchemy Table"


func panel_hint() -> String:
	return "Bring mushrooms with a recipe. Brewing consumes one mushroom and the gold fee; the Alchemy Table keeps the rest."


func _refresh_content() -> void:
	clear_body()
	_offered.clear()
	var inventory := _inventory()
	if inventory != null:
		for mushroom_id: String in Lore.MUSHROOMS:
			var mushroom: Dictionary = Lore.MUSHROOMS[mushroom_id]
			if (mushroom.get("brew", {}) as Dictionary).is_empty():
				continue
			var count := int(inventory.call(&"count_item", StringName(mushroom_id)))
			if count <= 0:
				continue
			_offered.append(mushroom_id)
			_build_row(mushroom_id, mushroom, count)
	if _offered.is_empty():
		add_label(
			add_row(),
			"No recipes available — forage a mushroom outside the gate.",
			13,
			UITheme.DIM
		)


## Mushroom ids currently offered (owned and with a brew recipe). Recomputed from
## the live inventory, so it is correct even while the panel has not been opened.
func get_offered_ids() -> Array[String]:
	var ids: Array[String] = []
	var inventory := _inventory()
	if inventory == null:
		return ids
	for mushroom_id: String in Lore.MUSHROOMS:
		var mushroom: Dictionary = Lore.MUSHROOMS[mushroom_id]
		if (mushroom.get("brew", {}) as Dictionary).is_empty():
			continue
		if int(inventory.call(&"count_item", StringName(mushroom_id))) <= 0:
			continue
		ids.append(mushroom_id)
	return ids


## Brews one `mushroom_id`. Returns false without changing anything when the
## recipe is unknown, the mushroom is missing, gold is short, or the satchel
## cannot hold the potion.
func brew(mushroom_id: String) -> bool:
	var mushroom := Lore.get_mushroom(mushroom_id)
	var brew_recipe: Dictionary = mushroom.get("brew", {})
	if brew_recipe.is_empty():
		_set_status("%s has no recipe." % Lore.item_display_name(mushroom_id), UITheme.DANGEROUS)
		return false
	var potion_id := str(brew_recipe.get("potion", ""))
	var fee := int(brew_recipe.get("fee", 0))
	if potion_id.is_empty() or not Lore.is_potion(potion_id):
		_set_status("That recipe is incomplete.", UITheme.DANGEROUS)
		return false
	var gate := _gate(potion_id)
	if not gate.is_empty():
		# Nothing consumes the effect yet, so no fee and no mushroom is spent.
		_set_status(
			"Not usable yet — %s" % str(gate.get("reason", "")), UITheme.DANGEROUS
		)
		return false
	var inventory := _inventory()
	if inventory == null:
		_set_status("No satchel to brew with.", UITheme.DANGEROUS)
		return false
	var id := StringName(mushroom_id)
	if int(inventory.call(&"count_item", id)) <= 0:
		_set_status("You have no %s." % Lore.item_display_name(mushroom_id), UITheme.DANGEROUS)
		return false
	if not Game.spend_gold(fee):
		_play_click()
		_set_status(
			"Not enough gold — brewing costs %d g." % fee,
			UITheme.DANGEROUS
		)
		_refresh_gold()
		_queue_refresh()
		return false
	if int(inventory.call(&"remove_item", id, 1)) != 1:
		Game.add_gold(fee)
		_set_status("Could not take the mushroom.", UITheme.DANGEROUS)
		return false
	var leftover := int(inventory.call(&"add_item", StringName(potion_id), 1))
	if leftover > 0:
		# Put the ingredients back rather than lose them to a full satchel.
		inventory.call(&"add_item", id, 1)
		Game.add_gold(fee)
		_set_status("Your satchel is full.", UITheme.DANGEROUS)
		_queue_refresh()
		return false
	_play_click()
	_set_status(
		"Brewed %s for %d g." % [Lore.item_display_name(potion_id), fee]
	)
	_queue_refresh()
	return true


func _build_row(mushroom_id: String, mushroom: Dictionary, count: int) -> void:
	var rarity := Lore.item_rarity(mushroom_id)
	var potion_id := str((mushroom.get("brew", {}) as Dictionary).get("potion", ""))
	var fee := int((mushroom.get("brew", {}) as Dictionary).get("fee", 0))
	var gate := _gate(potion_id)
	var row := add_row()
	add_label(row, Lore.item_display_name(mushroom_id), 14, Lore.rarity_color(rarity))
	var count_label := add_label(row, "x%d" % count, 12, UITheme.DIM, false)
	count_label.custom_minimum_size = Vector2(44.0, 0.0)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_label(
		row, "→ %s" % Lore.item_display_name(potion_id), 13,
		Lore.rarity_color(Lore.item_rarity(potion_id))
	)
	if not gate.is_empty():
		add_label(row, str(gate.get("tag", "")), 11, UITheme.AMBER, false)
	var affordable := Game.gold >= fee
	var fee_label := add_label(
		row, "%d g" % fee, 13, UITheme.GOLD if affordable else UITheme.DANGEROUS, false
	)
	fee_label.custom_minimum_size = Vector2(64.0, 0.0)
	fee_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if not gate.is_empty():
		var blocked := add_button(row, "Unavailable", false)
		blocked.disabled = true
		blocked.tooltip_text = "Not usable yet — %s" % str(gate.get("reason", ""))
		return
	var button_text := "Brew" if affordable else "Need %d g" % (fee - Game.gold)
	var brew_button := add_button(row, button_text, affordable)
	brew_button.disabled = not affordable
	brew_button.pressed.connect(brew.bind(mushroom_id))


## Gate entry for the recipe's output potion (`{tag, reason}`), or `{}` when the
## potion's effect works today.
func _gate(potion_id: String) -> Dictionary:
	var gate: Variant = GATED_POTIONS.get(potion_id, null)
	return gate if gate is Dictionary else {}
