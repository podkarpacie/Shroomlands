class_name LootChest
extends StaticBody3D
## A one-shot reward container in a forest structure. Opening it puts `loot`
## into the player's inventory and `gold` into their purse, then shows an empty
## chest. Nothing is generated here: `LayeredForest` decides the contents by
## depth layer.

@export var loot: Array[String] = []
@export var gold := 0

var opened := false

@onready var _lid: MeshInstance3D = $Lid


func _ready() -> void:
	add_to_group(&"interactable")


func get_interaction_text() -> String:
	return "Empty chest" if opened else "Open chest  [E]"


func interact(player: Node) -> void:
	if opened or player == null:
		return
	opened = true
	var inventory := player.get_node_or_null("InventorySystem")
	var given := 0
	for id: String in loot:
		if inventory != null:
			given += int(inventory.call(&"add_item", StringName(id), 1))
	if gold > 0:
		Game.add_run_gold(gold)
	EventBus.toast_requested.emit("Chest: %d item(s), %d gold" % [given, gold])
	_open_lid()


## Visual only: the reward is already applied, so a missing tween target cannot
## lose it.
func _open_lid() -> void:
	if _lid == null:
		return
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_lid, "rotation:x", -1.15, 0.35).set_trans(Tween.TRANS_BACK)
	tween.tween_property(_lid, "position:y", 0.92, 0.35)
