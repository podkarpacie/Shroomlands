extends CanvasLayer
## Screen-space grade over the 3D view: biome tint, vignette, grain and a
## danger pulse. Sits on layer 5, below the HUD (10) and every panel (20+).
##
## Danger is read from the local `Atmosphere` node (HP + nearby creatures), so
## the vignette and the heartbeat react to the same number.

const TINTS: Array[Color] = [
	Color(0.62, 0.86, 0.68), Color(0.70, 0.58, 0.90), Color(0.90, 0.52, 0.48),
	Color(0.42, 0.58, 0.80), Color(0.88, 0.86, 0.70),
]

var _danger := 0.0
var _last_key := ""
var _material: ShaderMaterial = null

@onready var _screen: ColorRect = $Screen


func _ready() -> void:
	_material = _screen.material as ShaderMaterial
	_apply_tint()
	set_process(true)


func _process(delta: float) -> void:
	if _material == null:
		return
	var atmosphere := get_tree().get_first_node_in_group(&"atmosphere")
	var target := 0.0
	if atmosphere != null and atmosphere.has_method(&"danger_level"):
		target = float(atmosphere.call(&"danger_level"))
	_danger = lerpf(_danger, clampf(target, 0.0, 1.0), 1.0 - exp(-2.2 * delta))
	var pulse := _danger * (0.45 + 0.25 * sin(Time.get_ticks_msec() * 0.006))
	_material.set_shader_parameter("pulse", pulse)
	_material.set_shader_parameter("vignette_strength", 0.50 + _danger * 0.55)
	_material.set_shader_parameter("grain_strength", 0.030 + _danger * 0.05)
	_apply_tint()


func current_tint() -> Color:
	if _material == null:
		return Color.WHITE
	var value: Variant = _material.get_shader_parameter("tint")
	return value if value is Color else Color.WHITE


func danger_level() -> float:
	return _danger


## Only writes the shader when the area actually changes; this is called from
## `_process` and both parameters are uniform uploads.
func _apply_tint() -> void:
	if _material == null:
		return
	var key := "%d:%s" % [Game.forest_layer, Game.current_biome]
	if key == _last_key:
		return
	_last_key = key
	var color := Color(0.62, 0.86, 0.68)
	var strength := 0.09
	if Game.forest_layer > 0:
		color = TINTS[clampi(Game.forest_layer - 1, 0, TINTS.size() - 1)]
		strength = 0.10 + 0.014 * Game.forest_layer
	elif Game.current_biome == &"town":
		color = Color(0.80, 0.78, 0.66)
		strength = 0.055
	_material.set_shader_parameter("tint", color)
	_material.set_shader_parameter("tint_strength", strength)
