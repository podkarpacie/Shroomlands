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

var gold: int = STARTING_GOLD
var discovered_mushrooms: Dictionary = {}
var chosen_vocation: StringName = &""
var current_biome: StringName = &"verdant_bloom"
## XP gathered before PlayerStats exists (main menu, save load). PlayerStats
## drains this on spawn.
var pending_xp: int = 0


func _ready() -> void:
	# Network reporting hooks. Gold, discoveries and the vocation are only known
	# to the owner, so a session reports every change to `Main`, which routes it
	# to the server's roster. Offline the handler returns before doing anything.
	EventBus.gold_changed.connect(_report_progress.unbind(1))
	EventBus.species_discovered.connect(_report_progress.unbind(1))
	EventBus.vocation_chosen.connect(_report_progress.unbind(1))


func _report_progress() -> void:
	if Network.mode == Network.OFFLINE:
		return
	var main := get_tree().get_first_node_in_group(&"main")
	if main == null or not main.has_method(&"report_own_progress"):
		return
	main.call(&"report_own_progress", gold, discovered_mushrooms.keys(), String(chosen_vocation))


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
	chosen_vocation = &""
	current_biome = &"verdant_bloom"
	pending_xp = 0
	EventBus.gold_changed.emit(gold)


func _local_level() -> int:
	var player := get_local_player()
	if player != null and "level" in player:
		return int(player.get("level"))
	return 1
