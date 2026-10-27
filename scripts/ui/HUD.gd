extends CanvasLayer
## Heads-up display for the local player: vitals, progression, hotbar, crosshair,
## interaction prompt and the gather bar.
##
## The HUD owns no game state. Every value arrives through `EventBus`; the first
## frame is seeded from the live player components so it is already correct
## before any signal fires. Gameplay never references this node.

const HOTBAR_NAME_CHARS := 18
const SLOT_SIZE := 48
const DAMAGE_FLASH_SECONDS := 0.35
const DAMAGE_FLASH_ALPHA := 0.38
## Vignette texture: a small frame stretched over the screen. Transparent up to
## VIGNETTE_INNER of each half-extent — the middle 70 % of the frame — and
## opaque on the border, where the modulate alpha above sets the real strength.
const VIGNETTE_SIZE := Vector2i(256, 144)
const VIGNETTE_INNER := 0.70
## How long the "You died" screen holds before the body respawns.
const DEATH_OVERLAY_SECONDS := 2.5
## How often the plot status line re-reads the player's position.
const PLOT_STATUS_INTERVAL := 0.25
## How long a toast stays on screen.
const TOAST_SECONDS := 2.6
const SECONDS_PER_HOUR := 3600.0

@onready var _vitals_backdrop: Panel = $Root/VitalsBackdrop
@onready var _progression_backdrop: Panel = $Root/ProgressionBackdrop
@onready var _hotbar_backdrop: Panel = $Root/HotbarBackdrop
@onready var _prompt_backdrop: Panel = $Root/PromptBackdrop
@onready var _gather_backdrop: Panel = $Root/GatherBackdrop
@onready var _plot_backdrop: Panel = $Root/PlotBackdrop
@onready var _hp_label: Label = $Root/Vitals/HPLabel
@onready var _hp_bar: ProgressBar = $Root/Vitals/HPBar
@onready var _stamina_bar: ProgressBar = $Root/Vitals/StaminaBar
@onready var _stamina_value: Label = $Root/Vitals/StaminaValue
@onready var _level_label: Label = $Root/Progression/LevelLabel
@onready var _biome_label: Label = $Root/Progression/BiomeLabel
@onready var _xp_bar: ProgressBar = $Root/Progression/XPBar
@onready var _xp_value: Label = $Root/Progression/XPValue
@onready var _gold_label: Label = $Root/Progression/GoldLabel
@onready var _vocation_button: Button = $Root/Progression/VocationButton
@onready var _crosshair: Control = $Root/Crosshair
@onready var _prompt_label: Label = $Root/InteractionPrompt
@onready var _gather_box: VBoxContainer = $Root/GatherBox
@onready var _gather_label: Label = $Root/GatherBox/GatherLabel
@onready var _gather_bar: ProgressBar = $Root/GatherBox/GatherBar
@onready var _selected_item: Label = $Root/SelectedItem
@onready var _hotbar: HBoxContainer = $Root/Hotbar
@onready var _plot_status: Label = $Root/PlotStatus

var _player: Node = null
var _inventory: Node = null
var _selected := 0
var _subscriptions: Array[Dictionary] = []
var _slot_panels: Array[PanelContainer] = []
var _slot_styles: Array[StyleBoxFlat] = []
var _slot_icons: Array[TextureRect] = []
var _slot_names: Array[Label] = []
var _slot_counts: Array[Label] = []
var _slot_keys: Array[Label] = []
var _slot_rarity: Array[ColorRect] = []
var _selection_tween: Tween = null

## Last HP seen, so only a *drop* flashes the screen.
var _last_hp := -1.0
## Last level seen, so the vocation suffix can be rebuilt from either signal.
var _level := 1
var _damage_flash: TextureRect = null
var _damage_layer: Control = null
var _death_overlay: ColorRect = null
var _death_timer: Timer = null
var _damage_flash_left := 0.0
var _toast_panel: PanelContainer = null
var _toast_label: Label = null
var _toast_timer: Timer = null
var _plot_system_ref: Node = null
var _plot_status_left := 0.0


