extends SceneTree
## Headless HUD + inventory panel test on the real `main.tscn`.
##
## Covers the UI contract only: structure, signal-driven updates and the toggle
## path. `main.tscn` is loaded lazily because autoload identifiers are only
## resolvable after the `--script` main loop starts (same constraint as
## test_player.gd).

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0


func _initialize() -> void:
	# Structural/behaviour run only: a private save and a private plots file,
	# so neither this suite nor PlotSystem touches the developer's profile.
	TestEnv.isolate("test_ui")
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
	await _wait_physics(30)

	var hud := main.get_node_or_null("HUD") as CanvasLayer
	var inventory_ui := main.get_node_or_null("InventoryUI") as CanvasLayer
	_check("Main has a HUD CanvasLayer", hud != null)
	_check("Main has an InventoryUI CanvasLayer", inventory_ui != null)
	if hud == null or inventory_ui == null:
		_finish()
		return

	# --- HUD structure ------------------------------------------------------
	var hp_bar := hud.find_child("HPBar", true, false) as ProgressBar
	var stamina_bar := hud.find_child("StaminaBar", true, false) as ProgressBar
	var hp_label := hud.get_node_or_null("Root/Vitals/HPLabel") as Label
	var gold_label := hud.get_node_or_null("Root/Progression/GoldLabel") as Label
	_check("HUD has an HP ProgressBar", hp_bar != null)
	_check("HUD has a stamina ProgressBar", stamina_bar != null)
	_check("HUD has an HP label", hp_label != null)
	_check("HUD has a gold label", gold_label != null)
	if hp_bar != null:
		_check("HP bar hides its built-in percentage", not hp_bar.show_percentage)
	if stamina_bar != null:
		_check("stamina bar hides its built-in percentage", not stamina_bar.show_percentage)

	var hotbar := hud.get_node_or_null("Root/Hotbar") as HBoxContainer
	_check("HUD has a Hotbar container", hotbar != null)
	if hotbar != null:
		_check("hotbar holds 8 slots (%d)" % hotbar.get_child_count(), hotbar.get_child_count() == 8)
		if hotbar.get_child_count() == 8:
			var first := hotbar.get_child(0) as Control
			_check("hotbar slots are 48x48 (%s)" % first.custom_minimum_size, first.custom_minimum_size == Vector2(48, 48))

	var grid := inventory_ui.find_child("Grid", true, false) as GridContainer
	_check("inventory panel has a GridContainer", grid != null)
	if grid != null:
		_check("inventory grid uses 6 columns (%d)" % grid.columns, grid.columns == 6)
		_check("inventory grid holds 48 slots (%d)" % grid.get_child_count(), grid.get_child_count() == 48)
		if grid.get_child_count() == 48:
			var grid_first := grid.get_child(0) as Control
			_check(
				"inventory slots are 56x56 (%s)" % grid_first.custom_minimum_size,
				grid_first.custom_minimum_size == Vector2(56, 56)
			)
	_check("inventory panel starts hidden", not inventory_ui.visible)
	_check("inventory has an item detail panel", inventory_ui.find_child("Detail", true, false) != null)
	_check("inventory has a live 3D preview", inventory_ui.find_child("Preview", true, false) != null)
	_check("inventory has a sort button", inventory_ui.find_child("SortButton", true, false) != null)

	var player := get_first_node_in_group(&"player")
	_check("a player was spawned", player != null)
	if player == null:
		_finish()
		return
	var inventory: Variant = player.get_node_or_null("InventorySystem")
	_check("player has an InventorySystem", inventory != null)
	if inventory == null:
		_finish()
		return

	var bus: Variant = root.get_node_or_null("EventBus")
	_check("EventBus autoload is available", bus != null)
	if bus == null:
		_finish()
		return

	# --- hotbar mirrors the inventory --------------------------------------
	var leftover := int(inventory.call(&"add_item", &"konop", 5))
	_check("adding 5 konop fits the inventory", leftover == 0)

	var hud_slot := hud.get_node_or_null("Root/Hotbar/Slot0")
	_check("HUD hotbar slot 0 exists", hud_slot != null)
	if hud_slot != null:
		var name_label := hud_slot.find_child("NameLabel", true, false) as Label
		var count_label := hud_slot.find_child("CountLabel", true, false) as Label
		var hotbar_icon := hud_slot.find_child("Icon", true, false) as TextureRect
		_check("hotbar slot 0 has a name label", name_label != null)
		_check("hotbar slot 0 has a count label", count_label != null)
		_check(
			"hotbar slot 0 has an item icon",
			hotbar_icon != null and hotbar_icon.texture != null
		)
		if name_label != null:
			_check(
				"hotbar slot 0 shows the item name (%s)" % name_label.text,
				name_label.text.to_lower().contains("konop")
			)
		if count_label != null:
			_check("hotbar slot 0 shows the stack count (%s)" % count_label.text, count_label.text == "5")
		if name_label != null:
			var lore: Node = root.get_node_or_null("Lore")
			var common := Color.WHITE
			if lore != null:
				common = lore.call(&"rarity_color", "common") as Color
			_check(
				"the hotbar name uses the rarity colour (%s)" % name_label.get_theme_color("font_color"),
				name_label.get_theme_color("font_color") == common
			)

	if grid != null:
		var grid_slot := grid.get_node_or_null("Slot0")
		var grid_name: Label = null
		var grid_count: Label = null
		if grid_slot != null:
			grid_name = grid_slot.find_child("NameLabel", true, false) as Label
			grid_count = grid_slot.find_child("CountLabel", true, false) as Label
		if grid_name != null:
			_check(
				"inventory slot 0 shows the item name (%s)" % grid_name.text,
				grid_name.text.to_lower().contains("konop")
			)
		else:
			_check("inventory slot 0 has a name label", false)
		if grid_count != null:
			_check("inventory slot 0 shows the stack count (%s)" % grid_count.text, grid_count.text == "5")
		else:
			_check("inventory slot 0 has a count label", false)
		var grid_icon: TextureRect = null
		if grid_slot != null:
			grid_icon = grid_slot.find_child("Icon", true, false) as TextureRect
		_check(
			"inventory slot 0 has an item icon",
			grid_icon != null and grid_icon.texture != null
		)

	# --- vitals / gold signals ---------------------------------------------
	bus.emit_signal(&"hp_changed", 50.0, 100.0)
	await process_frame
	if hp_label != null:
		_check("HP label follows hp_changed (%s)" % hp_label.text, hp_label.text == "HP 50/100")
	if hp_bar != null:
		_check("HP bar value follows hp_changed (%.1f)" % hp_bar.value, is_equal_approx(hp_bar.value, 50.0))

	bus.emit_signal(&"stamina_changed", 25.0, 100.0)
	await process_frame
	if stamina_bar != null:
		_check(
			"stamina bar value follows stamina_changed (%.1f)" % stamina_bar.value,
			is_equal_approx(stamina_bar.value, 25.0)
		)

	bus.emit_signal(&"gold_changed", 321)
	await process_frame
	if gold_label != null:
		_check("gold label follows gold_changed (%s)" % gold_label.text, gold_label.text == "Gold 321")

	# --- inventory toggle ---------------------------------------------------
	inventory_ui.call(&"toggle")
	await process_frame
	_check("toggle() opens the inventory panel", inventory_ui.visible)
	if player.has_method(&"set_ui_blocking"):
		_check("the player is UI-blocked while the panel is open", bool(player.get(&"ui_blocking")))
	inventory_ui.call(&"toggle")
	await process_frame
	_check("toggle() closes the inventory panel", not inventory_ui.visible)
	if player.has_method(&"set_ui_blocking"):
		_check("the player is released when the panel closes", not bool(player.get(&"ui_blocking")))

	# --- gather progress bar ------------------------------------------------
	var gather_bar := hud.find_child("GatherBar", true, false) as ProgressBar
	_check("HUD has a gather ProgressBar", gather_bar != null)
	if gather_bar != null:
		_check("gather bar is hidden while idle", not gather_bar.is_visible_in_tree())
		bus.emit_signal(&"gather_progress_changed", 0.5, 1.2)
		await process_frame
		_check("gather bar appears while gathering", gather_bar.is_visible_in_tree())
		_check("gather bar value is 0.5 (%.2f)" % gather_bar.value, is_equal_approx(gather_bar.value, 0.5))
		_check("gather bar max is 1.2 (%.2f)" % gather_bar.max_value, is_equal_approx(gather_bar.max_value, 1.2))
		bus.emit_signal(&"gather_finished", "konop")
		await process_frame
		_check("gather bar hides on gather_finished", not gather_bar.is_visible_in_tree())

	# --- interaction prompt -------------------------------------------------
	var prompt_label := hud.get_node_or_null("Root/InteractionPrompt") as Label
	_check("HUD has an interaction prompt label", prompt_label != null)
	if prompt_label != null:
		_check("interaction prompt starts hidden", not prompt_label.is_visible_in_tree())
		bus.emit_signal(&"interaction_prompt_changed", "Gather Konop  [E]")
		await process_frame
		_check(
			"interaction prompt follows the signal (%s)" % prompt_label.text,
			prompt_label.is_visible_in_tree() and prompt_label.text.contains("Konop")
		)
		bus.emit_signal(&"interaction_prompt_changed", "")
		await process_frame
		_check("an empty prompt hides the label", not prompt_label.is_visible_in_tree())

	# --- buff row -----------------------------------------------------------
	var buff_row := hud.find_child("BuffRow", true, false) as VBoxContainer
	_check("HUD has a buff row under the vitals", buff_row != null)
	var stats: Variant = player.get_node_or_null("Stats")
	_check("the player has Stats for the buff row", stats != null)
	if buff_row != null and stats != null:
		_check("the buff row starts hidden", not buff_row.visible)
		stats.call(&"apply_effect", {"buff": {"id": "hud_test", "duration": 30.0}})
		await process_frame
		_check(
			"a buff shows one pill (%d)" % buff_row.get_child_count(),
			buff_row.visible and buff_row.get_child_count() == 1
		)
		var pill_label: Label = null
		if buff_row.get_child_count() > 0:
			pill_label = buff_row.get_child(0).find_child("Label", true, false) as Label
		_check(
			"the pill names the buff (%s)" % (pill_label.text if pill_label != null else ""),
			pill_label != null and pill_label.text.contains("Hud Test")
		)
		stats.call(&"apply_effect", {"poison": {"damage": 1.0, "duration": 30.0}})
		await process_frame
		_check("poison adds a second pill (%d)" % buff_row.get_child_count(), buff_row.get_child_count() == 2)
		var poison_pill := buff_row.get_node_or_null("BuffPill_poison") as Control
		var poison_label: Label = null
		if poison_pill != null:
			poison_label = poison_pill.find_child("Label", true, false) as Label
		_check(
			"the poison pill uses the danger colour",
			poison_label != null
				and poison_label.get_theme_color("font_color") == Color(0.92, 0.18, 0.18)
		)
		stats.call(&"apply_effect", {"cleanse": true})
		await process_frame
		_check("cleanse removes the poison pill", buff_row.get_node_or_null("BuffPill_poison") == null)

	_finish()


func _wait_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all UI assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
