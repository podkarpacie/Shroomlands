extends Node
## Global audio: a small pool of SFX players, one ambient music player and the
## two persisted volume levels.
##
## Every cue is synthesised by `tools/generate_audio.py` into
## `res://assets/audio/` and is resolved by id, so gameplay code names a sound
## ("gather") instead of a file path and the mix can be retuned in one place.
## Volumes are linear 0..1 everywhere outside this file; the audio buses take
## decibels, which is why every setter converts through `linear_to_db` with a
## floor (see `_db_for`).
##
## The ambient bed belongs to the world, not the menu: it starts when a node in
## group `main` (the root of `main.tscn`) enters the tree and stops when the last
## one leaves. The lobby is deliberately silent apart from the UI click.
##
## A headless run (dedicated server, CI) starts with output disabled: there is no
## listener, and a playback that is still active when the process quits is
## reported as a leaked resource by Godot 4.7 (godotengine/godot#76745).
## `set_output_enabled(true)` re-enables the pool for tools and tests.

const SFX_DIR := "res://assets/audio"
const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "settings"
const MUSIC_BUS := &"Music"
const SFX_BUS := &"SFX"
const WORLD_GROUP := &"main"

## Eight voices cover a crit, a gather and a level-up landing together; a single
## player would cut the previous cue every time it is retriggered.
const SFX_VOICES := 8
## Defaults match the bus layout: -12 dB for the ambience, -4 dB for effects.
const DEFAULT_MUSIC_VOLUME := 0.2511886432
const DEFAULT_SFX_VOLUME := 0.6309573445
## `linear_to_db(0.0)` is -inf, so silence is mapped to this instead.
const MIN_LINEAR := 0.0001
## A gather also reports the item it produced, and one pickup can add several
## stacks in a row; cues closer together than this are the same event.
const DUPLICATE_WINDOW_MSEC := 150
## `Main._ready` restores a save by re-emitting level and item signals, which is
## not a moment to cheer; the first second of a world stays quiet.
const WORLD_SETTLE_MSEC := 1000

var _voices: Array[AudioStreamPlayer] = []
var _voice_started: Array[int] = []
var _music: AudioStreamPlayer = null
## `id -> AudioStream`, including `null` for a cue that does not exist, so an
## unknown id warns once and then stays quiet.
var _streams: Dictionary = {}
var _warned_buses: Dictionary = {}
var _music_volume := DEFAULT_MUSIC_VOLUME
var _sfx_volume := DEFAULT_SFX_VOLUME
## False in a headless run; see the class comment.
var _output_enabled := DisplayServer.get_name() != "headless"
var _world: Node = null
var _settle_until_msec := 0
var _pickup_quiet_until_msec := 0
## Last HP seen on `hp_changed`; negative until the first report.
var _last_hp := -1.0


func _ready() -> void:
	_build_players()
	_load_volumes()
	_apply_volumes()
	_connect_events()
	# `main.tscn` may be entered before or after this autoload's `_ready`, so
	# watch the tree instead of hard-coding a reference to the world scene.
	get_tree().node_added.connect(_on_node_added)
	for node: Node in get_tree().get_nodes_in_group(WORLD_GROUP):
		_watch_world(node)


func _exit_tree() -> void:
	if get_tree() != null and get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	if _world != null and is_instance_valid(_world):
		if _world.tree_exiting.is_connected(_on_world_exiting):
			_world.tree_exiting.disconnect(_on_world_exiting)
		_world = null
	_disconnect_events()
	_release_players()


## Drops the streams this manager holds as the tree is torn down, so a reloaded
## manager starts from a clean slate instead of keeping a few megabytes alive.
func _release_players() -> void:
	for voice: AudioStreamPlayer in _voices:
		voice.stop()
		voice.stream = null
	if _music != null:
		_music.stop()
		_music.stream = null
	_streams.clear()


# --- public API ------------------------------------------------------------


