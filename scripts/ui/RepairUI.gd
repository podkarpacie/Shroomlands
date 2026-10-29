extends "res://scripts/ui/StationPanelUI.gd"
## Repair Bench: shows the local weapon's condition and restores it to 100 for
## 2 gold per point. The condition itself lives on `PlayerController` and is worn
## by `CombatSystem`; this panel is the only place that spends gold on it.

const COST_PER_POINT := 2


func panel_title() -> String:
	return "Repair Bench"


func panel_hint() -> String:
	return "Every swing wears the weapon by one point. At 0 it deals half damage. Repairs cost %d g per point." % COST_PER_POINT


func _refresh_content() -> void:
	clear_body()
	var condition := get_condition()
	var row := add_row()
	add_label(row, "Weapon condition", 14, UITheme.TEXT)
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = float(MAX_CONDITION)
	bar.value = float(condition)
	bar.custom_minimum_size = Vector2(0.0, 18.0)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	UITheme.style_bar(bar, UITheme.ACCENT if condition > 0 else UITheme.DANGEROUS, 5)
	row.add_child(bar)
	var value := add_label(row, "%d / %d" % [condition, MAX_CONDITION], 13, UITheme.ACCENT, false)
	value.custom_minimum_size = Vector2(76.0, 0.0)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	var cost := repair_cost()
	var action_row := add_row()
	var description := "Perfect condition." if condition >= MAX_CONDITION else "Restores 100 at %d g per point." % COST_PER_POINT
	add_label(action_row, description, 13, UITheme.DIM)
	if condition < MAX_CONDITION:
		var cost_label := add_label(action_row, "%d g" % cost, 14, UITheme.GOLD, false)
		cost_label.custom_minimum_size = Vector2(72.0, 0.0)
		cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		var repair_button := add_button(action_row, "Repair", true)
		repair_button.disabled = Game.gold < cost
		repair_button.pressed.connect(repair)


## Gold the next repair costs; 0 at full condition.
func repair_cost() -> int:
	return maxi(MAX_CONDITION - get_condition(), 0) * COST_PER_POINT


func get_condition() -> int:
	var player := _local_player()
	if player == null or not ("weapon_condition" in player):
		return MAX_CONDITION
	return clampi(int(player.get(&"weapon_condition")), 0, MAX_CONDITION)


## Restores the weapon to 100. Returns false (and spends nothing) when it is
## already full, there is no local body, or the gold is short.
func repair() -> bool:
	var player := _local_player()
	if player == null:
		_set_status("No weapon to repair.", UITheme.DANGEROUS)
		return false
	var condition := get_condition()
	if condition >= MAX_CONDITION:
		_set_status("Already in perfect condition.", UITheme.DIM)
		return false
	var cost := repair_cost()
	if not Game.spend_gold(cost):
		_play_click()
		_set_status("Not enough gold — this repair costs %d g." % cost, UITheme.DANGEROUS)
		_refresh_gold()
		_queue_refresh()
		return false
	player.set(&"weapon_condition", MAX_CONDITION)
	_play_click()
	_set_status("Repaired to %d for %d g." % [MAX_CONDITION, cost])
	_queue_refresh()
	return true
