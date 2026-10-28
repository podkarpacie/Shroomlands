extends Node3D
## Authoritative plot registry: buy with gold, a wall-clock daily fee that also
## accrues while the game is closed, expiry after unpaid days, and 1 m grid
## building on owned plots.
##
## The fee schedule is driven by `Time.get_unix_time_from_system()`, never by a
## scene timer: `_fee_timer` only decides how often the backlog is settled, so
## days spent offline are charged on the next load instead of vanishing with the
## process. Gold never goes negative, so an unaffordable day becomes an unpaid
## day and `PLOT_EXPIRY_DAYS` of them reclaim the plot.
##
## Multiplayer: the server owns the state. A client's `buy_plot`/`place_object`
## queue an RPC, and the server validates and broadcasts the resulting snapshot;
## no peer ever invents plot state locally. Offline mutates directly.

const PLOT_COUNT := 6
const PLOT_SIZE := 12.0
const PLOT_PRICE := 100
## Snap step for building; also the size of one build cell.
const GRID_SIZE := 1.0
const DAY_SECONDS := 86400
## How often the running game settles the wall-clock backlog.
const FEE_TICK_SECONDS := 60.0
## Plot 0 starts here; each following plot continues along +X.
const ORIGIN_X := -36.0
const ORIGIN_Z := 24.0
## Signs stand this far inside the plot's front-left corner. Keeping them off
## the plot centre leaves the buildable middle free, so the hut a player puts
## there no longer sits on the board or its floating label. Still inside the
## plot, so `plot_at(sign.position)` keeps returning that plot's id.
const SIGN_INSET := 1.5
const PLOTS_PATH := "user://plots.json"
const PLOTS_TMP_PATH := "user://plots.json.tmp"
const PLOT_SIGN_SCENE := preload("res://scenes/world/plot_sign.tscn")

const OBJECT_COSTS := {
	&"hut": 40,
	&"farm": 25,
	&"workshop": 35,
	&"chest": 10,
}

## Ground tint per plot, alternating so the 12 m boundaries read at a glance.
const PLOT_TINTS: Array[Color] = [
	Color(0.26, 0.45, 0.21),
	Color(0.36, 0.37, 0.33),
]
const OWNED_TINTS: Array[Color] = [
	Color(0.52, 0.60, 0.22),
	Color(0.55, 0.57, 0.25),
]

## Test seam: when >= 0 the system reads the fee clock from here instead of the
## wall clock, so elapsed days can be simulated without sleeping.
@export var now_override := -1

var _plots: Array[Dictionary] = []
var _signs: Array[Node] = []
var _quads: Array[MeshInstance3D] = []
var _objects_root: Node3D = null
var _fee_timer: Timer = null


func _ready() -> void:
	add_to_group(&"plot_system")
	reset_plots()
	# A client mirrors the server; loading its own stale file would fight the
	# first authoritative snapshot.
	if Network.mode != Network.CLIENT:
		load_plots()
		charge_daily_fees()
	_build_visuals()
	_rebuild_object_nodes()
	_refresh_visuals()
	_fee_timer = Timer.new()
	_fee_timer.name = "FeeTimer"
	_fee_timer.wait_time = FEE_TICK_SECONDS
	_fee_timer.timeout.connect(charge_daily_fees)
	add_child(_fee_timer)
	_fee_timer.start()
	if Network.mode == Network.CLIENT:
		# The node exists on this peer now, so the snapshot request cannot hit a
		# missing `Main/PlotSystem` (a server push on `peer_connected` can race
		# the client's scene load).
		_request_state_when_connected()


# --- queries ----------------------------------------------------------------

## Copy of one plot, so callers cannot mutate the registry by accident.
func get_plot(plot_id: int) -> Dictionary:
	if not _valid_plot(plot_id):
		return {}
	return _plots[plot_id].duplicate(true)


