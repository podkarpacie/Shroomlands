extends StaticBody3D
## A plot marker standing in its plot's front-left corner. It is the purchase
## entry point: the interaction ray sees it (layer 3, like harvestables), and
## every state query goes through PlotSystem so the sign owns no plot data.
##
## The corner rather than the plot centre is deliberate: players build in the
## middle, and a sign there disappeared under a hut's roof and label.
##
## Physics layer 3 keeps it out of the camera spring arm's layer-1 cast, so a
## sign never collapses the third-person camera. The player walks through it.

@export var plot_id := 0

var _system: Node = null
var _subscriptions: Array[Dictionary] = []

@onready var _label: Label3D = $Label


func _ready() -> void:
	add_to_group(&"interactable")
	_track(EventBus.plot_purchased, _on_plot_changed)
	_track(EventBus.plot_expired, _on_plot_changed)
	refresh()


func _exit_tree() -> void:
	for entry: Dictionary in _subscriptions:
		var sig: Signal = entry["signal"]
		var handler: Callable = entry["handler"]
		if sig.is_connected(handler):
			sig.disconnect(handler)
	_subscriptions.clear()


## Called by PlotSystem right after instancing; `system` is the registry.
func configure(id: int, system: Node) -> void:
	plot_id = id
	_system = system
	refresh()


func get_interaction_text() -> String:
	var plot := _plot()
	if plot.is_empty():
		return "Plot %d" % (plot_id + 1)
	if StringName(plot.get("owner", &"")) == &"":
		return "Buy plot %d — %d gold  [E]" % [plot_id + 1, _price()]
	if _owned_by_local(plot):
		return "Plot %d — yours · %d g/day" % [plot_id + 1, Game.PLOT_DAILY_FEE]
	return "Plot %d — owned by %s" % [plot_id + 1, String(plot.get("owner", ""))]


## Routes the purchase through PlotSystem; failures become a HUD toast instead
## of a silent no-op.
func interact(_player: Node) -> void:
	if _system == null:
		return
	var plot := _plot()
	if not plot.is_empty() and StringName(plot.get("owner", &"")) != &"":
		EventBus.toast_requested.emit("Plot %d is already owned" % (plot_id + 1))
		return
	if Network.mode == Network.CLIENT:
		_system.call(&"buy_plot", plot_id, _local_owner())
		EventBus.toast_requested.emit("Purchase request sent…")
		return
	if bool(_system.call(&"buy_plot", plot_id, _local_owner())):
		EventBus.toast_requested.emit("Plot %d bought for %d gold" % [plot_id + 1, _price()])
	else:
		EventBus.toast_requested.emit("Not enough gold")


## Repaints the floating label; PlotSystem calls this after ownership changes.
func refresh() -> void:
	if _label == null:
		return
	var plot := _plot()
	if plot.is_empty():
		_label.text = "Plot %d" % (plot_id + 1)
		return
	if StringName(plot.get("owner", &"")) == &"":
		_label.text = "Plot %d\n%d g" % [plot_id + 1, _price()]
	elif _owned_by_local(plot):
		_label.text = "Plot %d\nyours" % (plot_id + 1)
	else:
		_label.text = "Plot %d\nowned" % (plot_id + 1)


func _plot() -> Dictionary:
	if _system == null or not _system.has_method(&"get_plot"):
		return {}
	return _system.call(&"get_plot", plot_id) as Dictionary


func _owned_by_local(plot: Dictionary) -> bool:
	if _system == null or not _system.has_method(&"is_owned_by"):
		return false
	return bool(_system.call(&"is_owned_by", plot_id, _local_owner()))


func _local_owner() -> StringName:
	if _system != null and _system.has_method(&"local_owner_id"):
		return _system.call(&"local_owner_id") as StringName
	return StringName(str(multiplayer.get_unique_id()))


func _price() -> int:
	if _system != null and _system.has_method(&"plot_price"):
		return int(_system.call(&"plot_price"))
	return 100


func _on_plot_changed(_id: int) -> void:
	refresh()


func _track(sig: Signal, handler: Callable) -> void:
	sig.connect(handler)
	_subscriptions.append({"signal": sig, "handler": handler})
