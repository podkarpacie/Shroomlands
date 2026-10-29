extends SceneTree
## Headless test for the rigged player animation.
##
## The real player scene is driven on a plain floor: the animator selects its clip
## from the body's own position deltas, so the harness moves the body instead of
## pressing keys, and holds the clips long enough for the crossfades to finish.
## Everything asserted here is what a player actually sees: the imported rig, the
## gait it picks, the one-shots `attack`/`draw`/`holster`, the hands the club and
## the held prop hang from, and a body nobody owns animating from positions alone.

const PLAYER_SCENE_PATH := "res://scenes/player/player.tscn"
const RIGGED_MODEL_PATH := "res://assets/models/player_rigged.gltf"
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")
## The clip names the Blockbench export writes; the importer keeps them verbatim.
const EXPECTED_CLIPS: Array[String] = ["idle", "walk", "run", "attack", "draw", "holster"]
const GAITS: Array[StringName] = [&"idle", &"walk", &"run"]
## Measured speeds used to pick a gait. `run` starts at 6 m/s, so 7 is safely in.
const WALK_SPEED := 4.0
const RUN_SPEED := 7.0
## How long the attack clip runs plus its crossfade back to locomotion.
const ATTACK_TAIL := 0.8
const DRAW_TAIL := 0.7

var _failures := 0
var _player: CharacterBody3D = null
var _visual: Node3D = null
var _animator: Node = null
var _clips: AnimationPlayer = null
var _steps: Array[int] = []


func _initialize() -> void:
	TestEnv.isolate("test_rig")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	_make_floor()
	var packed := load(PLAYER_SCENE_PATH) as PackedScene
	_check("player.tscn loads", packed != null)
	if packed == null:
		_finish()
		return
	_player = packed.instantiate() as CharacterBody3D
	_player.position = Vector3(0.0, 1.0, 0.0)
	root.add_child(_player)
	await physics_frame
	# The animator measures position deltas, so the harness owns the movement.
	_player.set_physics_process(false)
	await _still(0.6)

	if not _check_rig():
		_finish()
		return
	await _check_gaits()
	await _check_footsteps()
	await _check_attack()
	await _check_held_item()
	_check_hands()
	await _check_remote_body()
	_finish()


## The model, its animation player, the six clips and the animator driving them.
func _check_rig() -> bool:
	_visual = _player.get_node_or_null("Model/Visual") as Node3D
	_animator = _player.get_node_or_null("Animator")
	_check("the player has Model/Visual", _visual != null)
	_check("the player has an Animator", _animator != null)
	if _visual == null or _animator == null:
		return false
	_check(
		"Model/Visual is the rigged model (%s)" % _visual.scene_file_path,
		_visual.scene_file_path == RIGGED_MODEL_PATH
	)
	_check(
		"the animator is PlayerAnimator, not the procedural limb rig",
		_animator.get_script() != null
			and String(_animator.get_script().resource_path).ends_with("PlayerAnimator.gd")
	)
	_check("the rig has its hip bone", _visual.find_child("hips", true, false) != null)

	_clips = _visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_check("the rigged model carries an AnimationPlayer", _clips != null)
	if _clips == null:
		return false
	var names: Array[String] = []
	for name in _clips.get_animation_list():
		names.append(String(name))
	print("rig clips: %s" % str(names))
	for expected in EXPECTED_CLIPS:
		_check("the imported clips include '%s'" % expected, names.has(expected))
	_check("the animator did not disable itself", not bool(_animator.get("_disabled")))
	return true


