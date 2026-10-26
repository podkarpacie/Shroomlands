extends CanvasLayer
## Heads-up display for the local player: vitals, progression, hotbar, crosshair,
## interaction prompt and the gather bar.
##
## The HUD owns no game state. Every value arrives through `EventBus`; the first
## frame is seeded from the live player components so it is already correct
## before any signal fires. Gameplay never references this node.

const HOTBAR_NAME_CHARS := 7
const SLOT_SIZE := 48
## Inner margin for slot labels so text never touches the slot border.
const SLOT_LABEL_MARGIN := 3
## Red edge frame that fades out after a hit. Edge-only on purpose: a
## screen-wide wash hurts readability, so the middle stays clear.
const DAMAGE_FLASH_SECONDS := 0.35
const DAMAGE_FLASH_ALPHA := 0.35
## Vignette texture: a small frame stretched over the screen. Transparent up to
## VIGNETTE_INNER of each half-extent — the middle 70 % of the frame — and
## opaque on the border, where the modulate alpha above sets the real strength.
const VIGNETTE_SIZE := Vector2i(256, 144)
const VIGNETTE_INNER := 0.70
## How long the "You died" screen holds before the body respawns.
const DEATH_OVERLAY_SECONDS := 2.5
## Crosshair tint after a landed hit, back to normal within this window.
const HIT_FLASH_SECONDS := 0.22
## How often the plot status line re-reads the player's position.
const PLOT_STATUS_INTERVAL := 0.25
## How long a toast stays on screen.
const TOAST_SECONDS := 2.6
const SECONDS_PER_HOUR := 3600.0

const PALETTE := {
	"text": Color(0.92, 0.94, 0.88),
	"text_dim": Color(0.66, 0.71, 0.60),
	"gold": Color(0.96, 0.80, 0.30),
	"plot": Color(0.70, 0.86, 0.46),
	"hp_fill": Color(0.80, 0.17, 0.18),
	"stamina_fill": Color(0.72, 0.84, 0.22),
	"xp_fill": Color(0.38, 0.70, 1.00),
	"bar_track": Color(0.06, 0.07, 0.05, 0.85),
	"slot": Color(0.07, 0.08, 0.06, 0.88),
	"slot_border": Color(0.30, 0.36, 0.24, 0.90),
	"slot_active": Color(0.98, 0.83, 0.32),
	"crosshair": Color(0.97, 0.98, 0.92, 0.85),
	"prompt": Color(0.97, 0.98, 0.92),
	"shadow": Color(0.0, 0.0, 0.0, 0.75),
	"damage": Color(0.85, 0.06, 0.05),
	"hit": Color(0.98, 0.86, 0.36),
	"crit": Color(1.0, 0.55, 0.16),
	"death": Color(0.14, 0.02, 0.03, 0.72),
}

@onready var _hp_label: Label = $Root/Vitals/HPLabel
@onready var _hp_bar: ProgressBar = $Root/Vitals/HPBar
@onready var _stamina_bar: ProgressBar = $Root/Vitals/StaminaBar
@onready var _level_label: Label = $Root/Progression/LevelLabel
@onready var _xp_bar: ProgressBar = $Root/Progression/XPBar
@onready var _gold_label: Label = $Root/Progression/GoldLabel
@onready var _vocation_button: Button = $Root/Progression/VocationButton
@onready var _crosshair: ColorRect = $Root/Crosshair
@onready var _prompt_label: Label = $Root/InteractionPrompt
@onready var _gather_box: VBoxContainer = $Root/GatherBox
@onready var _gather_label: Label = $Root/GatherBox/GatherLabel
@onready var _gather_bar: ProgressBar = $Root/GatherBox/GatherBar
@onready var _hotbar: HBoxContainer = $Root/Hotbar
@onready var _plot_status: Label = $Root/PlotStatus

var _player: Node = null
var _inventory: Node = null
var _selected := 0
var _subscriptions: Array[Dictionary] = []
var _slot_panels: Array[PanelContainer] = []
var _slot_styles: Array[StyleBoxFlat] = []
var _slot_names: Array[Label] = []
var _slot_counts: Array[Label] = []

