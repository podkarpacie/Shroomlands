extends Node
## Transport abstraction: the only script that knows ENet from WebSocket.
## Gameplay code calls host()/join()/disconnect_peer() and listens on signals.
##
## One server process serves **one** transport at a time: either ENet (UDP,
## desktop) or WebSocket (TCP, the transport a browser can speak). A mixed
## ENet + WebSocket instance would need a second `MultiplayerAPI` and is out of
## scope for the MVP. A desktop process can still join a WebSocket server by
## asking for that transport explicitly.

const DEFAULT_PORT := 7777
const MAX_PLAYERS := 32

const TRANSPORT_AUTO := "auto"
const TRANSPORT_ENET := "enet"
const TRANSPORT_WEBSOCKET := "websocket"
const TRANSPORTS := [TRANSPORT_ENET, TRANSPORT_WEBSOCKET]

const OFFLINE := 0
const SERVER := 1
const CLIENT := 2

## Where a failed lobby-initiated join returns to. The lobby hands over to the
## world immediately (see `join`), so a connection failure has to unwind that
## scene change or the player is stranded in an empty world.
const LOBBY_SCENE_PATH := "res://scenes/multiplayer/lobby.tscn"

var mode := OFFLINE
## Transport of the current session ("enet" or "websocket"); empty while offline.
var transport := ""
## Reason of the last lobby-initiated join failure; LobbyUI shows and clears it.
var last_error := ""
## Set for a lobby session: a lost server returns to the menu with `last_error`.
var _return_to_lobby := false

signal hosted
signal joined
signal connection_failed(reason: String)
signal peer_disconnected(peer_id: int)

## Peer id of the host as seen by a client; 0 while offline.
var _server_peer_id := 0
## This process's peer id. The host is always 1; a client learns its id when
## the ENet/WebSocket handshake completes. 0 while offline.
var local_peer_id := 0
## True when hosting as a headless server: no player is spawned for the host.
var is_dedicated := false


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func is_web() -> bool:
	return OS.has_feature("web")


## "auto" resolves to WebSocket in a browser and ENet everywhere else. An
## unknown name returns "" so callers can report it as a bad parameter.
func resolve_transport(requested: String) -> String:
	var wanted := requested.strip_edges().to_lower()
	if wanted.is_empty() or wanted == TRANSPORT_AUTO:
		return TRANSPORT_WEBSOCKET if is_web() else TRANSPORT_ENET
	if TRANSPORTS.has(wanted):
		return wanted
	return ""


## A browser — and a desktop WebSocket client — dials `ws://host:port/`. A full
## ws:// or wss:// URL is used as-is, which is what a TLS tunnel hands you.
func websocket_url(address: String, port: int) -> String:
	var trimmed := address.strip_edges()
	if trimmed.begins_with("ws://") or trimmed.begins_with("wss://"):
		return trimmed
	return "ws://%s:%d/" % [trimmed, port]


func host(port: int = DEFAULT_PORT, transport_name: String = TRANSPORT_AUTO) -> Error:
	if mode != OFFLINE:
		return ERR_ALREADY_IN_USE
	if port < 1 or port > 65535:
		connection_failed.emit("invalid port %d" % port)
		return ERR_INVALID_PARAMETER
	var resolved := resolve_transport(transport_name)
	if resolved.is_empty():
		connection_failed.emit("unknown transport '%s'" % transport_name)
		return ERR_INVALID_PARAMETER
	if resolved == TRANSPORT_WEBSOCKET:
		# Browsers cannot open a listening socket; this only succeeds on a
		# desktop/server build (the dedicated server's --transport=websocket).
		var web_peer := WebSocketMultiplayerPeer.new()
		var web_error := web_peer.create_server(port)
		if web_error != OK:
			connection_failed.emit(
				"cannot host on TCP %d (%s)" % [port, error_string(web_error)]
			)
			return web_error
		multiplayer.multiplayer_peer = web_peer
	else:
		var enet_peer := ENetMultiplayerPeer.new()
		var enet_error := enet_peer.create_server(port, MAX_PLAYERS)
		if enet_error != OK:
			connection_failed.emit(
				"cannot host on UDP %d (%s)" % [port, error_string(enet_error)]
			)
			return enet_error
		multiplayer.multiplayer_peer = enet_peer
	transport = resolved
	mode = SERVER
	_server_peer_id = 1
	local_peer_id = 1
	hosted.emit()
	EventBus.network_started.emit(true)
	return OK


