class_name InventorySystem
extends Node
## 6x8 player inventory: 48 slots of `{id: StringName, count: int}`, empty
## slots are `{}`. Owns stacking, hotbar lookup and the save shape; the UI in
## phase 6 only calls this API and listens on `EventBus`.
##
## The inventory never rejects an id that has no `Lore` entry — accepting it is
## safer than losing loot to a typo — but it warns once so data mistakes surface.

const MAX_STACK := 64
const SLOT_COUNT: int = Game.INVENTORY_COLS * Game.INVENTORY_ROWS
## Replication cadence ceiling for the owner's inventory report (10 Hz). The
## window is a trailing debounce: the last change inside it is still sent.
const SYNC_INTERVAL := 0.1

## Empty slots are `{}`; a filled slot is always `{id: StringName, count: int}`.
var slots: Array[Dictionary] = []

var _warned_unknown: Dictionary = {}
var _sync_pending := false
var _sync_left := 0.0


## Slots exist before `_ready`, so tests and tools can use `new()` directly;
## `_ready` re-runs the (idempotent) fill for scene-instantiated components.
func _init() -> void:
	_ensure_slots()


func _ready() -> void:
	_ensure_slots()
	# Only the owning peer reports its inventory, and only inside a network
	# session. A replicated copy of this component stays a passive node: nothing
	# ever writes to it, so it never emits into the local UI.
	if Network.mode == Network.OFFLINE or not is_multiplayer_authority():
		set_process(false)
		return
	EventBus.inventory_changed.connect(_on_sync_requested)


## Flushes the pending inventory report once the debounce window closes.
func _process(delta: float) -> void:
	if not _sync_pending:
		return
	_sync_left -= delta
	if _sync_left > 0.0:
		return
	_flush_sync()


func _on_sync_requested() -> void:
	if _sync_pending:
		return
	_sync_pending = true
	_sync_left = SYNC_INTERVAL


func _flush_sync() -> void:
	_sync_pending = false
	_sync_left = 0.0
	var main := get_tree().get_first_node_in_group(&"main")
	if main == null or not main.has_method(&"report_inventory"):
		return
	main.call(&"report_inventory", to_sync_payload())


## Slot-by-slot wire shape of this inventory: `SLOT_COUNT` entries, `{}` for an
## empty slot and `{id, count}` for a filled one. `Main` validates it on the
## server before it becomes a peer's mirror.
func to_sync_payload() -> Array:
	_ensure_slots()
	var payload: Array = []
	for index: int in SLOT_COUNT:
		var slot: Dictionary = slots[index]
		if slot.is_empty():
			payload.append({})
		else:
			payload.append({
				"id": StringName(slot.get("id", &"")),
				"count": int(slot.get("count", 0)),
			})
	return payload


## Adds up to `count` items and returns the leftover that did not fit (0 when
## everything was accepted). Partial stacks fill first, then empty slots.
func add_item(id: StringName, count: int) -> int:
	_ensure_slots()
	if id == &"" or count <= 0:
		return 0
	_warn_unknown(id)

	var limit := max_stack(id)
	var remaining := count
	var hotbar_touched := false

	for index: int in SLOT_COUNT:
		if remaining <= 0:
			break
		var slot: Dictionary = slots[index]
		if slot.is_empty() or StringName(slot.get("id", &"")) != id:
			continue
		var space := limit - int(slot.get("count", 0))
		if space <= 0:
			continue
		var moved := mini(space, remaining)
		slots[index] = {"id": id, "count": int(slot["count"]) + moved}
		remaining -= moved
		hotbar_touched = hotbar_touched or index < Game.HOTBAR_SLOTS
		EventBus.item_added.emit(String(id), moved)

	for index: int in SLOT_COUNT:
		if remaining <= 0:
			break
		if not (slots[index] as Dictionary).is_empty():
			continue
		var moved := mini(limit, remaining)
		slots[index] = {"id": id, "count": moved}
		remaining -= moved
		hotbar_touched = hotbar_touched or index < Game.HOTBAR_SLOTS
		EventBus.item_added.emit(String(id), moved)

	if remaining < count:
		EventBus.inventory_changed.emit()
		if hotbar_touched:
			EventBus.hotbar_changed.emit()
	return remaining


## Removes up to `count` items, last slot first, and returns how many were
## actually removed.
func remove_item(id: StringName, count: int) -> int:
	_ensure_slots()
	if id == &"" or count <= 0:
		return 0

	var remaining := count
	var hotbar_touched := false
	for index in range(SLOT_COUNT - 1, -1, -1):
		if remaining <= 0:
			break
		var slot: Dictionary = slots[index]
		if slot.is_empty() or StringName(slot.get("id", &"")) != id:
			continue
		var available := int(slot.get("count", 0))
		var taken := mini(available, remaining)
		if taken <= 0:
			continue
		if taken >= available:
			slots[index] = {}
		else:
			slots[index] = {"id": id, "count": available - taken}
		remaining -= taken
		hotbar_touched = hotbar_touched or index < Game.HOTBAR_SLOTS
		EventBus.item_removed.emit(String(id), taken)

	var removed := count - remaining
	if removed > 0:
		EventBus.inventory_changed.emit()
		if hotbar_touched:
			EventBus.hotbar_changed.emit()
	return removed