## Last HP seen, so only a *drop* flashes the screen.
var _last_hp := -1.0
## Last level seen, so the vocation suffix can be rebuilt from either signal.
var _level := 1
var _damage_flash: TextureRect = null
var _death_overlay: ColorRect = null
var _death_timer: Timer = null
var _damage_flash_left := 0.0
var _hit_flash_left := 0.0
var _hit_flash_color := Color.WHITE
var _toast_label: Label = null
var _toast_timer: Timer = null
var _plot_system_ref: Node = null
var _plot_status_left := 0.0


func _ready() -> void:
	_build_hotbar()
	_style_static_nodes()
	_build_feedback_nodes()
	_apply_initial_state()
	_connect_signals()
	_vocation_button.pressed.connect(_on_vocation_pressed)


func _process(delta: float) -> void:
	if _damage_flash_left > 0.0:
		_damage_flash_left = maxf(_damage_flash_left - delta, 0.0)
		var tint := _damage_flash.modulate
		tint.a = DAMAGE_FLASH_ALPHA * (_damage_flash_left / DAMAGE_FLASH_SECONDS)
		_damage_flash.modulate = tint
	if _hit_flash_left > 0.0:
		_hit_flash_left = maxf(_hit_flash_left - delta, 0.0)
		var base: Color = PALETTE["crosshair"]
		_crosshair.color = base.lerp(_hit_flash_color, _hit_flash_left / HIT_FLASH_SECONDS)
	_plot_status_left = maxf(_plot_status_left - delta, 0.0)
	if _plot_status_left <= 0.0:
		_plot_status_left = PLOT_STATUS_INTERVAL
		_refresh_plot_status()


func _exit_tree() -> void:
	if not is_instance_valid(EventBus):
		return
	for entry: Dictionary in _subscriptions:
		var sig: Signal = entry["signal"]
		var handler: Callable = entry["handler"]
		if sig.is_connected(handler):
			sig.disconnect(handler)
	_subscriptions.clear()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	var index := _number_key_index(key)
	if index < 0:
		return
	_set_selected(index)
	get_viewport().set_input_as_handled()


func _number_key_index(event: InputEventKey) -> int:
	var code := event.keycode
	if code == KEY_NONE:
		code = event.physical_keycode
	if code >= KEY_1 and code <= KEY_8:
		return int(code - KEY_1)
	return -1


func _set_selected(index: int) -> void:
	if _slot_styles.is_empty():
		return
	_selected = clampi(index, 0, _slot_styles.size() - 1)
	for slot_index in _slot_styles.size():
		var style := _slot_styles[slot_index]
		style.border_color = (
			PALETTE["slot_active"] if slot_index == _selected else PALETTE["slot_border"]
		)
		style.bg_color = PALETTE["slot"]


## Hotbar slots are built in code: eight identical cells with a name, a stack
## count and a border that lights up on the selected slot.
func _build_hotbar() -> void:
	for index in Game.HOTBAR_SLOTS:
		var slot := PanelContainer.new()
		slot.name = "Slot%d" % index
		slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxFlat.new()
		style.bg_color = PALETTE["slot"]
		style.border_color = PALETTE["slot_border"]
		style.set_border_width_all(2)
		style.set_corner_radius_all(6)
		slot.add_theme_stylebox_override("panel", style)

		var overlay := Control.new()
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		slot.add_child(overlay)

		var name_margin := MarginContainer.new()
		name_margin.name = "NameMargin"
		name_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		name_margin.offset_bottom = -12.0
		name_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_margin.add_theme_constant_override("margin_left", SLOT_LABEL_MARGIN)
		name_margin.add_theme_constant_override("margin_right", SLOT_LABEL_MARGIN)
		name_margin.add_theme_constant_override("margin_top", 2)
		overlay.add_child(name_margin)

		# `clip_text` stays off: a centered name one pixel wider than its box
		# would otherwise lose part of its first glyph on the left (Venomveil
		# rendered as "/enomve…"). The margin keeps the text off the border.
		var name_label := Label.new()
		name_label.name = "NameLabel"
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.clip_text = false
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.add_theme_font_size_override("font_size", 9)
		name_label.add_theme_color_override("font_color", PALETTE["text"])
		name_margin.add_child(name_label)

		var count_label := Label.new()
		count_label.name = "CountLabel"
		count_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		count_label.offset_left = 12.0
		count_label.offset_top = 20.0
		count_label.offset_right = -4.0
		count_label.offset_bottom = -2.0
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		count_label.add_theme_font_size_override("font_size", 10)
		count_label.add_theme_color_override("font_color", PALETTE["text_dim"])
		overlay.add_child(count_label)

		_hotbar.add_child(slot)
		_slot_panels.append(slot)
		_slot_styles.append(style)
		_slot_names.append(name_label)
		_slot_counts.append(count_label)
	_set_selected(0)


