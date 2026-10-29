extends "res://scripts/ui/StationPanelUI.gd"
## Fungal Market: a Buy tab with every `Lore.POTIONS` entry at `fee x 3`, and a
## Sell tab that pays `Lore.mushroom_value` for one mushroom per click.
##
## The panel is a view over `Game` and the player's `InventorySystem`; the two
## operations are public so the shop suite can exercise them without opening a
## window. Buying checks gold before touching anything, and a failed inventory
## add refunds the purchase.

const TAB_BUY := "buy"
const TAB_SELL := "sell"
## Potions whose effect needs a system this phase does not have: there is no
## armour to repair and no darkness to see through. They stay in the catalogue
## as data; the row is tagged and the button refuses, so gold never buys nothing.
## Keep in sync with `AlchemyUI.GATED_POTIONS`.
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

var _tab := TAB_BUY
var _buy_tab: Button = null
var _sell_tab: Button = null


func panel_title() -> String:
	return "Fungal Market"


func panel_hint() -> String:
	return "Potions are brewed by the alchemists; the shop sells them at a markup. Mushrooms sell for their rarity value."


func _setup() -> void:
	_buy_tab = add_tool_button("Buy")
	_sell_tab = add_tool_button("Sell")
	_buy_tab.pressed.connect(_set_tab.bind(TAB_BUY))
	_sell_tab.pressed.connect(_set_tab.bind(TAB_SELL))


func _refresh_content() -> void:
	clear_body()
	_mark_tabs()
	if _tab == TAB_BUY:
		_build_buy()
	else:
		_build_sell()


# --- operations (public for tests) ------------------------------------------


## Buys one potion for `Lore.potion_price`. Returns false and changes nothing
## when the id is unknown, the gold is short, or the satchel cannot hold it.
func buy_potion(potion_id: String) -> bool:
	if not Lore.is_potion(potion_id):
		_set_status("The shop does not stock that.", UITheme.DANGEROUS)
		return false
	var gate := _gate(potion_id)
	if not gate.is_empty():
		# The row is visible as data; the sale is refused rather than take gold
		# for an effect nothing applies yet.
		_set_status(
			"Not usable yet — %s" % str(gate.get("reason", "")), UITheme.DANGEROUS
		)
		return false
	var inventory := _inventory()
	if inventory == null:
		_set_status("No satchel to put it in.", UITheme.DANGEROUS)
		return false
	var price := Lore.potion_price(potion_id)
	if not Game.spend_gold(price):
		_play_click()
		_set_status(
			"Not enough gold — %s costs %d g." % [Lore.item_display_name(potion_id), price],
			UITheme.DANGEROUS
		)
		_refresh_gold()
		return false
	var leftover := int(inventory.call(&"add_item", StringName(potion_id), 1))
	if leftover > 0:
		# Nothing may be lost when the satchel is full.
		Game.add_gold(price)
		_set_status("Your satchel is full.", UITheme.DANGEROUS)
		_queue_refresh()
		return false
	_play_click()
	_set_status(
		"Bought %s for %d g." % [Lore.item_display_name(potion_id), price]
	)
	_queue_refresh()
	return true


## Sells exactly one `mushroom_id` for its rarity value. Returns false when the
## player owns none or the id is not a mushroom.
func sell_mushroom(mushroom_id: String) -> bool:
	if not Lore.is_mushroom(mushroom_id):
		_set_status("The shop does not buy that.", UITheme.DANGEROUS)
		return false
	var inventory := _inventory()
	if inventory == null:
		_set_status("No satchel to sell from.", UITheme.DANGEROUS)
		return false
	var id := StringName(mushroom_id)
	if int(inventory.call(&"count_item", id)) <= 0:
		_set_status("You have no %s to sell." % Lore.item_display_name(mushroom_id), UITheme.DANGEROUS)
		return false
	if int(inventory.call(&"remove_item", id, 1)) != 1:
		_set_status("Could not take the mushroom.", UITheme.DANGEROUS)
		return false
	var value := Lore.mushroom_value(Lore.item_rarity(mushroom_id))
	Game.add_gold(value)
	_play_click()
	_set_status("Sold one %s for %d g." % [Lore.item_display_name(mushroom_id), value])
	_queue_refresh()
	return true


