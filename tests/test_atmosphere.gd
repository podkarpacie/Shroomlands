extends SceneTree
## Headless atmosphere test: the default view is first person, the screen grade
## follows the biome/layer, the new ambient cues exist, and danger rises when a
## creature closes in.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const ENEMY_SCENE_PATH := "res://scenes/world/enemy.tscn"
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _main: Node = null
var _player: Node3D = null
var _game: Node = null
var _audio: Node = null


func _initialize() -> void:
	TestEnv.isolate("test_atmosphere")
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
	_main = packed.instantiate()
	root.add_child(_main)
	await _wait(30)
	_game = root.get_node_or_null("/root/Game")
	_audio = root.get_node_or_null("/root/Audio")
	_check("Game and Audio autoloads exist", _game != null and _audio != null)
	if _game == null or _audio == null:
		_finish()
		return
	_player = get_first_node_in_group(&"player") as Node3D
	_check("a player was spawned", _player != null)
	if _player == null:
		_finish()
		return

	# --- first person is the default --------------------------------------
	var arm := _player.get_node_or_null("CameraPivot/SpringArm3D") as SpringArm3D
	_check("the player has a spring arm", arm != null)
	_check("the controller reports first person", bool(_player.call(&"is_first_person")))
	if arm != null:
		_check("the arm starts at the eyes (%.2f m)" % arm.spring_length, arm.spring_length <= 0.6)

	# --- screen grade ------------------------------------------------------
	var screen_fx := _main.get_node_or_null("ScreenFX")
	_check("main.tscn has a ScreenFX layer", screen_fx != null)
	if screen_fx == null:
		_finish()
		return
	var town_tint: Color = screen_fx.call(&"current_tint")
	_check("the town gets a warm tint (%s)" % town_tint, town_tint.r >= town_tint.g)
	_game.set(&"forest_layer", 3)
	screen_fx.call(&"_apply_tint")
	var crimson_tint: Color = screen_fx.call(&"current_tint")
	_check("layer 3 shifts the tint red (%s)" % crimson_tint, crimson_tint.r > crimson_tint.g)
	_check("the material is a ShaderMaterial",
		(screen_fx.get_node("Screen") as ColorRect).material is ShaderMaterial)

	# --- quiet dynamic cues ------------------------------------------------
	for id: StringName in [&"creak", &"whisper", &"drip", &"heartbeat"]:
		_check("the '%s' cue resolves" % id, bool(_audio.call(&"has_cue", id)))
	var atmosphere := _main.get_node_or_null("Atmosphere")
	_check("main.tscn has an Atmosphere node", atmosphere != null)
	_check("the atmosphere is in its group",
		atmosphere != null and atmosphere.is_in_group(&"atmosphere"))

	# --- danger rises near a creature -------------------------------------
	_check("town danger starts low (%.2f)" % float(atmosphere.call(&"danger_level")),
		float(atmosphere.call(&"danger_level")) < 0.25)
	var enemy := (load(ENEMY_SCENE_PATH) as PackedScene).instantiate() as Node3D
	enemy.position = _player.global_position + Vector3(4.0, 0.0, 0.0)
	root.add_child(enemy)
	await _wait(40)
	var danger := float(atmosphere.call(&"danger_level"))
	_check("a creature at 4 m raises danger (%.2f)" % danger, danger > 0.4)
	_check("the screen grade follows the danger (%.2f)" % float(screen_fx.call(&"danger_level")),
		float(screen_fx.call(&"danger_level")) > 0.2)
	enemy.queue_free()
	await _wait(3)
	_finish()


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
		print("PASSED  all atmosphere assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
