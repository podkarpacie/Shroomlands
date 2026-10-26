extends CanvasLayer
## Simple plot building: `build_toggle` (B) enters, a translucent ghost snaps to
## the 1 m grid under the cursor, LMB places the selected palette object.
##
## The player keeps walking but stops attacking: the controller has a separate
## `build_mode` flag, because `ui_blocking` would also freeze movement. Plot
## ownership, affordability and cell validity all come from PlotSystem; this
## script only owns the ghost, the palette and the input routing.

const GROUND_MASK := 1
const RAY_LENGTH := 200.0
## Palette order; costs come from PlotSystem (`get_object_cost`).
const ITEM_IDS: Array[StringName] = [&"hut", &"farm", &"workshop", &"chest"]
const DEFAULT_ITEM := &"hut"
## Test/capture seam: aim the ghost at a fixed world point instead of the mouse.
var aim_override := Vector3.ZERO
var has_aim_override := false

const PALETTE := {
	"panel": Color(0.04, 0.05, 0.04, 0.94),
	"border": Color(0.38, 0.52, 0.30, 0.80),
	"text": Color(0.92, 0.94, 0.88),
	"dim": Color(0.66, 0.71, 0.60),
	"ok": Color(0.35, 0.95, 0.35, 0.35),
	"bad": Color(0.95, 0.25, 0.20, 0.35),
}

@onready var _palette: PanelContainer = $Root/Palette
@onready var _title: Label = $Root/Palette/Margin/Content/Title
@onready var _items: VBoxContainer = $Root/Palette/Margin/Content/Items
@onready var _hint: Label = $Root/Palette/Margin/Content/Hint

var _active := false
var _player: Node = null
var _system: Node = null
var _selected: StringName = DEFAULT_ITEM
var _button_group := ButtonGroup.new()
var _ghost: MeshInstance3D = null
var _ghost_material: StandardMaterial3D = null
var _target_plot := -1
var _target_cell := Vector3i.ZERO
var _target_ok := false


func _ready() -> void:
	_palette.visible = false
	_style()
	_build_palette()
	_build_ghost()


func _exit_tree() -> void:
	_clear_ghost()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"build_toggle"):
		_bind_player()
		if _player != null and bool(_player.get(&"ui_blocking")):
			return
		set_active(not _active)
		get_viewport().set_input_as_handled()
		return
	if not _active:
		return
	if event.is_action_pressed(&"ui_cancel"):
		set_active(false)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			_try_place()
			get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not _active:
		return
	_refresh_target()


## Public toggle used by B/Esc and by the capture harness.
func set_active(value: bool) -> void:
	if _active == value:
		return
	_active = value
	_palette.visible = value
	_bind_player()
	if _player != null and _player.has_method(&"set_build_mode"):
		_player.call(&"set_build_mode", value)
	if value:
		if DisplayServer.has_feature(DisplayServer.FEATURE_MOUSE):
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_refresh_target()
	else:
		_set_ghost_visible(false)
		if DisplayServer.has_feature(DisplayServer.FEATURE_MOUSE):
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func is_active() -> bool:
	return _active


func _build_palette() -> void:
	for item: StringName in ITEM_IDS:
		var button := Button.new()
		button.name = "Item_%s" % String(item)
		button.toggle_mode = true
		button.button_group = _button_group
		button.button_pressed = item == _selected
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.text = "%s · %d g" % [String(item).capitalize(), _cost(item)]
		button.pressed.connect(_select_item.bind(item))
		_items.add_child(button)


func _select_item(item: StringName) -> void:
	_selected = item
	if _ghost != null:
		_ghost.mesh = _box(_size(item))
	_refresh_target()


func _build_ghost() -> void:
	_ghost = MeshInstance3D.new()
	_ghost.name = "BuildGhost"
	_ghost.mesh = _box(_size(_selected))
	_ghost.visible = false
	_ghost_material = StandardMaterial3D.new()
	_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ghost_material.albedo_color = PALETTE["ok"]
	_ghost.material_override = _ghost_material
	# Parented to this layer, not to Main: `_ready` runs while the scene is still
	# setting up its children, and a Node3D under a CanvasLayer still joins the
	# viewport's World3D.
	add_child(_ghost)