func count_item(id: StringName) -> int:
	_ensure_slots()
	var total := 0
	for slot: Dictionary in slots:
		if not slot.is_empty() and StringName(slot.get("id", &"")) == id:
			total += int(slot.get("count", 0))
	return total


func has_item(id: StringName, count: int) -> bool:
	if count <= 0:
		return true
	return count_item(id) >= count


## True when no slot can accept another item, whatever its id.
func is_full() -> bool:
	_ensure_slots()
	for slot: Dictionary in slots:
		if slot.is_empty():
			return false
		if int(slot.get("count", 0)) < max_stack(StringName(slot.get("id", &""))):
			return false
	return true


## Copy of one slot; out-of-range indices read as an empty slot.
func get_slot(index: int) -> Dictionary:
	_ensure_slots()
	if index < 0 or index >= SLOT_COUNT:
		return {}
	return (slots[index] as Dictionary).duplicate()


func set_slot(index: int, id: StringName, count: int) -> void:
	_ensure_slots()
	if index < 0 or index >= SLOT_COUNT:
		return
	if id == &"" or count <= 0:
		clear_slot(index)
		return
	_warn_unknown(id)
	slots[index] = {"id": id, "count": mini(count, max_stack(id))}
	_changed(index)


func clear_slot(index: int) -> void:
	_ensure_slots()
	if index < 0 or index >= SLOT_COUNT or (slots[index] as Dictionary).is_empty():
		return
	slots[index] = {}
	_changed(index)


## Drag/drop primitive for the phase-6 inventory panel.
func swap_slots(a: int, b: int) -> void:
	_ensure_slots()
	if a == b or a < 0 or b < 0 or a >= SLOT_COUNT or b >= SLOT_COUNT:
		return
	var first: Dictionary = slots[a]
	slots[a] = slots[b]
	slots[b] = first
	EventBus.inventory_changed.emit()
	if a < Game.HOTBAR_SLOTS or b < Game.HOTBAR_SLOTS:
		EventBus.hotbar_changed.emit()


## Reorders every occupied stack by rarity and then name, compacting the gaps.
## Called by the satchel's Sort button; the hotbar follows the first eight slots.
func sort_slots() -> void:
	_ensure_slots()
	var entries: Array[Dictionary] = []
	for slot: Dictionary in slots:
		if not slot.is_empty():
			entries.append(slot.duplicate())
	entries.sort_custom(_sort_entry)
	for index: int in SLOT_COUNT:
		slots[index] = entries[index].duplicate() if index < entries.size() else {}
	EventBus.inventory_changed.emit()
	EventBus.hotbar_changed.emit()


func _sort_entry(a: Dictionary, b: Dictionary) -> bool:
	var id_a := StringName(a.get("id", &""))
	var id_b := StringName(b.get("id", &""))
	var rank_a := _sort_rank(id_a)
	var rank_b := _sort_rank(id_b)
	if rank_a != rank_b:
		return rank_a < rank_b
	var name_a := Lore.item_display_name(str(id_a)).to_lower()
	var name_b := Lore.item_display_name(str(id_b)).to_lower()
	if name_a != name_b:
		return name_a < name_b
	return String(id_a) < String(id_b)


func _sort_rank(id: StringName) -> int:
	var rarity := Lore.item_rarity(str(id))
	if not rarity.is_empty():
		return Lore.rarity_rank(rarity)
	if Lore.RESOURCES.has(str(id)):
		return 20
	return 40


## First `Game.HOTBAR_SLOTS` slot ids in order, `&""` for gaps.
func hotbar_ids() -> Array[StringName]:
	_ensure_slots()
	var ids: Array[StringName] = []
	for index: int in Game.HOTBAR_SLOTS:
		var slot: Dictionary = slots[index]
		ids.append(&"" if slot.is_empty() else StringName(slot.get("id", &"")))
	return ids


## Removes one item (or the whole stack) and returns what should hit the ground
## as `{id, count}`. An empty slot drops nothing.
func drop_slot(index: int, drop_all := false) -> Dictionary:
	_ensure_slots()
	if index < 0 or index >= SLOT_COUNT:
		return {}
	var slot: Dictionary = slots[index]
	if slot.is_empty():
		return {}
	var id := StringName(slot.get("id", &""))
	var held := int(slot.get("count", 0))
	var dropped := held if drop_all else 1
	slots[index] = {} if dropped >= held else {"id": id, "count": held - dropped}
	EventBus.item_removed.emit(String(id), dropped)
	_changed(index)
	return {"id": id, "count": dropped}