## Plays one cue on a free voice, with a little pitch variation so repeated
## hits do not sound like a machine. An unknown id warns once and plays nothing.
func play_sfx(id: StringName, pitch_jitter := 0.06, volume_db := 0.0) -> void:
	_play(id, 1.0, pitch_jitter, volume_db)


## True when `id` resolves to a cue. Resolving an unknown id warns once.
func has_cue(id: StringName) -> bool:
	return _stream_for(id) != null


## Starts the seamless ambient bed. Safe to call repeatedly.
func start_music() -> void:
	if not _output_enabled or _music == null or _music.playing:
		return
	var stream := _stream_for(&"ambient_mycelia")
	if stream == null:
		return
	_ensure_loop(stream)
	_music.stream = stream
	_music.play()


## The WAV importer marks the ambience as a forward loop; this keeps the bed
## looping even if the import descriptor is regenerated with the default.
func _ensure_loop(stream: AudioStream) -> void:
	var wav := stream as AudioStreamWAV
	if wav == null or wav.loop_mode != AudioStreamWAV.LOOP_DISABLED:
		return
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = int(round(wav.get_length() * float(wav.mix_rate)))


func stop_music() -> void:
	if _music != null and _music.playing:
		_music.stop()


func is_music_playing() -> bool:
	return _music != null and _music.playing


func is_output_enabled() -> bool:
	return _output_enabled


## Turns the pool and the ambient bed on or off. Disabling stops everything that
## is still sounding; a headless process starts disabled.
func set_output_enabled(enabled: bool) -> void:
	if _output_enabled == enabled:
		return
	_output_enabled = enabled
	if enabled:
		if _world != null:
			start_music()
		return
	stop_music()
	for voice: AudioStreamPlayer in _voices:
		voice.stop()


## Linear 0..1, persisted. 0 is silence, never -inf on the bus.
func set_music_volume(linear: float) -> void:
	_music_volume = clampf(linear, 0.0, 1.0)
	_set_bus_volume(MUSIC_BUS, _music_volume)
	_save_volumes()


func set_sfx_volume(linear: float) -> void:
	_sfx_volume = clampf(linear, 0.0, 1.0)
	_set_bus_volume(SFX_BUS, _sfx_volume)
	_save_volumes()


func music_volume() -> float:
	return _music_volume


func sfx_volume() -> float:
	return _sfx_volume


# --- players and buses -----------------------------------------------------


func _build_players() -> void:
	for index in SFX_VOICES:
		var voice := AudioStreamPlayer.new()
		voice.name = "Sfx%d" % (index + 1)
		voice.bus = SFX_BUS
		add_child(voice)
		_voices.append(voice)
		_voice_started.append(0)
	_music = AudioStreamPlayer.new()
	_music.name = "Music"
	_music.bus = MUSIC_BUS
	add_child(_music)


## Decibels for a linear level, floored so 0 % is quiet instead of -inf.
func _db_for(linear: float) -> float:
	return linear_to_db(maxf(linear, MIN_LINEAR))


func _bus_index(bus: StringName) -> int:
	var index := AudioServer.get_bus_index(bus)
	if index < 0 and not _warned_buses.has(bus):
		_warned_buses[bus] = true
		push_warning(
			"AudioManager: audio bus '%s' is missing; check default_bus_layout.tres." % bus
		)
	return index


func _set_bus_volume(bus: StringName, linear: float) -> void:
	var index := _bus_index(bus)
	if index < 0:
		return
	AudioServer.set_bus_volume_db(index, _db_for(linear))


func _apply_volumes() -> void:
	_set_bus_volume(MUSIC_BUS, _music_volume)
	_set_bus_volume(SFX_BUS, _sfx_volume)


# --- cue resolution and playback -------------------------------------------


