class_name ConsumableSystem
extends Node
## Uses consumable items (`Lore.ITEMS` with an `effect`): the F key uses the
## selected hotbar slot. Effects: `heal` and `stamina` are instant, `regen` ticks
## health for a few seconds. The `potion_potency` skill strengthens all of them.
##
## It will not burn a potion that would do nothing (healing at full health), and
## a short per-item cooldown stops key-mashing from draining a stack.

var selected_slot := 0

var _cooldown_left := 0.0
var _regen_rate := 0.0
var _regen_left := 0.0


func _ready() -> void:
	if not is_multiplayer_authority():
		set_process(false)
		set_process_unhandled_input(false)
		return
	EventBus.hotbar_selected.connect(func(index: int) -> void: selected_slot = index)
	EventBus.player_died.connect(_stop_regen)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"use_item") and not _ui_blocking():
		use_selected()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_cooldown_left = maxf(_cooldown_left - delta, 0.0)
	if _regen_left > 0.0:
		var step := minf(delta, _regen_left)
		_regen_left -= step
		var stats := _stats()
		if stats != null and stats.has_method(&"heal"):
			stats.call(&"heal", _regen_rate * step)


func cooldown_left() -> float:
	return _cooldown_left


func is_regenerating() -> bool:
	return _regen_left > 0.0


## Uses whatever is in the selected hotbar slot.
func use_selected() -> bool:
	var inventory := _inventory()
	if inventory == null:
		return false
	var ids: Array[StringName] = inventory.hotbar_ids()
	if selected_slot < 0 or selected_slot >= ids.size() or ids[selected_slot] == &"":
		return false
	return use_item(ids[selected_slot])


## True when one unit was consumed and its effect applied.
func use_item(id: StringName) -> bool:
	if not is_multiplayer_authority():
		return false
	var definition := Lore.get_item(str(id))
	var effect: Dictionary = definition.get("effect", {})
	if effect.is_empty():
		return false
	var inventory := _inventory()
	var stats := _stats()
	if inventory == null or stats == null or inventory.count_item(id) < 1:
		return false
	if bool(stats.call(&"is_dead")):
		return false
	if _cooldown_left > 0.0:
		return false
	var refusal := _pointless(effect, stats)
	if not refusal.is_empty():
		EventBus.toast_requested.emit(refusal)
		return false

	var potency := 1.0 + _modifier("potion_potency")
	if effect.has("heal"):
		stats.call(&"heal", float(effect["heal"]) * potency)
	if effect.has("stamina"):
		var gained := float(effect["stamina"]) * potency
		stats.stamina = minf(float(stats.stamina) + gained, float(stats.max_stamina))
		EventBus.stamina_changed.emit(stats.stamina, stats.max_stamina)
	if effect.has("regen"):
		var regen: Dictionary = effect["regen"]
		_regen_rate = float(regen.get("per_second", 0.0)) * potency
		_regen_left = float(regen.get("seconds", 0.0))

	inventory.remove_item(id, 1)
	_cooldown_left = float(definition.get("cooldown", 1.0))
	EventBus.item_used.emit(str(id))
	EventBus.toast_requested.emit("Used %s." % Lore.item_display_name(str(id)))
	return true


## Why using this now would be a waste, or "" when it would do something.
func _pointless(effect: Dictionary, stats: Node) -> String:
	var only_heals := effect.has("heal") and not effect.has("stamina") and not effect.has("regen")
	if only_heals and float(stats.hp) >= float(stats.max_hp):
		return "Already at full health."
	var only_stamina := effect.has("stamina") and not effect.has("heal") and not effect.has("regen")
	if only_stamina and float(stats.stamina) >= float(stats.max_stamina):
		return "Stamina is already full."
	return ""


func _stop_regen() -> void:
	_regen_left = 0.0
	_regen_rate = 0.0


func _modifier(stat: String) -> float:
	var parent := get_parent()
	var skills := parent.get_node_or_null("SkillSystem") as SkillSystem if parent != null else null
	return skills.get_modifier(stat) if skills != null else 0.0


func _ui_blocking() -> bool:
	var parent := get_parent()
	return parent != null and "ui_blocking" in parent and bool(parent.get("ui_blocking"))


func _inventory() -> Node:
	var parent := get_parent()
	return parent.get_node_or_null("InventorySystem") if parent != null else null


func _stats() -> Node:
	var parent := get_parent()
	return parent.get_node_or_null("Stats") if parent != null else null
