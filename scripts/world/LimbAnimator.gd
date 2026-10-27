extends Node
## Procedural animation for the cube-built glTF characters (player, blightling).
##
## The models are rigid cubes with no skeleton, so this swings the limb nodes
## about hip and shoulder pivots computed from each mesh's own bounds: walk and
## run swing, a breathing idle, a tucked jump pose, a squash on landing, a
## forward lean at speed and a lagging cap. Nothing here is authoritative.
##
## Speed comes from how far the body actually moved between physics ticks, not
## from `velocity`, so a replicated copy of a player (which only receives a
## position) animates exactly like the local one.
##
## Parent: the `CharacterBody3D`. Looks for the limbs below `visual_path`; a
## model without `leg_l`, `arm_l`, ... simply skips that part.

@export var visual_path: NodePath = ^"../Model/Visual"
## Metres travelled per full walk cycle (two steps).
@export var stride_length := 1.7
@export var leg_swing_deg := 38.0
@export var arm_swing_deg := 30.0
@export var bob_height := 0.04
## Forward lean at `run_speed`, in degrees.
@export var lean_deg := 9.0
@export var walk_speed := 4.5
@export var run_speed := 7.5

const LEGS := [&"leg_l", &"leg_r"]
const ARMS := [&"arm_l", &"arm_r"]
const HANDS := {&"hand_l": &"arm_l", &"hand_r": &"arm_r"}
const CAP_PREFIXES := ["cap_", "spike"]

var _body: Node3D = null
var _visual: Node3D = null
var _visual_rest_pos := Vector3.ZERO
## name -> {node, rest, pivot}
var _limbs := {}
var _caps: Array = []
var _cap_pivot := Vector3.ZERO

var _last_position := Vector3.ZERO
var _instant_speed := 0.0
var _instant_vy := 0.0
var _speed := 0.0
var _vy := 0.0
var _phase := 0.0
var _time := 0.0
var _squash := 0.0
var _cap_lag := 0.0
var _last_speed := 0.0

## Transient pose on top of locomotion. 0 = none, 1 = player swing, 2 = bite,
## 3 = hit flinch. The timer is read-side only; gameplay never waits on it.
var _attack_left := 0.0
var _attack_total := 0.0
var _attack_kind := 0
var _attack_heavy := false


func _ready() -> void:
	_body = get_parent() as Node3D
	_visual = get_node_or_null(visual_path) as Node3D
	if _body == null or _visual == null:
		set_process(false)
		set_physics_process(false)
		return
	_visual_rest_pos = _visual.position
	_last_position = _body.global_position
	_collect_limbs()
	if _body.has_signal(&"landed"):
		_body.connect(&"landed", _on_landed)


func _collect_limbs() -> void:
	for limb_name in LEGS + ARMS:
		var node := _visual.find_child(String(limb_name), true, false) as MeshInstance3D
		if node == null:
			continue
		var box := node.get_aabb()
		# Hinge at the top centre of the limb: hip for a leg, shoulder for an arm.
		var pivot := node.transform * Vector3(box.get_center().x, box.end.y, box.get_center().z)
		_limbs[limb_name] = {"node": node, "rest": node.transform, "pivot": pivot}
	for hand_name in HANDS:
		var node := _visual.find_child(String(hand_name), true, false) as Node3D
		var arm: Dictionary = _limbs.get(HANDS[hand_name], {})
		if node == null or arm.is_empty():
			continue
		# A hand rides on its arm, so it swings about the arm's shoulder.
		_limbs[hand_name] = {"node": node, "rest": node.transform, "pivot": arm["pivot"]}
	var rim := _visual.find_child("cap_rim", true, false) as MeshInstance3D
	if rim != null:
		var box := rim.get_aabb()
		_cap_pivot = rim.transform * Vector3(box.get_center().x, box.position.y, box.get_center().z)
	for child in _visual.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		for prefix in CAP_PREFIXES:
			if String(mesh_instance.name).begins_with(prefix):
				_caps.append({"node": mesh_instance, "rest": mesh_instance.transform})
				break


## Player swing. Called by `CombatSystem` the instant the hitbox is evaluated,
## so arm and damage share a frame. Heavy swings hold the follow-through longer.
func play_attack(heavy := false) -> void:
	_attack_kind = 1
	_attack_heavy = heavy
	_attack_total = 0.44 if heavy else 0.34
	_attack_left = _attack_total


## Blightling bite: a short lunge with both arms thrown wide.
func play_bite() -> void:
	_attack_kind = 2
	_attack_heavy = false
	_attack_total = 0.30
	_attack_left = _attack_total


## Flinch away from a blow; heavy and critical hits hold it longer.
func play_hit(heavy := false) -> void:
	_attack_kind = 3
	_attack_heavy = heavy
	_attack_total = 0.26 if heavy else 0.18
	_attack_left = _attack_total


func _physics_process(delta: float) -> void:
	if delta <= 0.0:
		return
	var moved := _body.global_position - _last_position
	_last_position = _body.global_position
	_instant_speed = Vector2(moved.x, moved.z).length() / delta
	_instant_vy = moved.y / delta