## Index of the plot containing `world_pos`, or -1. Only X/Z matter; the plot
## row lies at z = ORIGIN_Z .. ORIGIN_Z + PLOT_SIZE.
func plot_at(world_pos: Vector3) -> int:
	if world_pos.z < ORIGIN_Z or world_pos.z >= ORIGIN_Z + PLOT_SIZE:
		return -1
	var offset := world_pos.x - ORIGIN_X
	if offset < 0.0 or offset >= PLOT_SIZE * PLOT_COUNT:
		return -1
	return int(offset / PLOT_SIZE)


func is_owned_by(plot_id: int, who: StringName) -> bool:
	if not _valid_plot(plot_id) or who == &"":
		return false
	return StringName(_plots[plot_id]["owner"]) == who


func get_object_cost(object_id: StringName) -> int:
	return int(OBJECT_COSTS.get(object_id, 0))


func plot_price() -> int:
	return PLOT_PRICE


## Seconds until the next fee for an owned plot; 0 when unowned or already due.
func next_fee_seconds(plot_id: int) -> int:
	if not _valid_plot(plot_id):
		return 0
	var plot: Dictionary = _plots[plot_id]
	if StringName(plot["owner"]) == &"":
		return 0
	var last := int(plot["last_fee_at"])
	if last <= 0:
		return 0
	return maxi(0, last + DAY_SECONDS - _now())


## The peer id that buys/owns plots from this machine, as used by every owner
## comparison. Offline this is 1, matching `multiplayer.get_unique_id()`.
func local_owner_id() -> StringName:
	return StringName(str(multiplayer.get_unique_id()))


## A 1 m cell is valid only when the whole footprint fits: the centre must sit
## half a grid step inside the plot rectangle. The cell must also be free.
func can_place(plot_id: int, cell: Vector3i) -> bool:
	if not _valid_plot(plot_id) or not _cell_inside(plot_id, cell):
		return false
	for entry: Dictionary in _plots[plot_id]["objects"]:
		var recorded: Vector3i = entry["cell"]
		if recorded == cell:
			return false
	return true


# --- mutations --------------------------------------------------------------

## True when the purchase went through (or, on a client, was queued for the
## server). False when out of range, already owned, or unaffordable.
func buy_plot(plot_id: int, buyer: StringName) -> bool:
	if not _valid_plot(plot_id):
		return false
	if Network.mode == Network.CLIENT:
		request_buy.rpc_id(1, plot_id)
		return true
	return _apply_buy(plot_id, buyer)


## True when the object was placed (or, on a client, the request was queued).
func place_object(plot_id: int, object_id: StringName, cell: Vector3i) -> bool:
	if not _valid_plot(plot_id):
		return false
	if Network.mode == Network.CLIENT:
		request_place.rpc_id(1, plot_id, String(object_id), cell)
		return true
	return _apply_place(plot_id, object_id, cell, local_owner_id())


## Settles every full 24 h since `last_fee_at` for each owned plot. Each paid
## day emits `gold_changed` through `Game.spend_gold`; each unpaid day accrues
## and `PLOT_EXPIRY_DAYS` of them reclaim the plot. Every settled day advances
## the clock, paid or not, so a missed day is never billed twice.
func charge_daily_fees() -> void:
	if Network.mode == Network.CLIENT:
		return
	var now := _now()
	var changed := false
	for plot: Dictionary in _plots:
		if StringName(plot["owner"]) == &"":
			continue
		var last := int(plot["last_fee_at"])
		if last <= 0:
			plot["last_fee_at"] = now
			changed = true
			continue
		var days := int((now - last) / DAY_SECONDS)
		if days <= 0:
			continue
		var unpaid := int(plot["unpaid_days"])
		var settled := 0
		var expired := false
		for _day in days:
			settled += 1
			if Game.spend_gold(Game.PLOT_DAILY_FEE):
				unpaid = 0
			else:
				unpaid += 1
			if unpaid >= Game.PLOT_EXPIRY_DAYS:
				expired = true
				break
		changed = true
		if expired:
			_expire(plot)
			continue
		plot["last_fee_at"] = last + settled * DAY_SECONDS
		plot["unpaid_days"] = unpaid
	if changed:
		_rebuild_object_nodes()
		_refresh_visuals()
		save_plots()
		if Network.mode == Network.SERVER:
			_broadcast()


# --- persistence ------------------------------------------------------------

