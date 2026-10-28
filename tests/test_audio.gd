extends SceneTree
## Headless audio test: the bus layout, the synthesised cues, cue playback and
## the persisted volume levels.
##
## Nothing here can be heard — a headless Godot has no output device — so the
## suite asserts what is observable: the buses exist and resolve, every cue
## loads as a non-empty `AudioStream`, a pooled player really starts, 0 % maps to
## a finite (very low) bus volume, and the ambient stream is marked as a loop.
## `user://settings.cfg` is stashed by tests/test_env.gd, so the developer's own
## volumes are restored untouched.

const TestEnv := preload("res://tests/test_env.gd")

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "settings"
const SFX_DIR := "res://assets/audio"
const CUES: Array[String] = [
	"hit",
	"enemy_hit",
	"enemy_die",
	"gather",
	"pickup",
	"level_up",
	"death",
	"place",
	"footstep",
	"ui_click",
	"ambient_mycelia",
]
const AMBIENT := "ambient_mycelia"
const PROBE_MUSIC_VOLUME := 0.37
const PROBE_SFX_VOLUME := 0.42
const DEFAULT_MUSIC_VOLUME := 0.2511886432
const DEFAULT_SFX_VOLUME := 0.6309573445

var _failures := 0


func _initialize() -> void:
	TestEnv.stash(SETTINGS_PATH)
	_run()


func _finalize() -> void:
	TestEnv.restore_all()


