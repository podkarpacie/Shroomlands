extends SceneTree
## Headless Spore Bloom test on the real `main.tscn` player: a nearby player
## arms the bloom, the swell bursts into a cloud that ticks HP, leaving the
## cloud stops the damage, and a hit before the burst destroys it with no loot.
##
## `main.tscn` is loaded lazily for the same reason as `test_combat.gd`
## (autoload identifiers are not resolvable while `--script` compiles).

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const BLOOM_SCENE_PATH := "res://scenes/world/spore_bloom.tscn"
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _main: Node = null
var _player: Node3D = null
var _stats: Node = null
var _inventory: Node = null


func _initialize() -> void:
	TestEnv.isolate("test_spore_bloom")
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
	_stats = _player.get_node_or_null("Stats")
	_inventory = _player.get_node_or_null("InventorySystem")
	_check("player has Stats and InventorySystem", _stats != null and _inventory != null)
	if _stats == null or _inventory == null:
		_finish()
		return

	var bloom_scene := load(BLOOM_SCENE_PATH) as PackedScene
	_check("spore_bloom.tscn loads", bloom_scene != null)
	if bloom_scene == null:
		_finish()
		return

	await _check_spawn(bloom_scene)
	await _check_burst_and_cloud(bloom_scene)
	await _check_destroyed_before_burst(bloom_scene)
	_finish()


## A bloom far from the player: authored model installed, fallback hidden and
## the scene is a valid combat target that stays idle.
func _check_spawn(bloom_scene: PackedScene) -> void:
	var bloom := bloom_scene.instantiate()
	bloom.position = _player.global_position + Vector3(8.0, 0.0, 8.0)
	root.add_child(bloom)
	await _wait_physics(3)

	_check("a bloom joins the hazard group", bloom.is_in_group(&"hazard"))
	_check("the authored model is installed", bloom.get_node_or_null("Model") != null)
	_check("the primitive stem is hidden", not (bloom.get_node("Stem") as Node3D).visible)
	_check("a distant bloom stays idle", int(bloom.get("state")) == 0)
	_check("idle bloom is not a cloud", not bool(bloom.call("is_cloud_active")))

	bloom.queue_free()
	await _wait_physics(2)


## The designed sequence: arm at 2.5 m, swell 0.6 s, burst, tick damage while
## inside, stop when the player leaves.
func _check_burst_and_cloud(bloom_scene: PackedScene) -> void:
	var hp_before := float(_stats.get("hp"))
	var bloom := bloom_scene.instantiate()
	bloom.position = _player.global_position + Vector3(1.5, 0.0, 0.0)
	root.add_child(bloom)
	await _wait_physics(5)

	_check("a bloom within 2.5 m arms", bool(bloom.call("is_armed")))
	await create_timer(0.85).timeout
	_check("the swell bursts after 0.6 s", bool(bloom.call("is_cloud_active")))
	var cloud := bloom.get_node_or_null("Cloud") as CPUParticles3D
	_check("the burst emits a cloud", cloud != null and cloud.emitting)

	await create_timer(1.1).timeout
	var hp_inside := float(_stats.get("hp"))
	_check(
		"the cloud ticks damage (%.0f -> %.0f)" % [hp_before, hp_inside],
		hp_inside < hp_before
	)

	# Step well outside the 3 m cloud and let another tick window pass.
	_player.global_position += Vector3(14.0, 0.0, 0.0)
	await _wait_physics(3)
	var hp_left := float(_stats.get("hp"))
	await create_timer(1.2).timeout
	_check(
		"leaving the cloud stops the damage (%.0f -> %.0f)" % [hp_left, float(_stats.get("hp"))],
		is_equal_approx(float(_stats.get("hp")), hp_left)
	)

	bloom.queue_free()
	await _wait_physics(2)


## Hitting it before the swell finishes destroys it harmlessly: no burst, no
## cloud, and nothing enters the inventory. Two real light swings prove the
## CombatSystem query actually reaches a hazard (layer 32 + `hazard` group).
func _check_destroyed_before_burst(bloom_scene: PackedScene) -> void:
	var items_before := _inventory_total()
	var combat := _player.get_node_or_null("CombatSystem")
	var pivot := _player.get_node_or_null("CameraPivot") as Node3D
	_check("player has a CombatSystem and camera pivot", combat != null and pivot != null)
	if combat == null or pivot == null:
		return

	var forward := -pivot.global_basis.z
	forward.y = 0.0
	forward = Vector3.FORWARD if forward.length() < 0.1 else forward.normalized()
	var bloom := bloom_scene.instantiate()
	# Long swell: this test is about the swing, not the timer.
	bloom.set(&"swell_seconds", 6.0)
	bloom.position = _player.global_position + forward * 1.6
	root.add_child(bloom)
	await _wait_physics(3)
	_check("the second bloom arms", bool(bloom.call("is_armed")))

	combat.call(&"try_attack")
	await _wait_physics(2)
	_check("a real swing reaches the bloom", int(combat.get("last_hit_count")) >= 1)
	await create_timer(0.6).timeout
	combat.call(&"try_attack")
	await _wait_physics(2)
	_check("two light swings destroy it", bool(bloom.get("dead")))
	_check("a destroyed bloom is no longer a target", not bloom.is_in_group(&"hazard"))
	_check("a destroyed bloom never bursts", not bool(bloom.call("is_cloud_active")))
	var cloud := bloom.get_node_or_null("Cloud") as CPUParticles3D
	_check("no cloud starts on a destroyed bloom", cloud == null or not cloud.emitting)

	await create_timer(0.5).timeout
	_check("the bloom drops no loot", _inventory_total() == items_before)


func _inventory_total() -> int:
	var total := 0
	var slots: Array = _inventory.get("slots")
	for slot: Dictionary in slots:
		total += int(slot.get("count", 0))
	return total


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
	if _failures == 0:
		print("PASSED  all spore bloom assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