## Wipes the registry back to `PLOT_COUNT` unowned plots. Generated nodes are
## rebuilt; the save file is left alone (call `save_plots()` to persist this).
func reset_plots() -> void:
	_plots.clear()
	for index in PLOT_COUNT:
		_plots.append(_make_plot(index))
	_rebuild_object_nodes()
	_refresh_visuals()


func to_dict() -> Dictionary:
	var plots: Array = []
	for plot: Dictionary in _plots:
		var objects: Array = []
		for entry: Dictionary in plot["objects"]:
			var cell: Vector3i = entry["cell"]
			objects.append({"id": String(entry["id"]), "cell": [cell.x, cell.y, cell.z]})
		plots.append({
			"id": int(plot["id"]),
			"owner": String(plot["owner"]),
			"purchased_at": int(plot["purchased_at"]),
			"last_fee_at": int(plot["last_fee_at"]),
			"unpaid_days": int(plot["unpaid_days"]),
			"objects": objects,
		})
	return {"version": 1, "plots": plots}


## Replaces the registry from a snapshot. Unknown ids, wrong types and objects
## outside their plot are dropped, never fatal.
func from_dict(data: Dictionary) -> void:
	reset_plots()
	var entries: Variant = data.get("plots")
	if entries is Array:
		for entry: Variant in entries:
			if not entry is Dictionary:
				continue
			_apply_entry(entry as Dictionary)
	_rebuild_object_nodes()
	_refresh_visuals()


func save_plots() -> bool:
	var file := FileAccess.open(PLOTS_TMP_PATH, FileAccess.WRITE)
	if file == null:
		push_error("PlotSystem: cannot write %s (%s)" % [
			PLOTS_TMP_PATH, error_string(FileAccess.get_open_error())
		])
		return false
	file.store_string(JSON.stringify(to_dict(), "\t"))
	file.close()

	var dir := DirAccess.open("user://")
	if dir == null:
		push_error("PlotSystem: cannot open user:// (%s)" % error_string(DirAccess.get_open_error()))
		return false
	var err := dir.rename(PLOTS_TMP_PATH.get_file(), PLOTS_PATH.get_file())
	if err != OK and dir.file_exists(PLOTS_PATH.get_file()):
		# Some platforms refuse to rename over an existing file.
		dir.remove(PLOTS_PATH.get_file())
		err = dir.rename(PLOTS_TMP_PATH.get_file(), PLOTS_PATH.get_file())
	if err != OK:
		push_error("PlotSystem: cannot replace %s (%s)" % [PLOTS_PATH, error_string(err)])
		dir.remove(PLOTS_TMP_PATH.get_file())
		return false
	print("PlotSystem: saved %d plots to %s" % [_plots.size(), PLOTS_PATH])
	return true


func load_plots() -> void:
	var data := _read_file()
	if data.is_empty():
		# No file yet: a clean registry is the valid initial state.
		if not FileAccess.file_exists(PLOTS_PATH):
			return
		# A corrupt file is repaired rather than trusted.
		reset_plots()
		save_plots()
		return
	from_dict(data)


# --- multiplayer ------------------------------------------------------------

@rpc("any_peer", "call_local", "reliable")
func request_buy(plot_id: int) -> void:
	if Network.mode != Network.SERVER:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	if _apply_buy(plot_id, StringName(str(sender))):
		_broadcast()


@rpc("any_peer", "call_local", "reliable")
func request_place(plot_id: int, object_id: String, cell: Vector3i) -> void:
	if Network.mode != Network.SERVER:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	if _apply_place(plot_id, StringName(object_id), cell, StringName(str(sender))):
		_broadcast()


@rpc("authority", "call_local", "reliable")
func sync_plots(data: Dictionary) -> void:
	from_dict(data)


## Client -> server: "I am ready, send me the current plots". Sent from the
## client's `_ready`, so the server never addresses a node that does not exist.
@rpc("any_peer", "call_local", "reliable")
func request_state() -> void:
	if Network.mode != Network.SERVER:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 0:
		return
	sync_plots.rpc_id(sender, to_dict())


