class_name SkillTreeUI
extends MenuPanel
## Skill tree panel (K): one tab per tree, nodes laid out by tier, click a node to
## learn a rank. Vocation trees appear once a vocation is chosen.
##
## A pure view over `SkillSystem`: `check_learn` explains why a node is locked
## (it becomes the tooltip) and `learn` does the work.

const SkillData := preload("res://scripts/core/SkillData.gd")
const CARD_SIZE := Vector2(176, 78)

var _skills: Node = null
var _tree := "gathering"
var _tabs: HBoxContainer = null
var _tiers: VBoxContainer = null
var _points: Label = null
var _note: Label = null
var _respec: Button = null
var _confirm_respec := false


func _init() -> void:
	toggle_action = &"skills_menu"
	panel_title = "Skills"
	panel_size = Vector2(900, 540)


func _add_header_extras(header: HBoxContainer) -> void:
	_points = _label("", 16, UITheme.AMBER)
	header.add_child(_points)
	_respec = Button.new()
	_respec.text = "Respec"
	_respec.custom_minimum_size = Vector2(120, 32)
	UITheme.style_button(_respec)
	_respec.pressed.connect(_on_respec_pressed)
	header.add_child(_respec)


func _build_content(root: VBoxContainer) -> void:
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 6)
	root.add_child(_tabs)

	_note = _label("", 13, UITheme.DIM)
	root.add_child(_note)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_tiers = VBoxContainer.new()
	_tiers.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tiers.add_theme_constant_override("separation", 10)
	scroll.add_child(_tiers)

	_track(EventBus.skills_changed, _refresh)
	_track(EventBus.skill_points_changed, func(_n: int) -> void: _refresh())
	_track(EventBus.level_changed, func(_level: int) -> void: _refresh())
	_track(EventBus.gold_changed, func(_g: int) -> void: _refresh())


func _on_opened() -> void:
	_skills = _find_system()
	_confirm_respec = false
	_refresh()


func current_tree() -> String:
	return _tree


func select_tree(id: String) -> void:
	if SkillData.TREES.has(id):
		_tree = id
		_refresh()


func _find_system() -> Node:
	var player := Game.get_local_player()
	return player.get_node_or_null("SkillSystem") if player != null else null


func _refresh() -> void:
	if not visible or _tiers == null:
		return
	if _skills == null or not is_instance_valid(_skills):
		_skills = _find_system()
	if _skills == null:
		return
	var vocation := String(Game.chosen_vocation)
	var visible_trees := SkillData.trees_for(vocation)
	if not visible_trees.has(_tree):
		_tree = visible_trees[0]

	_points.text = (
		"Points  %d / %d"
		% [int(_skills.call(&"points_available")), int(_skills.call(&"points_total"))]
	)
	var cost := int(_skills.call(&"respec_cost"))
	_respec.disabled = cost <= 0
	_respec.text = "Confirm (%d g)?" % cost if _confirm_respec else "Respec (%d g)" % cost
	_note.text = (
		"" if not vocation.is_empty()
		else "Choose a vocation at level %d to unlock its skill trees." % Game.VOCATION_UNLOCK_LEVEL
	)

	for child in _tabs.get_children():
		child.queue_free()
	for tree_id in visible_trees:
		var button := Button.new()
		button.text = str(SkillData.get_tree(tree_id)["name"])
		button.custom_minimum_size = Vector2(0, 32)
		UITheme.style_button(button, tree_id == _tree)
		button.pressed.connect(select_tree.bind(tree_id))
		_tabs.add_child(button)
	_rebuild_tiers()


func _rebuild_tiers() -> void:
	for child in _tiers.get_children():
		child.queue_free()
	var tree := SkillData.get_tree(_tree)
	var accent: Color = tree.get("color", UITheme.ACCENT)
	var row: HBoxContainer = null
	var row_tier := -1
	for id in SkillData.tree_nodes(_tree):
		var node := SkillData.get_node(id)
		if int(node["tier"]) != row_tier:
			row_tier = int(node["tier"])
			row = HBoxContainer.new()
			row.add_theme_constant_override("separation", 10)
			var tier_label := _label("Tier %d" % row_tier, 12, UITheme.FAINT)
			tier_label.custom_minimum_size = Vector2(46, 0)
			row.add_child(tier_label)
			_tiers.add_child(row)
		row.add_child(_node_card(id, node, accent))


func _node_card(id: String, node: Dictionary, accent: Color) -> Button:
	var rank := int(_skills.call(&"rank", id))
	var max_rank := int(node["max_rank"])
	var verdict: Dictionary = _skills.call(&"check_learn", id)
	var can_learn := bool(verdict.get("ok", false))
	var maxed := rank >= max_rank

	var button := Button.new()
	button.custom_minimum_size = CARD_SIZE
	button.text = "%s\nRank %d / %d" % [str(node["name"]), rank, max_rank]
	button.add_theme_font_override("font", UITheme.bold_font())
	button.add_theme_font_size_override("font_size", 13)
	button.focus_mode = Control.FOCUS_NONE
	var border := UITheme.BORDER_DIM
	var fill := UITheme.PANEL_DEEP
	var text := UITheme.DIM
	if maxed:
		border = UITheme.GOLD
		fill = Color(0.13, 0.11, 0.05, 0.96)
		text = UITheme.GOLD
	elif rank > 0:
		border = accent
		fill = UITheme.PANEL_ALT
		text = UITheme.TEXT
	elif can_learn:
		border = accent.lightened(0.2)
		fill = UITheme.PANEL_ALT
		text = UITheme.TEXT
	for state: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		var style := UITheme.panel_style(fill, border, 8, 2 if can_learn or rank > 0 else 1, 0)
		if state == "hover" and can_learn:
			style.bg_color = fill.lightened(0.08)
		button.add_theme_stylebox_override(state, style)
	for color_name: String in ["font_color", "font_hover_color", "font_pressed_color", "font_disabled_color"]:
		button.add_theme_color_override(color_name, text)
	button.tooltip_text = _tooltip(node, verdict, rank)
	button.pressed.connect(_on_node_pressed.bind(id))
	return button


func _tooltip(node: Dictionary, verdict: Dictionary, rank: int) -> String:
	var lines: Array[String] = [str(node["description"])]
	var effect := SkillData.effect_text(node.get("effects", {}))
	if not effect.is_empty():
		lines.append("Each rank: %s" % effect)
	for recipe_id: String in node.get("unlocks", []):
		lines.append("Unlocks: %s" % Lore.item_display_name(str(Lore.get_recipe(recipe_id)["output"]["id"])))
	if int(node.get("min_level", 1)) > 1:
		lines.append("Level %d" % int(node["min_level"]))
	if rank < int(node["max_rank"]) and not bool(verdict.get("ok", false)):
		lines.append(str(verdict.get("message", "")))
	return "\n".join(lines)


func _on_node_pressed(id: String) -> void:
	if _skills != null:
		_skills.call(&"learn", id)


func _on_respec_pressed() -> void:
	if _skills == null:
		return
	if not _confirm_respec:
		_confirm_respec = true
		_refresh()
		return
	_confirm_respec = false
	_skills.call(&"respec")
	_refresh()