func _process(delta: float) -> void:
	_time += delta
	var follow := 1.0 - exp(-14.0 * delta)
	_speed = lerpf(_speed, _instant_speed, follow)
	_vy = lerpf(_vy, _instant_vy, follow)
	var airborne := _is_airborne()

	var pace := clampf(_speed / walk_speed, 0.0, 1.6)
	if not airborne and _speed > 0.15:
		_phase += (_speed * delta / stride_length) * TAU
	var swing := sin(_phase)
	var walking := 0.0 if airborne else clampf(_speed / 1.2, 0.0, 1.0)

	# --- legs and arms ---------------------------------------------------------
	var leg_angle := deg_to_rad(leg_swing_deg) * pace * walking * swing
	var arm_angle := deg_to_rad(arm_swing_deg) * pace * walking * swing
	var idle_sway := sin(_time * 1.6) * 0.04 * (1.0 - walking)
	var tuck := 0.0
	var arms_up := 0.0
	if airborne:
		tuck = 0.55 if _vy < 0.0 else 0.35
		arms_up = clampf(0.5 + _vy * 0.06, 0.2, 0.9)

	# --- transient attack / flinch pose ---------------------------------------
	var attack_kind := _attack_kind
	var attack := 0.0
	if _attack_left > 0.0:
		var progress := 1.0 - _attack_left / maxf(_attack_total, 0.0001)
		attack = sin(clampf(progress, 0.0, 1.0) * PI)
		_attack_left = maxf(_attack_left - delta, 0.0)
		if _attack_left <= 0.0:
			_attack_kind = 0
	var arm_l_angle := -arm_angle + idle_sway + arms_up
	var arm_r_angle := arm_angle - idle_sway + arms_up
	var torso_twist := 0.0
	var lunge := 0.0
	var attack_pitch := 0.0
	match attack_kind:
		1:
			# Right arm drives the club down and across; left arm counterbalances.
			var drive := (1.85 if _attack_heavy else 1.45) * attack
			arm_r_angle -= drive
			arm_l_angle += drive * 0.30
			torso_twist = -0.38 * attack
			lunge = -0.10 * attack
		2:
			# Bite: both arms out, whole body pitches into the player.
			arm_l_angle += 0.75 * attack
			arm_r_angle += 0.75 * attack
			attack_pitch = 0.34 * attack
			lunge = -0.16 * attack
		3:
			# Flinch: arms come up, body recoils away from the blow.
			arm_l_angle += 0.62 * attack
			arm_r_angle += 0.62 * attack
			attack_pitch = -0.26 * attack
			lunge = 0.09 * attack

	_swing(&"leg_l", leg_angle + tuck)
	_swing(&"leg_r", -leg_angle + tuck * 0.6)
	_swing(&"arm_l", arm_l_angle)
	_swing(&"arm_r", arm_r_angle)
	_swing(&"hand_l", arm_l_angle)
	_swing(&"hand_r", arm_r_angle)

	# --- body: bob, breathing, lean, landing squash ------------------------------
	_squash = lerpf(_squash, 0.0, 1.0 - exp(-9.0 * delta))
	var bob := absf(sin(_phase)) * bob_height * pace * walking
	var breath := sin(_time * 2.1) * 0.012 * (1.0 - walking)
	var stretch := clampf(_vy * 0.012, 0.0, 0.07) if airborne else 0.0
	var sy := 1.0 + breath + stretch - _squash
	var sxz := 1.0 - breath * 0.5 - stretch * 0.4 + _squash * 0.5
	_visual.scale = Vector3(sxz, sy, sxz)
	_visual.position = _visual_rest_pos + Vector3(0.0, bob, lunge)
	_visual.rotation.y = torso_twist
	var lean_target := -deg_to_rad(lean_deg) * clampf(_speed / run_speed, 0.0, 1.2)
	_visual.rotation.x = (
		lerpf(_visual.rotation.x, lean_target, 1.0 - exp(-8.0 * delta)) + attack_pitch
	)

	# --- cap: lags behind speed changes, then settles ------------------------------
	var accel := (_speed - _last_speed) / maxf(delta, 0.0001)
	_last_speed = _speed
	var cap_target := clampf(-accel * 0.012, -0.25, 0.25) + (-_vy * 0.02 if airborne else 0.0)
	_cap_lag = lerpf(_cap_lag, cap_target, 1.0 - exp(-10.0 * delta))
	for cap in _caps:
		var node: Node3D = cap["node"]
		node.transform = _about(_cap_pivot, Basis(Vector3.RIGHT, _cap_lag)) * cap["rest"]


func _is_airborne() -> bool:
	var body := _body as CharacterBody3D
	if body != null and body.is_multiplayer_authority():
		return not body.is_on_floor() and absf(_vy) > 0.6
	return absf(_vy) > 0.8


func _swing(limb_name: StringName, angle: float) -> void:
	var limb: Dictionary = _limbs.get(limb_name, {})
	if limb.is_empty():
		return
	var node: Node3D = limb["node"]
	node.transform = _about(limb["pivot"], Basis(Vector3.RIGHT, angle)) * limb["rest"]


## `basis` applied about `pivot` (parent space).
func _about(pivot: Vector3, basis: Basis) -> Transform3D:
	return Transform3D(Basis.IDENTITY, pivot) * Transform3D(basis, Vector3.ZERO) * Transform3D(Basis.IDENTITY, -pivot)


func _on_landed(impact_speed: float) -> void:
	_squash = clampf(impact_speed / 14.0, 0.05, 0.3)