func set_tab(tab: String) -> void:
	_set_tab(tab)


func current_tab() -> String:
	return _tab


# --- rows --------------------------------------------------------------------


func _set_tab(tab: String) -> void:
	if tab != TAB_BUY and tab != TAB_SELL:
		return
	_tab = tab
	_refresh_content()


func _mark_tabs() -> void:
	if _buy_tab == null or _sell_tab == null:
		return
	_buy_tab.add_theme_color_override(
		"font_color", UITheme.ACCENT if _tab == TAB_BUY else UITheme.TEXT
	)
	_sell_tab.add_theme_color_override(
		"font_color", UITheme.ACCENT if _tab == TAB_SELL else UITheme.TEXT
	)


func _build_buy() -> void:
	for potion_id: String in Lore.POTIONS:
		var potion: Dictionary = Lore.POTIONS[potion_id]
		var rarity := Lore.item_rarity(potion_id)
		var gate := _gate(potion_id)
		var row := add_row()
		add_label(row, Lore.item_display_name(potion_id), 14, Lore.rarity_color(rarity))
		var effect := add_label(
			row, effect_summary(potion.get("effect", {})), 11, UITheme.DIM
		)
		effect.custom_minimum_size = Vector2(250.0, 0.0)
		effect.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		if not gate.is_empty():
			add_label(row, str(gate.get("tag", "")), 11, UITheme.AMBER, false)
		var price := Lore.potion_price(potion_id)
		var affordable := Game.gold >= price
		var price_label := add_label(
			row,
			"%d g" % price,
			13,
			UITheme.GOLD if affordable else UITheme.DANGEROUS,
			false
		)
		price_label.custom_minimum_size = Vector2(64.0, 0.0)
		price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		if not gate.is_empty():
			var blocked := add_button(row, "Unavailable", false)
			blocked.disabled = true
			blocked.tooltip_text = "Not usable yet — %s" % str(gate.get("reason", ""))
			continue
		var buy := add_button(row, "Buy" if affordable else "Need %d g" % (price - Game.gold))
		buy.disabled = not affordable
		buy.pressed.connect(buy_potion.bind(potion_id))
	if Lore.POTIONS.is_empty():
		add_label(add_row(), "The shelves are empty.", 13, UITheme.DIM)


## Gate entry for `potion_id` (`{tag, reason}`), or `{}` when it works today.
func _gate(potion_id: String) -> Dictionary:
	var gate: Variant = GATED_POTIONS.get(potion_id, null)
	return gate if gate is Dictionary else {}


func _build_sell() -> void:
	var inventory := _inventory()
	var shown := 0
	if inventory != null:
		for mushroom_id: String in Lore.MUSHROOMS:
			var count := int(inventory.call(&"count_item", StringName(mushroom_id)))
			if count <= 0:
				continue
			shown += 1
			var rarity := Lore.item_rarity(mushroom_id)
			var value := Lore.mushroom_value(rarity)
			var row := add_row()
			add_label(row, Lore.item_display_name(mushroom_id), 14, Lore.rarity_color(rarity))
			var count_label := add_label(row, "x%d" % count, 12, UITheme.DIM, false)
			count_label.custom_minimum_size = Vector2(48.0, 0.0)
			count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			var value_label := add_label(row, "%d g" % value, 13, UITheme.GOLD, false)
			value_label.custom_minimum_size = Vector2(64.0, 0.0)
			value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			var sell := add_button(row, "Sell one")
			sell.pressed.connect(sell_mushroom.bind(mushroom_id))
	if shown == 0:
		add_label(
			add_row(), "No mushrooms to sell — forage outside the gate.", 13, UITheme.DIM
		)