func _ready() -> void:
	UITheme.install(get_tree().root)
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
	_plot_status_left = maxf(_plot_status_left - delta, 0.0)
	if _plot_status_left <= 0.0:
		_plot_status_left = PLOT_STATUS_INTERVAL
		_refresh_plot_status()
	# A low-HP heartbeat on the vitality card: subtle, no number flicker.
	var ratio := 1.0
	if _last_hp >= 0.0 and _hp_bar.max_value > 0.0:
		ratio = _last_hp / _hp_bar.max_value
	var pulse := 0.0
	if ratio < 0.30 and ratio > 0.0 and _vitals_backdrop != null:
		pulse = (sin(Time.get_ticks_msec() * 0.012) * 0.5 + 0.5) * 0.35
		_vitals_backdrop.modulate = Color(1.0, 1.0 - pulse * 0.10, 1.0 - pulse * 0.10, 1.0)
	else:
		_vitals_backdrop.modulate = Color.WHITE


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
	if _selection_tween != null and _selection_tween.is_valid():
		_selection_tween.kill()
	_selection_tween = create_tween().set_parallel(true)
	for slot_index in _slot_styles.size():
		var style := _slot_styles[slot_index]
		var filled := _slot_item_id(slot_index) != &""
		var rarity := ItemVisuals.color(String(_slot_item_id(slot_index))) if filled else UITheme.BORDER_DIM
		style.bg_color = (
			Color(0.15, 0.20, 0.11, 0.98) if slot_index == _selected
			else Color(0.065, 0.085, 0.060, 0.94)
		)
		style.border_color = UITheme.ACCENT if slot_index == _selected else (rarity if filled else UITheme.BORDER_DIM)
		style.set_border_width_all(2 if slot_index == _selected else 1)
		style.shadow_color = Color(UITheme.ACCENT, 0.32) if slot_index == _selected else Color(0, 0, 0, 0)
		style.shadow_size = 8 if slot_index == _selected else 0
		_selection_tween.tween_property(
			_slot_panels[slot_index],
			"scale",
			Vector2.ONE * (1.075 if slot_index == _selected else 1.0),
			0.12
		).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_update_selected_label()


