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


func take_damage(amount: float, source: Node = null) -> void:
	if _dead or amount <= 0.0:
		return
	last_damage_source = source
	hp = maxf(hp - amount, 0.0)
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
	EventBus.hp_changed.emit(hp, max_hp)
	EventBus.player_died.emit()
	# TODO(phase-6): death UI listens on player_died; respawn() is called from it.


func respawn() -> void:
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
