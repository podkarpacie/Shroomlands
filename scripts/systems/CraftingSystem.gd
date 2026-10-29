class_name CraftingSystem
extends Node
## Turns mushrooms into goods. Recipes live in `Lore.RECIPES`.
##
## A craft takes the recipe's `seconds` (shortened by the `craft_speed` skill),
## consumes the inputs and produces the output in one step when the timer ends,
## so cancelling or being hurt mid-brew costs nothing. Skills can save an
## ingredient or add a bonus potion. Everything happens on the owner's peer and
## reaches the server through the normal inventory report, like gathering.
##
## `status` answers "can I craft this, and if not why" for the UI, and `begin`
## and `craft_now` both go through it, so the rules live in exactly one place.

const SkillData := preload("res://scripts/core/SkillData.gd")
const BONUS_OUTPUT := 1

var _recipe_id := ""
var _elapsed := 0.0
var _total := 0.0
var _last_hp := -1.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	if not is_multiplayer_authority():
		set_process(false)
		return
	_rng.randomize()
	EventBus.hp_changed.connect(_on_hp_changed)
	EventBus.player_died.connect(cancel)


## Fixes the dice for a test.
func seed_rng(value: int) -> void:
	_rng.seed = value


# --- asking ----------------------------------------------------------------------

## `{ok, reason, message, inputs: [{id, need, have}]}`. `reason` is one of:
## unknown, busy, dead, level, skill, ingredients, space.
func status(recipe_id: String, ignore_busy := false) -> Dictionary:
	var recipe := Lore.get_recipe(recipe_id)
	var inputs: Array[Dictionary] = []
	if recipe.is_empty():
		return _status(false, "unknown", "Unknown recipe.", inputs)
	var inventory := _inventory()
	for input: Dictionary in recipe.get("inputs", []):
		var have: int = inventory.count_item(StringName(input["id"])) if inventory != null else 0
		inputs.append({"id": str(input["id"]), "need": int(input["count"]), "have": have})
	if inventory == null:
		return _status(false, "unknown", "No inventory.", inputs)
	if is_crafting() and not ignore_busy:
		return _status(false, "busy", "Already brewing.", inputs)
	var stats := _stats()
	if stats != null and stats.has_method(&"is_dead") and bool(stats.call(&"is_dead")):
		return _status(false, "dead", "You cannot craft while dead.", inputs)
	var level := int(stats.get("level")) if stats != null else 1
	if level < int(recipe.get("level", 1)):
		return _status(false, "level", "Requires level %d." % int(recipe["level"]), inputs)
	var skills := _skills()
	var needed_skill := str(recipe.get("skill", ""))
	if not needed_skill.is_empty() and (skills == null or not skills.has_skill(needed_skill)):
		var skill_name := str(SkillData.get_node(needed_skill).get("name", needed_skill))
		return _status(false, "skill", "Requires the skill %s." % skill_name, inputs)
	for entry in inputs:
		if int(entry["have"]) < int(entry["need"]):
			return _status(false, "ingredients", "Missing ingredients.", inputs)
	var output: Dictionary = recipe["output"]
	var removals: Array = []
	for input: Dictionary in recipe.get("inputs", []):
		removals.append({"id": input["id"], "count": input["count"]})
	# Leave room for a lucky extra only when the player can actually roll one.
	var room := int(output["count"]) + (BONUS_OUTPUT if _modifier("craft_bonus_chance") > 0.0 else 0)
	if not inventory.would_fit(removals, StringName(output["id"]), room):
		return _status(false, "space", "Inventory full.", inputs)
	return _status(true, "", "", inputs)


func is_crafting() -> bool:
	return _recipe_id != ""


func current_recipe() -> String:
	return _recipe_id


func progress_ratio() -> float:
	if not is_crafting() or _total <= 0.0:
		return 0.0
	return clampf(_elapsed / _total, 0.0, 1.0)


## Brew time after skills.
func brew_seconds(recipe_id: String) -> float:
	var base := float(Lore.get_recipe(recipe_id).get("seconds", 1.0))
	return maxf(base / (1.0 + _modifier("craft_speed")), 0.05)


# --- doing -----------------------------------------------------------------------