## Eight cells with an item icon, a key number, a stack badge and a rarity bar.
## The NameLabel is kept (and kept current) for accessibility and the UI contract,
## but the icon is what carries the slot at 48 px.
func _build_hotbar() -> void:
	for index in Game.HOTBAR_SLOTS:
		var slot := PanelContainer.new()
		slot.name = "Slot%d" % index
		slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.pivot_offset = Vector2(SLOT_SIZE, SLOT_SIZE) * 0.5
		var style := UITheme.slot_style()
		slot.add_theme_stylebox_override("panel", style)

		# PanelContainer lays out every direct child to fill the cell. All the
		# layered slot art therefore lives in one free-positioned overlay.
		var overlay := Control.new()
		overlay.name = "Overlay"
		overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(overlay)

		var icon := TextureRect.new()
		icon.name = "Icon"
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 7.0
		icon.offset_top = 5.0
		icon.offset_right = -7.0
		icon.offset_bottom = -11.0
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.add_child(icon)

		var key := Label.new()
		key.name = "KeyLabel"
		key.text = str(index + 1)
		key.position = Vector2(4.0, 1.0)
		key.size = Vector2(14.0, 12.0)
		key.mouse_filter = Control.MOUSE_FILTER_IGNORE
		key.add_theme_font_override("font", UITheme.regular_font())
		key.add_theme_font_size_override("font_size", 9)
		key.add_theme_color_override("font_color", UITheme.FAINT)
		key.add_theme_color_override("font_outline_color", UITheme.SHADOW)
		key.add_theme_constant_override("outline_size", 2)
		overlay.add_child(key)

		var count := Label.new()
		count.name = "CountLabel"
		count.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		count.offset_left = 12.0
		count.offset_top = 25.0
		count.offset_right = -4.0
		count.offset_bottom = -2.0
		count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		count.mouse_filter = Control.MOUSE_FILTER_IGNORE
		count.add_theme_font_override("font", UITheme.bold_font())
		count.add_theme_font_size_override("font_size", 11)
		count.add_theme_color_override("font_color", UITheme.TEXT)
		count.add_theme_color_override("font_outline_color", UITheme.SHADOW)
		count.add_theme_constant_override("outline_size", 3)
		overlay.add_child(count)

		var name_label := Label.new()
		name_label.name = "NameLabel"
		name_label.visible = false
		name_label.position = Vector2(2.0, 2.0)
		name_label.size = Vector2(SLOT_SIZE - 4.0, 44.0)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.add_theme_font_size_override("font_size", 8)
		overlay.add_child(name_label)

		var rarity := ColorRect.new()
		rarity.name = "RarityBar"
		rarity.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		rarity.offset_left = 5.0
		rarity.offset_top = -3.0
		rarity.offset_right = -5.0
		rarity.offset_bottom = -1.0
		rarity.color = Color(0, 0, 0, 0)
		rarity.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.add_child(rarity)
		overlay.move_child(rarity, 0)

		_hotbar.add_child(slot)
		_slot_panels.append(slot)
		_slot_styles.append(style)
		_slot_icons.append(icon)
		_slot_names.append(name_label)
		_slot_counts.append(count)
		_slot_keys.append(key)
		_slot_rarity.append(rarity)
	_set_selected(0)


func _style_static_nodes() -> void:
	_vitals_backdrop.add_theme_stylebox_override(
		"panel", UITheme.panel_style(UITheme.PANEL, UITheme.BORDER_DIM, 14, 1, 12)
	)
	_progression_backdrop.add_theme_stylebox_override(
		"panel", UITheme.panel_style(UITheme.PANEL, UITheme.BORDER_DIM, 14, 1, 12)
	)
	_hotbar_backdrop.add_theme_stylebox_override(
		"panel", UITheme.panel_style(Color(0.04, 0.055, 0.038, 0.92), UITheme.BORDER_DIM, 14, 1, 12)
	)
	_prompt_backdrop.add_theme_stylebox_override(
		"panel", UITheme.pill_style(UITheme.PANEL_DEEP, UITheme.BORDER_DIM, 14)
	)
	_gather_backdrop.add_theme_stylebox_override(
		"panel", UITheme.pill_style(UITheme.PANEL, UITheme.BORDER_DIM, 14)
	)
	_plot_backdrop.add_theme_stylebox_override(
		"panel", UITheme.pill_style(UITheme.PANEL, UITheme.BORDER_DIM, 10)
	)

	UITheme.style_bar(_hp_bar, UITheme.HP, 8)
	UITheme.style_bar(_stamina_bar, UITheme.STAMINA, 5)
	UITheme.style_bar(_xp_bar, UITheme.XP, 3)
	UITheme.style_bar(_gather_bar, UITheme.STAMINA, 6)

	var vitals_title := $Root/Vitals/VitalsTitle as Label
	UITheme.style_label(vitals_title, 10, UITheme.ACCENT_SOFT, 2)
	vitals_title.text = "VITALITY"
	UITheme.style_heading(_hp_label, 16, UITheme.TEXT)
	UITheme.style_label(_stamina_value, 9, UITheme.DIM, 0)
	UITheme.style_heading(_level_label, 20, UITheme.TEXT)
	UITheme.style_label(_biome_label, 9, UITheme.ACCENT_SOFT, 0)
	UITheme.style_label(_xp_value, 10, UITheme.DIM, 0)
	UITheme.style_heading(_gold_label, 15, UITheme.GOLD)
	UITheme.style_label(_prompt_label, 16, UITheme.TEXT, 4)
	UITheme.style_label(_gather_label, 12, UITheme.ACCENT_SOFT, 3)
	UITheme.style_label(_plot_status, 13, UITheme.ACCENT_SOFT, 2)
	UITheme.style_label(_selected_item, 14, UITheme.TEXT, 4)
	_prompt_label.visible = false
	_prompt_backdrop.visible = false
	_gather_box.visible = false
	_gather_bar.visible = false
	_gather_backdrop.visible = false
	_plot_status.visible = false
	_plot_backdrop.visible = false
	_style_vocation_button()
	if _crosshair != null and _crosshair.has_method(&"set_spread"):
		_crosshair.call(&"set_spread", 0.0)


