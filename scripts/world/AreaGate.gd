extends StaticBody3D
## A two-post gate between areas. The middle is walkable; only the posts and the
## lintel have collision. Interacting asks `Main.enter_area` for `target_scene`,
## which owns the actual swap (and, in a networked session, refuses it for now).

@export var target_scene := "res://scenes/world/verdant_bloom.tscn"
@export var target_label := "Verdant Bloom"
@export var prompt := "Travel to"

@onready var _label: Label3D = get_node_or_null(^"Label")


func _ready() -> void:
	add_to_group(&"interactable")
	if _label != null:
		_label.text = target_label


func get_interaction_text() -> String:
	return "%s %s  [E]" % [prompt, target_label]


func interact(_player: Node) -> void:
	var main := get_tree().get_first_node_in_group(&"main")
	if main == null or not main.has_method(&"enter_area"):
		EventBus.toast_requested.emit("The gate is sealed")
		return
	# `enter_area` reports a refusal itself (networked session, bad path), so a
	# successful call needs no extra toast here.
	main.call(&"enter_area", target_scene)
