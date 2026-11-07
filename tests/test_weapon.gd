extends SceneTree
## Headless weapon test: the club is a real inventory item. It starts equipped,
## can be unequipped/dropped, changes combat damage, survives save/load, and the
## old-save migration gives a club to a player who predates weapons.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const TestEnv := preload("res://tests/test_env.gd")
const INVENTORY_SCRIPT := "res://scripts/systems/InventorySystem.gd"
const ITEM_VISUALS_SCRIPT := "res://scripts/ui/ItemVisuals.gd"
const CLUB := &"mycelium_club"

var _failures := 0


func _initialize() -> void:
	TestEnv.isolate("test_weapon")
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
	await _wait(30)
	var player := get_first_node_in_group(&"player") as Node3D
	_check("a player was spawned", player != null)
	if player == null:
		_finish()
		return
	var inventory := player.get_node_or_null("InventorySystem")
	var combat := player.get_node_or_null("CombatSystem")
	_check("the player has InventorySystem and CombatSystem",
		inventory != null and combat != null)
	if inventory == null or combat == null:
		_finish()
		return

	_check("the starting club is carried (%d)" % int(inventory.call(&"count_item", CLUB)),
		int(inventory.call(&"count_item", CLUB)) == 1)
	_check("the starting club is equipped (%s)" % inventory.get(&"equipped_weapon"),
		str(inventory.get(&"equipped_weapon")) == "mycelium_club")
	var slot := _slot_of(inventory, CLUB)
	_check("the club occupies one slot (%d)" % slot, slot >= 0)
	var club := player.get_node_or_null("Weapon/Club") as Node3D
	_check("the right hand shows the club", club != null and club.visible)
	_check("the armed light damage is 12 (%.1f)" % float(combat.call(&"current_attack_damage", false)),
		is_equal_approx(float(combat.call(&"current_attack_damage", false)), 12.0))
	_check("the armed heavy damage is 22 (%.1f)" % float(combat.call(&"current_attack_damage", true)),
		is_equal_approx(float(combat.call(&"current_attack_damage", true)), 22.0))

	# --- unequip / equip through the satchel path ------------------------
	_check("double-click unequips the club", bool(inventory.call(&"use_slot", slot)))
	await _wait(3)
	_check("nothing is equipped", str(inventory.get(&"equipped_weapon")) == "")
	_check("the hand is empty", club == null or not club.visible)
	_check("bare hands hit for 4 (%.1f)" % float(combat.call(&"current_attack_damage", false)),
		is_equal_approx(float(combat.call(&"current_attack_damage", false)), 4.0))
	_check("bare-handed heavy hits for 7 (%.1f)" % float(combat.call(&"current_attack_damage", true)),
		is_equal_approx(float(combat.call(&"current_attack_damage", true)), 7.0))
	_check("double-click re-equips the club", bool(inventory.call(&"use_slot", slot)))
	await _wait(3)
	_check("the club is equipped again", str(inventory.get(&"equipped_weapon")) == "mycelium_club")
	_check("the hand shows it again", club != null and club.visible)

	# --- dropping the item empties the hand ------------------------------
	var dropped: Dictionary = inventory.call(&"drop_slot", slot, true)
	_check("the club can be dropped (%s)" % dropped.get("id", ""),
		str(dropped.get("id", "")) == "mycelium_club")
	_check("the club is gone", int(inventory.call(&"count_item", CLUB)) == 0)
	_check("dropping it unequips it", str(inventory.get(&"equipped_weapon")) == "")
	await _wait(3)
	_check("the hand is empty after the drop", club == null or not club.visible)

	# --- save shape and old-save migration -------------------------------
	inventory.call(&"add_item", CLUB, 1)
	_check("the club can be picked up again", bool(inventory.call(&"equip_weapon", CLUB)))
	var data: Dictionary = inventory.call(&"to_dict")
	_check("the save records the equipped weapon (%s)" % data.get("weapon", ""),
		str(data.get("weapon", "")) == "mycelium_club")
	var inventory_script := load(INVENTORY_SCRIPT) as GDScript
	var loaded = inventory_script.new()
	loaded.call(&"from_dict", data)
	_check("loading restores the equip", str(loaded.get(&"equipped_weapon")) == "mycelium_club")

	var old = inventory_script.new()
	old.call(&"from_dict", {"slots": {"0": ["mycelium_club", 1]}})
	_check("an old save has no weapon state", str(old.get(&"equipped_weapon")) == "")
	old.call(&"ensure_starting_weapon")
	_check("the migration equips the carried club", str(old.get(&"equipped_weapon")) == "mycelium_club")

	# --- icon/preview art exists -----------------------------------------
	var visuals := load(ITEM_VISUALS_SCRIPT) as GDScript
	_check("the club is an item visual", bool(visuals.all_ids().has("mycelium_club")))
	var model = visuals.build_model("mycelium_club", 1.15)
	_check("the club builds a preview model", model != null)
	_check("the club is typed as a weapon (%s)" % str(visuals.call(&"kind", "mycelium_club")),
		str(visuals.call(&"kind", "mycelium_club")) == "Weapon")
	_check("the club has its real description (%s)" % str(visuals.call(&"description", "mycelium_club")).substr(0, 24),
		str(visuals.call(&"description", "mycelium_club")).contains("knotted club"))
	_finish()


func _slot_of(inventory: Node, id: StringName) -> int:
	var slots: Array = inventory.get(&"slots")
	for index in slots.size():
		var slot: Dictionary = slots[index]
		if not slot.is_empty() and StringName(slot.get("id", &"")) == id:
			return index
	return -1


func _wait(frames: int) -> void:
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
		print("PASSED  all weapon assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