func _style_static_nodes() -> void:
	_style_bar(_hp_bar, PALETTE["hp_fill"], 8)
	_style_bar(_stamina_bar, PALETTE["stamina_fill"], 5)
	_style_bar(_xp_bar, PALETTE["xp_fill"], 3)
	_style_bar(_gather_bar, PALETTE["stamina_fill"], 6)
	_style_outlined_label(_hp_label, PALETTE["text"], 14)
	_style_outlined_label(_level_label, PALETTE["text"], 18)
	_style_outlined_label(_gold_label, PALETTE["gold"], 15)
	_style_outlined_label(_prompt_label, PALETTE["prompt"], 16)
	_style_outlined_label(_gather_label, PALETTE["text_dim"], 12)
	_style_outlined_label(_plot_status, PALETTE["plot"], 14)
	_style_vocation_button()
	_crosshair.color = PALETTE["crosshair"]
	_prompt_label.visible = false
	_gather_box.visible = false
	_gather_bar.visible = false
	_plot_status.visible = false


func _style_bar(bar: ProgressBar, fill: Color, radius: int) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = PALETTE["bar_track"]
	track.set_corner_radius_all(radius)
	var filled := StyleBoxFlat.new()
	filled.bg_color = fill
	filled.set_corner_radius_all(radius)
	bar.add_theme_stylebox_override("background", track)
	bar.add_theme_stylebox_override("fill", filled)
	bar.show_percentage = false


func _style_outlined_label(label: Label, color: Color, size: int) -> void:
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", PALETTE["shadow"])
	label.add_theme_constant_override("outline_size", 4)
	label.add_theme_font_size_override("font_size", size)


## The unlock hint is a borderless button: normally it only points at the V key,
## but a click asks the modal to open as well.
func _style_vocation_button() -> void:
	var empty := StyleBoxEmpty.new()
	for state: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		_vocation_button.add_theme_stylebox_override(state, empty)
	_vocation_button.add_theme_color_override("font_color", PALETTE["text_dim"])
	_vocation_button.add_theme_color_override("font_hover_color", PALETTE["gold"])
	_vocation_button.add_theme_color_override("font_pressed_color", PALETTE["gold"])
	_vocation_button.add_theme_color_override("font_outline_color", PALETTE["shadow"])
	_vocation_button.add_theme_constant_override("outline_size", 3)
	_vocation_button.add_theme_font_size_override("font_size", 11)
	_vocation_button.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_vocation_button.focus_mode = Control.FOCUS_NONE
	_vocation_button.visible = false


## The damage vignette and the death screen are built in code: both are pure
## view state of this script, so they stay out of the static HUD layout.
func _build_feedback_nodes() -> void:
	var root := $Root as Control
	_damage_flash = TextureRect.new()
	_damage_flash.name = "DamageVignette"
	_damage_flash.texture = _vignette_texture()
	_damage_flash.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_damage_flash.stretch_mode = TextureRect.STRETCH_SCALE
	_damage_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_damage_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_damage_flash.modulate = Color(1.0, 1.0, 1.0, 0.0)
	root.add_child(_damage_flash)
	# Behind the vitals, hotbar and prompts: the frame tints the world, never
	# the numbers the player needs to read during a fight.
	root.move_child(_damage_flash, 0)

	_death_overlay = ColorRect.new()
	_death_overlay.name = "DeathOverlay"
	_death_overlay.color = PALETTE["death"]
	_death_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_death_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_overlay.visible = false
	root.add_child(_death_overlay)

	var label := Label.new()
	label.name = "DeathLabel"
	label.text = "You died"
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 64)
	label.add_theme_color_override("font_color", PALETTE["text"])
	label.add_theme_color_override("font_outline_color", PALETTE["shadow"])
	label.add_theme_constant_override("outline_size", 8)
	_death_overlay.add_child(label)

	_death_timer = Timer.new()
	_death_timer.name = "DeathTimer"
	_death_timer.one_shot = true
	_death_timer.wait_time = DEATH_OVERLAY_SECONDS
	_death_timer.timeout.connect(_on_death_screen_timeout)
	add_child(_death_timer)

	# Transient feedback (plot bought/expired, build refused) sits under the
	# progression block, centred, so it never covers the interaction prompt.
	_toast_label = Label.new()
	_toast_label.name = "Toast"
	_toast_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_toast_label.offset_left = -360.0
	_toast_label.offset_top = 96.0
	_toast_label.offset_right = 360.0
	_toast_label.offset_bottom = 128.0
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_label.visible = false
	_style_outlined_label(_toast_label, PALETTE["gold"], 18)
	root.add_child(_toast_label)

	_toast_timer = Timer.new()
	_toast_timer.name = "ToastTimer"
	_toast_timer.one_shot = true
	_toast_timer.wait_time = TOAST_SECONDS
	_toast_timer.timeout.connect(_on_toast_timeout)
	add_child(_toast_timer)


