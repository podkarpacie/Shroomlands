extends "res://scripts/ui/StationPanelUI.gd"
## Plot Board: a read-only summary of the six plots, straight from the live
## `PlotSystem`. It deliberately has no buttons: buying, building and fees stay
## on the plot signs where they already live.

const PLOT_COUNT := 6


func panel_title() -> String:
	return "Plot Board"


func panel_hint() -> String:
	return "The six 12 x 12 m plots are north of the gate, just outside the wall. Buy one at its sign, then build on the 1 m grid."


func _refresh_content() -> void:
	clear_body()
	var system := get_tree().get_first_node_in_group(&"plot_system")
	if system == null:
		add_label(add_row(), "The plot registry is not available.", 13, UITheme.DANGEROUS)
		return
	var local_id := str(multiplayer.get_unique_id())
	for plot_id in PLOT_COUNT:
		var plot: Dictionary = system.call(&"get_plot", plot_id) as Dictionary
		if plot.is_empty():
			continue
		var owner_id := String(plot.get("owner", ""))
		var owner_text := "Unowned"
		var color := UITheme.DIM
		if owner_id != "":
			if owner_id == local_id:
				owner_text = "Yours"
				color = UITheme.ACCENT
			else:
				owner_text = "Player %s" % owner_id
				color = UITheme.TEXT
		var objects := (plot.get("objects", []) as Array).size()
		var row := add_row()
		add_label(row, "Plot %d" % (plot_id + 1), 14, UITheme.TEXT)
		add_label(row, owner_text, 13, color)
		var details := add_label(
			row,
			"%d g/day · %d object%s" % [
				Game.PLOT_DAILY_FEE, objects, "" if objects == 1 else "s"
			],
			12,
			UITheme.DIM,
			false
		)
		details.custom_minimum_size = Vector2(210.0, 0.0)
		details.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
