extends Node
## Player vitals and progression. Owns HP, stamina, level and XP; gold stays in
## `Game`, which forwards XP here, so every value has exactly one owner.
##
## Multiplayer: the body's own client stays the authority for its vitals, the
## same model the transform already uses. `player.tscn` therefore carries a
## second `MultiplayerSynchronizer` under `Stats` (config `net_vitals.tres`,
## `root_path = ".."`, i.e. this node) that replicates `hp`, `stamina`, `level`
## and `xp` owner -> peers. The alternative — mirroring the four values onto the
## player root — would have needed exported forwarders on `PlayerController`,
## which already exposes level/xp only as get/set pairs.
##
## A replicated copy of this node is a read-only mirror: it must not emit into
## the shared `EventBus`, because those signals feed the local HUD and would
## show another player's HP, stamina or level there.

@export var max_hp := 100.0
@export var max_stamina := 100.0
@export var stamina_regen := 18.0
@export var sprint_drain := 22.0

## Vocation bonuses (one per player, applied once — see `apply_vocation_bonus`).
const KNIGHT_BONUS_HP := 20.0
const HEALER_BONUS_STAMINA_REGEN := 6.0
const HARVESTER_BONUS_STAMINA := 25.0
const RANGER_BONUS_WALK_SPEED := 0.8
const RANGER_BONUS_SPRINT_SPEED := 1.2

## Poison is a DoT with its own timer: one tick per second, refreshed (never
## stacked) by a second dose. Total damage is split across whole seconds.
const POISON_TICK_SECONDS := 1.0
## How often `buffs_changed` is re-emitted while a timed effect runs, so the HUD
## countdown advances without the HUD polling the stats.
const BUFF_TICK_SECONDS := 1.0

var hp: float = 0.0
var stamina: float = 0.0
var level := 1
var xp := 0
## Last node that damaged the player; the death screen reads this later.
var last_damage_source: Node = null

var _sprinting := false
var _dead := false
## The vocation whose bonus already ran on this instance; empty until then.
var _vocation_bonus := &""

## Active timed buffs keyed by id: one entry per id, re-applying refreshes the
## timer and replaces the modifiers instead of stacking.
var _buffs: Dictionary = {}
## Poison state, or `{}`. See `apply_poison`.
var _poison: Dictionary = {}
## Heal-over-time state, or `{}`. See `_begin_heal_over_time`.
var _heal_over_time: Dictionary = {}
## What the buffs currently add to the exported maxima, so expiry can put the
## base back even after a vocation bonus changed `max_hp`.
var _max_hp_bonus := 0.0
var _max_stamina_bonus := 0.0
var _last_buff_emit := 0.0


func _ready() -> void:
	hp = max_hp
	stamina = max_stamina
	if not is_local_owner():
		# Somebody else's body: the synchronizer writes these values and this
		# copy must not run regen or announce vitals to the local HUD.
		set_process(false)
		return
	EventBus.hp_changed.emit(hp, max_hp)
	EventBus.stamina_changed.emit(stamina, max_stamina)
	EventBus.xp_changed.emit(xp, Game.xp_to_level(level))
	_drain_pending_xp()


## True on the peer that owns this body, and therefore the only place its
## vitals may change. Offline the local peer owns everything, so this stays
## true and no code path changes.
func is_local_owner() -> bool:
	return is_multiplayer_authority()


func _process(delta: float) -> void:
	if _dead:
		return
	_tick_effects(delta)
	if _dead:
		return
	if _sprinting:
		if stamina > 0.0:
			stamina = maxf(stamina - sprint_drain * delta, 0.0)
			EventBus.stamina_changed.emit(stamina, max_stamina)
		return
	if stamina >= max_stamina:
		return
	stamina = minf(stamina + stamina_regen * delta, max_stamina)
	EventBus.stamina_changed.emit(stamina, max_stamina)


## The controller reports whether sprint is held, so drain and regen never fight.
func set_sprinting(value: bool) -> void:
	_sprinting = value


func is_dead() -> bool:
	return _dead


## Discrete stamina cost (dodge, heavy attack, …). Unchanged and false when the
## player cannot afford it.
func use_stamina(amount: float) -> bool:
	if amount <= 0.0:
		return true
	if _dead or stamina < amount:
		return false
	stamina -= amount
	EventBus.stamina_changed.emit(stamina, max_stamina)
	return true