func _refresh_target() -> void:
	var system := _plot_system()
	if system == null or _ghost == null:
		_set_ghost_visible(false)
		return
	var point := Vector3.ZERO
	if has_aim_override:
		point = aim_override
	else:
		var camera := get_viewport().get_camera_3d()
		if camera == null:
			_set_ghost_visible(false)
			return
		var mouse := get_viewport().get_mouse_position()
		var from := camera.project_ray_origin(mouse)
		var to := from + camera.project_ray_normal(mouse) * RAY_LENGTH
		var query := PhysicsRayQueryParameters3D.create(from, to, GROUND_MASK)
		var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty():
			_set_ghost_visible(false)
			return
		point = hit["position"]

	var cell := Vector3i(roundi(point.x), 0, roundi(point.z))
	var snapped := Vector3(float(cell.x), 0.0, float(cell.z))
	_target_cell = cell
	_target_plot = int(system.call(&"plot_at", snapped))
	var owned := false
	if _target_plot >= 0:
		owned = bool(system.call(&"is_owned_by", _target_plot, system.call(&"local_owner_id")))
	var free := _target_plot >= 0 and bool(system.call(&"can_place", _target_plot, cell))
	_target_ok = owned and free and Game.gold >= _cost(_selected)

	_ghost.position = Vector3(float(cell.x), _size(_selected).y * 0.5, float(cell.z))
	_set_ghost_visible(true)
	_ghost_material.albedo_color = PALETTE["ok"] if _target_ok else PALETTE["bad"]


func _try_place() -> void:
	if not _target_ok or _system == null:
		return
	var placed := bool(_system.call(&"place_object", _target_plot, _selected, _target_cell))
	if not placed:
		if Game.gold < _cost(_selected):
			EventBus.toast_requested.emit("Not enough gold")
		else:
			EventBus.toast_requested.emit("Cannot place here")
	_refresh_target()


func _set_ghost_visible(value: bool) -> void:
	if _ghost == null:
		return
	_ghost.visible = value


func _clear_ghost() -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null


func _bind_player() -> void:
	if _player != null and is_instance_valid(_player):
		return
	_player = Game.get_local_player()
	if _player == null:
		return
	if _player.has_method(&"set_build_mode"):
		_player.call(&"set_build_mode", _active)


func _plot_system() -> Node:
	if _system != null and is_instance_valid(_system):
		return _system
	_system = get_tree().get_first_node_in_group(&"plot_system")
	return _system


func _cost(item: StringName) -> int:
	var system := _plot_system()
	if system != null and system.has_method(&"get_object_cost"):
		return int(system.call(&"get_object_cost", item))
	return 0


## Placeholder footprints match the meshes PlotSystem instantiates.
func _size(item: StringName) -> Vector3:
	match String(item):
		"hut":
			return Vector3(2.0, 2.0, 2.0)
		"farm":
			return Vector3(3.0, 0.2, 3.0)
		"workshop":
			return Vector3(2.0, 1.5, 2.0)
		"chest":
			return Vector3(1.0, 1.0, 1.0)
	return Vector3.ONE


func _box(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh


func _style() -> void:
	var panel := StyleBoxFlat.new()
	panel.bg_color = PALETTE["panel"]
	panel.border_color = PALETTE["border"]
	panel.set_border_width_all(2)
	panel.set_corner_radius_all(8)
	panel.content_margin_left = 12.0
	panel.content_margin_right = 12.0
	panel.content_margin_top = 10.0
	panel.content_margin_bottom = 10.0
	_palette.add_theme_stylebox_override("panel", panel)
	_title.add_theme_color_override("font_color", PALETTE["text"])
	_title.add_theme_font_size_override("font_size", 16)
	_hint.add_theme_color_override("font_color", PALETTE["dim"])
	_hint.add_theme_font_size_override("font_size", 11)
