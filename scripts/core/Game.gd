extends Node
## Session/global runtime state: gold, discovered species, vocation, biome.
## Player vitals and XP belong to PlayerStats; Game forwards and notifies.

const MAX_LEVEL := 100
const VOCATION_UNLOCK_LEVEL := 20
const STARTING_GOLD := 50
const HOTBAR_SLOTS := 8
const INVENTORY_COLS := 6
const INVENTORY_ROWS := 8
const PLOT_DAILY_FEE := 10
const PLOT_EXPIRY_DAYS := 3
## Expedition goal: loot value needed to "make quota" on a layer.
const RUN_BASE_QUOTA := 40
const RUN_QUOTA_PER_LAYER := 20
## Action skills (RuneScape-style): xp comes from doing, each level costs more.
const SKILL_MAX_LEVEL := 20
const SKILL_XP_BASE := 60
## Foraging thresholds that each add +1 mushroom to a harvest.
const FORAGING_BONUS_LEVELS: Array[int] = [5, 10, 15]
## A chosen vocation grants +25% skill xp in its affinity skill.
const VOCATION_SKILL_BONUS := 0.25

var gold: int = STARTING_GOLD
var discovered_mushrooms: Dictionary = {}
## Action skills: `{id: {level, xp}}`, persisted with the save and owned by the
## local peer (each player levels their own character).
var skills: Dictionary = {}
var chosen_vocation: StringName = &""
var current_biome: StringName = &"verdant_bloom"
## 1-5 while a Layered Forest area is active, 0 in town / the Verdant Bloom.
## The descent gate sets it before `Main.enter_area`, so the new area and its
## enemy roster read the same value.
var forest_layer: int = 0
## Scene path of the active area; saved/restored so a forest save reopens there.
var area_path := ""
## XP gathered before PlayerStats exists (main menu, save load). PlayerStats
## drains this on spawn.
var pending_xp: int = 0
## Current expedition (one forest layer). `run_gold` is the loot value gathered
## this run, which is what the quota and the summary screen measure.
var run_layer := 0
var run_gold := 0
var run_quota := 0
var run_mushrooms := 0
var run_deaths := 0
var run_started_msec := 0
## Last finished expedition, read by the summary UI and tests.
var last_run: Dictionary = {}


func _ready() -> void:
	_ensure_skills()
	# Network reporting hooks. Gold, discoveries and the vocation are only known
	# to the owner, so a session reports every change to `Main`, which routes it
	# to the server's roster. Offline the handler returns before doing anything.
	EventBus.gold_changed.connect(_report_progress.unbind(1))
	EventBus.species_discovered.connect(_report_progress.unbind(1))
	EventBus.vocation_chosen.connect(_report_progress.unbind(1))
	EventBus.mushroom_gathered.connect(_on_mushroom_gathered)


func _report_progress() -> void:
	if Network.mode == Network.OFFLINE:
		return
	var main := get_tree().get_first_node_in_group(&"main")
	if main == null or not main.has_method(&"report_own_progress"):
		return
	main.call(&"report_own_progress", gold, discovered_mushrooms.keys(), String(chosen_vocation))


## Starts (or restarts) the expedition clock and quota when a forest layer loads.
func start_run(layer: int) -> void:
	run_layer = clampi(layer, 1, 5)
	run_gold = 0
	run_quota = RUN_BASE_QUOTA + RUN_QUOTA_PER_LAYER * run_layer
	run_mushrooms = 0
	run_deaths = 0
	run_started_msec = Time.get_ticks_msec()


## Gold found in a chest/crate. Always pays the purse; in a run it also counts
## toward the quota.
func add_run_gold(amount: int) -> void:
	if amount <= 0:
		return
	add_gold(amount)
	if forest_layer > 0:
		run_gold += amount


## Mushrooms count toward the quota at their shop value, so a careful forager
## can make quota without finding every chest.
func add_run_mushrooms(id: String, count: int) -> void:
	if forest_layer <= 0 or count <= 0:
		return
	run_mushrooms += count
	var rarity := str(Lore.get_mushroom(id).get("rarity", ""))
	run_gold += Lore.mushroom_value(rarity) * count


func note_run_death() -> void:
	if forest_layer > 0:
		run_deaths += 1


