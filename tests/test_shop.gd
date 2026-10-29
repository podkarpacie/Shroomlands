extends SceneTree
## Headless shop test on the real `main.tscn`: buying a potion costs `fee x 3`
## and adds it, an unaffordable buy changes nothing, selling removes exactly one
## mushroom and pays its rarity value, and selling an item you do not have fails.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0


func _initialize() -> void:
	TestEnv.isolate("test_shop")
	TestEnv.stash("user://plots.json")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	var packed := load(MAIN_SCENE_PATH) as PackedScene
	_check("main.tscn loads", packed != null)
	if packed == null:
		_finish()
		return
	var main := packed.instantiate()
	root.add_child(main)
	await _wait_physics(20)

	var game := root.get_node_or_null("Game")
	_check("Game autoload is available", game != null)
	var player := get_first_node_in_group(&"player")
	_check("a player was spawned", player != null)
	if game == null or player == null:
		_finish()
		return
	var inventory := player.get_node_or_null("InventorySystem")
	_check("the player has an InventorySystem", inventory != null)
	var shop := main.get_node_or_null("ShopUI")
	_check("Main has a ShopUI panel", shop != null)
	if inventory == null or shop == null:
		_finish()
		return

	# --- helpers and prices -------------------------------------------------
	var lore: Variant = root.get_node_or_null("Lore")
	_check("Lore autoload is available", lore != null)
	if lore != null:
		_check(
			"mushroom_value is common 5 / rare 20 / epic 60 / legendary 150",
			int(lore.call(&"mushroom_value", "common")) == 5
			and int(lore.call(&"mushroom_value", "rare")) == 20
			and int(lore.call(&"mushroom_value", "epic")) == 60
			and int(lore.call(&"mushroom_value", "legendary")) == 150
		)
		_check(
			"potion_price marks a potion up to fee x 3 (%d)" % int(lore.call(&"potion_price", "konop_draught")),
			int(lore.call(&"potion_price", "konop_draught")) == 15
		)
		_check("potion_price rejects non-potions", int(lore.call(&"potion_price", "konop")) == 0)

	# --- buy ----------------------------------------------------------------
	game.set("gold", 100)
	var price := 15
	_check("the player starts without the potion", int(inventory.call(&"count_item", &"konop_draught")) == 0)
	var bought := bool(shop.call(&"buy_potion", "konop_draught"))
	_check("buy_potion() succeeds with enough gold", bought)
	_check("buying deducts fee x 3 (gold %d)" % int(game.get("gold")), int(game.get("gold")) == 100 - price)
	_check(
		"buying adds the potion to the inventory",
		int(inventory.call(&"count_item", &"konop_draught")) == 1
	)

	# --- not enough gold ----------------------------------------------------
	game.set("gold", 10)
	var before_gold := int(game.get("gold"))
	var before_potions := int(inventory.call(&"count_item", &"konop_draught"))
	var poor := bool(shop.call(&"buy_potion", "fury_draught"))
	_check("buying without gold fails", not poor)
	_check("a failed buy leaves gold untouched", int(game.get("gold")) == before_gold)
	_check(
		"a failed buy leaves the inventory untouched",
		int(inventory.call(&"count_item", &"fury_draught")) == 0
		and int(inventory.call(&"count_item", &"konop_draught")) == before_potions
	)

	# --- sell ---------------------------------------------------------------
	game.set("gold", 0)
	var added := int(inventory.call(&"add_item", &"kazar", 2))
	_check("two kazar fit the inventory", added == 0)
	var sold := bool(shop.call(&"sell_mushroom", "kazar"))
	_check("sell_mushroom() succeeds when the mushroom is owned", sold)
	_check("selling one rare mushroom pays 20 g (gold %d)" % int(game.get("gold")), int(game.get("gold")) == 20)
	_check(
		"selling removes exactly one mushroom (%d left)" % int(inventory.call(&"count_item", &"kazar")),
		int(inventory.call(&"count_item", &"kazar")) == 1
	)

	var gold_before_missing := int(game.get("gold"))
	var missing := bool(shop.call(&"sell_mushroom", "fury"))
	_check("selling an item you do not have fails", not missing)
	_check("a failed sell changes no gold", int(game.get("gold")) == gold_before_missing)
	_check("a failed sell removes nothing", int(inventory.call(&"count_item", &"fury")) == 0)

	var unknown := bool(shop.call(&"buy_potion", "not_a_potion"))
	_check("buying an unknown potion fails", not unknown)
	_check("an unknown buy changes no gold", int(game.get("gold")) == gold_before_missing)

	# --- potions with no system behind them yet -----------------------------
	# Armour Patch and Nighteye Draught stay in `Lore.POTIONS`, but nothing
	# repairs armour or darkens the world yet. The shop tags the rows and refuses
	# the sale instead of taking gold for an effect nothing applies.
	game.set("gold", 200)
	var gated_before := int(game.get("gold"))
	shop.call(&"set_open", true)
	await _wait_physics(2)
	var armour_row := _row(shop, "Armour Patch")
	var nighteye_row := _row(shop, "Nighteye Draught")
	_check(
		"the shop tags both gated potions and disables their buttons (%s / %s)" % [
			str(armour_row.get("text", "")), str(nighteye_row.get("text", ""))
		],
		"(needs equipment)" in str(armour_row.get("text", ""))
		and "(needs darkness)" in str(nighteye_row.get("text", ""))
		and _button(armour_row) != null and _button(armour_row).disabled
		and _button(nighteye_row) != null and _button(nighteye_row).disabled
	)
	var armour_bought := bool(shop.call(&"buy_potion", "armour_patch"))
	var nighteye_bought := bool(shop.call(&"buy_potion", "nighteye_draught"))
	_check("buying a gated potion is refused", not armour_bought and not nighteye_bought)
	_check("a refused buy spends no gold", int(game.get("gold")) == gated_before)
	_check(
		"a refused buy adds nothing to the satchel",
		int(inventory.call(&"count_item", &"armour_patch")) == 0
		and int(inventory.call(&"count_item", &"nighteye_draught")) == 0
	)
	shop.call(&"set_open", false)

	_finish()


func _wait_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame


## One live panel row by its item label, as `{text, button}`. The first label is
## the item name in both the shop and the alchemy table.
func _row(panel: CanvasLayer, item_label: String) -> Dictionary:
	var body := panel.get_node_or_null(
		"Station/Center/Card/Margin/Content/BodyScroll/BodyMargin/Body"
	)
	if body == null:
		return {}
	for panel_row: Node in body.get_children():
		var labels := panel_row.find_children("*", "Label", true, false)
		if labels.is_empty() or str((labels[0] as Label).text) != item_label:
			continue
		var texts: Array[String] = []
		for node: Node in labels:
			texts.append(str((node as Label).text))
		var buttons := panel_row.find_children("*", "Button", true, false)
		return {
			"text": " ".join(texts),
			"button": buttons[0] if not buttons.is_empty() else null,
		}
	return {}


func _button(row: Dictionary) -> Button:
	return row.get("button") as Button


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all shop assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