func _broadcast() -> void:
	if Network.mode != Network.SERVER:
		return
	sync_plots.rpc(to_dict())


func _request_state_when_connected() -> void:
	var peer := multiplayer.multiplayer_peer
	if peer == null:
		return
	if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		request_state.rpc_id(1)
	elif not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)


func _on_connected_to_server() -> void:
	request_state.rpc_id(1)


# --- internals --------------------------------------------------------------

func _apply_buy(plot_id: int, buyer: StringName) -> bool:
	if not _valid_plot(plot_id) or buyer == &"":
		return false
	var plot: Dictionary = _plots[plot_id]
	if StringName(plot["owner"]) != &"":
		return false
	if not Game.spend_gold(PLOT_PRICE):
		return false
	var now := _now()
	plot["owner"] = buyer
	plot["purchased_at"] = now
	plot["last_fee_at"] = now
	plot["unpaid_days"] = 0
	EventBus.plot_purchased.emit(plot_id)
	save_plots()
	_refresh_visuals()
	return true


func _apply_place(
	plot_id: int, object_id: StringName, cell: Vector3i, who: StringName
) -> bool:
	if not _valid_plot(plot_id) or get_object_cost(object_id) <= 0:
		return false
	if not is_owned_by(plot_id, who):
		return false
	var snapped := Vector3i(cell.x, 0, cell.z)
	if not can_place(plot_id, snapped):
		return false
	var cost := get_object_cost(object_id)
	if not Game.spend_gold(cost):
		return false
	var objects: Array = _plots[plot_id]["objects"]
	objects.append({"id": object_id, "cell": snapped})
	_spawn_object_node(object_id, snapped)
	EventBus.object_placed.emit(plot_id, String(object_id), snapped)
	save_plots()
	return true


## Reclaims a plot: owner and objects go, the generated meshes go, and the
## expiry signal lets the HUD/signs tell the player.
func _expire(plot: Dictionary) -> void:
	var plot_id := int(plot["id"])
	plot["owner"] = &""
	plot["purchased_at"] = 0
	plot["last_fee_at"] = 0
	plot["unpaid_days"] = 0
	(plot["objects"] as Array).clear()
	EventBus.plot_expired.emit(plot_id)


func _apply_entry(entry: Dictionary) -> void:
	var plot_id := _as_int(entry.get("id"), -1)
	if not _valid_plot(plot_id):
		return
	var plot: Dictionary = _plots[plot_id]
	var owner := StringName(_as_string(entry.get("owner"), ""))
	plot["owner"] = owner
	plot["purchased_at"] = maxi(_as_int(entry.get("purchased_at"), 0), 0)
	plot["last_fee_at"] = maxi(_as_int(entry.get("last_fee_at"), 0), 0)
	plot["unpaid_days"] = clampi(_as_int(entry.get("unpaid_days"), 0), 0, Game.PLOT_EXPIRY_DAYS)
	if owner == &"":
		return
	if int(plot["last_fee_at"]) <= 0:
		# A save without a fee timestamp starts billing from the purchase.
		plot["last_fee_at"] = int(plot["purchased_at"]) if int(plot["purchased_at"]) > 0 else _now()
	var objects: Variant = entry.get("objects")
	if not objects is Array:
		return
	for raw: Variant in objects:
		var parsed := _parse_object(raw)
		if parsed.is_empty():
			continue
		var cell: Vector3i = parsed["cell"]
		if not _cell_inside(plot_id, cell):
			continue
		if not can_place(plot_id, cell):
			continue
		(plot["objects"] as Array).append(parsed)


func _parse_object(raw: Variant) -> Dictionary:
	if not raw is Dictionary:
		return {}
	var entry := raw as Dictionary
	var id := StringName(_as_string(entry.get("id"), ""))
	if get_object_cost(id) <= 0:
		return {}
	var cell_raw: Variant = entry.get("cell")
	if not cell_raw is Array:
		return {}
	var coords: Array = cell_raw
	if coords.size() != 3:
		return {}
	var numbers: Array[int] = []
	for coord: Variant in coords:
		if not (coord is int or coord is float):
			return {}
		numbers.append(int(coord))
	return {"id": id, "cell": Vector3i(numbers[0], 0, numbers[2])}


