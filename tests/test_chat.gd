extends SceneTree
## Headless chat test on the real `main.tscn`.
##
## Covers the UI contract only: the log and the input line exist, lines arrive
## through `EventBus.chat_message_received`, the ring is capped, the `/l ` prefix
## is parsed, and opening/closing the field blocks and releases the player.
## The networked relay is proven by `tests/run_network_test.ps1`.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const CAP := 100
const OVERFLOW := 120
## Keeps the developer's files untouched; see tests/test_env.gd.
const TestEnv := preload("res://tests/test_env.gd")

var _failures := 0


func _initialize() -> void:
	# Structural/behaviour run only: a private save and a private plots file,
	# so this suite never reads or writes the developer's profile.
	TestEnv.isolate("test_chat")
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
	var main := packed.instantiate()
	root.add_child(main)
	await _wait_physics(30)

	var chat := main.get_node_or_null("ChatUI")
	_check("Main has a ChatUI CanvasLayer", chat != null)
	if chat == null:
		_finish()
		return
	var log_label := chat.get_node_or_null("Root/LogPanel/Margin/LogScroll/Log") as RichTextLabel
	var input := chat.get_node_or_null("Root/InputPanel/Margin/Input") as LineEdit
	var log_scroll := chat.get_node_or_null("Root/LogPanel/Margin/LogScroll") as ScrollContainer
	_check("chat has a RichTextLabel log", log_label != null)
	_check("chat log sits in a ScrollContainer", log_scroll != null)
	_check("chat has a LineEdit input", input != null)
	if log_label == null or input == null:
		_finish()
		return
	_check("the chat input starts hidden", not input.is_visible_in_tree())

	var bus: Variant = root.get_node_or_null("EventBus")
	_check("EventBus autoload is available", bus != null)
	if bus == null:
		_finish()
		return

	# --- rendering from the signal -----------------------------------------
	bus.emit_signal(&"chat_message_received", "Player 1", "hello", "global")
	await process_frame
	_check(
		"a received line is rendered",
		String(chat.call(&"get_log_text")).contains("hello")
	)
	bus.emit_signal(&"chat_message_received", "Player 2", "remote line", "global")
	await process_frame
	_check(
		"a remote sender is rendered",
		String(chat.call(&"get_log_text")).contains("Player 2")
	)
	_check(
		"the local peer's own line is styled as you",
		String(chat.call(&"get_log_text")).contains("you: hello")
	)

	# --- ring buffer --------------------------------------------------------
	for index in OVERFLOW:
		bus.emit_signal(&"chat_message_received", "Player 2", "msg %03d" % index, "global")
	await process_frame
	var line_count := int(chat.call(&"log_line_count"))
	_check("the log caps at %d lines (%d)" % [CAP, line_count], line_count == CAP)
	var log_text := String(chat.call(&"get_log_text"))
	_check("the oldest line is dropped", not log_text.contains("msg 000"))
	_check("the newest line is kept", log_text.contains("msg %03d" % (OVERFLOW - 1)))

	# --- channel parsing ----------------------------------------------------
	var global_parse: Dictionary = chat.call(&"parse_channel", "hi")
	_check(
		"a plain message is global (%s/%s)" % [global_parse.get("channel"), global_parse.get("text")],
		String(global_parse.get("channel", "")) == "global"
		and String(global_parse.get("text", "")) == "hi"
	)
	var local_parse: Dictionary = chat.call(&"parse_channel", "/l hi")
	_check(
		"`/l ` selects local and is stripped (%s/%s)" % [
			local_parse.get("channel"), local_parse.get("text")
		],
		String(local_parse.get("channel", "")) == "local"
		and String(local_parse.get("text", "")) == "hi"
	)

	# --- offline echo -------------------------------------------------------
	chat.call(&"send_text", "echo offline")
	await process_frame
	_check(
		"offline chat echoes locally",
		String(chat.call(&"get_log_text")).contains("echo offline")
	)
	chat.call(&"send_text", "/l psst")
	await process_frame
	var local_text := String(chat.call(&"get_log_text"))
	_check(
		"offline local chat is tagged",
		local_text.contains("(local)") and local_text.contains("psst")
	)

	# --- open / close blocks the player ------------------------------------
	var player := get_first_node_in_group(&"player")
	_check("a player was spawned", player != null)
	if player != null:
		_check("the player starts unblocked", not bool(player.get(&"ui_blocking")))
		chat.call(&"set_open", true)
		await process_frame
		_check("opening chat shows the input", input.is_visible_in_tree())
		_check("opening chat UI-blocks the player", bool(player.get(&"ui_blocking")))
		_check("opening chat gives the field focus", input.has_focus())
		chat.call(&"set_open", false)
		await process_frame
		_check("closing chat hides the input", not input.is_visible_in_tree())
		_check("closing chat releases the player", not bool(player.get(&"ui_blocking")))

	_finish()


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
		print("PASSED  all chat assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
