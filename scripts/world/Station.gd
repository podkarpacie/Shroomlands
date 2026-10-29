extends StaticBody3D
## One piece of civic furniture in the town: the shop counter, the alchemy table,
## the repair bench and the plot board all use this scene. The player's
## interaction ray finds the node (group `interactable`, layer 1) and calls
## `interact`, which opens the panel named by `panel_node_name` under `Main`.
##
## The panel owns the rows and the economy; this node only carries the prompt and
## the world model, so adding a station is a scene instance plus its panel.

## Title painted on the floating sign above the counter.
@export var station_title := "Station"
## Verb shown in the HUD prompt.
@export var prompt := "Use"
## Name of the panel CanvasLayer under `Main` this station opens.
@export var panel_node_name: StringName = &"ShopUI"

@onready var _label: Label3D = get_node_or_null(^"Label")


func _ready() -> void:
	add_to_group(&"interactable")
	if _label != null:
		_label.text = station_title


func get_interaction_text() -> String:
	return "%s  [E]" % prompt


func interact(_player: Node) -> void:
	var main := get_tree().get_first_node_in_group(&"main")
	if main == null:
		return
	var panel := main.get_node_or_null(NodePath(String(panel_node_name)))
	if panel == null or not panel.has_method(&"set_open"):
		EventBus.toast_requested.emit("This station is not available")
		return
	panel.call(&"set_open", true)
