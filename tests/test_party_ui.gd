extends SceneTree
## Headless party UI test: the HUD lists the group with a lamp marker, only the
## leader can hand the lamp to the nearest living body, and the lamp follows.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const PLAYER_SCENE_PATH := "res://scenes/player/player.tscn"
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _main: Node = null
var _player: Node3D = null
var _other: Node3D = null
var _party: Node = null
var _hud: Node = null


func _initialize() -> void:
	TestEnv.isolate("test_party_ui")
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
	_party = root.get_node_or_null("/root/Party")
	_check("the Party autoload exists", _party != null)
	if _party == null:
		_finish()
		return
	_player = get_first_node_in_group(&"player") as Node3D
	_check("a player was spawned", _player != null)
	if _player == null:
		_finish()
		return
	_hud = _main.get_node_or_null("HUD")
	var party_label := _main.get_node_or_null("HUD/Root/PartyBackdrop/PartyLabel") as Label
	_check("the HUD has a party panel", party_label != null)
	if party_label != null:
		_check("the party panel names the solo leader (%s)" % party_label.text,
			party_label.text.contains("PARTY") and party_label.text.contains("[LAMP]")
			and party_label.text.contains("(you)"))
	_check("L is bound to pass_lamp", InputMap.has_action(&"pass_lamp"))
	_check("main has the PartyActions node", _main.get_node_or_null("PartyActions") != null)

	# A second body joins the party.
	_other = (load(PLAYER_SCENE_PATH) as PackedScene).instantiate() as Node3D
	_other.name = "2"
	_other.set_multiplayer_authority(2)
	_other.position = _player.position + Vector3(2.0, 0.0, 0.0)
	_main.get_node("Players").add_child(_other)
	await _wait(10)
	_check("the party now has two bodies", get_nodes_in_group(&"player").size() == 2)

	var lamp := _player.get_node_or_null("SporeLamp")
	_check("the leader has a lamp", lamp != null)
	if lamp != null:
		lamp.call(&"toggle")
		_check("the leader's lamp is on", bool(lamp.call(&"is_on")))

	# --- handoff ----------------------------------------------------------
	var target := int(_party.call(&"pass_to_nearest", _player, 8.0))
	_check("the nearest forager receives the lamp (%d)" % target, target == 2)
	_check("leadership moved", int(_party.get(&"leader_id")) == 2)
	await _wait(40)
	if lamp != null:
		_check("the old leader's lamp goes dark", not bool(lamp.call(&"is_on")))
	if party_label != null:
		_check("the HUD marks the new leader (%s)" % party_label.text,
			party_label.text.contains("[LAMP] Player 2"))

	var refused := int(_party.call(&"pass_to_nearest", _player, 8.0))
	_check("a non-leader cannot pass it (%d)" % refused, refused == -1)

	# --- nobody close -----------------------------------------------------
	_party.call(&"set_leader", 1)
	_other.position += Vector3(40.0, 0.0, 0.0)
	await _wait(10)
	var nobody := int(_party.call(&"pass_to_nearest", _player, 8.0))
	_check("an empty clearing keeps the lamp (%d)" % nobody, nobody == 0)
	_check("leadership stayed put", int(_party.get(&"leader_id")) == 1)
	await _wait(40)
	if party_label != null:
		_check("the HUD marks the local leader (%s)" % party_label.text,
			party_label.text.contains("[LAMP] Player 1"))

	_other.queue_free()
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
		print("PASSED  all party UI assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