func _style_vocation_button() -> void:
	var empty := StyleBoxEmpty.new()
	for state: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		_vocation_button.add_theme_stylebox_override(state, empty)
	_vocation_button.add_theme_font_override("font", UITheme.regular_font())
	_vocation_button.add_theme_color_override("font_color", UITheme.DIM)
	_vocation_button.add_theme_color_override("font_hover_color", UITheme.AMBER)
	_vocation_button.add_theme_color_override("font_pressed_color", UITheme.AMBER)
	_vocation_button.add_theme_color_override("font_outline_color", UITheme.SHADOW)
	_vocation_button.add_theme_constant_override("outline_size", 3)
	_vocation_button.add_theme_font_size_override("font_size", 11)
	_vocation_button.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_vocation_button.focus_mode = Control.FOCUS_NONE
	_vocation_button.visible = false


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

	# A dedicated layer keeps floating numbers above the HUD but below the death
	# screen, so a stale number cannot float over "YOU DIED".
	_damage_layer = Control.new()
	_damage_layer.name = "DamageNumbers"
	_damage_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_damage_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_damage_layer)

	_death_overlay = ColorRect.new()
	_death_overlay.name = "DeathOverlay"
	_death_overlay.color = Color(0.11, 0.012, 0.022, 0.78)
	_death_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_death_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_overlay.visible = false
	root.add_child(_death_overlay)

	var death_box := VBoxContainer.new()
	death_box.name = "DeathContent"
	death_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	death_box.alignment = BoxContainer.ALIGNMENT_CENTER
	death_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	death_box.add_theme_constant_override("separation", 8)
	_death_overlay.add_child(death_box)

	var label := Label.new()
	label.name = "DeathLabel"
	label.text = "YOU DIED"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UITheme.style_heading(label, 58, Color(0.96, 0.48, 0.38))
	label.add_theme_constant_override("outline_size", 10)
	death_box.add_child(label)

	var sub := Label.new()
	sub.name = "DeathSub"
	sub.text = "The Mycelium pulls you back to the bloom…"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UITheme.style_label(sub, 16, UITheme.DIM, 4)
	death_box.add_child(sub)

	_death_timer = Timer.new()
	_death_timer.name = "DeathTimer"
	_death_timer.one_shot = true
	_death_timer.wait_time = DEATH_OVERLAY_SECONDS
	_death_timer.timeout.connect(_on_death_screen_timeout)
	add_child(_death_timer)

	_toast_panel = PanelContainer.new()
	_toast_panel.name = "ToastPanel"
	_toast_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_toast_panel.offset_left = -330.0
	_toast_panel.offset_top = 92.0
	_toast_panel.offset_right = 330.0
	_toast_panel.offset_bottom = 134.0
	_toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_panel.visible = false
	_toast_panel.add_theme_stylebox_override(
		"panel", UITheme.pill_style(UITheme.PANEL, UITheme.BORDER, 14)
	)
	root.add_child(_toast_panel)

	_toast_label = Label.new()
	_toast_label.name = "Toast"
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UITheme.style_label(_toast_label, 15, UITheme.AMBER, 4)
	_toast_panel.add_child(_toast_label)

	_toast_timer = Timer.new()
	_toast_timer.name = "ToastTimer"
	_toast_timer.one_shot = true
	_toast_timer.wait_time = TOAST_SECONDS
	_toast_timer.timeout.connect(_on_toast_timeout)
	add_child(_toast_timer)


