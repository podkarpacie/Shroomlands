class_name SkillSystem
extends Node
## The player's skill tree: points, learned ranks and the bonuses they give.
##
## Content lives in `scripts/core/SkillData.gd`; this node only does the rules.
## Points are one per level from level 2. A node can be learned when it has rank
## left, a point is free, the level is high enough, its prerequisites have at
## least one rank and (for a vocation tree) that vocation is chosen.
##
## Effects are summed per stat (`get_modifier`). Flat stats (health, stamina,
## regen, speed) are pushed into `Stats` and the controller as *deltas*, so they
## stack with vocation bonuses instead of fighting them; fractions and chances are
## read on demand by the systems that use them (combat, gathering, crafting).
##
## Owner-only, like the other systems: a replicated copy of someone else's body
## keeps this node but never runs it. Skills are not synced to other peers.

const SkillData := preload("res://scripts/core/SkillData.gd")
const FLAT_STATS: Array[String] = [
	"max_hp", "max_stamina", "stamina_regen", "walk_speed", "sprint_speed"
]

## node id -> rank (int, > 0)
var learned: Dictionary = {}

var _applied: Dictionary = {}


func _ready() -> void:
	if not is_multiplayer_authority():
		return
	EventBus.level_changed.connect(_on_level_changed)
	EventBus.vocation_chosen.connect(_on_vocation_chosen)


# --- points ----------------------------------------------------------------------

func player_level() -> int:
	var stats := _stats()
	return maxi(int(stats.get("level")) if stats != null else 1, 1)


func points_total(level_override := -1) -> int:
	var level := level_override if level_override > 0 else player_level()
	return maxi(level - 1, 0) * SkillData.POINTS_PER_LEVEL


func points_spent() -> int:
	var spent := 0
	for id: String in learned:
		spent += _cost(id) * int(learned[id])
	return spent


func points_available() -> int:
	return maxi(points_total() - points_spent(), 0)


# --- reading ---------------------------------------------------------------------

func rank(id: String) -> int:
	return int(learned.get(id, 0))


func has_skill(id: String) -> bool:
	return rank(id) > 0


## Sum of `effects[stat] * rank` over everything learned.
func get_modifier(stat: String) -> float:
	var total := 0.0
	for id: String in learned:
		var effects: Dictionary = SkillData.get_node(id).get("effects", {})
		total += float(effects.get(stat, 0.0)) * float(learned[id])
	return total


## A recipe needs its `skill` (when it names one) learned first.
func is_recipe_unlocked(recipe_id: String) -> bool:
	var skill := str(Lore.get_recipe(recipe_id).get("skill", ""))
	return skill.is_empty() or has_skill(skill)


# --- learning --------------------------------------------------------------------

## `{ok, reason, message}`; `reason` is one of: unknown, maxed, vocation, level,
## requires, points.
func check_learn(id: String, level_override := -1) -> Dictionary:
	var node := SkillData.get_node(id)
	if node.is_empty():
		return _verdict(false, "unknown", "No such skill.")
	if rank(id) >= int(node.get("max_rank", 1)):
		return _verdict(false, "maxed", "Already at full rank.")
	var owner_vocation := str(SkillData.get_tree(str(node.get("tree", ""))).get("vocation", ""))
	if not owner_vocation.is_empty() and owner_vocation != String(Game.chosen_vocation):
		return _verdict(false, "vocation", "Requires the %s vocation." % owner_vocation.capitalize())
	var level := level_override if level_override > 0 else player_level()
	if level < int(node.get("min_level", 1)):
		return _verdict(false, "level", "Requires level %d." % int(node["min_level"]))
	for required: String in node.get("requires", []):
		if not has_skill(required):
			var needed := str(SkillData.get_node(required).get("name", required))
			return _verdict(false, "requires", "Requires %s first." % needed)
	var free := maxi(points_total(level_override) - points_spent(), 0)
	if free < _cost(id):
		return _verdict(false, "points", "No skill points left.")
	return _verdict(true, "", "")


func learn(id: String) -> bool:
	if not is_multiplayer_authority():
		return false
	var verdict := check_learn(id)
	if not bool(verdict["ok"]):
		return false
	learned[id] = rank(id) + 1
	_apply_flat_effects()
	_announce("Learned %s (rank %d)." % [str(SkillData.get_node(id)["name"]), rank(id)])
	return true


func respec_cost() -> int:
	return points_spent() * SkillData.RESPEC_GOLD_PER_POINT