func _read_file() -> Dictionary:
	if not FileAccess.file_exists(PLOTS_PATH):
		return {}
	var file := FileAccess.open(PLOTS_PATH, FileAccess.READ)
	if file == null:
		push_warning("PlotSystem: cannot open %s (%s)" % [
			PLOTS_PATH, error_string(FileAccess.get_open_error())
		])
		return {}
	var text := file.get_as_text()
	file.close()
	# `JSON.parse_string` logs an engine ERROR on malformed input; the instance
	# API reports the same failure as a return code, so a corrupt save stays a
	# quiet repair instead of a scary red log line.
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK or not json.data is Dictionary:
		print("PlotSystem: ignoring corrupt plots at %s" % PLOTS_PATH)
		return {}
	return json.data as Dictionary


func _make_plot(index: int) -> Dictionary:
	return {
		"id": index,
		"owner": &"",
		"purchased_at": 0,
		"last_fee_at": 0,
		"unpaid_days": 0,
		"objects": [],
	}


func _valid_plot(plot_id: int) -> bool:
	return plot_id >= 0 and plot_id < _plots.size()


func _cell_inside(plot_id: int, cell: Vector3i) -> bool:
	if not _valid_plot(plot_id):
		return false
	var half := GRID_SIZE * 0.5
	var min_x := ORIGIN_X + float(plot_id) * PLOT_SIZE
	return (
		float(cell.x) >= min_x + half
		and float(cell.x) <= min_x + PLOT_SIZE - half
		and float(cell.z) >= ORIGIN_Z + half
		and float(cell.z) <= ORIGIN_Z + PLOT_SIZE - half
	)


func _now() -> int:
	return now_override if now_override >= 0 else int(Time.get_unix_time_from_system())


func _as_int(value: Variant, fallback: int) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	return fallback


func _as_string(value: Variant, fallback: String) -> String:
	if value is String:
		return value
	return fallback


# --- visuals ----------------------------------------------------------------

## The row itself: a tinted 12x12 quad, one corner post and an interactable
## sign per plot. Built once; ownership only repaints.
func _build_visuals() -> void:
	if _objects_root != null:
		return
	_objects_root = Node3D.new()
	_objects_root.name = "Objects"
	add_child(_objects_root)

	var visuals := Node3D.new()
	visuals.name = "Plots"
	add_child(visuals)

	for plot_id in PLOT_COUNT:
		var centre := _plot_centre(plot_id)
		var quad := MeshInstance3D.new()
		quad.name = "PlotGround%d" % plot_id
		var plane := PlaneMesh.new()
		plane.size = Vector2(PLOT_SIZE, PLOT_SIZE)
		plane.material = _material(PLOT_TINTS[plot_id % PLOT_TINTS.size()])
		quad.mesh = plane
		quad.position = Vector3(centre.x, 0.02, centre.z)
		visuals.add_child(quad)
		_quads.append(quad)

		var post := MeshInstance3D.new()
		post.name = "PlotPost%d" % plot_id
		var post_mesh := BoxMesh.new()
		post_mesh.size = Vector3(0.3, 1.8, 0.3)
		post_mesh.material = _material(Color(0.55, 0.42, 0.26))
		post.mesh = post_mesh
		post.position = Vector3(centre.x - PLOT_SIZE * 0.5 + 0.4, 0.9, centre.z - PLOT_SIZE * 0.5 + 0.4)
		visuals.add_child(post)

		var post_cap := MeshInstance3D.new()
		post_cap.name = "PlotPostCap%d" % plot_id
		var cap_mesh := BoxMesh.new()
		cap_mesh.size = Vector3(0.44, 0.16, 0.44)
		cap_mesh.material = _material(Color(0.95, 0.80, 0.30))
		post_cap.mesh = cap_mesh
		post_cap.position = post.position + Vector3(0.0, 0.98, 0.0)
		visuals.add_child(post_cap)

		var sign := PLOT_SIGN_SCENE.instantiate()
		sign.name = "PlotSign%d" % plot_id
		sign.position = Vector3(
			centre.x - PLOT_SIZE * 0.5 + SIGN_INSET,
			0.0,
			centre.z - PLOT_SIZE * 0.5 + SIGN_INSET
		)
		visuals.add_child(sign)
		if sign.has_method(&"configure"):
			sign.call(&"configure", plot_id, self)
		_signs.append(sign)


