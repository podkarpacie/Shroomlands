extends Node3D
## The item in the selected hotbar slot, held in the left hand.
##
## The glTF character has no skeleton, so — like `SwingWeapon` — this node is a
## sibling of the model. Every frame it takes the *position* from `hand_l` and the
## *orientation* from the body's facing yaw alone: `LimbAnimator` pitches forward
## and rolls that arm outward to carry a prop, and inheriting the hand's basis used
## to lay the mushroom flat on its side. The owner resolves its own selection
## through `InventorySystem` and writes the id to the replicated `held_item` on the
## player root; every other peer only renders that value. That is deliberate: a
## remote inventory is never applied to a local `InventorySystem`, so a peer must
## not try to resolve another player's slot.
##
## Only `glowcap` and `emberstem` ship a model. Any other id keeps the
## authoritative `held_item` value and draws nothing — a missing model is not a
## reason to build a placeholder mushroom.

const HAND_NAME := &"hand_l"
## Held ids with a model. A mushroom without one is simply absent here.
const MODELS := {
	&"glowcap": "res://assets/models/glowcap.gltf",
	&"emberstem": "res://assets/models/emberstem.gltf",
}
## Height of the prop in metres. The source models are 0.57 m and 0.74 m tall,
## so both are normalised to a hand-sized mushroom instead of dwarfing the body.
const HELD_HEIGHT := 0.22
## The hand mesh's origin is its Blockbench min corner, so this offset puts the
## prop's base just above the middle of the fist and on its outer side. Local to
## `hand_l`, in metres.
const HAND_GRIP := Vector3(0.02, 0.105, 0.09)
## Lean the upright prop away from the torso (-X, the left side) and a touch
## forward (-Z), a few degrees so it does not look mechanically perfect. Applied
## in the body's yaw frame, never in the hand's.
const GRIP_TILT := Vector3(-0.05, 0.0, 0.10)

@export var player_path: NodePath = ^".."

## Slot the local HUD has selected. Only the owner reads it.
var _selected := 0
var _player: Node = null
var _inventory: Node = null
var _hand: Node3D = null
## The `Model` node: the character's facing lives there, not on the body, which
## never turns.
var _model: Node3D = null
## id -> cached visual. Built once per id, then only shown or hidden.
var _visuals := {}
var _shown: StringName = &""


func _ready() -> void:
	_player = get_node_or_null(player_path)
	_hand = _find_hand()
	if _player != null:
		_model = _player.get_node_or_null(^"Model") as Node3D
	if _player == null or _hand == null:
		# A model without `hand_l` still plays; there is nowhere to hold a prop.
		visible = false
		set_process(false)
		return
	_inventory = _player.get_node_or_null("InventorySystem")
	if not is_multiplayer_authority():
		# A replicated body renders `held_item` and never writes it.
		return
	if is_instance_valid(EventBus):
		EventBus.hotbar_selected.connect(_on_hotbar_selected)
		EventBus.inventory_changed.connect(_on_inventory_changed)
	# A HUD that was ready before this body spawned already emitted its
	# selection; slot 0 is the default either way.
	_refresh()


func _exit_tree() -> void:
	if not is_instance_valid(EventBus):
		return
	if EventBus.hotbar_selected.is_connected(_on_hotbar_selected):
		EventBus.hotbar_selected.disconnect(_on_hotbar_selected)
	if EventBus.inventory_changed.is_connected(_on_inventory_changed):
		EventBus.inventory_changed.disconnect(_on_inventory_changed)


func _process(_delta: float) -> void:
	if not is_instance_valid(_player) or not is_instance_valid(_hand):
		# The body or its hand is gone: nothing left to carry the prop.
		visible = false
		set_process(false)
		return
	# The replicated value is the only source of truth for what to draw, so a
	# remote peer and the owner go through the same path.
	var id := StringName(_player.get(&"held_item"))
	if id != _shown:
		_show(id)
	# Position from the hand, so the prop rides in the fist as the arm swings;
	# orientation from the body's yaw, so the carry pose cannot tip it over.
	global_transform = Transform3D(_upright_basis(), _hand.global_transform * HAND_GRIP)


## World basis the prop is drawn with: the body's facing yaw plus a fixed lean.
## The arm's pitch and roll are deliberately dropped — they are a carry pose, not
## the item's orientation.
func _upright_basis() -> Basis:
	var yaw := 0.0
	if is_instance_valid(_model):
		yaw = _model.global_rotation.y
	else:
		var body := _player as Node3D
		if body != null:
			yaw = body.global_rotation.y
	return Basis(Vector3.UP, yaw) * Basis.from_euler(GRIP_TILT)


## Owner only: the id in the selected slot. Emits nothing itself; the write to
## `held_item` is what reaches the other peers.
func _refresh() -> void:
	if _inventory == null or not _inventory.has_method(&"get_slot"):
		return
	var slot: Dictionary = _inventory.call(&"get_slot", _selected)
	var id := StringName(slot.get("id", &"")) if int(slot.get("count", 0)) > 0 else &""
	_player.set(&"held_item", id)


func _on_hotbar_selected(index: int) -> void:
	_selected = index
	_refresh()


func _on_inventory_changed() -> void:
	_refresh()


## Shows the visual for `id` and hides the rest. Instances stay cached, so
## selecting back and forth never reloads a model or leaves one behind.
func _show(id: StringName) -> void:
	_shown = id
	for key: StringName in _visuals:
		(_visuals[key] as Node3D).visible = key == id
	if id == &"" or not MODELS.has(id):
		return
	var visual := _visual_for(id)
	if visual != null:
		visual.visible = true


func _visual_for(id: StringName) -> Node3D:
	if _visuals.has(id):
		return _visuals[id] as Node3D
	var packed := load(String(MODELS[id])) as PackedScene
	if packed == null:
		return null
	var model := packed.instantiate() as Node3D
	if model == null:
		return null
	var visual := Node3D.new()
	visual.name = "Held%s" % String(id).capitalize()
	add_child(visual)
	visual.add_child(model)

	# The models stand on their own y = 0 with a blocky base offset, so the
	# wrapper normalises them once: bottom of the stem on the grip point, body
	# centred on it, scaled to `HELD_HEIGHT`.
	var bounds := _model_bounds(model)
	var height := maxf(bounds.size.y, 0.001)
	var scale_factor := HELD_HEIGHT / height
	visual.scale = Vector3.ONE * scale_factor
	model.position = Vector3(-bounds.get_center().x, -bounds.position.y, -bounds.get_center().z)

	# A 22 cm prop under a metre from the sun's soft-shadow penumbra resolves as
	# a salt-and-pepper dither instead of a soft blob, exactly like the club, so
	# it casts nothing and the body's own shadow carries the ground contact.
	for node: Node in model.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_visuals[id] = visual
	return visual


## Bounds of every mesh below `model`, in `model`'s own space.
func _model_bounds(model: Node3D) -> AABB:
	var to_model := model.global_transform.affine_inverse()
	var result := AABB()
	var first := true
	for node: Node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var box := to_model * (mesh.global_transform * mesh.get_aabb())
		result = box if first else result.merge(box)
		first = false
	return result


func _find_hand() -> Node3D:
	var parent := get_parent()
	if parent == null:
		return null
	var visual := parent.get_node_or_null("Model/Visual") as Node3D
	if visual == null:
		return null
	return visual.find_child(String(HAND_NAME), true, false) as Node3D