## Refunds every point for gold. False when there is nothing to refund or the
## player cannot pay.
func respec() -> bool:
	if not is_multiplayer_authority() or learned.is_empty():
		return false
	if not Game.spend_gold(respec_cost()):
		EventBus.toast_requested.emit("Not enough gold to respec.")
		return false
	learned.clear()
	_apply_flat_effects()
	_announce("Skills reset.")
	return true


# --- saving ----------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {"learned": learned.duplicate()}


## Restores a snapshot. Unknown ids, bad ranks, anything the level or points
## cannot afford and anything whose prerequisites are missing are dropped, so a
## hand-edited or outdated save can never grant skills the rules forbid.
## `level_override` is the saved level, used because the stats are restored after.
func from_dict(data: Dictionary, level_override := -1) -> void:
	var saved: Variant = data.get("learned", {})
	learned.clear()
	if saved is Dictionary:
		var ids: Array[String] = []
		for raw_id: Variant in saved:
			if raw_id is String and SkillData.NODES.has(raw_id):
				ids.append(raw_id)
		ids.sort_custom(_sort_for_loading)
		for id in ids:
			var wanted := clampi(_as_rank(saved[id]), 0, int(SkillData.get_node(id)["max_rank"]))
			for _step in wanted:
				if not bool(check_learn(id, level_override).get("ok", false)):
					break
				learned[id] = rank(id) + 1
	_apply_flat_effects()
	EventBus.skills_changed.emit()
	EventBus.skill_points_changed.emit(points_available())


# --- internals -------------------------------------------------------------------

func _cost(id: String) -> int:
	return maxi(int(SkillData.get_node(id).get("cost", 1)), 1)


func _verdict(ok: bool, reason: String, message: String) -> Dictionary:
	return {"ok": ok, "reason": reason, "message": message}


func _as_rank(value: Variant) -> int:
	if value is int or value is float:
		return int(value)
	return 0


func _sort_for_loading(a: String, b: String) -> bool:
	var tier_a := int(SkillData.get_node(a)["tier"])
	var tier_b := int(SkillData.get_node(b)["tier"])
	return tier_a < tier_b if tier_a != tier_b else a < b


func _announce(text: String) -> void:
	EventBus.toast_requested.emit(text)
	EventBus.skills_changed.emit()
	EventBus.skill_points_changed.emit(points_available())


func _stats() -> Node:
	var parent := get_parent()
	return parent.get_node_or_null("Stats") if parent != null else null


func _apply_flat_effects() -> void:
	for stat in FLAT_STATS:
		var target := get_modifier(stat)
		var diff := target - float(_applied.get(stat, 0.0))
		if is_zero_approx(diff):
			continue
		_push_flat(stat, diff)
		_applied[stat] = target


func _push_flat(stat: String, diff: float) -> void:
	var stats := _stats()
	var body := get_parent()
	match stat:
		"max_hp":
			if stats != null:
				stats.max_hp = maxf(float(stats.max_hp) + diff, 1.0)
				stats.hp = clampf(float(stats.hp) + maxf(diff, 0.0), 0.0, float(stats.max_hp))
				EventBus.hp_changed.emit(stats.hp, stats.max_hp)
		"max_stamina":
			if stats != null:
				stats.max_stamina = maxf(float(stats.max_stamina) + diff, 1.0)
				stats.stamina = clampf(
					float(stats.stamina) + maxf(diff, 0.0), 0.0, float(stats.max_stamina)
				)
				EventBus.stamina_changed.emit(stats.stamina, stats.max_stamina)
		"stamina_regen":
			if stats != null:
				stats.stamina_regen = maxf(float(stats.stamina_regen) + diff, 0.0)
		"walk_speed":
			if body != null and body.has_method(&"apply_vocation_speed_bonus"):
				body.call(&"apply_vocation_speed_bonus", diff, 0.0)
		"sprint_speed":
			if body != null and body.has_method(&"apply_vocation_speed_bonus"):
				body.call(&"apply_vocation_speed_bonus", 0.0, diff)


func _on_level_changed(new_level: int) -> void:
	var available := points_available()
	EventBus.skill_points_changed.emit(available)
	if new_level > 1 and available > 0:
		EventBus.toast_requested.emit("Skill point available (%d)." % available)


func _on_vocation_chosen(_id: String) -> void:
	EventBus.skills_changed.emit()