## --- effects ---------------------------------------------------------------
## One entry point for food, potions and any future hazard. Instants apply once;
## `poison` is a refreshing DoT; `buff` is a refreshing timed modifier. Unknown
## keys (`vision`, `repair_armor`, `throwable`) are stored as data for the
## systems that will read them later, and are ignored here.
func apply_effect(effect: Dictionary) -> void:
	if _dead or effect.is_empty():
		return
	if effect.has("heal"):
		heal(float(effect["heal"]))
	if effect.has("heal_full") and bool(effect["heal_full"]):
		heal(maxf(max_hp - hp, 0.0))
	if effect.has("heal_over_time"):
		_begin_heal_over_time(effect["heal_over_time"])
	if effect.has("stamina"):
		add_stamina(float(effect["stamina"]))
	if effect.has("cleanse") and bool(effect["cleanse"]):
		clear_poison()
	if effect.has("buff"):
		apply_buff(effect["buff"])
	if effect.has("poison"):
		var poison: Dictionary = effect["poison"]
		apply_poison(float(poison.get("damage", 0.0)), float(poison.get("duration", 0.0)))
	if effect.has("self_damage"):
		# Shared damage path: clamps at 0 and runs `die()` when it empties the bar.
		take_damage(float(effect["self_damage"]))


## One-off stamina gain, clamped to the current maximum.
func add_stamina(amount: float) -> void:
	if _dead or amount <= 0.0:
		return
	stamina = minf(stamina + amount, max_stamina)
	EventBus.stamina_changed.emit(stamina, max_stamina)


## Applies or refreshes a timed buff. Buffs never stack: a second dose resets
## `duration` and replaces the modifiers on the one entry for that id.
func apply_buff(buff: Dictionary) -> void:
	if _dead or buff.is_empty():
		return
	var id := str(buff.get("id", ""))
	if id.is_empty():
		return
	var duration := float(buff.get("duration", 0.0))
	if duration <= 0.0:
		return
	var entry := buff.duplicate()
	entry["time_left"] = duration
	entry["duration"] = duration
	_buffs[StringName(id)] = entry
	_recompute_bonuses()
	_buff_changed()


## Poison damage over a fixed duration. A second dose refreshes the timer and
## replaces the amount instead of summing with the old one.
func apply_poison(damage: float, duration: float) -> void:
	if _dead or damage <= 0.0 or duration <= 0.0:
		return
	var ticks := maxi(int(ceil(duration / POISON_TICK_SECONDS)), 1)
	_poison = {
		"damage": damage,
		"duration": duration,
		"time_left": duration,
		"tick_left": minf(POISON_TICK_SECONDS, duration),
		"per_tick": damage / float(ticks),
		"ticks": ticks,
		"ticks_done": 0,
	}
	_buff_changed()


func is_poisoned() -> bool:
	return not _poison.is_empty()


func clear_poison() -> void:
	if _poison.is_empty():
		return
	_poison.clear()
	_buff_changed()


## Active timed effects for the HUD, one row each: buffs first, then poison
## (`harmful`). `time_left` counts down; `duration` is the full length.
func get_buffs() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for id: StringName in _buffs:
		var buff: Dictionary = _buffs[id]
		result.append({
			"id": String(id),
			"name": _buff_name(id, buff),
			"time_left": maxf(float(buff.get("time_left", 0.0)), 0.0),
			"duration": float(buff.get("duration", 0.0)),
			"harmful": bool(buff.get("harmful", false)),
		})
	if not _poison.is_empty():
		result.append({
			"id": "poison",
			"name": "Poison",
			"time_left": maxf(float(_poison.get("time_left", 0.0)), 0.0),
			"duration": float(_poison.get("duration", 0.0)),
			"harmful": true,
		})
	return result


## Outgoing damage multiplier (Weapon Oil, Fury). Multiplies across buffs, so
## two different buffs both count; the same buff id never stacks.
func damage_multiplier() -> float:
	var result := 1.0
	for id: StringName in _buffs:
		result *= float((_buffs[id] as Dictionary).get("damage_mult", 1.0))
	return result


## Multiplier applied to incoming damage (`armor_mult`): below 1 reduces it,
## above 1 makes every hit hurt more.
func incoming_damage_multiplier() -> float:
	var result := 1.0
	for id: StringName in _buffs:
		result *= float((_buffs[id] as Dictionary).get("armor_mult", 1.0))
	return result


func _buff_name(id: StringName, buff: Dictionary) -> String:
	var fallback := String(id).capitalize()
	return str(buff.get("name", fallback))


func _begin_heal_over_time(config: Dictionary) -> void:
	var amount := float(config.get("amount", 0.0))
	var duration := float(config.get("duration", 0.0))
	if amount <= 0.0 or duration <= 0.0:
		return
	_heal_over_time = {
		"amount": amount,
		"duration": duration,
		"time_left": duration,
		"healed": 0.0,
	}
	_buff_changed()


