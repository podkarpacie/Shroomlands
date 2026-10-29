extends SceneTree
## Headless effect-engine test: instant heals clamp, self-damage respects the
## death path, poison ticks and expires without stacking, buffs refresh instead
## of stacking, `max_hp_flat` reverts cleanly, and `damage_mult` really changes
## `CombatSystem` output on a live body.
##
## Effect-only cases run on a bare `PlayerStats` node; the combat case uses the
## real player scene plus a minimal dummy enemy body on the enemy layer, so the
## hitbox query is the production path.

const PLAYER_SCENE_PATH := "res://scenes/player/player.tscn"
const STATS_SCRIPT_PATH := "res://scripts/player/PlayerStats.gd"
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0
var _stats_script: GDScript = null
var _buffs_signals := 0


## A creature the swing query can find: layer 16 body, in the `enemy` group and
## with the same `take_damage` signature the real Enemy exposes.
class DummyEnemy:
	extends StaticBody3D

	var dead := false
	var hp := 100.0
	var hits := 0
	var taken := 0.0

	func take_damage(
		amount: float,
		_is_crit := false,
		_source: Node = null,
		_direction := Vector3.ZERO,
		_heavy := false
	) -> void:
		hits += 1
		taken += amount
		hp = maxf(hp - amount, 0.0)


