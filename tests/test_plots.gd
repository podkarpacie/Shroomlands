extends SceneTree
## Headless PlotSystem test: purchase, grid building, wall-clock daily fees
## (simulated through `now_override`, never sleeping), expiry after unpaid days
## and JSON persistence.
##
## `PlotSystem.gd` is loaded lazily: autoload identifiers are only resolvable
## after the `--script` main loop starts (same constraint as test_player.gd).

const PLOT_SCRIPT_PATH := "res://scripts/systems/PlotSystem.gd"
const PLOTS_PATH := "user://plots.json"
## Arbitrary fixed wall clock so day arithmetic is deterministic.
const BASE_TIME := 1_700_000_000
const DAY := 86400

var _failures := 0
var _plots: Node3D = null
var _game: Node = null
var _daily_fee := 10
var _expiry_days := 3
var _purchased: Array[int] = []
var _expired: Array[int] = []
var _placed: Array[Dictionary] = []
var _toasts: Array[String] = []


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	_remove_save()

	_game = root.get_node_or_null("Game")
	var bus: Node = root.get_node_or_null("EventBus")
	_check("Game autoload is available", _game != null)
	_check("EventBus autoload is available", bus != null)
	if _game == null or bus == null:
		_finish()
		return
	var constants: Dictionary = _game.get_script().get_script_constant_map()
	_daily_fee = int(constants.get("PLOT_DAILY_FEE", 10))
	_expiry_days = int(constants.get("PLOT_EXPIRY_DAYS", 3))
	bus.connect(&"plot_purchased", _on_purchased)
	bus.connect(&"plot_expired", _on_expired)
	bus.connect(&"object_placed", _on_object_placed)
	bus.connect(&"toast_requested", _on_toast_requested)

	var plot_script := load(PLOT_SCRIPT_PATH) as Script
	_check("PlotSystem script loads", plot_script != null)
	if plot_script == null:
		_finish()
		return
	var plot_constants: Dictionary = plot_script.get_script_constant_map()
	_plots = plot_script.new() as Node3D
	_check("PlotSystem instantiates", _plots != null)
	if _plots == null:
		_finish()
		return
	_plots.name = "PlotSystem"
	root.add_child(_plots)
	await process_frame

	# --- fresh state --------------------------------------------------------
	_check("fresh state has %d plots" % int(plot_constants.get("PLOT_COUNT", 0)), _plot_count() == 6)
	for index in 6:
		var plot := _get_plot(index)
		_check(
			"plot %d starts unowned with no objects" % index,
			not plot.is_empty() and StringName(plot["owner"]) == &"" and (plot["objects"] as Array).is_empty()
		)
	_check("get_plot(6) is empty", _get_plot(6).is_empty())
	_check("get_plot(-1) is empty", _get_plot(-1).is_empty())

	# --- plot_at mapping ----------------------------------------------------
	_check("plot_at(-30, 30) is plot 0", _plot_at(Vector3(-30.0, 0.0, 30.0)) == 0)
	_check("plot_at(-18.5, 35.9) is plot 1", _plot_at(Vector3(-18.5, 0.0, 35.9)) == 1)
	_check("plot_at(35.5, 24.1) is plot 5", _plot_at(Vector3(35.5, 0.0, 24.1)) == 5)
	_check("plot_at(0, 0) is outside (-1)", _plot_at(Vector3(0.0, 0.0, 0.0)) == -1)
	_check("plot_at(-40, 30) is outside (-1)", _plot_at(Vector3(-40.0, 0.0, 30.0)) == -1)
	_check("plot_at(0, 36.5) is outside (-1)", _plot_at(Vector3(0.0, 0.0, 36.5)) == -1)

	_check("chest costs 10", _cost(&"chest") == 10)
	_check("hut costs 40", _cost(&"hut") == 40)
	_check("an unknown object costs nothing", _cost(&"castle") == 0)

	var owner: StringName = _plots.call(&"local_owner_id")
	_check("local_owner_id() is not empty", owner != &"")
	_plots.set(&"now_override", BASE_TIME)

	# --- buying -------------------------------------------------------------
	_game.set(&"gold", 250)
	_check("buying plot 0 succeeds", bool(_plots.call(&"buy_plot", 0, owner)))
	_check("buying plot 0 costs 100 gold (%d)" % int(_game.get("gold")), int(_game.get("gold")) == 150)
	var bought := _get_plot(0)
	_check("plot 0 owner is the buyer", StringName(bought["owner"]) == owner)
	_check("plot 0 purchase timestamp is the injected now", int(bought["purchased_at"]) == BASE_TIME)
	_check("plot 0 fee clock starts at the purchase", int(bought["last_fee_at"]) == BASE_TIME)
	_check("plot_purchased fired for plot 0", _purchased.has(0))

	_check("buying an owned plot fails", not bool(_plots.call(&"buy_plot", 0, owner)))
	_check("failed re-purchase leaves gold at 150", int(_game.get("gold")) == 150)

	_game.set(&"gold", 50)
	_check("buying with 50 gold fails", not bool(_plots.call(&"buy_plot", 1, owner)))
	_check("failed purchase leaves gold unchanged (50)", int(_game.get("gold")) == 50)

	# --- building -----------------------------------------------------------
	_game.set(&"gold", 250)
	var chest_cell := Vector3i(-29, 0, 30)
	_check("placing a chest on plot 0 succeeds", bool(_plots.call(&"place_object", 0, &"chest", chest_cell)))
	_check("chest costs 10 gold (%d)" % int(_game.get("gold")), int(_game.get("gold")) == 240)
	var built := _get_plot(0)
	var objects: Array = built["objects"]
	_check("plot 0 records exactly one object", objects.size() == 1)
	if objects.size() == 1:
		var entry: Dictionary = objects[0]
		var recorded_cell: Vector3i = entry["cell"]
		_check("the recorded object is a chest", StringName(entry["id"]) == &"chest")
		_check("the recorded cell is the placed cell", recorded_cell == chest_cell)
	_check("object_placed fired for plot 0/chest", _placed.size() == 1 and int(_placed[0]["plot"]) == 0)

	_check("a second object in the same cell fails", not bool(_plots.call(&"place_object", 0, &"hut", chest_cell)))
	_check("a failed duplicate leaves gold at 240", int(_game.get("gold")) == 240)
	_check("a cell outside the plot fails", not bool(_plots.call(&"place_object", 0, &"hut", Vector3i(0, 0, 30))))
	_check("placing on an unowned plot fails", not bool(_plots.call(&"place_object", 1, &"chest", Vector3i(-17, 0, 30))))
	_check("object count stays at one after the failures", (_get_plot(0)["objects"] as Array).size() == 1)

	_check("can_place() rejects the occupied cell", not bool(_plots.call(&"can_place", 0, chest_cell)))
	_check("can_place() accepts a free cell inside plot 0", bool(_plots.call(&"can_place", 0, Vector3i(-28, 0, 30))))
	_check("can_place() rejects the plot edge", not bool(_plots.call(&"can_place", 0, Vector3i(-36, 0, 30))))
	_check("is_owned_by() sees the buyer", bool(_plots.call(&"is_owned_by", 0, owner)))
	_check("is_owned_by() is false on an unowned plot", not bool(_plots.call(&"is_owned_by", 1, owner)))
	_check("the build_toggle input action exists", InputMap.has_action(&"build_toggle"))

	# --- plot sign ----------------------------------------------------------
	var sign_scene := load("res://scenes/world/plot_sign.tscn") as PackedScene
	_check("plot_sign.tscn loads", sign_scene != null)
	var sign: Node = null
	if sign_scene != null:
		sign = sign_scene.instantiate()
		root.add_child(sign)
		sign.call(&"configure", 0, _plots)
		_check("the sign joins the 'interactable' group", sign.is_in_group(&"interactable"))
		_check(
			"the sign's layer is visible to the interact ray (mask 5)",
			(int(sign.get("collision_layer")) & 5) != 0
		)
		var owned_text := str(sign.call(&"get_interaction_text"))
		_check(
			"an owned sign reports the daily fee (%s)" % owned_text,
			owned_text == "Plot 1 — yours · %d g/day" % _daily_fee
		)
		sign.call(&"configure", 1, _plots)
		var price_text := str(sign.call(&"get_interaction_text"))
		_check(
			"an unowned sign offers the purchase (%s)" % price_text,
			price_text == "Buy plot 2 — 100 gold  [E]"
		)

	# --- daily fee ----------------------------------------------------------
	var fee_before := int(_game.get("gold"))
	_plots.set(&"now_override", BASE_TIME + DAY - 10)
	_plots.call(&"charge_daily_fees")
	_check("a partial offline day charges nothing", int(_game.get("gold")) == fee_before)

	_plots.set(&"now_override", BASE_TIME + DAY)
	_plots.call(&"charge_daily_fees")
	_check(
		"+24 h offline elapsed charges one daily fee (%d -> %d)" % [fee_before, int(_game.get("gold"))],
		int(_game.get("gold")) == fee_before - _daily_fee
	)
	_check("+24 h moves the fee clock by exactly one day", int(_get_plot(0)["last_fee_at"]) == BASE_TIME + DAY)
	_check("charge_daily_fees() is idempotent within the same day", _charge_twice_is_stable())

	_plots.set(&"now_override", BASE_TIME + 2 * DAY)
	_plots.call(&"charge_daily_fees")
	_check(
		"+48 h offline has charged two days total (%d)" % int(_game.get("gold")),
		int(_game.get("gold")) == fee_before - 2 * _daily_fee
	)

	# --- persistence --------------------------------------------------------
	var snapshot := _get_plot(0)
	_check("save_plots() writes the file", bool(_plots.call(&"save_plots")) and FileAccess.file_exists(PLOTS_PATH))
	_plots.call(&"reset_plots")
	_check("reset_plots() clears the owner", StringName(_get_plot(0)["owner"]) == &"")
	_plots.call(&"load_plots")
	var restored := _get_plot(0)
	_check("reload restores the owner", StringName(restored["owner"]) == StringName(snapshot["owner"]))
	_check("reload restores purchased_at", int(restored["purchased_at"]) == int(snapshot["purchased_at"]))
	_check("reload restores last_fee_at", int(restored["last_fee_at"]) == int(snapshot["last_fee_at"]))
	_check("reload restores unpaid_days", int(restored["unpaid_days"]) == int(snapshot["unpaid_days"]))
	var restored_objects: Array = restored["objects"]
	_check("reload restores the object count", restored_objects.size() == 1)
	if restored_objects.size() == 1:
		var restored_entry: Dictionary = restored_objects[0]
		var restored_cell: Vector3i = restored_entry["cell"]
		_check("reload restores the object id", StringName(restored_entry["id"]) == &"chest")
		_check("reload restores the object cell", restored_cell == chest_cell)

	# --- expiry after unpaid days ------------------------------------------
	_game.set(&"gold", 220)
	_check("buying plot 2 for the expiry test succeeds", bool(_plots.call(&"buy_plot", 2, owner)))
	_check("plot 2 records its own chest", bool(_plots.call(&"place_object", 2, &"chest", Vector3i(-5, 0, 30))))
	_game.set(&"gold", 0)
	var expiry_clock := int(_get_plot(2)["last_fee_at"])
	for day in _expiry_days:
		_plots.set(&"now_override", expiry_clock + (day + 1) * DAY)
		_plots.call(&"charge_daily_fees")
		if day < _expiry_days - 1:
			_check(
				"unpaid day %d accumulates (%d)" % [day + 1, int(_get_plot(2)["unpaid_days"])],
				int(_get_plot(2)["unpaid_days"]) == day + 1
			)
	_check("three unpaid days expire plot 2", StringName(_get_plot(2)["owner"]) == &"")
	_check("plot_expired fired for plot 2", _expired.has(2))
	_check("an expired plot keeps no objects", (_get_plot(2)["objects"] as Array).is_empty())
	await process_frame
	var object_root := _plots.get_node_or_null("Objects")
	_check(
		"expired plot meshes are removed (objects left: %d)" % (
			object_root.get_child_count() if object_root != null else -1
		),
		object_root != null and object_root.get_child_count() == 0
	)

	# --- corrupt file -------------------------------------------------------
	var file := FileAccess.open(PLOTS_PATH, FileAccess.WRITE)
	_check("the save file can be corrupted for the test", file != null)
	if file != null:
		file.store_string("{ this is not valid json")
		file.close()
	_plots.call(&"load_plots")
	_check("a corrupt file resets to six unowned plots", _plot_count() == 6 and StringName(_get_plot(0)["owner"]) == &"")
	var repaired_text := FileAccess.get_file_as_string(PLOTS_PATH)
	var repaired: Variant = JSON.parse_string(repaired_text)
	_check("plots.json is regenerated as valid JSON", repaired is Dictionary)
	if repaired is Dictionary:
		var repaired_plots: Variant = (repaired as Dictionary).get("plots")
		_check(
			"the regenerated file holds 6 plots",
			repaired_plots is Array and (repaired_plots as Array).size() == 6
		)

	# --- sign interaction ---------------------------------------------------
	_game.set(&"gold", 250)
	sign.call(&"configure", 1, _plots)
	sign.call(&"interact", null)
	_check("interacting with an unowned sign buys the plot", StringName(_get_plot(1)["owner"]) == owner)
	_check("the sign purchase spends 100 gold (%d)" % int(_game.get("gold")), int(_game.get("gold")) == 150)
	_check(
		"a purchase toast is emitted (%s)" % (_toasts[0] if not _toasts.is_empty() else ""),
		not _toasts.is_empty() and _toasts[0] == "Plot 2 bought for 100 gold"
	)
	sign.call(&"interact", null)
	_check(
		"interacting with an owned sign only toasts (%s)" % (_toasts[1] if _toasts.size() > 1 else ""),
		_toasts.size() == 2 and _toasts[1] == "Plot 2 is already owned"
	)

	# --- a foreign owner on the sign ---------------------------------------
	if sign != null:
		_plots.call(&"from_dict", {
			"version": 1,
			"plots": [{
				"id": 3,
				"owner": "999",
				"purchased_at": 1,
				"last_fee_at": 1,
				"unpaid_days": 0,
				"objects": [],
			}],
		})
		sign.call(&"configure", 3, _plots)
		var foreign_text := str(sign.call(&"get_interaction_text"))
		_check(
			"a foreign-owned sign names the owner (%s)" % foreign_text,
			foreign_text == "Plot 4 — owned by 999"
		)

	_remove_save()
	_finish()