func _stream_for(id: StringName) -> AudioStream:
	if _streams.has(id):
		return _streams[id] as AudioStream
	var stream: AudioStream = null
	var path := "%s/%s.wav" % [SFX_DIR, id]
	if ResourceLoader.exists(path):
		stream = load(path) as AudioStream
	if stream == null:
		# Baked in above with the null: the next request stays silent.
		push_warning("AudioManager: unknown audio cue '%s' (%s)." % [id, path])
		_streams[id] = null
		return null
	_streams[id] = stream
	return stream


func _play(id: StringName, pitch: float, pitch_jitter: float, volume_db: float) -> void:
	if not _output_enabled:
		return
	var stream := _stream_for(id)
	if stream == null:
		return
	var index := _pick_voice()
	_voice_started[index] = Time.get_ticks_msec()
	var voice := _voices[index]
	voice.stream = stream
	voice.pitch_scale = maxf(pitch + randf_range(-pitch_jitter, pitch_jitter), 0.05)
	voice.volume_db = clampf(volume_db, -60.0, 6.0)
	voice.play()


## Index of a free voice, or of the one that started longest ago when all are
## busy, so a burst of hits never cuts the cue that is still ringing.
func _pick_voice() -> int:
	for index in _voices.size():
		if not _voices[index].playing:
			return index
	var oldest := 0
	for index in _voices.size():
		if _voice_started[index] < _voice_started[oldest]:
			oldest = index
	return oldest


# --- event wiring ----------------------------------------------------------


func _connect_events() -> void:
	if not is_instance_valid(EventBus):
		return
	_track(EventBus.enemy_hit, _on_enemy_hit)
	_track(EventBus.mushroom_gathered, _on_mushroom_gathered)
	_track(EventBus.item_added, _on_item_added)
	_track(EventBus.level_changed, _on_level_changed)
	_track(EventBus.player_died, _on_player_died)
	_track(EventBus.object_placed, _on_object_placed)
	_track(EventBus.vocation_chosen, _on_vocation_chosen)
	_track(EventBus.hp_changed, _on_hp_changed)


func _disconnect_events() -> void:
	if not is_instance_valid(EventBus):
		return
	for entry: Array in [
		[EventBus.enemy_hit, _on_enemy_hit],
		[EventBus.mushroom_gathered, _on_mushroom_gathered],
		[EventBus.item_added, _on_item_added],
		[EventBus.level_changed, _on_level_changed],
		[EventBus.player_died, _on_player_died],
		[EventBus.object_placed, _on_object_placed],
		[EventBus.vocation_chosen, _on_vocation_chosen],
		[EventBus.hp_changed, _on_hp_changed],
	]:
		var source: Signal = entry[0]
		var handler: Callable = entry[1]
		if source.is_connected(handler):
			source.disconnect(handler)


## Connects only when the signal is free of this handler, so a reloaded autoload
## never plays a cue twice.
func _track(source: Signal, handler: Callable) -> void:
	if not source.is_connected(handler):
		source.connect(handler)


## True while a freshly loaded world is still restoring its save.
func _settling() -> bool:
	return Time.get_ticks_msec() < _settle_until_msec


## `enemy_hit` fires on the creature that lost HP. A lethal one is the death
## squelch; everything else is the player's blade connecting.
func _on_enemy_hit(enemy: Node, _amount: float, is_crit: bool) -> void:
	if _settling():
		return
	var dying := (
		enemy != null
		and is_instance_valid(enemy)
		and "hp" in enemy
		and float(enemy.get(&"hp")) <= 0.0
	)
	if dying:
		_play(&"enemy_die", 1.0, 0.05, -2.0)
		return
	if is_crit:
		_play(&"hit", 1.18, 0.03, 3.0)
	else:
		play_sfx(&"hit", 0.09)


func _on_mushroom_gathered(_mushroom_id: String, _count: int) -> void:
	if _settling():
		return
	# The same gather also adds the item, and the pickup ding is for pickups.
	_pickup_quiet_until_msec = Time.get_ticks_msec() + DUPLICATE_WINDOW_MSEC
	play_sfx(&"gather", 0.08, -1.0)