## Eats one mushroom or drinks one potion from `index`. Consumes exactly one
## item and applies its `Lore` effect to the body's `Stats`; returns false (and
## changes nothing) for an empty slot, a resource, an unknown id, or a body
## without stats. Toxicity is charged as a one-off HP loss after the effect,
## through the normal damage path so it can kill.
func use_slot(index: int) -> bool:
	_ensure_slots()
	if index < 0 or index >= SLOT_COUNT:
		return false
	var slot: Dictionary = slots[index]
	if slot.is_empty() or int(slot.get("count", 0)) <= 0:
		return false
	var id := StringName(slot.get("id", &""))
	var stats := _stats()
	if stats == null or bool(stats.call(&"is_dead")):
		return false

	var mushroom := Lore.get_mushroom(str(id))
	var potion := Lore.get_potion(str(id))
	var effect: Dictionary
	var message: String
	if not mushroom.is_empty():
		effect = mushroom.get("eat", {})
		message = "You eat %s" % Lore.item_display_name(str(id))
	elif not potion.is_empty():
		effect = potion.get("effect", {})
		message = "You drink %s" % Lore.item_display_name(str(id))
	else:
		EventBus.toast_requested.emit(
			"%s is not edible" % Lore.item_display_name(str(id))
		)
		return false

	_consume_one(index, id)
	stats.call(&"apply_effect", effect)
	var toxicity := int(mushroom.get("toxicity", 0))
	if toxicity > 0:
		stats.call(&"take_damage", float(toxicity))
		message += "  ·  toxic"
	EventBus.toast_requested.emit(message)
	return true


## Removes exactly one item from `index`, keeping the rest of the stack in place.
func _consume_one(index: int, id: StringName) -> void:
	var held := int((slots[index] as Dictionary).get("count", 0))
	slots[index] = {} if held <= 1 else {"id": id, "count": held - 1}
	EventBus.item_removed.emit(String(id), 1)
	_changed(index)


## The body's vitals component. `use_slot` needs one to apply an effect to; a
## standalone inventory (tooling, tests) simply refuses to consume.
func _stats() -> Node:
	var body := get_parent()
	if body == null:
		return null
	var stats := body.get_node_or_null("Stats")
	if stats != null and stats.has_method(&"apply_effect"):
		return stats
	return null


## Compact save shape: only occupied slots, as `{"slots": {"0": [id, count]}}`.
func to_dict() -> Dictionary:
	_ensure_slots()
	var packed := {}
	for index: int in SLOT_COUNT:
		var slot: Dictionary = slots[index]
		if slot.is_empty():
			continue
		packed[str(index)] = [String(slot.get("id", &"")), int(slot.get("count", 0))]
	return {"slots": packed}


## Replaces the whole inventory from `to_dict()`. Malformed entries are skipped.
func from_dict(data: Dictionary) -> void:
	_ensure_slots()
	for index: int in SLOT_COUNT:
		slots[index] = {}
	var packed: Variant = data.get("slots", {})
	if packed is Dictionary:
		for key: Variant in packed:
			var key_text := str(key)
			if not key_text.is_valid_int():
				continue
			var index := key_text.to_int()
			if index < 0 or index >= SLOT_COUNT:
				continue
			var entry: Variant = (packed as Dictionary)[key]
			if not (entry is Array) or (entry as Array).size() < 2:
				continue
			var id := StringName(str(entry[0]))
			var count := int(entry[1])
			if id == &"" or count <= 0:
				continue
			slots[index] = {"id": id, "count": mini(count, max_stack(id))}
	EventBus.inventory_changed.emit()
	EventBus.hotbar_changed.emit()


## Stack size for an id. `Lore` may override `MAX_STACK` with `stack_size`.
func max_stack(id: StringName) -> int:
	var limit := int(Lore.get_mushroom(str(id)).get("stack_size", MAX_STACK))
	return maxi(limit, 1)


func _ensure_slots() -> void:
	if slots.size() == SLOT_COUNT:
		return
	slots.clear()
	for _index: int in SLOT_COUNT:
		slots.append({})


func _changed(index: int) -> void:
	EventBus.inventory_changed.emit()
	if index < Game.HOTBAR_SLOTS:
		EventBus.hotbar_changed.emit()


func _warn_unknown(id: StringName) -> void:
	if Lore.is_mushroom(str(id)) or Lore.is_potion(str(id)) or Lore.RESOURCES.has(str(id)):
		return
	if _warned_unknown.has(id):
		return
	_warned_unknown[id] = true
	push_warning("InventorySystem: unknown item id '%s' accepted without a Lore entry." % id)
