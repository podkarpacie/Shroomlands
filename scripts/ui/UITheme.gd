class_name UITheme
extends RefCounted
## Shared palette and widget factories for every piece of Shroomlands UI.
##
## The game ships one runtime theme, installed once on the root Window, plus a
## handful of factories for the views that build their cells in code. Keeping the
## colours and corner radii here means the HUD, satchel, chat, build palette and
## lobby read as one product instead of five unrelated panels.

const BG := Color(0.035, 0.048, 0.036, 0.94)
const PANEL := Color(0.055, 0.072, 0.052, 0.96)
const PANEL_ALT := Color(0.085, 0.105, 0.072, 0.96)
const PANEL_DEEP := Color(0.025, 0.034, 0.026, 0.97)
const BORDER := Color(0.40, 0.55, 0.31, 0.88)
const BORDER_DIM := Color(0.24, 0.33, 0.20, 0.82)
const ACCENT := Color(0.76, 0.93, 0.42)
const ACCENT_SOFT := Color(0.58, 0.78, 0.38)
const AMBER := Color(0.98, 0.78, 0.32)
const TEXT := Color(0.93, 0.95, 0.89)
const DIM := Color(0.64, 0.70, 0.58)
const FAINT := Color(0.44, 0.51, 0.41)
const SHADOW := Color(0.0, 0.0, 0.0, 0.78)
const HP := Color(0.86, 0.22, 0.20)
const HP_BRIGHT := Color(1.00, 0.42, 0.32)
const STAMINA := Color(0.72, 0.86, 0.24)
const XP := Color(0.38, 0.72, 1.00)
const GOLD := Color(0.98, 0.79, 0.32)
const CRIT := Color(1.00, 0.55, 0.16)
const RARE := Color(0.35, 0.60, 1.00)
const VERY_RARE := Color(0.72, 0.38, 1.00)
const DANGEROUS := Color(0.92, 0.18, 0.18)
const DIM_OVERLAY := Color(0.015, 0.024, 0.018, 0.82)

const FONT_PATH := "res://assets/fonts/Inter-Variable.ttf"

static var _theme_installed := false
static var _font_regular: Font = null
static var _font_bold: Font = null


