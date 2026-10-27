extends Control
## Minimal four-tick crosshair with a centre dot and a hit-confirmation flare.
## Drawing it (instead of four ColorRects) keeps the geometry crisp at any DPI
## and lets the hit marker animate without adding scene nodes.

const BASE_COLOR := Color(0.94, 0.96, 0.90, 0.82)
const HIT_SECONDS := 0.20

var _hit_left := 0.0
var _hit_color := Color(1.0, 0.86, 0.36)
var _spread := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(44.0, 44.0)
	pivot_offset = custom_minimum_size * 0.5
	queue_redraw()


func set_hit(color: Color) -> void:
	_hit_color = color
	_hit_left = HIT_SECONDS
	queue_redraw()


func set_spread(amount: float) -> void:
	_spread = clampf(amount, 0.0, 8.0)
	queue_redraw()


func _process(delta: float) -> void:
	if _hit_left <= 0.0:
		return
	_hit_left = maxf(_hit_left - delta, 0.0)
	queue_redraw()


func _draw() -> void:
	var centre := size * 0.5
	var gap := 5.0 + _spread
	var length := 7.0
	var colour := BASE_COLOR
	var shadow := Color(0.0, 0.0, 0.0, 0.55)
	var offsets: Array[Vector2] = [
		Vector2(gap, 0), Vector2(-gap, 0), Vector2(0, gap), Vector2(0, -gap)
	]
	# Shadow pass first: the crosshair stays readable against bright mushroom caps.
	for offset: Vector2 in offsets:
		var direction := offset.normalized()
		draw_line(
			centre + offset + direction,
			centre + offset + direction * length,
			shadow,
			3.0,
			true
		)
	draw_circle(centre, 1.7, colour)
	for offset: Vector2 in offsets:
		var direction := offset.normalized()
		draw_line(centre + offset, centre + offset + direction * length, colour, 1.5, true)

	if _hit_left <= 0.0:
		return
	var alpha := _hit_left / HIT_SECONDS
	var flare := _hit_color
	flare.a = alpha
	var inner := 7.0 + (1.0 - alpha) * 5.0
	var outer := inner + 6.0
	var corners: Array[Vector2] = [
		Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)
	]
	for corner: Vector2 in corners:
		var a := centre + corner * inner
		var b := centre + corner * outer
		draw_line(a, b, flare, 2.2, true)
