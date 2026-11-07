class_name VoiceInput
extends Node
## Microphone loudness -> monster hearing.
##
## The YAPYAP/Lethal Company hook is that the creature hears the *player*, not
## just the character. This node opens a private microphone bus, measures RMS
## loudness and emits `EventBus.disturbance_emitted` with a radius that scales
## from a whisper to a shout. Every `Enemy` already investigates disturbances,
## so talking, laughing or screaming pulls them in.
##
## Privacy: off by default. `V` toggles the microphone; the bus is muted to
## -80 dB so the mic is captured but never echoed to the speakers. On a machine
## with no microphone the toggle reports it and stays off. `push_voice()` is the
## same path the mic uses, which keeps the behaviour testable headless.

@export var min_radius := 5.0
@export var max_radius := 24.0
@export var threshold := 0.06
@export var emit_interval := 0.4
## Raw mic RMS is quiet; scale it before clamping to 0..1.
@export var gain := 4.0

var enabled := false
var available := false
var loudness := 0.0

var _bus := -1
var _capture: AudioEffectCapture = null
var _player: AudioStreamPlayer = null
var _smooth := 0.0
var _emit_left := 0.0


func _ready() -> void:
	set_process(false)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"voice_toggle"):
		toggle()


func toggle() -> void:
	if enabled:
		_shutdown()
		return
	if not _open_mic():
		EventBus.toast_requested.emit("No microphone found - voice hearing stays off")
		return
	enabled = true
	set_process(true)
	EventBus.toast_requested.emit("Voice on - the mycelium hears you (V to mute)")


func is_enabled() -> bool:
	return enabled


## Feeds one loudness sample through the same emit path as the microphone.
## Returns the emitted radius, or 0 when the sample stayed below the threshold.
func push_voice(value: float) -> float:
	loudness = clampf(value, 0.0, 1.0)
	if loudness < threshold:
		return 0.0
	return _emit()


func _process(delta: float) -> void:
	if not enabled or _capture == null:
		return
	var frames := _capture.get_frames_available()
	var peak := 0.0
	if frames > 0:
		var buffer := _capture.get_buffer(frames)
		var sum := 0.0
		for index in buffer.size():
			var sample := buffer[index].x
			sum += sample * sample
		peak = sqrt(sum / float(maxi(buffer.size(), 1)))
	_smooth = lerpf(_smooth, clampf(peak * gain, 0.0, 1.0), 0.35)
	loudness = _smooth
	_emit_left -= delta
	if loudness >= threshold and _emit_left <= 0.0:
		_emit_left = emit_interval
		_emit()


func _emit() -> float:
	var body := get_parent() as Node3D
	var origin := body.global_position if body != null else Vector3.ZERO
	var radius := lerpf(min_radius, max_radius, loudness)
	var inventory := body.get_node_or_null("InventorySystem") if body != null else null
	if inventory != null and inventory.has_method(&"gear_multiplier"):
		radius *= float(inventory.call(&"gear_multiplier", "noise_mult"))
	Network.report_disturbance(origin, radius)
	return radius


func _open_mic() -> bool:
	if _player != null:
		_player.play()
		available = true
		return true
	var bus := AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "Microphone")
	# Capture happens before the bus is silenced, so the mic is heard by the
	# game and never by the room.
	AudioServer.set_bus_volume_db(bus, -80.0)
	var capture := AudioEffectCapture.new()
	capture.buffer_length = 0.1
	AudioServer.add_bus_effect(bus, capture)
	var player := AudioStreamPlayer.new()
	player.name = "MicrophoneInput"
	player.stream = AudioStreamMicrophone.new()
	player.bus = "Microphone"
	add_child(player)
	player.play()
	_bus = bus
	_capture = capture
	_player = player
	available = true
	return true


func _shutdown() -> void:
	enabled = false
	set_process(false)
	loudness = 0.0
	_smooth = 0.0
	if _player != null:
		_player.stop()
	EventBus.toast_requested.emit("Voice off")