## Installs the shared theme on the root Window. Idempotent, so every UI root can
## call it during `_ready` and whichever loads first wins.
static func install(root: Node) -> void:
	if root == null or not (root is Window) or _theme_installed:
		return
	if root.has_meta(&"shroomlands_ui_theme"):
		_theme_installed = true
		return
	var theme := Theme.new()
	theme.default_font = regular_font()
	theme.default_font_size = 14

	theme.set_color("font_color", "Label", TEXT)
	theme.set_color("font_shadow_color", "Label", SHADOW)
	theme.set_constant("shadow_offset_x", "Label", 1)
	theme.set_constant("shadow_offset_y", "Label", 1)
	theme.set_color("font_color", "RichTextLabel", TEXT)
	theme.set_color("default_color", "RichTextLabel", TEXT)
	theme.set_font("normal_font", "RichTextLabel", regular_font())
	theme.set_font_size("normal_font_size", "RichTextLabel", 13)
	theme.set_constant("line_separation", "RichTextLabel", 3)

	theme.set_color("font_color", "Button", TEXT)
	theme.set_color("font_hover_color", "Button", Color.WHITE)
	theme.set_color("font_pressed_color", "Button", ACCENT)
	theme.set_color("font_disabled_color", "Button", FAINT)
	theme.set_font("font", "Button", bold_font())
	theme.set_font_size("font_size", "Button", 14)
	theme.set_constant("outline_size", "Button", 0)
	for state: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		theme.set_stylebox(state, "Button", button_style(state))

	theme.set_color("font_color", "LineEdit", TEXT)
	theme.set_color("font_placeholder_color", "LineEdit", FAINT)
	theme.set_color("caret_color", "LineEdit", ACCENT)
	theme.set_color("selection_color", "LineEdit", Color(0.35, 0.52, 0.28, 0.65))
	theme.set_font("font", "LineEdit", regular_font())
	theme.set_font_size("font_size", "LineEdit", 14)
	theme.set_stylebox("normal", "LineEdit", line_style(PANEL_DEEP, BORDER_DIM))
	theme.set_stylebox("focus", "LineEdit", line_style(PANEL_ALT, ACCENT))
	theme.set_constant("minimum_character_width", "LineEdit", 4)

	theme.set_stylebox("panel", "PanelContainer", panel_style())
	theme.set_stylebox("panel", "Panel", panel_style())
	theme.set_stylebox("panel", "PopupPanel", panel_style(PANEL, BORDER, 10, 1, 14))
	theme.set_stylebox("panel", "TooltipPanel", panel_style(PANEL_DEEP, BORDER, 8, 1, 10))
	theme.set_color("font_color", "TooltipLabel", TEXT)
	theme.set_font("font", "TooltipLabel", regular_font())
	theme.set_font_size("font_size", "TooltipLabel", 12)

	theme.set_stylebox("background", "ProgressBar", bar_track(6))
	theme.set_stylebox("fill", "ProgressBar", bar_fill(ACCENT, 6))
	theme.set_font("font", "ProgressBar", bold_font())
	theme.set_font_size("font_size", "ProgressBar", 11)
	theme.set_color("font_color", "ProgressBar", TEXT)

	theme.set_stylebox("scroll", "VScrollBar", scroll_style())
	theme.set_stylebox("grabber", "VScrollBar", scroll_grab_style(false))
	theme.set_stylebox("grabber_highlight", "VScrollBar", scroll_grab_style(true))
	theme.set_stylebox("grabber_pressed", "VScrollBar", scroll_grab_style(true))

	theme.set_type_variation(&"TitleLabel", &"Label")
	theme.set_font("font", &"TitleLabel", bold_font())
	theme.set_font_size("font_size", &"TitleLabel", 26)
	theme.set_color("font_color", &"TitleLabel", TEXT)
	theme.set_color("font_outline_color", &"TitleLabel", SHADOW)
	theme.set_constant("outline_size", &"TitleLabel", 6)

	theme.set_type_variation(&"SectionLabel", &"Label")
	theme.set_font("font", &"SectionLabel", bold_font())
	theme.set_font_size("font_size", &"SectionLabel", 11)
	theme.set_color("font_color", &"SectionLabel", ACCENT_SOFT)

	theme.set_type_variation(&"MutedLabel", &"Label")
	theme.set_font("font", &"MutedLabel", regular_font())
	theme.set_font_size("font_size", &"MutedLabel", 12)
	theme.set_color("font_color", &"MutedLabel", DIM)

	root.theme = theme
	root.set_meta(&"shroomlands_ui_theme", true)
	_theme_installed = true


static func regular_font() -> Font:
	if _font_regular == null:
		_font_regular = load(FONT_PATH) as Font
		if _font_regular == null:
			_font_regular = ThemeDB.fallback_font
	return _font_regular


static func bold_font() -> Font:
	if _font_bold == null:
		var base := regular_font()
		if base != null and base.resource_path.ends_with(".ttf"):
			var variation := FontVariation.new()
			variation.base_font = base
			variation.variation_opentype = {"wght": 700.0}
			_font_bold = variation
		else:
			_font_bold = base
	return _font_bold


static func panel_style(
	bg: Color = PANEL,
	border: Color = BORDER,
	radius: int = 12,
	border_width: int = 1,
	shadow_size: int = 10
) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 12.0
	style.content_margin_bottom = 12.0
	if shadow_size > 0:
		style.shadow_color = Color(0.0, 0.0, 0.0, 0.42)
		style.shadow_size = shadow_size
		style.shadow_offset = Vector2(0.0, 3.0)
	style.anti_aliasing = true
	return style


