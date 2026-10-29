extends Node
## First-person arms for the rigged player.
##
## The rig keeps its hands as plain bone nodes and `SwingWeapon`/`HeldItem` copy
## those bones' world transforms, so the club and the held prop follow whatever
## the wrists do. The authored `idle`/`walk`/`run` clips hang both arms straight
## down, which leaves nothing but the body's sides in a camera parked at the
## eyes. This node bends the arms forward while the view is first person, putting
## the fists (and everything parented to them) in the lower part of the frame.
##
## It has to win over the `AnimationPlayer` that owns the same bones. A clip
## writes its track values in the player's own process callback, so this node
## runs with `process_priority` above it and blends the bone it finds there
## toward a pose built from the rig's rest rotation. At full weight the
## locomotion clip contributes nothing, and when the view leaves the weight
## falls back to zero and the clip owns the arms again.
##
## A slow sine plus a lag that follows the camera's yaw keeps the hands from
## looking welded to the lens.

## Bone name -> extra rotation in degrees, applied in the bone's own frame.
## `arm_upper_*` pitches the arm forward and rolls it outboard, `arm_lower_*`
## bends the elbow so the fists come up in front of the chest, and the wrist
## rolls the club from "forward along the lens" to "up and out to the right".
##
## The numbers are deliberately modest: the arms are third-person boxes 22 cm
## thick, so a 62 degree pitch put both forearms across the middle of the frame
## and the club head on the crosshair. A shallower pitch keeps the upper arms
## below the bottom edge and leaves the lens looking out over the fists, which
## sit in the lower corners.
const POSE := {
	&"arm_upper_left2": Vector3(45.0, 0.0, -30.0),
	&"arm_lower_left2": Vector3(55.0, 0.0, 0.0),
	&"hand_left2": Vector3(0.0, 90.0, 0.0),
	&"arm_upper_right2": Vector3(45.0, 0.0, 30.0),
	&"arm_lower_right2": Vector3(55.0, 0.0, 0.0),
	&"hand_right2": Vector3(-35.0, 77.0, -97.0),
}
## Bones the pose displaces from their authored position, not just their angle.
## The shoulder pivots sit below and behind the eye, so the near end of each
## upper arm crosses the camera's near plane and smears a slab of cream across a
## third of the frame however the bone is turned. Pulling the whole chain this
## far forward and down puts it in front of the lens instead; the elbow, hand,
## club and held prop inherit the shift, and it is blended back to the authored
## position when the view leaves first person.
const DISPLACED_BONES: Array[StringName] = [&"arm_upper_left2", &"arm_upper_right2"]
const ARM_OFFSET := Vector3(0.0, -0.16, -0.24)
## Degrees of idle sway on the upper arms. Small on purpose: the hands should
## breathe, not wave.
const SWAY_DEGREES := Vector3(1.1, 1.6, 0.8)
## How fast the pose fades in and out, per second.
const BLEND_RATE := 14.0
## Degrees of wrist lag per radian/second of camera yaw, and its ceiling.
const LAG_PER_RADIAN := 3.0
const LAG_LIMIT := 6.0

var _active := false
var _blend := 0.0
## name -> bone node.
var _bones := {}
## name -> the bone's authored rest rotation, the frame the FPS pose is built in.
var _rest := {}
## name -> the authored position of a bone `ARM_OFFSET` displaces.
var _rest_positions := {}
## name -> the quaternion we wrote last frame. A bone the current clip does not
## animate still carries that write, so it is blended from the rest pose instead
## of compounding the offset frame after frame.
var _applied := {}
var _sway_time := 0.0
var _lag := 0.0
var _last_yaw := 0.0


