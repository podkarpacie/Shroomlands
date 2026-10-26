extends SceneTree
## Regression for the chat/inventory movement leak: while a text field or a modal
## panel is open the body must ignore WASD, sprint and jump, and start walking
## again the moment the flag clears.
##
## `main.tscn` is loaded lazily: autoload identifiers only resolve after the
## `--script` main loop starts (same constraint as test_player.gd).

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _main: Node = null
var _player: Node3D = null


func _initialize() -> void:
	# Structural/behaviour run only: a private save and a private plots file,
	# so this suite never reads or writes the developer's profile.
	TestEnv.isolate("test_movement_block")
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
	await _wait_physics(30)

	_player = get_first_node_in_group(&"player") as Node3D
	_check("a player was spawned", _player != null)
	if _player == null:
		_finish()
		return
	_check("the player starts on the floor", _player.is_on_floor())

	# --- the real bug: typing in the chat field walks the body --------------
	var chat := _main.get_node_or_null("ChatUI")
	_check("Main has a ChatUI", chat != null)
	if chat != null:
		chat.call(&"set_open", true)
		await _wait_physics(2)
		_check("opening the chat sets ui_blocking", bool(_player.get(&"ui_blocking")))
		var chat_start := _player.global_position
		Input.action_press(&"move_forward")
		await _wait_physics(30)
		Input.action_release(&"move_forward")
		var chat_walk := _player.global_position.distance_to(chat_start)
		print("displacement while the chat field is open: %.3f m" % chat_walk)
		_check("typing in the chat field does not walk the player (%.3f m)" % chat_walk, chat_walk < 0.05)
		chat.call(&"set_open", false)
		await _wait_physics(2)
		_check("closing the chat releases the player", not bool(_player.get(&"ui_blocking")))

	# --- the flag itself ----------------------------------------------------
	var start := _player.global_position
	_player.call(&"set_ui_blocking", true)
	_check("ui_blocking is set", bool(_player.get(&"ui_blocking")))

	Input.action_press(&"move_forward")
	Input.action_press(&"sprint")
	var lowest := start.y
	for _frame in 30:
		await physics_frame
		lowest = minf(lowest, _player.global_position.y)
	var blocked_displacement := _player.global_position.distance_to(start)
	print("displacement while ui_blocking: %.3f m" % blocked_displacement)
	_check(
		"holding move_forward while blocked does not walk (%.3f m)" % blocked_displacement,
		blocked_displacement < 0.05
	)
	_check("sprint stays off while blocked", not bool(_player.get(&"is_sprinting")))
	_check("the body stays grounded while blocked", _player.is_on_floor())
	_check(
		"the body neither floats nor sinks while blocked (lowest y = %.2f, start %.2f)" % [lowest, start.y],
		absf(lowest - start.y) < 0.05
	)
	Input.action_release(&"sprint")

	# Jump is ignored as well, so a "space" typed into a field cannot hop.
	Input.action_press(&"jump")
	await _wait_physics(2)
	Input.action_release(&"jump")
	var peak := _player.global_position.y
	for _frame in 10:
		await physics_frame
		peak = maxf(peak, _player.global_position.y)
	_check("jump is ignored while blocked (peak y = %.2f)" % peak, peak - start.y < 0.05)

	# --- release: movement comes straight back ------------------------------
	_player.call(&"set_ui_blocking", false)
	_check("ui_blocking is cleared", not bool(_player.get(&"ui_blocking")))
	var resumed_start := _player.global_position
	Input.action_press(&"move_forward")
	for _frame in 30:
		await physics_frame
	Input.action_release(&"move_forward")
	var resumed := _player.global_position.distance_to(resumed_start)
	print("displacement after the block clears: %.3f m" % resumed)
	_check("the player walks again once the block clears (%.2f m)" % resumed, resumed > 0.3)

	_finish()


func _wait_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	Input.action_release(&"move_forward")
	Input.action_release(&"sprint")
	Input.action_release(&"jump")
	if _failures == 0:
		print("PASSED  all movement-block assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