## Closes the expedition, stores/returns the summary and notifies the UI.
func finish_run() -> Dictionary:
	var met := run_gold >= run_quota and run_quota > 0
	var bonus := int(run_quota / 2) if met else 0
	var summary := {
		"layer": run_layer,
		"name": str(Lore.DEPTH_LAYERS.get(str(run_layer), {}).get("name", "The Forest")),
		"gold": run_gold,
		"quota": run_quota,
		"met": met,
		"bonus": bonus,
		"mushrooms": run_mushrooms,
		"deaths": run_deaths,
		"seconds": maxf((Time.get_ticks_msec() - run_started_msec) / 1000.0, 0.0),
	}
	if bonus > 0:
		add_gold(bonus)
	# Extracting is Survival practice, quota or not.
	add_skill_xp(&"survival", 15 if met else 6)
	last_run = summary
	EventBus.run_finished.emit(summary)
	return summary


func _on_mushroom_gathered(id: String, count: int) -> void:
	add_run_mushrooms(id, count)
	# Foraging is progression too: a fifth of the species' shop value in XP, so
	# a run levels you even when the blades stay sheathed.
	var rarity := str(Lore.get_mushroom(id).get("rarity", ""))
	var per_pick := maxi(1, Lore.mushroom_value(rarity) / 5)
	add_xp(per_pick * count)
	# Foraging levels from foraging, not from the character XP funnel.
	add_skill_xp(&"foraging", maxi(1, Lore.mushroom_value(rarity) / 10) * count)


## XP needed to advance from `level` to `level + 1`; monotonic by construction.
func xp_to_level(level: int) -> int:
	return 100 * clampi(level, 1, MAX_LEVEL)


func add_gold(amount: int) -> void:
	if amount == 0:
		return
	gold = maxi(gold + amount, 0)
	EventBus.gold_changed.emit(gold)


## Deducts `amount` only when affordable; the balance is untouched otherwise.
func spend_gold(amount: int) -> bool:
	if amount < 0 or gold < amount:
		return false
	if amount == 0:
		return true
	gold -= amount
	EventBus.gold_changed.emit(gold)
	return true


## Records a first-time species discovery; the catalogue UI listens on EventBus.
func discover_mushroom(id: String) -> void:
	if id.is_empty() or not Lore.is_mushroom(id) or discovered_mushrooms.has(id):
		return
	discovered_mushrooms[id] = true
	EventBus.species_discovered.emit(id)


func add_xp(amount: int) -> void:
	if amount <= 0:
		return
	var player := get_local_player()
	if player != null and player.has_method(&"add_xp"):
		player.add_xp(amount)
	else:
		pending_xp += amount


## --- Action skills -------------------------------------------------------


func _ensure_skills() -> void:
	for id: String in Lore.SKILLS:
		var raw: Variant = skills.get(id)
		if raw is Dictionary:
			var level := clampi(int((raw as Dictionary).get("level", 1)), 1, SKILL_MAX_LEVEL)
			var xp := maxi(int((raw as Dictionary).get("xp", 0)), 0)
			if level >= SKILL_MAX_LEVEL:
				xp = 0
			else:
				xp = mini(xp, skill_xp_to_level(level) - 1)
			skills[id] = {"level": level, "xp": xp}
		else:
			skills[id] = {"level": 1, "xp": 0}


func skill_xp_to_level(level: int) -> int:
	return SKILL_XP_BASE * clampi(level, 1, SKILL_MAX_LEVEL)


func skill_level(id: String) -> int:
	_ensure_skills()
	return int((skills.get(id, {}) as Dictionary).get("level", 1))


func skill_xp(id: String) -> int:
	_ensure_skills()
	return int((skills.get(id, {}) as Dictionary).get("xp", 0))


## The skill a chosen vocation leans on, or "" before the choice.
func vocation_affinity() -> String:
	if chosen_vocation == &"":
		return ""
	var vocation: Dictionary = Lore.VOCATIONS.get(String(chosen_vocation), {})
	return str(vocation.get("affinity", ""))


