extends CanvasLayer
## End-of-expedition results: shows the layer, loot value against the quota,
## mushrooms, deaths and time, and pays a bonus when the quota was met.
##
## `Main` closes the run when the party leaves a forest layer, so this panel
## appears after the player is back in town. It blocks movement through the
## player's `ui_blocking` flag rather than pausing the tree, so a session's
## server keeps running.

const UITheme := preload("res://scripts/ui/UITheme.gd")

@onready var _title: Label = $Root/Center/Card/Margin/Content/Title
@onready var _verdict: Label = $Root/Center/Card/Margin/Content/Verdict
@onready var _body: Label = $Root/Center/Card/Margin/Content/Body
@onready var _continue: Button = $Root/Center/Card/Margin/Content/ContinueButton


func _ready() -> void:
	visible = false
	EventBus.run_finished.connect(_on_run_finished)
	_continue.pressed.connect(_close)


func _on_run_finished(summary: Dictionary) -> void:
	var met := bool(summary.get("met", false))
	_title.text = "EXPEDITION COMPLETE" if met else "QUOTA MISSED"
	_title.modulate = UITheme.ACCENT if met else UITheme.AMBER
	_verdict.text = (
		"Quota met — the guild pays a bonus"
		if met else "Quota missed — you kept what you carried"
	)
	_verdict.modulate = UITheme.ACCENT_SOFT if met else UITheme.AMBER
	var seconds := int(summary.get("seconds", 0.0))
	_body.text = "%s — Layer %d\nLoot value   %d / %d g\nBonus        %d g\nMushrooms    %d\nDeaths       %d\nTime         %d:%02d" % [
		str(summary.get("name", "The Forest")),
		int(summary.get("layer", 1)),
		int(summary.get("gold", 0)),
		int(summary.get("quota", 0)),
		int(summary.get("bonus", 0)),
		int(summary.get("mushrooms", 0)),
		int(summary.get("deaths", 0)),
		seconds / 60,
		seconds % 60,
	]
	visible = true
	_set_blocking(true)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_continue.grab_focus()


func _close() -> void:
	visible = false
	_set_blocking(false)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _set_blocking(value: bool) -> void:
	var player := Game.get_local_player()
	if player != null and player.has_method(&"set_ui_blocking"):
		player.call(&"set_ui_blocking", value)
