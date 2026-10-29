extends SceneTree
## Headless held-item test: the selected hotbar slot decides the id on the player
## root, that id is what every peer renders, and only an id with a model draws
## something in the left hand.
##
## The player scene is instantiated on its own (no `main.tscn`): the item system
## needs an `InventorySystem`, a `HeldItem` and the glTF hands, nothing else. The
## second body is the remote case: it is not the multiplayer authority, so it
## must render the replicated `held_item` and never resolve its own selection.

const PLAYER_SCENE_PATH := "res://scenes/player/player.tscn"
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0


func _initialize() -> void:
	TestEnv.isolate("test_holding")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	var bus: Node = root.get_node_or_null("EventBus")
	_check("the EventBus autoload exists", bus != null)
	if bus == null:
		_finish()
		return
	_check("EventBus declares hotbar_selected", bus.has_signal(&"hotbar_selected"))

	var packed := load(PLAYER_SCENE_PATH) as PackedScene
	_check("player.tscn loads", packed != null)
	if packed == null:
		_finish()
		return
	var player := packed.instantiate() as Node3D
	root.add_child(player)
	await physics_frame
	await process_frame

	var held := player.get_node_or_null("HeldItem")
	var inventory := player.get_node_or_null("InventorySystem")
	# The rigged model's hands are bone nodes, and the held prop hangs off the
	# left one; the club hangs off the right.
	var hand_l := player.find_child("hand_left2", true, false) as Node3D
	var hand_r := player.find_child("hand_right2", true, false) as Node3D
	_check("the player has a HeldItem node", held != null)
	_check("the player has an InventorySystem", inventory != null)
	_check("the model has hand_left2 and hand_right2", hand_l != null and hand_r != null)
	if held == null or inventory == null or hand_l == null or hand_r == null:
		_finish()
		return

	# --- Konop: a model that exists ---------------------------------------
	inventory.call(&"set_slot", 0, &"konop", 2)
	bus.emit_signal(&"hotbar_selected", 0)
	await process_frame
	_check(
		"selecting a Konop slot sets held_item to Konop (%s)" % _held(player),
		_held(player) == &"konop"
	)
	var visible := _visible_visuals(held)
	_check("the Konop has exactly one held visual (%d)" % visible.size(), visible.size() == 1)
	if visible.size() == 1:
		var visual := visible[0] as Node3D
		var box := _world_bounds(visual)
		_check(
			"the held Konop is hand-sized (%.2f m tall)" % box.size.y,
			box.size.y > 0.15 and box.size.y < 0.30
		)
		var centre := box.get_center()
		var to_left := centre.distance_to(hand_l.global_position)
		var to_right := centre.distance_to(hand_r.global_position)
		_check(
			"the visual sits in the left hand (%.2f m vs %.2f m to the right)" % [to_left, to_right],
			to_left < to_right and to_left < 0.30
		)

	# --- an empty slot clears it --------------------------------------------
	bus.emit_signal(&"hotbar_selected", 3)
	await process_frame
	_check("selecting an empty slot clears held_item (%s)" % _held(player), _held(player) == &"")
	_check("an empty slot shows no held visual", _visible_visuals(held).is_empty())

	# --- Shitake: the model swaps instead of stacking ---------------------
	inventory.call(&"set_slot", 1, &"shitake", 1)
	bus.emit_signal(&"hotbar_selected", 1)
	await process_frame
	_check(
		"switching to Shitake sets held_item (%s)" % _held(player),
		_held(player) == &"shitake"
	)
	var swapped := _visible_visuals(held)
	_check("Shitake shows exactly one visual (%d)" % swapped.size(), swapped.size() == 1)
	_check(
		"the cached Konop is hidden, not stacked (%d child, %d visible)" % [
			held.get_child_count(), swapped.size()
		],
		held.get_child_count() == 2
	)
	if swapped.size() == 1:
		_check(
			"the visible visual is the Shitake model (%s)" % String(swapped[0].name),
			String(swapped[0].name).contains("Shitake")
		)
		var konop_visual := held.get_node_or_null("HeldKonop") as Node3D
		_check(
			"the Konop visual is cached but hidden",
			konop_visual != null and not konop_visual.visible
		)

	# --- ghostcap: a mushroom without a model ------------------------------
	inventory.call(&"set_slot", 2, &"ghostcap", 1)
	bus.emit_signal(&"hotbar_selected", 2)
	await process_frame
	_check(
		"a model-less mushroom still sets held_item (%s)" % _held(player),
		_held(player) == &"ghostcap"
	)
	_check("a model-less mushroom draws nothing", _visible_visuals(held).is_empty())

	# --- a potion: no model of its own, a tinted fallback -------------------
	inventory.call(&"set_slot", 3, &"konop_draught", 1)
	bus.emit_signal(&"hotbar_selected", 3)
	await process_frame
	_check(
		"a potion still sets held_item (%s)" % _held(player),
		_held(player) == &"konop_draught"
	)
	_check(
		"a potion draws one tinted fallback (%d)" % _visible_visuals(held).size(),
		_visible_visuals(held).size() == 1
	)

	# --- the remote body: replicated value only ----------------------------
	var remote := packed.instantiate() as Node3D
	remote.name = "RemotePlayer"
	remote.set_multiplayer_authority(2)
	root.add_child(remote)
	await physics_frame
	var remote_held := remote.get_node_or_null("HeldItem")
	var remote_inventory := remote.get_node_or_null("InventorySystem")
	_check("the remote body has a HeldItem", remote_held != null)
	_check("the remote body is not the authority", not remote.is_multiplayer_authority())
	if remote_held == null or remote_inventory == null:
		_finish()
		return
	remote_inventory.call(&"set_slot", 0, &"konop", 3)
	bus.emit_signal(&"hotbar_selected", 0)
	await process_frame
	_check(
		"a non-authority body does not write held_item from its selection (%s)" % _held(remote),
		_held(remote) == &""
	)
	_check("its own selection draws nothing", _visible_visuals(remote_held).is_empty())

	# A peer only ever receives the id; that value has to render.
	remote.set(&"held_item", &"konop")
	await process_frame
	_check(
		"a replicated held_item renders in the remote hand",
		_visible_visuals(remote_held).size() == 1
	)
	_finish()


func _held(player: Node) -> StringName:
	return StringName(player.get(&"held_item"))


func _visible_visuals(held: Node) -> Array[Node]:
	var found: Array[Node] = []
	for child in held.get_children():
		if child is Node3D and (child as Node3D).is_visible_in_tree():
			found.append(child)
	return found


## World-space bounds of every mesh under `node`.
func _world_bounds(node: Node3D) -> AABB:
	var result := AABB()
	var first := true
	for mesh_node in node.find_children("*", "MeshInstance3D", true, false):
		var mesh := mesh_node as MeshInstance3D
		var box := mesh.global_transform * mesh.get_aabb()
		result = box if first else result.merge(box)
		first = false
	return result


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all held-item assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
