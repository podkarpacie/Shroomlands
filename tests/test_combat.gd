extends SceneTree
## Headless combat test on the real `main.tscn`: the player's `CombatSystem` must
## find real enemy bodies, spend stamina, respect the cooldown and the UI lock,
## and a killed creature must award XP and come back at its spawn point.
##
## `main.tscn` is loaded lazily: autoload identifiers only resolve after the
## `--script` main loop starts (same constraint as test_player.gd).

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _main: Node = null
var _player: Node3D = null
var _combat: Node = null
var _stats: Node = null
var _hits: Array[Dictionary] = []
var _deaths := 0
var _respawns := 0


func _initialize() -> void:
	# Structural/behaviour run only: a private save and a private plots file,
	# so this suite never reads or writes the developer's profile.
	TestEnv.isolate("test_combat")
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
	_combat = _player.get_node_or_null("CombatSystem")
	_check("Player/CombatSystem exists", _combat != null)
	_stats = _player.get_node_or_null("Stats")
	_check("player has a Stats component", _stats != null)
	if _combat == null or _stats == null:
		_finish()
		return

	var enemies := get_nodes_in_group(&"enemy")
	print("enemies in group 'enemy': %d" % enemies.size())
	_check("at least 4 enemies are alive (found %d)" % enemies.size(), enemies.size() >= 4)
	if enemies.size() < 2:
		_finish()
		return

	var bus: Variant = root.get_node_or_null("EventBus")
	_check("EventBus autoload is available", bus != null)
	if bus != null:
		bus.connect(
			&"enemy_hit",
			func(enemy: Node, amount: float, is_crit: bool) -> void:
				_hits.append({"enemy": enemy, "amount": amount, "crit": is_crit})
		)
		bus.connect(&"player_died", func() -> void: _deaths += 1)
		bus.connect(&"player_respawned", func() -> void: _respawns += 1)

	# --- one swing, in range -----------------------------------------------
	var target := enemies[0] as Node3D
	_stand_in_front_of(target)
	await _wait_physics(3)

	var light_damage := float(_combat.get("light_damage"))
	var crit_multiplier := float(_combat.get("crit_multiplier"))
	var stamina_cost := float(_combat.get("attack_stamina_cost"))
	var hp_before := float(target.get("hp"))
	var stamina_before := float(_stats.get("stamina"))
	var swung := bool(_combat.call(&"try_attack", false))
	var decrease := stamina_before - float(_stats.get("stamina"))
	var hp_after := float(target.get("hp"))
	var drop := hp_before - hp_after
	print("light swing: %.1f damage, %.1f stamina spent, enemy hp %.1f -> %.1f" % [
		drop, decrease, hp_before, hp_after
	])
	_check("try_attack() returns true when an enemy is in range", swung)
	_check(
		"the swing costs attack_stamina_cost (%.1f of %.1f)" % [decrease, stamina_cost],
		is_equal_approx(decrease, stamina_cost)
	)
	_check(
		"the enemy lost light_damage (%s, crit x%s) (%.1f)" % [light_damage, crit_multiplier, drop],
		is_equal_approx(drop, light_damage) or is_equal_approx(drop, light_damage * crit_multiplier)
	)
	_check("enemy_hit fired exactly once (%d)" % _hits.size(), _hits.size() == 1)
	if not _hits.is_empty():
		_check("enemy_hit names the creature that lost HP", _hits[0]["enemy"] == target)

	# --- cooldown -----------------------------------------------------------
	var second := bool(_combat.call(&"try_attack", false))
	_check("a second swing inside the cooldown returns false", not second)
	_check(
		"the blocked swing deals no damage (%.1f)" % float(target.get("hp")),
		is_equal_approx(float(target.get("hp")), hp_after)
	)
	var cooldown_left := float(_combat.call(&"cooldown_left"))
	print("cooldown after the swing: %.2f s" % cooldown_left)
	_check("cooldown_left() is running (%.2f s)" % cooldown_left, cooldown_left > 0.0)

	# --- modal UI / text entry ---------------------------------------------
	await _wait_physics(40)
	_player.call(&"set_ui_blocking", true)
	_check("ui_blocking makes try_attack() return false", not bool(_combat.call(&"try_attack", false)))
	_player.call(&"set_ui_blocking", false)
	_check("the swing works again once the UI releases the player", bool(_combat.call(&"try_attack", false)))

	# --- stamina ------------------------------------------------------------
	await _wait_physics(40)
	_stats.set("stamina", 0.0)
	_check("attacking with 0 stamina returns false", not bool(_combat.call(&"try_attack", false)))
	_stats.set("stamina", float(_stats.get("max_stamina")))

	# --- heavy swing (Shift + LMB) -----------------------------------------
	var heavy_target := enemies[2] as Node3D
	_stand_in_front_of(heavy_target)
	await _wait_physics(40)
	var heavy_hp_before := float(heavy_target.get("hp"))
	var heavy := bool(_combat.call(&"try_attack", true))
	var heavy_drop := heavy_hp_before - float(heavy_target.get("hp"))
	var heavy_damage := float(_combat.get("heavy_damage"))
	var heavy_cooldown := float(_combat.call(&"cooldown_left"))
	print("heavy swing: %.1f damage, cooldown %.2f s" % [heavy_drop, heavy_cooldown])
	_check("a heavy swing is accepted", heavy)
	_check(
		"the heavy swing deals heavy_damage (%s, crit x%s) (%.1f)" % [
			heavy_damage, crit_multiplier, heavy_drop
		],
		is_equal_approx(heavy_drop, heavy_damage)
		or is_equal_approx(heavy_drop, heavy_damage * crit_multiplier)
	)
	_check(
		"the heavy swing locks the arm 1.5x longer (%.2f s)" % heavy_cooldown,
		is_equal_approx(
			heavy_cooldown,
			float(_combat.get("attack_cooldown")) * float(_combat.get("heavy_cooldown_scale"))
		)
	)

	# --- kill: group exit, XP, respawn --------------------------------------
	var xp_before := int(_stats.get("xp"))
	var xp_reward := int(target.get("xp_reward"))
	var spawn_point := _spawn_position_of(target)
	target.set("respawn_seconds", 0.2)
	target.call(&"take_damage", 999.0, false, _player)
	await _wait_physics(2)
	_check("the killed enemy leaves the 'enemy' group", not target.is_in_group(&"enemy"))
	var model := target.get_node_or_null("Model") as Node3D
	var shrinking := model != null and model.scale.x < 0.99
	_check(
		"the killed enemy is hidden or shrinking (visible=%s scale=%.2f)" % [
			model != null and model.visible, 0.0 if model == null else model.scale.x
		],
		model != null and (not model.visible or shrinking)
	)
	var xp_gain := int(_stats.get("xp")) - xp_before
	print("xp after the kill: %d (+%d)" % [int(_stats.get("xp")), xp_gain])
	_check("killing the enemy awards xp_reward (%d of %d)" % [xp_gain, xp_reward], xp_gain == xp_reward)

	var back := await _wait_until(func() -> bool: return target.is_in_group(&"enemy"), 3000)
	_check("the enemy respawns after respawn_seconds", back)
	if back:
		_check(
			"the respawned enemy has full HP (%.1f/%.1f)" % [
				float(target.get("hp")), float(target.get("max_hp"))
			],
			is_equal_approx(float(target.get("hp")), float(target.get("max_hp")))
		)
		var spawn_distance := target.global_position.distance_to(spawn_point)
		print("respawn distance from the fixed spawn point: %.2f m" % spawn_distance)
		_check("the respawned enemy is back at its spawn point", spawn_distance < 0.75)

	# --- enemy damage, player death, HUD respawn ----------------------------
	var biter := enemies[1] as Node3D
	_stand_in_front_of(biter, 1.2)
	await _wait_physics(3)
	var hp_start := float(_stats.get("hp"))
	await _wait_seconds(2.0)
	var hp_later := float(_stats.get("hp"))
	print("enemy bites: player hp %.0f -> %.0f" % [hp_start, hp_later])
	_check("an adjacent enemy damages the player over time", hp_later < hp_start)

	_stats.set("hp", 6.0)
	var died := await _wait_until(func() -> bool: return _deaths > 0, 6000)
	_check("PlayerStats.die() fires EventBus.player_died", died)
	_check("hp is 0 at death (%.0f)" % float(_stats.get("hp")), is_zero_approx(float(_stats.get("hp"))))

	var respawned := await _wait_until(func() -> bool: return _respawns > 0, 6000)
	_check("the HUD respawns the player after the death overlay", respawned)
	_check(
		"hp is restored to max (%.0f/%.0f)" % [float(_stats.get("hp")), float(_stats.get("max_hp"))],
		is_equal_approx(float(_stats.get("hp")), float(_stats.get("max_hp")))
	)
	var spawn_marker := _main.find_child("PlayerSpawn", true, false) as Node3D
	if spawn_marker != null:
		var moved := _player.global_position.distance_to(spawn_marker.global_position)
		print("player distance to World/PlayerSpawn after respawn: %.2f m" % moved)
		_check("the player respawns at World/PlayerSpawn", moved < 1.5)
	else:
		_check("world has a PlayerSpawn marker", false)

	_finish()


## Stands the player `distance` metres in front of `enemy`. The camera pivot yaw
## is still 0, so the body's aim (and the swing) points down -Z, straight at it.
func _stand_in_front_of(enemy: Node3D, distance := 1.6) -> void:
	_player.global_position = enemy.global_position + Vector3(0.0, 0.9, distance)
	_player.velocity = Vector3.ZERO
	_player.reset_physics_interpolation()


## The fixed spawn point `Main` used for this creature, read from its constant
## map: nothing else in the scene knows where a creature belongs.
func _spawn_position_of(enemy: Node) -> Vector3:
	var constants: Dictionary = _main.get_script().get_script_constant_map()
	if not constants.has("ENEMY_SPAWNS"):
		return enemy.global_position
	var spawns: Array = constants["ENEMY_SPAWNS"]
	var index := String(enemy.name).trim_prefix("Enemy").to_int()
	if index < 0 or index >= spawns.size():
		return enemy.global_position
	var point: Vector3 = spawns[index]
	return point


func _wait_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _wait_seconds(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _wait_until(condition: Callable, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await process_frame
	return bool(condition.call())


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all combat assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
