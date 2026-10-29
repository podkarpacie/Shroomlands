extends SceneTree
## Headless alchemy test on the real `main.tscn`: brewing consumes one mushroom
## and the gold fee and grants the potion; an unaffordable fee is refused; a
## mushroom with no brew recipe is not offered; and the last mushroom clears the
## row.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0


func _initialize() -> void:
	TestEnv.isolate("test_alchemy")
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
	var lore: Variant = root.get_node_or_null("Lore")
	var player := get_first_node_in_group(&"player")
	_check("Game autoload is available", game != null)
	_check("Lore autoload is available", lore != null)
	_check("a player was spawned", player != null)
	if game == null or lore == null or player == null:
		_finish()
		return
	var inventory := player.get_node_or_null("InventorySystem")
	_check("the player has an InventorySystem", inventory != null)
	var alchemy := main.get_node_or_null("AlchemyUI")
	_check("Main has an AlchemyUI panel", alchemy != null)
	if inventory == null or alchemy == null:
		_finish()
		return

	inventory.call(&"add_item", &"konop", 2)
	var can_offer := alchemy.call(&"get_offered_ids") as Array
	_check("alchemy offers an owned recipe mushroom", can_offer.has("konop"))
	_check("alchemy does not offer a mushroom that is not owned", not can_offer.has("shitake"))

	# --- brew ---------------------------------------------------------------
	game.set("gold", 50)
	var brewed := bool(alchemy.call(&"brew", "konop"))
	_check("brewing succeeds with mushroom and gold", brewed)
	_check("brewing deducts the fee (gold %d)" % int(game.get("gold")), int(game.get("gold")) == 45)
	_check(
		"brewing consumes exactly one mushroom (%d left)" % int(inventory.call(&"count_item", &"konop")),
		int(inventory.call(&"count_item", &"konop")) == 1
	)
	_check(
		"brewing grants the output potion",
		int(inventory.call(&"count_item", &"konop_draught")) == 1
	)

	# --- unaffordable -------------------------------------------------------
	game.set("gold", 0)
	var before_mushrooms := int(inventory.call(&"count_item", &"konop"))
	var before_potions := int(inventory.call(&"count_item", &"konop_draught"))
	var poor := bool(alchemy.call(&"brew", "konop"))
	_check("brewing without the fee is refused", not poor)
	_check("a refused brew spends no gold", int(game.get("gold")) == 0)
	_check("a refused brew keeps the mushroom", int(inventory.call(&"count_item", &"konop")) == before_mushrooms)
	_check(
		"a refused brew grants no potion",
		int(inventory.call(&"count_item", &"konop_draught")) == before_potions
	)

	# --- a recipe-less item is never offered --------------------------------
	# Every designed species carries a recipe, so the "no brew entry" branch is
	# exercised through a recipe-less resource instead.
	inventory.call(&"add_item", &"mycelium_fiber", 1)
	var offered := alchemy.call(&"get_offered_ids") as Array
	_check("a recipe-less item is not offered", not offered.has("mycelium_fiber"))
	_check("brewing a recipe-less item fails", not bool(alchemy.call(&"brew", "mycelium_fiber")))
	_check(
		"the recipe-less item stays in the inventory",
		int(inventory.call(&"count_item", &"mycelium_fiber")) == 1
	)

	# --- the last mushroom clears the row ----------------------------------
	game.set("gold", 100)
	inventory.call(&"add_item", &"motoko", 1)
	var before_last := alchemy.call(&"get_offered_ids") as Array
	_check("a second recipe mushroom is offered", before_last.has("motoko"))
	var last := bool(alchemy.call(&"brew", "motoko"))
	_check("brewing the last mushroom succeeds", last)
	_check("the last mushroom is consumed", int(inventory.call(&"count_item", &"motoko")) == 0)
	var after_last := alchemy.call(&"get_offered_ids") as Array
	_check("brewing the last mushroom clears its row", not after_last.has("motoko"))

	# --- a recipe whose effect has no system behind it yet ------------------
	# Kora brews Armour Patch, and the armour system does not exist: the row stays
	# visible as data with a tag, and neither the fee nor the mushroom is spent.
	inventory.call(&"add_item", &"kora", 1)
	game.set("gold", 100)
	var gated_before := int(game.get("gold"))
	alchemy.call(&"set_open", true)
	await _wait_physics(2)
	var kora_row := _row(alchemy, "Kora")
	_check(
		"the gated alchemy row is tagged and its Brew button disabled (%s)" % str(kora_row.get("text", "")),
		"(needs equipment)" in str(kora_row.get("text", ""))
		and _button(kora_row) != null and _button(kora_row).disabled
	)
	alchemy.call(&"set_open", false)
	var gated_brew := bool(alchemy.call(&"brew", "kora"))
	_check("brewing a gated potion is refused", not gated_brew)
	_check(
		"a refused gated brew spends no gold and keeps the mushroom",
		int(game.get("gold")) == gated_before
		and int(inventory.call(&"count_item", &"kora")) == 1
	)

	_finish()


func _wait_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame


## One live panel row by its item label, as `{text, button}`. The first label is
## the mushroom name in the alchemy table.
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
		print("PASSED  all alchemy assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