## Edge-only vignette: strongest at the border and fully transparent across the
## middle 70 % of the screen, so a hit never tints the whole frame red. The
## frame is drawn under the HUD text, so vitals stay readable while it fades.
func _vignette_texture() -> ImageTexture:
	var tint: Color = PALETTE["damage"]
	var image := Image.create_empty(VIGNETTE_SIZE.x, VIGNETTE_SIZE.y, false, Image.FORMAT_RGBA8)
	for y in VIGNETTE_SIZE.y:
		var ny := (float(y) + 0.5) / float(VIGNETTE_SIZE.y) * 2.0 - 1.0
		for x in VIGNETTE_SIZE.x:
			var nx := (float(x) + 0.5) / float(VIGNETTE_SIZE.x) * 2.0 - 1.0
			# Chebyshev distance: 0 at the centre, 1 on any border, so the
			# transparent hole matches the screen's middle rather than a
			# circle that the non-uniform stretch would turn into an ellipse.
			var edge := maxf(absf(nx), absf(ny))
			image.set_pixel(x, y, Color(tint, smoothstep(VIGNETTE_INNER, 1.0, edge)))
	return ImageTexture.create_from_image(image)


func _flash_damage() -> void:
	if _damage_flash == null:
		return
	_damage_flash_left = DAMAGE_FLASH_SECONDS


func _apply_initial_state() -> void:
	_gold_label.text = "Gold %d" % Game.gold
	_xp_bar.max_value = Game.xp_to_level(1)
	_xp_bar.value = 0.0
	_bind_player()
	var stats := _stats_node()
	if stats == null:
		_on_hp_changed(100.0, 100.0)
		_on_stamina_changed(100.0, 100.0)
		_on_level_changed(1)
	else:
		_on_hp_changed(float(stats.get("hp")), float(stats.get("max_hp")))
		_on_stamina_changed(float(stats.get("stamina")), float(stats.get("max_stamina")))
		var level := int(stats.get("level"))
		_on_level_changed(level)
		_on_xp_changed(int(stats.get("xp")), Game.xp_to_level(level))
	_refresh_vocation_hint()
	_refresh_hotbar()


func _connect_signals() -> void:
	_track(EventBus.hp_changed, _on_hp_changed)
	_track(EventBus.stamina_changed, _on_stamina_changed)
	_track(EventBus.xp_changed, _on_xp_changed)
	_track(EventBus.level_changed, _on_level_changed)
	_track(EventBus.gold_changed, _on_gold_changed)
	_track(EventBus.inventory_changed, _on_inventory_changed)
	_track(EventBus.hotbar_changed, _on_inventory_changed)
	_track(EventBus.gather_progress_changed, _on_gather_progress_changed)
	_track(EventBus.gather_finished, _on_gather_finished)
	_track(EventBus.interaction_prompt_changed, _on_interaction_prompt_changed)
	_track(EventBus.enemy_hit, _on_enemy_hit)
	_track(EventBus.player_died, _on_player_died)
	_track(EventBus.player_respawned, _on_player_respawned)
	_track(EventBus.toast_requested, _on_toast_requested)
	_track(EventBus.plot_purchased, _on_plot_changed)
	_track(EventBus.plot_expired, _on_plot_changed)
	_track(EventBus.vocation_chosen, _on_vocation_chosen)


func _track(sig: Signal, handler: Callable) -> void:
	sig.connect(handler)
	_subscriptions.append({"signal": sig, "handler": handler})


func _bind_player() -> void:
	if _player != null and is_instance_valid(_player) and _inventory != null and is_instance_valid(_inventory):
		return
	var player := _local_body()
	if player == null:
		# Before this peer's body exists the group only holds other players'
		# replicas; binding to one would show their HP in this HUD for good.
		return
	_player = player
	_inventory = player.get_node_or_null("InventorySystem")