func _run() -> void:
	# Autoload `_ready` calls run on the first frame, after `_initialize`.
	await process_frame
	var audio: Node = root.get_node_or_null("Audio")
	_check("the Audio autoload exists", audio != null)
	if audio == null:
		_finish()
		return
	_check(
		"Audio is registered after EventBus",
		audio.get_index() > root.get_node("EventBus").get_index()
	)

	# --- buses --------------------------------------------------------------
	_check(
		"the bus layout is wired in project settings (%s)" % ProjectSettings.get_setting(
			"audio/buses/default_bus_layout", ""
		),
		String(ProjectSettings.get_setting("audio/buses/default_bus_layout", ""))
			== "res://default_bus_layout.tres"
	)
	_check(
		"Master is bus 0 (%s)" % AudioServer.get_bus_name(0),
		AudioServer.get_bus_name(0) == "Master"
	)
	var music_bus := AudioServer.get_bus_index(&"Music")
	var sfx_bus := AudioServer.get_bus_index(&"SFX")
	_check("the Music bus exists (index %d)" % music_bus, music_bus >= 0)
	_check("the SFX bus exists (index %d)" % sfx_bus, sfx_bus >= 0)
	# The suite starts with no settings file (TestEnv stashed it), so both levels
	# are the ones baked into default_bus_layout.tres.
	if music_bus >= 0:
		_check(
			"the Music bus sends to Master (%s)" % AudioServer.get_bus_send(music_bus),
			AudioServer.get_bus_send(music_bus) == &"Master"
		)
		_check(
			"the Music bus starts at the layout level (%.1f dB)" % AudioServer.get_bus_volume_db(
				music_bus
			),
			is_equal_approx(AudioServer.get_bus_volume_db(music_bus), -12.0)
		)
	if sfx_bus >= 0:
		_check(
			"the SFX bus sends to Master (%s)" % AudioServer.get_bus_send(sfx_bus),
			AudioServer.get_bus_send(sfx_bus) == &"Master"
		)
		_check(
			"the SFX bus starts at the layout level (%.1f dB)" % AudioServer.get_bus_volume_db(
				sfx_bus
			),
			is_equal_approx(AudioServer.get_bus_volume_db(sfx_bus), -4.0)
		)

	# --- cue files ----------------------------------------------------------
	for id: String in CUES:
		var path := "%s/%s.wav" % [SFX_DIR, id]
		var stream := load(path) as AudioStream
		_check("%s loads as an AudioStream" % path.get_file(), stream != null)
		if stream == null:
			continue
		_check("%s is non-empty (%.2f s)" % [path.get_file(), stream.get_length()],
			stream.get_length() > 0.0)
		if stream is AudioStreamWAV:
			var wav := stream as AudioStreamWAV
			_check("%s carries sample data (%d bytes)" % [path.get_file(), wav.data.size()],
				wav.data.size() > 1024)
		_check("Audio knows the '%s' cue" % id, bool(audio.call(&"has_cue", StringName(id))))

	# The footstep has to stay a short scuff: it is triggered twice per gait
	# cycle, so a long tail would smear the walk into a drone.
	var footstep := load("%s/footstep.wav" % SFX_DIR) as AudioStream
	_check("the footstep cue loads", footstep != null)
	if footstep != null:
		_check(
			"the footstep cue is short (%.3f s)" % footstep.get_length(),
			footstep.get_length() > 0.05 and footstep.get_length() < 0.15
		)

	# --- the ambient bed loops ---------------------------------------------
	var ambient := load("%s/%s.wav" % [SFX_DIR, AMBIENT]) as AudioStreamWAV
	_check("the ambient cue is an AudioStreamWAV", ambient != null)
	if ambient != null:
		_check(
			"the ambient stream is looped (loop_mode %d)" % ambient.loop_mode,
			ambient.loop_mode != AudioStreamWAV.LOOP_DISABLED
		)
		var frames := int(round(ambient.get_length() * float(ambient.mix_rate)))
		_check("the ambient loop covers the whole file (%d frames)" % ambient.loop_end,
			ambient.loop_end <= 0 or ambient.loop_end >= frames - 1)

	# --- playback -----------------------------------------------------------
	# A headless process starts silent (no output device, and an active playback
	# at exit is reported as a leaked resource); enabling output lets this suite
	# prove the pool really starts a player.
	_check(
		"a headless run starts with output disabled",
		not bool(audio.call(&"is_output_enabled"))
	)
	audio.call(&"set_output_enabled", true)
	_check("output can be enabled for the playback checks",
		bool(audio.call(&"is_output_enabled")))
	_check("Audio exposes play_sfx", audio.has_method(&"play_sfx"))
	audio.call(&"play_sfx", &"hit", 0.0, 0.0)
	_check("a valid cue starts a player", _any_voice_playing(audio, &"SFX"))

	# Unknown ids must be harmless and reported once; the second call finds the
	# cached miss and returns without warning again (the suite's stderr is
	# checked for a single warning line in the acceptance run).
	audio.call(&"play_sfx", &"not_a_cue")
	audio.call(&"play_sfx", &"not_a_cue")
	_check("an unknown cue is not reported as known", not bool(audio.call(&"has_cue", &"not_a_cue")))
	_check("an unknown cue leaves the pool playable", _any_voice_playing(audio, &"SFX"))

	# --- the world hook -----------------------------------------------------
	var fake_world := Node.new()
	fake_world.name = "FakeMain"
	fake_world.add_to_group(&"main")
	root.add_child(fake_world)
	_check("the ambient loop starts with the world", bool(audio.call(&"is_music_playing")))
	fake_world.queue_free()
	await process_frame
	_check("the ambient loop stops when the world leaves", not bool(audio.call(&"is_music_playing")))

	# --- volume setters -----------------------------------------------------
	if sfx_bus >= 0:
		audio.call(&"set_sfx_volume", 0.0)
		var silent_db := AudioServer.get_bus_volume_db(sfx_bus)
		_check("0 %% SFX is finite (%.1f dB)" % silent_db,
			is_finite(silent_db) and silent_db <= -60.0)
	if music_bus >= 0:
		audio.call(&"set_music_volume", 0.0)
		var silent_db := AudioServer.get_bus_volume_db(music_bus)
		_check("0 %% music is finite (%.1f dB)" % silent_db,
			is_finite(silent_db) and silent_db <= -60.0)
	if sfx_bus >= 0:
		audio.call(&"set_sfx_volume", 1.0)
		_check("100 %% SFX is 0 dB (%.1f dB)" % AudioServer.get_bus_volume_db(sfx_bus),
			is_equal_approx(AudioServer.get_bus_volume_db(sfx_bus), 0.0))

	# --- persistence --------------------------------------------------------
	audio.call(&"set_music_volume", PROBE_MUSIC_VOLUME)
	audio.call(&"set_sfx_volume", PROBE_SFX_VOLUME)
	_check("the setter keeps the linear level",
		is_equal_approx(float(audio.call(&"music_volume")), PROBE_MUSIC_VOLUME))
	var config := ConfigFile.new()
	_check("settings.cfg was written", config.load(SETTINGS_PATH) == OK)
	_check(
		"settings.cfg holds the music volume (%.2f)" % float(
			config.get_value(SETTINGS_SECTION, "music_volume", -1.0)
		),
		is_equal_approx(
			float(config.get_value(SETTINGS_SECTION, "music_volume", -1.0)), PROBE_MUSIC_VOLUME
		)
	)
	_check(
		"settings.cfg holds the SFX volume (%.2f)" % float(
			config.get_value(SETTINGS_SECTION, "sfx_volume", -1.0)
		),
		is_equal_approx(
			float(config.get_value(SETTINGS_SECTION, "sfx_volume", -1.0)), PROBE_SFX_VOLUME
		)
	)

	# A fresh manager reads the file back, proving the round trip rather than
	# just the in-memory value.
	var manager_script := load("res://scripts/core/AudioManager.gd") as GDScript
	var reloaded := manager_script.new() as Node
	_check("a fresh AudioManager instantiates", reloaded != null)
	if reloaded != null:
		root.add_child(reloaded)
		_check(
			"a fresh AudioManager restores the music volume (%.2f)" % float(
				reloaded.call(&"music_volume")
			),
			is_equal_approx(float(reloaded.call(&"music_volume")), PROBE_MUSIC_VOLUME)
		)
		_check(
			"a fresh AudioManager restores the SFX volume (%.2f)" % float(
				reloaded.call(&"sfx_volume")
			),
			is_equal_approx(float(reloaded.call(&"sfx_volume")), PROBE_SFX_VOLUME)
		)
		reloaded.queue_free()
		await process_frame

	# Leave the file at the shipped defaults; TestEnv puts the developer's own
	# settings back afterwards.
	audio.call(&"set_music_volume", DEFAULT_MUSIC_VOLUME)
	audio.call(&"set_sfx_volume", DEFAULT_SFX_VOLUME)
	audio.call(&"set_output_enabled", false)
	_check("disabling output silences the ambience", not bool(audio.call(&"is_music_playing")))
	# One mix cycle, so the audio server reaps the stopped playback before exit
	# instead of reporting it as leaked (godotengine/godot#76745).
	await create_timer(0.2).timeout
	_finish()


func _any_voice_playing(audio: Node, bus: StringName) -> bool:
	for child: Node in audio.get_children():
		var player := child as AudioStreamPlayer
		if player != null and player.bus == bus and player.is_playing():
			return true
	return false


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all audio assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