static func line_style(bg: Color = PANEL_DEEP, border: Color = BORDER_DIM) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 9.0
	style.content_margin_bottom = 9.0
	style.anti_aliasing = true
	return style


static func slot_style(
	selected := false,
	hovered := false,
	rarity: Color = BORDER_DIM
) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = (
		Color(0.15, 0.20, 0.11, 0.98) if selected
		else (Color(0.10, 0.13, 0.08, 0.96) if hovered else Color(0.065, 0.085, 0.060, 0.94))
	)
	style.border_color = ACCENT if selected else (rarity if hovered else BORDER_DIM)
	style.set_border_width_all(2 if selected else 1)
	style.set_corner_radius_all(8)
	# Slots are PanelContainers; their children live in a free-positioned
	# overlay. Zero content margins let that overlay cover the whole cell.
	style.content_margin_left = 0.0
	style.content_margin_right = 0.0
	style.content_margin_top = 0.0
	style.content_margin_bottom = 0.0
	if selected:
		style.shadow_color = Color(ACCENT, 0.35)
		style.shadow_size = 9
	style.anti_aliasing = true
	return style


static func bar_track(radius: int = 6) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.045, 0.03, 0.92)
	style.border_color = Color(0.16, 0.22, 0.14, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	return style


static func bar_fill(color: Color, radius: int = 6) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	return style


static func button_style(state := "normal", accent := false) -> StyleBoxFlat:
	var base := Color(0.22, 0.37, 0.18, 0.96) if accent else Color(0.085, 0.115, 0.075, 0.97)
	var border := Color(0.60, 0.82, 0.40, 0.95) if accent else Color(0.30, 0.42, 0.25, 0.9)
	if state == "hover":
		base = base.lightened(0.13)
		border = border.lightened(0.12)
	elif state == "pressed":
		base = base.darkened(0.18)
	elif state == "disabled":
		base = base.darkened(0.42)
		border = border.darkened(0.45)
	var style := StyleBoxFlat.new()
	style.bg_color = base
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	if state == "focus":
		style.border_color = ACCENT
	style.anti_aliasing = true
	return style


static func scroll_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.03, 0.02, 0.55)
	style.set_corner_radius_all(4)
	style.content_margin_left = 2.0
	style.content_margin_right = 2.0
	return style


static func scroll_grab_style(hovered: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.42, 0.58, 0.34, 0.95) if hovered else Color(0.28, 0.39, 0.23, 0.95)
	style.set_corner_radius_all(4)
	return style


## Styles a button with the shared look. `accent` is used for primary actions.
static func style_button(button: Button, accent := false) -> void:
	for state: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		button.add_theme_stylebox_override(state, button_style(state, accent))
	button.add_theme_font_override("font", bold_font())
	button.add_theme_font_size_override("font_size", 14)
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_pressed_color", ACCENT)
	button.add_theme_color_override("font_disabled_color", FAINT)
	button.focus_mode = Control.FOCUS_NONE


static func style_label(label: Label, size := 14, color := TEXT, outline := 4) -> void:
	label.add_theme_font_override("font", regular_font())
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if outline > 0:
		label.add_theme_color_override("font_outline_color", SHADOW)
		label.add_theme_constant_override("outline_size", outline)


static func style_heading(label: Label, size := 22, color := TEXT) -> void:
	label.add_theme_font_override("font", bold_font())
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", SHADOW)
	label.add_theme_constant_override("outline_size", 5)


static func style_bar(bar: ProgressBar, fill: Color, radius := 6) -> void:
	bar.add_theme_stylebox_override("background", bar_track(radius))
	bar.add_theme_stylebox_override("fill", bar_fill(fill, radius))
	bar.show_percentage = false


## A small rounded pill used for prompts, statuses and the selected-item name.
static func pill_style(bg: Color = PANEL_DEEP, border: Color = BORDER_DIM, radius := 12) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 5.0
	style.content_margin_bottom = 6.0
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.35)
	style.shadow_size = 6
	style.anti_aliasing = true
	return style