func _initialize() -> void:
	TestEnv.isolate("test_effects")
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	# `_initialize` runs before the root is processable in a `--script` run; one
	# frame here means every Stats node added later gets `_ready` synchronously.
	await process_frame
	var bus: Node = root.get_node_or_null("EventBus")
	_check("EventBus autoload exists", bus != null)
	if bus != null:
		_check("EventBus declares buffs_changed", bus.has_signal(&"buffs_changed"))
		bus.connect(&"buffs_changed", func() -> void: _buffs_signals += 1)

	_check_heals()
	await _check_over_time()
	_check_poison()
	await _check_buff_refresh_and_expiry()
	await _check_damage_multiplier_on_combat()
	_check_death_path()

	if _failures == 0:
		print("PASSED  all effect assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)


func _check_heals() -> void:
	var stats := _new_stats()
	stats.set("hp", float(stats.get("max_hp")) - 5.0)
	stats.call(&"apply_effect", {"heal": 100.0})
	_check(
		"a 100 HP heal clamps at max_hp (%.1f/%.1f)" % [
			float(stats.get("hp")), float(stats.get("max_hp"))
		],
		is_equal_approx(float(stats.get("hp")), float(stats.get("max_hp")))
	)

	stats.set("stamina", 10.0)
	stats.call(&"apply_effect", {"stamina": 500.0})
	_check(
		"a stamina restore clamps at max_stamina",
		is_equal_approx(float(stats.get("stamina")), float(stats.get("max_stamina")))
	)

	var buffs_before := _buffs_signals
	stats.call(&"apply_effect", {"buff": {"id": "probe", "duration": 5.0, "vision": 1.0}})
	_check("applying an effect emits buffs_changed", _buffs_signals > buffs_before)
	stats.free()


func _check_over_time() -> void:
	var stats := _new_stats()
	stats.set("hp", 50.0)
	stats.call(&"apply_effect", {
		"heal_over_time": {"amount": 10.0, "duration": 0.5},
	})
	await _wait_seconds(0.8)
	var healed := float(stats.get("hp")) - 50.0
	_check("heal_over_time heals its full amount (%.1f of 10)" % healed, absf(healed - 10.0) < 1.0)
	stats.free()


func _check_poison() -> void:
	var stats := _new_stats()
	stats.set("hp", 100.0)
	stats.call(&"apply_effect", {"poison": {"damage": 6.0, "duration": 2.0}})
	_check("poison starts active", bool(stats.call(&"is_poisoned")))
	_check_poison_pill(stats)
	await _wait_seconds(1.15)
	var after_tick := float(stats.get("hp"))
	_check("poison ticks after a second (%.1f HP)" % after_tick, after_tick < 100.0)
	_check("poison is still active mid-duration", bool(stats.call(&"is_poisoned")))
	await _wait_seconds(1.3)
	_check("poison expires on its own", not bool(stats.call(&"is_poisoned")))
	_check(
		"poison dealt about its total damage (%.1f of 6)" % (100.0 - float(stats.get("hp"))),
		absf((100.0 - float(stats.get("hp"))) - 6.0) < 1.0
	)
	_check("the poison row leaves get_buffs()", not _has_buff(stats, "poison"))

	# A second dose refreshes the timer instead of adding a second entry.
	stats.set("hp", 100.0)
	stats.call(&"apply_poison", 4.0, 1.0)
	await _wait_seconds(0.5)
	stats.call(&"apply_poison", 4.0, 1.0)
	var rows := _buff_rows(stats, "poison")
	_check("poison never stacks (one row)", rows.size() == 1)
	if rows.size() == 1:
		_check(
			"a second dose refreshes the poison timer (%.2f s)" % float(rows[0]["time_left"]),
			float(rows[0]["time_left"]) > 0.85
		)
	stats.free()


func _check_buff_refresh_and_expiry() -> void:
	var stats := _new_stats()
	var base_max := float(stats.get("max_hp"))
	stats.set("hp", base_max)
	stats.call(&"apply_effect", {
		"buff": {"id": "vigor", "duration": 0.5, "max_hp_flat": 25.0},
	})
	_check(
		"max_hp_flat raises max_hp (%.0f -> %.0f)" % [base_max, float(stats.get("max_hp"))],
		is_equal_approx(float(stats.get("max_hp")), base_max + 25.0)
	)
	var rows := _buff_rows(stats, "vigor")
	_check("get_buffs() lists the new buff", rows.size() == 1)
	if rows.size() == 1:
		_check("the row carries the derived name (%s)" % str(rows[0]["name"]), str(rows[0]["name"]) == "Vigor")
		_check("the row carries the full duration", is_equal_approx(float(rows[0]["duration"]), 0.5))
		_check("the row carries a running timer", float(rows[0]["time_left"]) > 0.2)

	# Re-apply: one entry, same max_hp (never +50).
	stats.call(&"apply_effect", {
		"buff": {"id": "vigor", "duration": 0.5, "max_hp_flat": 25.0},
	})
	rows = _buff_rows(stats, "vigor")
	_check("re-applying does not add a second row", rows.size() == 1)
	_check(
		"re-applying does not stack max_hp_flat (%.0f)" % float(stats.get("max_hp")),
		is_equal_approx(float(stats.get("max_hp")), base_max + 25.0)
	)
	_check("buffs_changed fired for the refresh", _buffs_signals > 0)

	await _wait_seconds(0.7)
	_check(
		"max_hp reverts to the base on expiry (%.0f)" % float(stats.get("max_hp")),
		is_equal_approx(float(stats.get("max_hp")), base_max)
	)
	_check(
		"current HP is clamped into the smaller pool (%.0f/%.0f)" % [
			float(stats.get("hp")), float(stats.get("max_hp"))
		],
		float(stats.get("hp")) <= float(stats.get("max_hp")) + 0.001
	)
	_check("the buff row disappears on expiry", _buff_rows(stats, "vigor").is_empty())
	stats.free()

	# Modifiers actually reach gameplay reads.
	var modifiers := _new_stats()
	modifiers.call(&"apply_effect", {
		"buff": {"id": "oil", "duration": 30.0, "damage_mult": 1.5},
	})
	modifiers.call(&"apply_effect", {
		"buff": {"id": "shell", "duration": 30.0, "armor_mult": 0.5},
	})
	_check(
		"damage_multiplier() reports damage_mult (%.2f)" % float(modifiers.call(&"damage_multiplier")),
		is_equal_approx(float(modifiers.call(&"damage_multiplier")), 1.5)
	)
	_check(
		"incoming_damage_multiplier() reports armor_mult (%.2f)" % float(
			modifiers.call(&"incoming_damage_multiplier")
		),
		is_equal_approx(float(modifiers.call(&"incoming_damage_multiplier")), 0.5)
	)
	modifiers.set("hp", 100.0)
	modifiers.call(&"take_damage", 10.0)
	_check(
		"armor_mult scales incoming damage (100 -> %.1f)" % float(modifiers.get("hp")),
		is_equal_approx(float(modifiers.get("hp")), 95.0)
	)
	modifiers.free()

	# A short damage buff really falls out of the multiplier.
	var short := _new_stats()
	short.call(&"apply_effect", {
		"buff": {"id": "flicker", "duration": 0.2, "damage_mult": 3.0},
	})
	_check("a short buff multiplies damage", is_equal_approx(float(short.call(&"damage_multiplier")), 3.0))
	await _wait_seconds(0.35)
	_check(
		"an expired buff stops multiplying (%.2f)",
		is_equal_approx(float(short.call(&"damage_multiplier")), 1.0)
	)
	short.free()


func _check_damage_multiplier_on_combat() -> void:
	var packed := load(PLAYER_SCENE_PATH) as PackedScene
	_check("player.tscn loads for the combat case", packed != null)
	if packed == null:
		return
	var player := packed.instantiate() as Node3D
	# The dummy fight is positional; freezing the body keeps every swing aligned.
	player.set_physics_process(false)
	root.add_child(player)
	await physics_frame
	var stats := player.get_node_or_null("Stats")
	var combat := player.get_node_or_null("CombatSystem")
	_check("the player has Stats", stats != null)
	_check("the player has CombatSystem", combat != null)
	if stats == null or combat == null:
		return

	var enemy := DummyEnemy.new()
	enemy.name = "DummyEnemy"
	enemy.collision_layer = 16
	enemy.collision_mask = 0
	enemy.add_to_group(&"enemy")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 1.4, 0.8)
	shape.shape = box
	enemy.add_child(shape)
	root.add_child(enemy)
	await physics_frame

	player.global_position = Vector3(0.0, 1.0, 0.0)
	enemy.global_position = Vector3(0.0, 1.0, -1.8)
	combat.set(&"crit_chance", 0.0)
	await physics_frame
	await physics_frame
	player.set_physics_process(false)

	# The body is frozen, but a physics frame before the flag took hold can still
	# drop it; re-anchor before each swing so the hitbox is deterministic.
	_reset_fight_position(player)
	var light_damage := float(combat.get("light_damage"))
	var hp_before := float(enemy.hp)
	var swung := bool(combat.call(&"try_attack", false))
	var first_drop := hp_before - float(enemy.hp)
	_check("the baseline swing finds the dummy (%d hit)" % enemy.hits, swung and enemy.hits == 1)
	_check(
		"an unbuffed swing deals light_damage (%.1f of %.1f)" % [first_drop, light_damage],
		is_equal_approx(first_drop, light_damage)
	)

	stats.call(&"apply_effect", {
		"buff": {"id": "test_oil", "duration": 10.0, "damage_mult": 2.0},
	})
	_check(
		"the outgoing buff is live (x%.2f)" % float(stats.call(&"damage_multiplier")),
		is_equal_approx(float(stats.call(&"damage_multiplier")), 2.0)
	)
	await _wait_seconds(0.7)
	_reset_fight_position(player)
	var buffed_before := float(enemy.hp)
	var second := bool(combat.call(&"try_attack", false))
	var second_drop := buffed_before - float(enemy.hp)
	_check("the buffed swing lands (%d hits)" % enemy.hits, second and enemy.hits == 2)
	_check(
		"damage_mult doubles CombatSystem output (%.1f of %.1f)" % [second_drop, light_damage * 2.0],
		is_equal_approx(second_drop, light_damage * 2.0)
	)
	_check(
		"the dummy took the sum of both hits (%.1f)" % float(enemy.taken),
		is_equal_approx(float(enemy.taken), light_damage + light_damage * 2.0)
	)
	player.queue_free()
	enemy.queue_free()
	await physics_frame