## Advances buffs, poison, heal-over-time and the HUD's countdown. Runs before
## the stamina branch in `_process`, so a DoT still ticks while sprinting.
func _tick_effects(delta: float) -> void:
	var expired := false
	for id: StringName in _buffs.keys():
		var buff: Dictionary = _buffs[id]
		buff["time_left"] = maxf(float(buff.get("time_left", 0.0)) - delta, 0.0)
		if float(buff["time_left"]) <= 0.0:
			_buffs.erase(id)
			expired = true
	if expired:
		_recompute_bonuses()
	_tick_poison(delta)
	if _dead:
		return
	_tick_heal_over_time(delta)
	if _has_timed_effects():
		_last_buff_emit += delta
		if _last_buff_emit >= BUFF_TICK_SECONDS:
			_last_buff_emit = 0.0
			_buff_changed()


func _tick_poison(delta: float) -> void:
	if _poison.is_empty():
		return
	_poison["time_left"] = maxf(float(_poison.get("time_left", 0.0)) - delta, 0.0)
	_poison["tick_left"] = float(_poison.get("tick_left", 0.0)) - delta
	var expired := float(_poison["time_left"]) <= 0.0
	if float(_poison["tick_left"]) > 0.0 and not expired:
		return
	_poison["tick_left"] = POISON_TICK_SECONDS
	var total := int(_poison.get("ticks", 1))
	var done := int(_poison.get("ticks_done", 0))
	var per_tick := float(_poison.get("per_tick", 0.0))
	# The last tick carries the remainder, so the total is exactly `damage`.
	var amount := per_tick
	if done + 1 >= total:
		amount = float(_poison.get("damage", 0.0)) - per_tick * float(total - 1)
	_poison["ticks_done"] = done + 1
	if amount > 0.0:
		take_damage(amount)
	if expired or done + 1 >= total:
		_poison.clear()
		_buff_changed()


func _tick_heal_over_time(delta: float) -> void:
	if _heal_over_time.is_empty():
		return
	var duration := maxf(float(_heal_over_time.get("duration", 0.0)), 0.001)
	var time_left := maxf(float(_heal_over_time.get("time_left", 0.0)) - delta, 0.0)
	var healed := float(_heal_over_time.get("healed", 0.0))
	var target := float(_heal_over_time.get("amount", 0.0)) * (
		1.0 - time_left / duration
	)
	var step := maxf(target - healed, 0.0)
	_heal_over_time["time_left"] = time_left
	_heal_over_time["healed"] = healed + step
	if step > 0.0:
		heal(step)
	if time_left <= 0.0:
		_heal_over_time.clear()
		_buff_changed()


func _has_timed_effects() -> bool:
	return not _buffs.is_empty() or not _poison.is_empty() or not _heal_over_time.is_empty()


## Restores `max_hp`/`max_stamina` to base + the sum of the active `*_flat`
## modifiers and clamps the current bars into the new maximum.
func _recompute_bonuses() -> void:
	var hp_bonus := 0.0
	var stamina_bonus := 0.0
	for id: StringName in _buffs:
		var buff: Dictionary = _buffs[id]
		hp_bonus += float(buff.get("max_hp_flat", 0.0))
		stamina_bonus += float(buff.get("max_stamina_flat", 0.0))
	if not is_equal_approx(hp_bonus, _max_hp_bonus):
		max_hp = maxf(max_hp - _max_hp_bonus + hp_bonus, 1.0)
		_max_hp_bonus = hp_bonus
		hp = minf(hp, max_hp)
		EventBus.hp_changed.emit(hp, max_hp)
	if not is_equal_approx(stamina_bonus, _max_stamina_bonus):
		max_stamina = maxf(max_stamina - _max_stamina_bonus + stamina_bonus, 1.0)
		_max_stamina_bonus = stamina_bonus
		stamina = minf(stamina, max_stamina)
		EventBus.stamina_changed.emit(stamina, max_stamina)


func _buff_changed() -> void:
	# A replicated body mirrors the owner's vitals and must never feed the
	# local HUD with another player's buffs. A node outside the tree (tooling,
	# tests before entry) has no owner to notify either.
	if not is_inside_tree() or not is_local_owner():
		return
	EventBus.buffs_changed.emit()


func _clear_effects() -> void:
	_buffs.clear()
	_poison.clear()
	_heal_over_time.clear()
	_recompute_bonuses()
	_buff_changed()