## Standing still breathes, walking and running pick their own clip, and the body
## falls back to idle once it stops.
func _check_gaits() -> void:
	_check("standing still plays idle (%s)" % String(_clips.current_animation),
		_clips.current_animation == &"idle")

	await _drive(_player, Vector3.RIGHT, WALK_SPEED, 0.6)
	_check(
		"moving at %.1f m/s plays walk (%s)" % [WALK_SPEED, String(_clips.current_animation)],
		_clips.current_animation == &"walk"
	)

	await _drive(_player, Vector3.RIGHT, RUN_SPEED, 0.6)
	_check(
		"moving at %.1f m/s plays run (%s)" % [RUN_SPEED, String(_clips.current_animation)],
		_clips.current_animation == &"run"
	)

	await _still(0.6)
	_check(
		"stopping returns to idle (%s)" % String(_clips.current_animation),
		_clips.current_animation == &"idle"
	)


## `AudioManager` connects the `stepped` signal of any node under a body in group
## `player`, so the animator still has to report footfalls from the gait clip.
func _check_footsteps() -> void:
	_check("the animator declares stepped(foot)", _animator.has_signal(&"stepped"))
	if not _animator.has_signal(&"stepped"):
		return
	_animator.connect(&"stepped", _on_stepped)

	_steps.clear()
	await _drive(_player, Vector3.LEFT, WALK_SPEED, 1.6)
	_check("walking reports footfalls (%d over 1.6 s)" % _steps.size(), _steps.size() >= 2)
	var alternates := _steps.size() >= 2
	for index in range(1, _steps.size()):
		if _steps[index] == _steps[index - 1]:
			alternates = false
	_check("the steps alternate feet (%s)" % str(_steps), alternates)

	await _still(0.6)
	_steps.clear()
	await _wait(0.7)
	_check("standing still reports no footfalls (%d)" % _steps.size(), _steps.is_empty())


func _on_stepped(foot: int) -> void:
	_steps.append(foot)


## A swing is a counter on the body: the owner bumps it in `CombatSystem`, and
## every peer plays `attack` when it changes, then hands the rig back.
func _check_attack() -> void:
	var before := int(_player.get(&"swing_seq"))
	_player.set(&"swing_seq", before + 1)
	await _wait(0.08)
	_check(
		"a swing_seq bump plays attack (%s)" % String(_clips.current_animation),
		_clips.current_animation == &"attack"
	)
	_check(
		"the swing reports itself as an attack pose (kind %d)" % int(_animator.get("_attack_kind")),
		int(_animator.get("_attack_kind")) == 1
	)
	await _wait(ATTACK_TAIL)
	_check(
		"the attack falls back to locomotion (%s)" % String(_clips.current_animation),
		_clips.current_animation in GAITS
	)
	_check("the attack pose is cleared", int(_animator.get("_attack_kind")) == 0)

	# The real swing path has to bump the counter itself, otherwise no other peer
	# would ever see it.
	var combat := _player.get_node_or_null("CombatSystem")
	_check("the player has a CombatSystem", combat != null)
	if combat == null:
		return
	var seq_before := int(_player.get(&"swing_seq"))
	var swung := bool(combat.call(&"try_attack", false))
	_check("the combat swing is accepted", swung)
	_check(
		"CombatSystem increments swing_seq (%d -> %d)" % [seq_before, int(_player.get(&"swing_seq"))],
		int(_player.get(&"swing_seq")) == seq_before + 1
	)
	await _wait(ATTACK_TAIL)
	_check(
		"the combat swing falls back to locomotion (%s)" % String(_clips.current_animation),
		_clips.current_animation in GAITS
	)


## `held_item` transitions drive the draw and holster one-shots, on the owner and
## on any peer that only sees the replicated value.
func _check_held_item() -> void:
	_check("the hand starts empty", StringName(_player.get(&"held_item")) == &"")
	_player.set(&"held_item", &"konop")
	await _wait(0.08)
	_check(
		"taking a konop plays draw (%s)" % String(_clips.current_animation),
		_clips.current_animation == &"draw"
	)
	await _wait(DRAW_TAIL)
	_check(
		"draw falls back to locomotion (%s)" % String(_clips.current_animation),
		_clips.current_animation in GAITS
	)

	# Past the debounce window, so the transition is not swallowed.
	await _wait(0.25)
	_player.set(&"held_item", &"")
	await _wait(0.08)
	_check(
		"emptying the hand plays holster (%s)" % String(_clips.current_animation),
		_clips.current_animation == &"holster"
	)
	await _wait(DRAW_TAIL)
	_check(
		"holster falls back to locomotion (%s)" % String(_clips.current_animation),
		_clips.current_animation in GAITS
	)