func begin(recipe_id: String) -> bool:
	if not is_multiplayer_authority():
		return false
	var verdict := status(recipe_id)
	if not bool(verdict["ok"]):
		var message := str(verdict["message"])
		if not message.is_empty():
			EventBus.toast_requested.emit(message)
		return false
	_recipe_id = recipe_id
	_elapsed = 0.0
	_total = brew_seconds(recipe_id)
	_last_hp = _player_hp()
	EventBus.craft_started.emit(recipe_id, _total)
	EventBus.craft_progress_changed.emit(0.0, _total)
	return true


func cancel() -> void:
	if not is_crafting():
		return
	var id := _recipe_id
	_reset()
	EventBus.craft_cancelled.emit(id)


## Crafts immediately with no timer: the same rules and rolls as a timed craft.
func craft_now(recipe_id: String) -> bool:
	if not is_multiplayer_authority():
		return false
	return _finish(recipe_id)


func _process(delta: float) -> void:
	if not is_crafting():
		return
	_elapsed += delta
	EventBus.craft_progress_changed.emit(minf(_elapsed, _total), _total)
	if _elapsed >= _total:
		var id := _recipe_id
		_reset()
		_finish(id)


## Re-checks the recipe at the end (the world may have changed during the brew),
## then consumes, produces and rewards in one go.
func _finish(recipe_id: String) -> bool:
	var verdict := status(recipe_id, true)
	if not bool(verdict["ok"]):
		var message := str(verdict["message"])
		if not message.is_empty():
			EventBus.toast_requested.emit(message)
		EventBus.craft_cancelled.emit(recipe_id)
		return false
	var recipe := Lore.get_recipe(recipe_id)
	var inventory := _inventory()
	var saved := _rng.randf() < _modifier("craft_save_chance")
	var bonus := _rng.randf() < _modifier("craft_bonus_chance")

	var removals: Array = []
	var first := true
	for input: Dictionary in recipe["inputs"]:
		var count := int(input["count"])
		if saved and first:
			count -= 1
		first = false
		if count > 0:
			removals.append({"id": input["id"], "count": count})
	var output: Dictionary = recipe["output"]
	var made := int(output["count"]) + (BONUS_OUTPUT if bonus else 0)
	if not inventory.would_fit(removals, StringName(output["id"]), made):
		EventBus.toast_requested.emit("Inventory full.")
		EventBus.craft_cancelled.emit(recipe_id)
		return false

	for removal: Dictionary in removals:
		inventory.remove_item(StringName(removal["id"]), int(removal["count"]))
	inventory.add_item(StringName(output["id"]), made)
	Game.add_xp(int(recipe.get("xp", 0)))
	EventBus.item_crafted.emit(recipe_id, str(output["id"]), made)
	var name := Lore.item_display_name(str(output["id"]))
	var note := "Crafted %s x%d." % [name, made]
	if bonus:
		note += " A lucky extra!"
	elif saved:
		note += " An ingredient was saved."
	EventBus.toast_requested.emit(note)
	return true


# --- internals -------------------------------------------------------------------

func _status(ok: bool, reason: String, message: String, inputs: Array[Dictionary]) -> Dictionary:
	return {"ok": ok, "reason": reason, "message": message, "inputs": inputs}


func _reset() -> void:
	_recipe_id = ""
	_elapsed = 0.0
	_total = 0.0
	_last_hp = -1.0


func _on_hp_changed(current: float, _max_hp: float) -> void:
	if is_crafting() and _last_hp >= 0.0 and current < _last_hp:
		cancel()
	_last_hp = current


func _modifier(stat: String) -> float:
	var skills := _skills()
	return skills.get_modifier(stat) if skills != null else 0.0


func _skills() -> SkillSystem:
	var parent := get_parent()
	return parent.get_node_or_null("SkillSystem") as SkillSystem if parent != null else null


func _inventory() -> Node:
	var parent := get_parent()
	return parent.get_node_or_null("InventorySystem") if parent != null else null


func _stats() -> Node:
	var parent := get_parent()
	return parent.get_node_or_null("Stats") if parent != null else null


func _player_hp() -> float:
	var stats := _stats()
	return float(stats.get("hp")) if stats != null else -1.0