func _ready() -> void:
	# `AnimationPlayer` runs at the default priority 0. Anything above it runs
	# after the clip has written the bones, which is the only way this pose wins.
	process_priority = 100
	# `SwingWeapon` and `HeldItem` copy the hand bones' world transforms in their
	# own `_process`. At the default priority they would read the clip's raw pose
	# *before* this node bends it, and the club would stay at the character's
	# side forever. Lifting them one step above this node makes them read the
	# posed hand without touching either script.
	for sibling: StringName in [&"Weapon", &"HeldItem"]:
		var attachment := get_parent().get_node_or_null(NodePath(sibling)) as Node
		if attachment != null and attachment.get_script() != null:
			attachment.process_priority = process_priority + 1
	var visual := _find_visual()
	if visual == null:
		set_process(false)
		return
	for name: StringName in POSE:
		var bone := visual.find_child(String(name), true, false) as Node3D
		if bone != null:
			_bones[name] = bone
			# Captured before the first clip frame is applied: the rig's authored
			# rest pose, which is the frame the arms-hanging-down pose lives in.
			_rest[name] = bone.quaternion
			if name in DISPLACED_BONES:
				_rest_positions[name] = bone.position
	if _bones.is_empty():
		# A model without the rigged arms still zooms; there is just no pose.
		set_process(false)


## Called by `PlayerController` when the view enters or leaves first person.
func set_active(value: bool) -> void:
	if _active == value:
		return
	_active = value
	if value:
		_lag = 0.0
		var pivot := _find_pivot()
		if pivot != null:
			_last_yaw = pivot.global_rotation.y


func _process(delta: float) -> void:
	var target := 1.0 if _active else 0.0
	_blend = lerpf(_blend, target, 1.0 - exp(-BLEND_RATE * delta))
	if not _active and _blend <= 0.002:
		return
	_sway_time += delta
	_update_lag(delta)
	var sway := Vector3(
		sin(_sway_time * 1.7), sin(_sway_time * 0.9), sin(_sway_time * 1.3)
	) * SWAY_DEGREES
	for name: StringName in _bones:
		var bone := _bones[name] as Node3D
		if not is_instance_valid(bone):
			continue
		# The animation player has already written this frame's clip value, so it
		# is what the pose blends from. A bone the current clip does not touch
		# still carries our last write; start from the rest pose there.
		var from := bone.quaternion
		if _applied.has(name) and from.is_equal_approx(_applied[name]):
			from = _rest[name]
		var degrees: Vector3 = POSE[name]
		if name == &"arm_upper_left2" or name == &"arm_upper_right2":
			degrees += sway
		if name == &"arm_upper_right2":
			degrees.z += _lag
		var pose := (
			(_rest[name] as Quaternion)
			* Quaternion(Basis.from_euler(degrees * (PI / 180.0)))
		)
		bone.quaternion = from.slerp(pose, _blend)
		_applied[name] = bone.quaternion
	for name: StringName in _rest_positions:
		var bone := _bones.get(name) as Node3D
		if not is_instance_valid(bone):
			continue
		var rest_position: Vector3 = _rest_positions[name]
		bone.position = rest_position.lerp(rest_position + ARM_OFFSET, _blend)


## Weapon lag: the arms swing the other way a fraction of a second after the
## crosshair, which is what separates a held prop from a decal on the lens.
func _update_lag(delta: float) -> void:
	var pivot := _find_pivot()
	if pivot == null:
		return
	var yaw := pivot.global_rotation.y
	var velocity := wrapf(yaw - _last_yaw, -PI, PI) / maxf(delta, 0.0001)
	_last_yaw = yaw
	var target := clampf(-velocity * LAG_PER_RADIAN, -LAG_LIMIT, LAG_LIMIT)
	_lag = lerpf(_lag, target, 1.0 - exp(-8.0 * delta))


func _find_visual() -> Node3D:
	var parent := get_parent()
	if parent == null:
		return null
	return parent.get_node_or_null(^"Model/Visual") as Node3D


func _find_pivot() -> Node3D:
	var parent := get_parent()
	if parent == null:
		return null
	return parent.get_node_or_null(^"CameraPivot") as Node3D