## The club and the held prop hang off bone nodes that the clips animate. A missed
## lookup disables both silently, so resolving them is the assertion.
func _check_hands() -> void:
	var weapon := _player.get_node_or_null("Weapon")
	_check("the player has a Weapon node", weapon != null)
	if weapon != null:
		var hand: Node = weapon.get("_hand") as Node
		_check(
			"SwingWeapon resolves its hand (%s)" % ("<null>" if hand == null else String(hand.name)),
			hand != null and hand.name == &"hand_right2"
		)
		_check("SwingWeapon stays visible", weapon.visible)
		var club := weapon.get_node_or_null("Club")
		_check("the club is built", club != null)
		if club != null:
			var shadows_off := true
			for part: GeometryInstance3D in club.get_children():
				if part.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
					shadows_off = false
			_check("every club part has shadows off", shadows_off)

	var held := _player.get_node_or_null("HeldItem")
	_check("the player has a HeldItem node", held != null)
	if held != null:
		var hand: Node = held.get("_hand") as Node
		_check(
			"HeldItem resolves its hand (%s)" % ("<null>" if hand == null else String(hand.name)),
			hand != null and hand.name == &"hand_left2"
		)
		_check("HeldItem stays visible", held.visible)


## A replicated body: no authority, only a stream of positions. It still has to
## animate, which is the property multiplayer depends on.
func _check_remote_body() -> void:
	var packed := load(PLAYER_SCENE_PATH) as PackedScene
	if packed == null:
		return
	var remote := packed.instantiate() as CharacterBody3D
	remote.position = Vector3(0.0, 1.0, 4.0)
	# Any peer id but ours (1): this body belongs to someone else.
	remote.set_multiplayer_authority(2)
	root.add_child(remote)
	await physics_frame
	_check("the remote body is not ours", not remote.is_multiplayer_authority())
	remote.set_physics_process(false)

	var remote_clips := remote.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_check("the remote body carries an AnimationPlayer", remote_clips != null)
	if remote_clips == null:
		return
	await _still(0.6)
	_check(
		"a still remote body plays idle (%s)" % String(remote_clips.current_animation),
		remote_clips.current_animation == &"idle"
	)
	await _drive(remote, Vector3.RIGHT, WALK_SPEED, 0.6)
	_check(
		"a moving remote body plays walk (%s)" % String(remote_clips.current_animation),
		remote_clips.current_animation == &"walk"
	)
	await _drive(remote, Vector3.RIGHT, RUN_SPEED, 0.5)
	_check(
		"a sprinting remote body plays run (%s)" % String(remote_clips.current_animation),
		remote_clips.current_animation == &"run"
	)


## Moves `body` at `speed` m/s along `direction`, one physics tick at a time, so
## the animator sees a real position delta.
func _drive(body: Node3D, direction: Vector3, speed: float, seconds: float) -> void:
	var step := direction.normalized() * speed / float(Engine.physics_ticks_per_second)
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await physics_frame
		if is_instance_valid(body):
			body.global_position += step


## Holds both bodies still for `seconds`, so the smoothed speed drops to zero.
func _still(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await physics_frame


func _wait(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


## A 200 m slab with its top at y = 0, so a drive never runs out of ground.
func _make_floor() -> void:
	var body := StaticBody3D.new()
	body.name = "TestFloor"
	body.collision_layer = 1
	body.position = Vector3(0.0, -0.5, 0.0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	shape.shape = box
	body.add_child(shape)
	root.add_child(body)


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all rigged-animation assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