## Edge-only vignette: strongest at the border and fully transparent across the
## middle 70 % of the screen, so a hit never tints the whole frame red.
func _vignette_texture() -> ImageTexture:
	var tint: Color = UITheme.HP
	var image := Image.create_empty(VIGNETTE_SIZE.x, VIGNETTE_SIZE.y, false, Image.FORMAT_RGBA8)
	for y in VIGNETTE_SIZE.y:
		var ny := (float(y) + 0.5) / float(VIGNETTE_SIZE.y) * 2.0 - 1.0
		for x in VIGNETTE_SIZE.x:
			var nx := (float(x) + 0.5) / float(VIGNETTE_SIZE.x) * 2.0 - 1.0
			var edge := maxf(absf(nx), absf(ny))
			image.set_pixel(x, y, Color(tint, smoothstep(VIGNETTE_INNER, 1.0, edge)))
	return ImageTexture.create_from_image(image)


func _flash_damage() -> void:
	if _damage_flash == null:
		return
	_damage_flash_left = DAMAGE_FLASH_SECONDS


func _apply_initial_state() -> void:
	_gold_label.text = "Gold %d" % Game.gold
	var biome := Lore.get_biome(String(Game.current_biome))
	if _biome_label != null:
		_biome_label.text = str(biome.get("name", "Verdant Bloom")).to_upper()
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
	var ratio := current / maxf(max_hp, 1.0)
	UITheme.style_bar(_hp_bar, UITheme.HP_BRIGHT if ratio < 0.30 else UITheme.HP, 8)
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
	_stamina_value.text = "STAMINA  %d / %d" % [roundi(current), roundi(max_stamina)]


func _on_xp_changed(current: int, needed: int) -> void:
	_xp_bar.max_value = maxi(needed, 1)
	_xp_bar.value = clampi(current, 0, int(_xp_bar.max_value))
	_xp_value.text = "XP  %d / %d" % [current, needed]


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
	_gather_backdrop.visible = value


func _on_interaction_prompt_changed(text: String) -> void:
	_prompt_label.text = text
	var visible := not text.strip_edges().is_empty()
	_prompt_label.visible = visible
	_prompt_backdrop.visible = visible


## A landed hit tints the crosshair with a hit-marker flare and floats the
## damage number over the creature. The swing already caused the HP change, so
## no second full-screen flash is used.
func _on_enemy_hit(enemy: Node, amount: float, is_crit: bool) -> void:
	if _crosshair != null and _crosshair.has_method(&"set_hit"):
		_crosshair.call(&"set_hit", UITheme.CRIT if is_crit else UITheme.ACCENT)
	_spawn_damage_number(enemy, amount, is_crit)


func _spawn_damage_number(enemy: Node, amount: float, is_crit: bool) -> void:
	if amount <= 0.0 or enemy == null or not is_instance_valid(enemy):
		return
	var target := enemy as Node3D
	if target == null:
		return
	var camera := get_viewport().get_camera_3d()
	var screen := get_viewport().get_visible_rect().size * 0.5
	if camera != null:
		screen = camera.unproject_position(target.global_position + Vector3(0.0, 1.25, 0.0))
	var label := Label.new()
	label.name = "DamageNumber"
	label.text = ("CRIT  %d" if is_crit else "%d") % roundi(amount)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size = Vector2(160.0, 40.0)
	label.position = screen - Vector2(80.0, 26.0) + Vector2(randf_range(-24.0, 24.0), 0.0)
	label.pivot_offset = label.size * 0.5
	UITheme.style_heading(
		label, 24 if is_crit else 18, UITheme.CRIT if is_crit else UITheme.AMBER
	)
	label.add_theme_constant_override("outline_size", 6)
	if _damage_layer != null:
		_damage_layer.add_child(label)
	else:
		$Root.add_child(label)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - 48.0, 0.72)
	tween.tween_property(label, "modulate:a", 0.0, 0.72).set_delay(0.10)
	tween.tween_property(label, "scale", Vector2.ONE * 1.18, 0.18)
	tween.chain().tween_callback(label.queue_free)