func _on_item_added(_id: String, count: int) -> void:
	if count <= 0 or _settling():
		return
	if Time.get_ticks_msec() < _pickup_quiet_until_msec:
		return
	_pickup_quiet_until_msec = Time.get_ticks_msec() + DUPLICATE_WINDOW_MSEC
	play_sfx(&"pickup", 0.04, -6.0)


func _on_level_changed(_new_level: int) -> void:
	if _settling():
		return
	play_sfx(&"level_up", 0.02, -2.0)


func _on_player_died() -> void:
	play_sfx(&"death", 0.0, -2.0)


func _on_object_placed(_plot_id: int, _object_id: String, _cell: Vector3i) -> void:
	play_sfx(&"place", 0.07, -3.0)


## A vocation is a milestone too, so it reuses the arpeggio one step lower.
func _on_vocation_chosen(_vocation_id: String) -> void:
	_play(&"level_up", 0.82, 0.01, -4.0)


## The player being hurt: the soft wet thud, not the blade cue. Only a decrease
## counts, so healing, respawning and the initial report stay silent.
func _on_hp_changed(current: float, _max_hp: float) -> void:
	var hurt := _last_hp >= 0.0 and current > 0.0 and current < _last_hp - 0.5
	_last_hp = current
	if not hurt or _settling():
		return
	_play(&"enemy_hit", 1.0, 0.08, -4.0)


# --- world tracking --------------------------------------------------------


func _on_node_added(node: Node) -> void:
	if node.is_in_group(WORLD_GROUP):
		_watch_world(node)
	_watch_footsteps(node)


## Every `LimbAnimator` under a body in group `player` reports its footfalls.
## A replicated body animates from position deltas, so its steps are as real as
## the local ones and both peers hear the same gait.
func _watch_footsteps(node: Node) -> void:
	if not node.has_signal(&"stepped"):
		return
	var body := node.get_parent()
	if body == null or not body.is_in_group(&"player"):
		return
	if not node.is_connected(&"stepped", _on_stepped):
		node.connect(&"stepped", _on_stepped)


## A step is texture under the scene, not an event: quieter than every combat
## cue, with enough pitch variation that the same sample does not machine-gun.
func _on_stepped(_foot: int) -> void:
	if _settling():
		return
	play_sfx(&"footstep", 0.12, -9.0)


func _watch_world(world: Node) -> void:
	if _world == world:
		return
	_world = world
	if not world.tree_exiting.is_connected(_on_world_exiting):
		world.tree_exiting.connect(_on_world_exiting)
	_settle_until_msec = Time.get_ticks_msec() + WORLD_SETTLE_MSEC
	start_music()


func _on_world_exiting() -> void:
	var exiting := _world
	_world = null
	for node: Node in get_tree().get_nodes_in_group(WORLD_GROUP):
		if node != exiting and not node.is_queued_for_deletion():
			_watch_world(node)
			return
	stop_music()


# --- persistence -----------------------------------------------------------


func _load_volumes() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	_music_volume = clampf(
		float(config.get_value(SETTINGS_SECTION, "music_volume", DEFAULT_MUSIC_VOLUME)), 0.0, 1.0
	)
	_sfx_volume = clampf(
		float(config.get_value(SETTINGS_SECTION, "sfx_volume", DEFAULT_SFX_VOLUME)), 0.0, 1.0
	)


## Rewrites only the two volume keys: the lobby owns the same file and its
## sensitivity and fullscreen settings have to survive a slider move.
func _save_volumes() -> void:
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH)
	config.set_value(SETTINGS_SECTION, "music_volume", _music_volume)
	config.set_value(SETTINGS_SECTION, "sfx_volume", _sfx_volume)
	var error := config.save(SETTINGS_PATH)
	if error != OK:
		push_warning("AudioManager: cannot save volumes: %s" % error_string(error))