## Puts the body back on its mark in front of the dummy.
func _reset_fight_position(player: Node3D) -> void:
	player.global_position = Vector3(0.0, 1.0, 0.0)
	player.velocity = Vector3.ZERO
	player.reset_physics_interpolation()


func _check_death_path() -> void:
	var deaths := [0]
	var bus: Node = root.get_node_or_null("EventBus")
	if bus != null:
		bus.connect(&"player_died", func() -> void: deaths[0] += 1)
	var stats := _new_stats()
	stats.set("hp", 5.0)
	stats.call(&"apply_effect", {"self_damage": 20.0})
	_check(
		"an overdose clamps HP at 0, never below (%.1f)" % float(stats.get("hp")),
		is_zero_approx(float(stats.get("hp")))
	)
	_check("an overdose runs the death path", bool(stats.call(&"is_dead")))
	_check("player_died fired exactly once (%d)" % int(deaths[0]), int(deaths[0]) == 1)
	stats.call(&"respawn")
	_check("respawn clears the death state", not bool(stats.call(&"is_dead")))
	_check(
		"respawn refills to max_hp (%.0f/%.0f)" % [
			float(stats.get("hp")), float(stats.get("max_hp"))
		],
		is_equal_approx(float(stats.get("hp")), float(stats.get("max_hp")))
	)
	stats.free()


func _check_poison_pill(stats: Node) -> void:
	var rows := _buff_rows(stats, "poison")
	_check("get_buffs() shows poison as a harmful row", rows.size() == 1 and bool(rows[0].get("harmful", false)))


func _buff_rows(stats: Node, id: String) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var all: Array = stats.call(&"get_buffs")
	for row: Dictionary in all:
		if str(row.get("id", "")) == id:
			rows.append(row)
	return rows


func _has_buff(stats: Node, id: String) -> bool:
	return not _buff_rows(stats, id).is_empty()


func _new_stats() -> Node:
	if _stats_script == null:
		_stats_script = load(STATS_SCRIPT_PATH) as GDScript
	var stats: Node = _stats_script.new()
	root.add_child(stats)
	return stats


func _wait_seconds(seconds: float) -> void:
	await create_timer(seconds).timeout


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)
