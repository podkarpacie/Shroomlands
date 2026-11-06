extends SceneTree
## Headless voice-hearing and leader test: a loud voice emits a wider monster
## disturbance than a quiet one, only the leader can light the lamp, and the
## forest return gate refuses the party while the leader is elsewhere.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const FOREST_PATH := "res://scenes/world/layered_forest.tscn"
const TOWN_PATH := "res://scenes/world/town.tscn"
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _main: Node = null
var _player: Node3D = null
var _game: Node = null
var _party: Node = null
var _bus: Node = null
var _disturbances := 0
var _last_radius := 0.0


func _initialize() -> void:
	TestEnv.isolate("test_voice_and_leader")
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
	_party = root.get_node_or_null("/root/Party")
	_bus = root.get_node_or_null("/root/EventBus")
	_check("Game, Party and EventBus autoloads exist",
		_game != null and _party != null and _bus != null)
	if _game == null or _party == null or _bus == null:
		_finish()
		return
	_bus.connect(&"disturbance_emitted", Callable(self, "_on_disturbance"))
	_player = get_first_node_in_group(&"player") as Node3D
	_check("a player was spawned", _player != null)
	if _player == null:
		_finish()
		return

	# --- voice: loud is heard further than quiet --------------------------
	var voice := _player.get_node_or_null("VoiceInput")
	_check("the player has a voice listener", voice != null)
	if voice == null:
		_finish()
		return
	_check("voice starts muted for privacy", not bool(voice.call("is_enabled")))
	var before := _disturbances
	var loud: float = float(voice.call("push_voice", 0.9))
	_check("a shout emits a disturbance (%.1f m)" % loud, loud >= 15.0)
	_check("the shout reached the event bus", _disturbances == before + 1)
	var quiet_before := _disturbances
	var whisper: float = float(voice.call("push_voice", 0.02))
	_check("a whisper is not a disturbance", is_zero_approx(whisper) and _disturbances == quiet_before)
	var mid: float = float(voice.call("push_voice", 0.4))
	_check("a normal voice sits between (%.1f m)" % mid, mid > 0.0 and mid < loud)

	# --- only the leader lights the lamp ---------------------------------
	var lamp := _player.get_node_or_null("SporeLamp")
	_check("the player has a spore-lamp", lamp != null)
	if lamp == null:
		_finish()
		return
	_check("the local player leads offline", bool(_party.call("is_leader", _player)))
	lamp.call(&"toggle")
	_check("the leader can light the lamp", bool(lamp.call("is_on")))
	_party.call(&"set_leader", 2)
	_check("passing the lead turns the lamp off", not bool(lamp.call("is_on")))
	lamp.call(&"toggle")
	_check("a non-leader cannot light it", not bool(lamp.call("is_on")))
	_party.call(&"set_leader", 1)
	lamp.call(&"toggle")
	_check("the leader can light it again", bool(lamp.call("is_on")))
	lamp.call(&"toggle")

	# --- can't go back without the leader --------------------------------
	var town := _main.get_node_or_null("World") as Node3D
	var descent := town.get_node_or_null("DescentGate") if town != null else null
	_check("town has a descent gate", descent != null)
	if descent == null:
		_finish()
		return
	descent.call(&"interact", _player)
	await _wait(12)
	var forest := _main.get_node_or_null("World") as Node3D
	_check("layer 1 loaded", forest != null and forest.scene_file_path == FOREST_PATH)
	if forest == null:
		_finish()
		return
	var back := forest.get_node_or_null("ReturnGate")
	_check("the forest has a return gate", back != null)
	if back == null:
		_finish()
		return
	_check("the return gate requires the leader", bool(back.get("requires_leader")))

	_party.call(&"set_leader", 2)
	back.call(&"interact", _player)
	await _wait(6)
	var still_forest := _main.get_node_or_null("World") as Node3D
	_check("an absent leader blocks the return",
		still_forest != null and still_forest.scene_file_path == FOREST_PATH)

	_party.call(&"set_leader", 1)
	back.call(&"interact", _player)
	await _wait(12)
	var back_in_town := _main.get_node_or_null("World") as Node3D
	_check("the leader unlocks the return",
		back_in_town != null and back_in_town.scene_file_path == TOWN_PATH)
	_party.call(&"set_leader", 1)
	_finish()


func _on_disturbance(_position: Vector3, radius: float) -> void:
	_disturbances += 1
	_last_radius = radius


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
		print("PASSED  all voice and leader assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