## Dials a server. `return_to_lobby` is for the menu: if the connection fails
## after the lobby has already handed over to the world, Network navigates back
## to `LOBBY_SCENE_PATH` and leaves the reason in `last_error`.
func join(
	ip: String,
	port: int = DEFAULT_PORT,
	transport_name: String = TRANSPORT_AUTO,
	return_to_lobby: bool = false
) -> Error:
	if mode != OFFLINE:
		return ERR_ALREADY_IN_USE
	if ip.is_empty():
		connection_failed.emit("empty server address")
		return ERR_INVALID_PARAMETER
	if port < 1 or port > 65535:
		connection_failed.emit("invalid port %d" % port)
		return ERR_INVALID_PARAMETER
	var resolved := resolve_transport(transport_name)
	if resolved.is_empty():
		connection_failed.emit("unknown transport '%s'" % transport_name)
		return ERR_INVALID_PARAMETER
	if resolved == TRANSPORT_WEBSOCKET:
		var url := websocket_url(ip, port)
		var web_peer := WebSocketMultiplayerPeer.new()
		var web_error := web_peer.create_client(url)
		if web_error != OK:
			connection_failed.emit("cannot connect to %s (%s)" % [url, error_string(web_error)])
			return web_error
		multiplayer.multiplayer_peer = web_peer
	else:
		var enet_peer := ENetMultiplayerPeer.new()
		var enet_error := enet_peer.create_client(ip, port)
		if enet_error != OK:
			connection_failed.emit(
				"cannot connect to %s:%d (%s)" % [ip, port, error_string(enet_error)]
			)
			return enet_error
		multiplayer.multiplayer_peer = enet_peer
	transport = resolved
	mode = CLIENT
	local_peer_id = 0
	_return_to_lobby = return_to_lobby
	return OK


## Host without a local player. A dedicated server still loads the world and
## spawns remote players; it just never owns one itself. Defaults to ENet; pass
## "websocket" to serve browsers.
func start_dedicated(port: int = DEFAULT_PORT, transport_name: String = TRANSPORT_ENET) -> Error:
	# Set the flag first so anything reacting to `hosted` never spawns a local
	# player, even if it loads the world from the signal.
	is_dedicated = true
	var error := host(port, transport_name)
	if error != OK:
		is_dedicated = false
	return error


## All peer ids in the session including this process's own id. Empty while
## offline; on a host the list starts with 1 and then every connected client.
func get_peers() -> Array[int]:
	var peers: Array[int] = []
	if mode == OFFLINE or local_peer_id == 0:
		return peers
	peers.append(local_peer_id)
	if mode == SERVER:
		for peer_id: int in multiplayer.get_peers():
			peers.append(peer_id)
	else:
		# The server is always peer 1 from a client's point of view.
		peers.append(1)
	return peers


func disconnect_peer() -> void:
	if mode == OFFLINE:
		return
	mode = OFFLINE
	transport = ""
	_server_peer_id = 0
	local_peer_id = 0
	is_dedicated = false
	_return_to_lobby = false
	var peer := multiplayer.multiplayer_peer
	if peer != null:
		peer.close()
		multiplayer.multiplayer_peer = null


func _on_peer_connected(peer_id: int) -> void:
	if mode == OFFLINE:
		return
	EventBus.player_joined.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if mode == OFFLINE:
		return
	peer_disconnected.emit(peer_id)
	EventBus.player_left.emit(peer_id)


func _on_connected_to_server() -> void:
	if mode != CLIENT:
		return
	_server_peer_id = multiplayer.get_unique_id()
	local_peer_id = multiplayer.get_unique_id()
	joined.emit()
	EventBus.network_started.emit(false)


func _on_connection_failed() -> void:
	if mode == OFFLINE:
		return
	var recover := _return_to_lobby
	disconnect_peer()
	connection_failed.emit("connection failed")
	if recover:
		_return_to_menu("could not reach the server")


func _on_server_disconnected() -> void:
	if mode == OFFLINE:
		return
	var host_id := _server_peer_id
	var recover := _return_to_lobby
	disconnect_peer()
	connection_failed.emit("server disconnected")
	if host_id != 0:
		peer_disconnected.emit(host_id)
		EventBus.player_left.emit(host_id)
	if recover:
		_return_to_menu("server disconnected")


## A lobby-initiated session loads the world before the handshake finishes, so a
## failure has to unwind that scene change; otherwise the player is left in an
## empty client world with no menu. `last_error` is shown by the fresh lobby.
func _return_to_menu(reason: String) -> void:
	last_error = reason
	_return_to_lobby = false
	var tree := get_tree()
	if tree == null:
		return
	tree.call_deferred(&"change_scene_to_file", LOBBY_SCENE_PATH)