func take_damage(amount: float, source: Node = null) -> void:
	if _dead or amount <= 0.0:
		return
	last_damage_source = source
	hp = maxf(hp - amount * incoming_damage_multiplier(), 0.0)
	EventBus.hp_changed.emit(hp, max_hp)
	if hp <= 0.0:
		die()


## Server -> owner leg of a creature bite. The AI runs on the server, but only
## the owner may write this body's HP (the same rule the transform follows), so
## the server routes the hit here and the vitals synchronizer carries the result
## back to every peer.
@rpc("any_peer", "call_remote", "reliable")
func apply_damage_rpc(amount: float) -> void:
	if not is_multiplayer_authority():
		return
	if multiplayer.get_remote_sender_id() != 1:
		# Only the server runs enemy AI; a peer may not hurt another player.
		return
	take_damage(amount)


func heal(amount: float) -> void:
	if _dead or amount <= 0.0:
		return
	hp = minf(hp + amount, max_hp)
	EventBus.hp_changed.emit(hp, max_hp)


func die() -> void:
	if _dead:
		return
	_dead = true
	hp = 0.0
	_sprinting = false
	# Buffs, poison and food do not survive death; reset the maxima first so the
	# respawn bar is the real base pool.
	_clear_effects()
	EventBus.hp_changed.emit(hp, max_hp)
	EventBus.player_died.emit()
	# TODO(phase-6): death UI listens on player_died; respawn() is called from it.


func respawn() -> void:
	_clear_effects()
	_dead = false
	last_damage_source = null
	hp = max_hp
	stamina = max_stamina
	_teleport_to_spawn()
	EventBus.hp_changed.emit(hp, max_hp)
	EventBus.stamina_changed.emit(stamina, max_stamina)
	EventBus.player_respawned.emit()


func add_xp(amount: int) -> void:
	if amount <= 0 or _dead:
		return
	xp += amount
	while level < Game.MAX_LEVEL and xp >= Game.xp_to_level(level):
		xp -= Game.xp_to_level(level)
		level_up()
	EventBus.xp_changed.emit(xp, Game.xp_to_level(level))


## One level per call; `add_xp` loops so a single large gain can grant several.
func level_up() -> void:
	if level >= Game.MAX_LEVEL:
		return
	level += 1
	EventBus.level_changed.emit(level)


## Applies the chosen vocation's stat bonus exactly once per Stats instance.
## `VocationUI` calls this right after `Game.set_vocation()` accepts a choice;
## `SaveSystem` calls it again when a save is loaded, so a loaded vocation is
## worth the same as one picked in game.
func apply_vocation_bonus(id: String) -> void:
	if id.is_empty() or not _vocation_bonus.is_empty() or not Lore.VOCATIONS.has(id):
		return
	match id:
		"knight":
			# Front-liner: a bigger pool, filled on the spot so the choice
			# reads as an upgrade rather than a longer empty bar.
			max_hp += KNIGHT_BONUS_HP
			hp = max_hp
			EventBus.hp_changed.emit(hp, max_hp)
		"healer":
			stamina_regen += HEALER_BONUS_STAMINA_REGEN
		"harvester":
			max_stamina += HARVESTER_BONUS_STAMINA
			EventBus.stamina_changed.emit(stamina, max_stamina)
		"ranger":
			_apply_controller_speed_bonus(RANGER_BONUS_WALK_SPEED, RANGER_BONUS_SPRINT_SPEED)
		_:
			return
	_vocation_bonus = StringName(id)


## The ranger bonus belongs to the controller, which owns walk/sprint speed.
## The body is the parent in `player.tscn`; a Stats node used standalone in a
## test simply has no body to tune.
func _apply_controller_speed_bonus(walk_bonus: float, sprint_bonus: float) -> void:
	var body := get_parent()
	if body == null or not body.has_method(&"apply_vocation_speed_bonus"):
		return
	body.call(&"apply_vocation_speed_bonus", walk_bonus, sprint_bonus)


## XP gathered while no player existed (menu, save load) waits in Game.
func _drain_pending_xp() -> void:
	if Game.pending_xp <= 0:
		return
	var pending := Game.pending_xp
	Game.pending_xp = 0
	add_xp(pending)


## Game owns session state but has no spawn accessor yet, so the world's
## `PlayerSpawn` marker is resolved from the scene tree on respawn only.
func _teleport_to_spawn() -> void:
	var body := get_parent() as Node3D
	if body == null or not is_inside_tree():
		return
	var spawn := get_tree().get_root().find_child("PlayerSpawn", true, false) as Node3D
	if spawn != null:
		body.global_position = spawn.global_position