## This peer's own body. `Game.get_local_player()` prefers an authoritative node,
## but a client also receives the host's body, so the authority has to match
## this peer id before the HUD may follow it.
func _local_body() -> Node:
	var player := Game.get_local_player()
	if player == null or not is_instance_valid(player):
		return null
	if player.get_multiplayer_authority() != multiplayer.get_unique_id():
		return null
	return player


func _stats_node() -> Node:
	if _player == null or not is_instance_valid(_player):
		_bind_player()
	if _player == null or not is_instance_valid(_player):
		return null
	return _player.get_node_or_null("Stats")


func _on_hp_changed(current: float, max_hp: float) -> void:
	_hp_bar.max_value = maxf(max_hp, 1.0)
	_hp_bar.value = clampf(current, 0.0, _hp_bar.max_value)
	_hp_label.text = "HP %d/%d" % [roundi(current), roundi(max_hp)]
	if _last_hp >= 0.0 and current < _last_hp - 0.001:
		_flash_damage()
	_last_hp = current
	if _inventory == null:
		# The player is spawned after the HUD's first frame; this first signal
		# is the earliest reliable moment to pick up its inventory.
		_bind_player()
		_refresh_hotbar()


func _on_stamina_changed(current: float, max_stamina: float) -> void:
	_stamina_bar.max_value = maxf(max_stamina, 1.0)
	_stamina_bar.value = clampf(current, 0.0, _stamina_bar.max_value)


func _on_xp_changed(current: int, needed: int) -> void:
	_xp_bar.max_value = maxi(needed, 1)
	_xp_bar.value = clampi(current, 0, int(_xp_bar.max_value))


func _on_level_changed(new_level: int) -> void:
	_level = new_level
	_level_label.text = _level_text()
	_xp_bar.max_value = Game.xp_to_level(new_level)
	_xp_bar.value = minf(_xp_bar.value, _xp_bar.max_value)
	_refresh_vocation_hint()


## "Lv 20 · Knight" once a vocation is chosen, plain "Lv 8" before that.
func _level_text() -> String:
	var vocation := Lore.get_vocation(String(Game.chosen_vocation))
	if vocation.is_empty():
		return "Lv %d" % _level
	return "Lv %d · %s" % [_level, str(vocation.get("name", ""))]


## Quiet hint, only while a vocation can still be picked at the current level.
func _refresh_vocation_hint() -> void:
	if _vocation_button == null:
		return
	_vocation_button.visible = (
		_level >= Game.VOCATION_UNLOCK_LEVEL and Game.chosen_vocation == &""
	)


func _on_vocation_chosen(_vocation_id: String) -> void:
	_level_label.text = _level_text()
	_refresh_vocation_hint()


## Same modal the V key opens; it refuses when nothing is eligible.
func _on_vocation_pressed() -> void:
	var ui := get_tree().get_first_node_in_group(&"vocation_ui")
	if ui != null and ui.has_method(&"open"):
		ui.call(&"open")


func _on_gold_changed(amount: int) -> void:
	_gold_label.text = "Gold %d" % amount


func _on_inventory_changed() -> void:
	_refresh_hotbar()


func _on_gather_progress_changed(current: float, total: float) -> void:
	if total <= 0.0:
		_set_gather_visible(false)
		return
	_gather_bar.max_value = total
	_gather_bar.value = clampf(current, 0.0, total)
	_set_gather_visible(true)


func _on_gather_finished(_mushroom_id: String) -> void:
	_set_gather_visible(false)


func _set_gather_visible(value: bool) -> void:
	_gather_box.visible = value
	_gather_bar.visible = value


func _on_interaction_prompt_changed(text: String) -> void:
	_prompt_label.text = text
	_prompt_label.visible = not text.strip_edges().is_empty()


## A landed hit only tints the crosshair: the swing already caused the HP change,
## so a second full-screen flash would read as the player being hurt.
func _on_enemy_hit(_enemy: Node, _amount: float, is_crit: bool) -> void:
	_hit_flash_left = HIT_FLASH_SECONDS
	_hit_flash_color = PALETTE["crit"] if is_crit else PALETTE["hit"]


func _on_player_died() -> void:
	_bind_player()
	if _death_overlay != null:
		_death_overlay.visible = true
	if _death_timer != null:
		_death_timer.start(DEATH_OVERLAY_SECONDS)