## Grants xp and returns how many levels were gained. A maxed skill stops
## collecting xp instead of overflowing a bar it can never fill.
func add_skill_xp(id: StringName, amount: int) -> int:
	var key := String(id)
	if amount <= 0 or not Lore.SKILLS.has(key):
		return 0
	if key == vocation_affinity():
		amount = maxi(amount + 1, int(round(float(amount) * (1.0 + VOCATION_SKILL_BONUS))))
	_ensure_skills()
	var entry: Dictionary = skills[key]
	var level := int(entry.get("level", 1))
	if level >= SKILL_MAX_LEVEL:
		return 0
	entry["xp"] = int(entry.get("xp", 0)) + amount
	var gained := 0
	while level < SKILL_MAX_LEVEL and int(entry["xp"]) >= skill_xp_to_level(level):
		entry["xp"] = int(entry["xp"]) - skill_xp_to_level(level)
		level += 1
		gained += 1
		EventBus.skill_level_up.emit(StringName(key), level)
	if level >= SKILL_MAX_LEVEL:
		entry["xp"] = 0
	entry["level"] = level
	EventBus.skill_changed.emit(
		StringName(key), level, int(entry["xp"]), skill_xp_to_level(level)
	)
	return gained


func skills_snapshot() -> Dictionary:
	_ensure_skills()
	return skills.duplicate(true)


## Restores a saved skill block, ignoring unknown ids and out-of-range values.
func apply_skills(data: Variant) -> void:
	skills.clear()
	_ensure_skills()
	if not (data is Dictionary):
		return
	for id: String in Lore.SKILLS:
		var raw: Variant = (data as Dictionary).get(id)
		if not (raw is Dictionary):
			continue
		var level := clampi(int((raw as Dictionary).get("level", 1)), 1, SKILL_MAX_LEVEL)
		var xp := maxi(int((raw as Dictionary).get("xp", 0)), 0)
		if level >= SKILL_MAX_LEVEL:
			xp = 0
		else:
			xp = mini(xp, skill_xp_to_level(level) - 1)
		skills[id] = {"level": level, "xp": xp}


## +1 mushroom per harvest for every foraging threshold reached.
func foraging_bonus() -> int:
	var level := skill_level("foraging")
	var bonus := 0
	for threshold: int in FORAGING_BONUS_LEVELS:
		if level >= threshold:
			bonus += 1
	return bonus


## Brew fees get 1 g cheaper per alchemy level, never free.
func alchemy_fee(base: int) -> int:
	return maxi(1, base - (skill_level("alchemy") - 1))


func combat_skill_scale() -> float:
	return 1.0 + 0.02 * float(skill_level("combat") - 1)


func survival_lamp_scale() -> float:
	return 1.0 + 0.05 * float(skill_level("survival") - 1)


## Search time multiplier, floored so a maxed search is still a real hold.
func survival_search_scale() -> float:
	return maxf(0.6, 1.0 - 0.02 * float(skill_level("survival") - 1))


## Only at VOCATION_UNLOCK_LEVEL, only once, and only for a known vocation id.
func set_vocation(id: String) -> bool:
	if id.is_empty() or not Lore.VOCATIONS.has(id):
		return false
	if chosen_vocation != &"":
		return false
	if _local_level() < VOCATION_UNLOCK_LEVEL:
		return false
	chosen_vocation = StringName(id)
	EventBus.vocation_chosen.emit(id)
	return true


## The local peer's body. A client also receives the host's replicated body in
## the same group, so "first node in the group" can belong to someone else.
## Prefer the node that is both authoritative and named after this peer id, then
## any authoritative node, and only then whatever the group returns first.
func get_local_player() -> Node:
	# After a disconnect there is no peer; HUD polling must not spam engine errors.
	if multiplayer.multiplayer_peer == null:
		return null
	var local_id := str(multiplayer.get_unique_id())
	var authoritative: Node = null
	for node: Node in get_tree().get_nodes_in_group(&"player"):
		if not node.is_multiplayer_authority():
			continue
		if authoritative == null:
			authoritative = node
		if String(node.name) == local_id:
			return node
	if authoritative != null:
		return authoritative
	return get_tree().get_first_node_in_group(&"player")


func reset_session() -> void:
	gold = STARTING_GOLD
	discovered_mushrooms.clear()
	skills.clear()
	_ensure_skills()
	chosen_vocation = &""
	current_biome = &"verdant_bloom"
	forest_layer = 0
	area_path = ""
	pending_xp = 0
	EventBus.gold_changed.emit(gold)


func _local_level() -> int:
	var player := get_local_player()
	if player != null and "level" in player:
		return int(player.get("level"))
	return 1