func _charge_twice_is_stable() -> bool:
	var before := int(_game.get("gold"))
	_plots.call(&"charge_daily_fees")
	return int(_game.get("gold")) == before


func _plot_count() -> int:
	var count := 0
	for index in 64:
		if _get_plot(index).is_empty():
			break
		count += 1
	return count


func _plot_at(at: Vector3) -> int:
	return int(_plots.call(&"plot_at", at))


func _cost(id: StringName) -> int:
	return int(_plots.call(&"get_object_cost", id))


func _get_plot(index: int) -> Dictionary:
	return _plots.call(&"get_plot", index) as Dictionary


func _on_purchased(plot_id: int) -> void:
	_purchased.append(plot_id)


func _on_expired(plot_id: int) -> void:
	_expired.append(plot_id)


func _on_object_placed(plot_id: int, object_id: String, cell: Vector3i) -> void:
	_placed.append({"plot": plot_id, "id": object_id, "cell": cell})


func _on_toast_requested(text: String) -> void:
	_toasts.append(text)


func _remove_save() -> void:
	if not FileAccess.file_exists(PLOTS_PATH):
		return
	var dir := DirAccess.open("user://")
	if dir != null:
		dir.remove(PLOTS_PATH.get_file())


func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label)


func _finish() -> void:
	if _failures == 0:
		print("PASSED  all plot assertions")
		quit(0)
	else:
		print("FAILED  %d assertion(s)" % _failures)
		quit(1)