## The death screen owns the respawn hand-off: `PlayerStats.die()` only raises the
## signal, so the body comes back exactly when the overlay clears.
func _on_death_screen_timeout() -> void:
	if _death_overlay != null:
		_death_overlay.visible = false
	var stats := _stats_node()
	if stats != null and stats.has_method(&"respawn"):
		stats.call(&"respawn")


func _on_player_respawned() -> void:
	if _death_overlay != null:
		_death_overlay.visible = false
	if _death_timer != null:
		_death_timer.stop()


func _on_toast_requested(text: String) -> void:
	if _toast_label == null:
		return
	_toast_label.text = text
	_toast_label.visible = true
	if _toast_timer != null:
		_toast_timer.start(TOAST_SECONDS)


func _on_toast_timeout() -> void:
	if _toast_label != null:
		_toast_label.visible = false


func _on_plot_changed(_plot_id: int) -> void:
	# Read the new state on the next frame instead of waiting for the poll.
	_plot_status_left = 0.0


## Compact plot line, shown only while the player stands on one of the plots.
func _refresh_plot_status() -> void:
	var system := _plot_system()
	_bind_player()
	if system == null or _player == null or not is_instance_valid(_player):
		_set_plot_status("")
		return
	var plot_id := int(system.call(&"plot_at", (_player as Node3D).global_position))
	if plot_id < 0:
		_set_plot_status("")
		return
	var plot: Dictionary = system.call(&"get_plot", plot_id)
	if plot.is_empty():
		_set_plot_status("")
		return
	var owner := StringName(plot.get("owner", &""))
	if owner == &"":
		_set_plot_status("Plot %d · %d g to buy" % [
			plot_id + 1, int(system.call(&"plot_price"))
		])
		return
	if bool(system.call(&"is_owned_by", plot_id, system.call(&"local_owner_id"))):
		var unpaid := int(plot.get("unpaid_days", 0))
		if unpaid > 0:
			_set_plot_status("Plot %d · yours · unpaid %d/%d d" % [
				plot_id + 1, unpaid, Game.PLOT_EXPIRY_DAYS
			])
			return
		var seconds := int(system.call(&"next_fee_seconds", plot_id))
		if seconds <= 0:
			_set_plot_status("Plot %d · yours · fee due" % (plot_id + 1))
			return
		_set_plot_status("Plot %d · yours · next fee in %d h" % [
			plot_id + 1, int(ceil(float(seconds) / SECONDS_PER_HOUR))
		])
		return
	_set_plot_status("Plot %d · owned by %s" % [plot_id + 1, String(owner)])


func _set_plot_status(text: String) -> void:
	_plot_status.text = text
	_plot_status.visible = not text.is_empty()


func _plot_system() -> Node:
	if _plot_system_ref != null and is_instance_valid(_plot_system_ref):
		return _plot_system_ref
	_plot_system_ref = get_tree().get_first_node_in_group(&"plot_system")
	return _plot_system_ref


func _refresh_hotbar() -> void:
	_bind_player()
	var ids: Array = []
	if _inventory != null and _inventory.has_method(&"hotbar_ids"):
		ids = _inventory.call(&"hotbar_ids")
	for index in _slot_panels.size():
		var id := StringName(ids[index]) if index < ids.size() else &""
		var count := 0
		if id != &"" and _inventory != null and _inventory.has_method(&"get_slot"):
			var slot: Dictionary = _inventory.call(&"get_slot", index)
			count = int(slot.get("count", 0))
		var name_label := _slot_names[index]
		var count_label := _slot_counts[index]
		if id == &"" or count <= 0:
			name_label.text = ""
			count_label.text = ""
			name_label.add_theme_color_override("font_color", PALETTE["text"])
			continue
		name_label.text = _short_name(id)
		count_label.text = str(count)
		name_label.add_theme_color_override("font_color", _item_color(id))


func _short_name(id: StringName) -> String:
	var display := Lore.item_display_name(String(id))
	if display.length() <= HOTBAR_NAME_CHARS:
		return display
	return display.substr(0, HOTBAR_NAME_CHARS - 1) + "…"


func _item_color(id: StringName) -> Color:
	var mushroom := Lore.get_mushroom(String(id))
	if mushroom.is_empty():
		return PALETTE["text"]
	return Lore.rarity_color(str(mushroom.get("rarity", "")))
