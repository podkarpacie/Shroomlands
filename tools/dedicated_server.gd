extends Node
## Entry point for the exported dedicated server and headless test clients.
##
## The shipped lobby is a menu and does not read command-line flags, so
## `tools/run_server.ps1` selects this scene through an `override.cfg` file
## written next to the server executable. With no flags it falls through to the
## normal lobby, which keeps the same binary usable as a regular game client.
##
## `--transport=enet|websocket` selects the transport (default enet). One
## process listens on one transport only; pass the same flag to a join client
## when the server was started in websocket mode.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const LOBBY_SCENE_PATH := "res://scenes/multiplayer/lobby.tscn"


func _ready() -> void:
	var join_address := ""
	var port := Network.DEFAULT_PORT
	var transport := Network.TRANSPORT_ENET
	var dedicated := false
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--net-dedicated":
			dedicated = true
		elif arg.begins_with("--port="):
			port = int(arg.trim_prefix("--port="))
		elif arg.begins_with("--join="):
			join_address = arg.trim_prefix("--join=")
		elif arg.begins_with("--transport="):
			transport = arg.trim_prefix("--transport=").strip_edges().to_lower()
	if not Network.TRANSPORTS.has(transport):
		push_error(
			"Dedicated server: unknown transport '%s' (use enet or websocket)" % transport
		)
		get_tree().quit(1)
		return
	if dedicated:
		_start_dedicated(port, transport)
	elif not join_address.is_empty():
		_join(join_address, port, transport)
	else:
		_change_scene(LOBBY_SCENE_PATH)


func _start_dedicated(port: int, transport: String) -> void:
	var error := Network.start_dedicated(port, transport)
	if error != OK:
		push_error(
			"Dedicated server: cannot listen on %s port %d (%s)" % [
				_transport_protocol(transport), port, error_string(error)
			]
		)
		get_tree().quit(1)
		return
	# Machine-readable first: `tools/run_server.ps1` and the host checks grep it.
	print("SHROOMLANDS_DEDICATED transport=%s port=%d" % [transport, port])
	print(
		"  listening on %s %d (%s)" % [
			"TCP" if transport == Network.TRANSPORT_WEBSOCKET else "UDP",
			port,
			_transport_protocol(transport),
		]
	)
	_change_scene(MAIN_SCENE_PATH)


func _join(address: String, port: int, transport: String) -> void:
	Network.joined.connect(_on_joined, CONNECT_ONE_SHOT)
	Network.connection_failed.connect(_on_join_failed, CONNECT_ONE_SHOT)
	var error := Network.join(address, port, transport)
	if error != OK:
		push_error(
			"Client: cannot connect to %s:%d over %s (%s)" % [
				address, port, _transport_protocol(transport), error_string(error)
			]
		)
		get_tree().quit(1)


func _on_joined() -> void:
	print("SHROOMLANDS_JOINED transport=%s" % Network.transport)
	_change_scene(MAIN_SCENE_PATH)


func _on_join_failed(reason: String) -> void:
	push_error("Client: connection failed: %s" % reason)
	get_tree().quit(1)


func _transport_protocol(transport: String) -> String:
	return "WebSocket/TCP" if transport == Network.TRANSPORT_WEBSOCKET else "ENet/UDP"


func _change_scene(path: String) -> void:
	# This node is the current scene while `_ready` runs, so the swap has to
	# wait one frame; changing it inline makes the SceneTree remove a node it is
	# still adding. Keep a local reference: this node is freed by the swap.
	var tree := get_tree()
	await tree.process_frame
	var error := tree.change_scene_to_file(path)
	if error != OK:
		push_error("Cannot load %s (%s)" % [path, error_string(error)])
		tree.quit(1)
		return
	print("SHROOMLANDS_WORLD_LOADING scene=%s" % path)