func _on_player_died() -> void:
	_bind_player()
	if _damage_layer != null:
		for child in _damage_layer.get_children():
			child.queue_free()
	if _death_overlay != null:
		_death_overlay.visible = true
		_death_overlay.modulate.a = 0.0
		create_tween().tween_property(_death_overlay, "modulate:a", 1.0, 0.25)
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
	if _toast_label == null or _toast_panel == null:
		return
	_toast_label.text = text
	_toast_panel.visible = true
	if _toast_timer != null:
		_toast_timer.start(TOAST_SECONDS)


func _on_toast_timeout() -> void:
	if _toast_panel != null:
		_toast_panel.visible = false


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
		_set_plot_status("Plot %d  ·  %d g to buy" % [
			plot_id + 1, int(system.call(&"plot_price"))
		])
		return
	if bool(system.call(&"is_owned_by", plot_id, system.call(&"local_owner_id"))):
		var unpaid := int(plot.get("unpaid_days", 0))
		if unpaid > 0:
			_set_plot_status("Plot %d  ·  yours  ·  unpaid %d/%d d" % [
				plot_id + 1, unpaid, Game.PLOT_EXPIRY_DAYS
			])
			return
		var seconds := int(system.call(&"next_fee_seconds", plot_id))
		if seconds <= 0:
			_set_plot_status("Plot %d  ·  yours  ·  fee due" % (plot_id + 1))
			return
		_set_plot_status("Plot %d  ·  yours  ·  next fee in %d h" % [
			plot_id + 1, int(ceil(float(seconds) / SECONDS_PER_HOUR))
		])
		return
	_set_plot_status("Plot %d  ·  owned by %s" % [plot_id + 1, String(owner)])


func _set_plot_status(text: String) -> void:
	_plot_status.text = text
	var visible := not text.is_empty()
	_plot_status.visible = visible
	_plot_backdrop.visible = visible


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
		var filled := id != &"" and count > 0
		var display := ItemVisuals.display_name(String(id)) if filled else ""
		var colour := ItemVisuals.color(String(id)) if filled else UITheme.TEXT
		_slot_icons[index].texture = ItemVisuals.icon(id) if filled else null
		_slot_icons[index].visible = filled
		_slot_names[index].text = display
		_slot_counts[index].text = str(count) if filled else ""
		_slot_rarity[index].color = colour if filled else Color(0, 0, 0, 0)
		_slot_panels[index].tooltip_text = (
			"%s\n%s" % [display, ItemVisuals.kind(String(id))] if filled else ""
		)
	_set_selected(_selected)


func _slot_item_id(index: int) -> StringName:
	if _inventory == null or not _inventory.has_method(&"get_slot"):
		return &""
	var slot: Dictionary = _inventory.call(&"get_slot", index)
	return StringName(slot.get("id", &"")) if int(slot.get("count", 0)) > 0 else &""


func _update_selected_label() -> void:
	if _selected_item == null:
		return
	var id := _slot_item_id(_selected)
	if id == &"":
		_selected_item.text = "Empty hotbar slot"
		_selected_item.add_theme_color_override("font_color", UITheme.FAINT)
		return
	var count := 0
	if _inventory != null and _inventory.has_method(&"get_slot"):
		var slot: Dictionary = _inventory.call(&"get_slot", _selected)
		count = int(slot.get("count", 0))
	_selected_item.text = "%s   ×%d" % [ItemVisuals.display_name(String(id)), count]
	_selected_item.add_theme_color_override("font_color", ItemVisuals.color(String(id)))