## Repaints quads and refreshes sign labels after any ownership change.
func _refresh_visuals() -> void:
	for plot_id in _quads.size():
		if not is_instance_valid(_quads[plot_id]):
			continue
		var owned := _valid_plot(plot_id) and StringName(_plots[plot_id]["owner"]) != &""
		var palette: Array[Color] = OWNED_TINTS if owned else PLOT_TINTS
		var material := _quads[plot_id].mesh.surface_get_material(0) as StandardMaterial3D
		if material != null:
			material.albedo_color = palette[plot_id % palette.size()]
	for sign: Node in _signs:
		if is_instance_valid(sign) and sign.has_method(&"refresh"):
			sign.call(&"refresh")


func _rebuild_object_nodes() -> void:
	if _objects_root == null:
		return
	for child in _objects_root.get_children():
		child.free()
	for plot: Dictionary in _plots:
		for entry: Dictionary in plot["objects"]:
			_spawn_object_node(entry["id"], entry["cell"])


func _spawn_object_node(object_id: StringName, cell: Vector3i) -> void:
	if _objects_root == null:
		return
	var root := Node3D.new()
	root.name = "%s_%d_%d" % [String(object_id), cell.x, cell.z]
	root.position = Vector3(float(cell.x), 0.0, float(cell.z))
	match String(object_id):
		"hut":
			_add_box(root, Vector3(2.0, 2.0, 2.0), Vector3(0.0, 1.0, 0.0), Color(0.52, 0.39, 0.25))
			_add_box(root, Vector3(2.2, 0.2, 2.2), Vector3(0.0, 2.1, 0.0), Color(0.62, 0.24, 0.18))
		"farm":
			_add_box(root, Vector3(3.0, 0.2, 3.0), Vector3(0.0, 0.1, 0.0), Color(0.34, 0.24, 0.15))
			for corner: Vector2 in [
				Vector2(-1.1, -1.1), Vector2(1.1, -1.1),
				Vector2(-1.1, 1.1), Vector2(1.1, 1.1),
			]:
				var stem := MeshInstance3D.new()
				var mesh := CylinderMesh.new()
				mesh.top_radius = 0.16
				mesh.bottom_radius = 0.10
				mesh.height = 0.6
				mesh.material = _material(Color(0.85, 0.83, 0.62))
				stem.mesh = mesh
				stem.position = Vector3(corner.x, 0.5, corner.y)
				root.add_child(stem)
		"workshop":
			_add_box(root, Vector3(2.0, 1.5, 2.0), Vector3(0.0, 0.75, 0.0), Color(0.44, 0.42, 0.35))
			_add_box(root, Vector3(1.4, 0.5, 0.4), Vector3(0.0, 0.25, 0.8), Color(0.30, 0.22, 0.14))
		"chest":
			_add_box(root, Vector3(1.0, 0.9, 1.0), Vector3(0.0, 0.45, 0.0), Color(0.42, 0.27, 0.14))
			_add_box(root, Vector3(1.04, 0.14, 1.04), Vector3(0.0, 0.97, 0.0), Color(0.30, 0.19, 0.10))
		_:
			root.queue_free()
			return
	_objects_root.add_child(root)


func _add_box(parent: Node3D, size: Vector3, offset: Vector3, tint: Color) -> void:
	var instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = _material(tint)
	instance.mesh = mesh
	instance.position = offset
	parent.add_child(instance)


func _material(tint: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	material.roughness = 1.0
	return material


func _plot_centre(plot_id: int) -> Vector3:
	return Vector3(
		ORIGIN_X + float(plot_id) * PLOT_SIZE + PLOT_SIZE * 0.5,
		0.0,
		ORIGIN_Z + PLOT_SIZE * 0.5
	)
