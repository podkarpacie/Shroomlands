class_name ItemVisuals
extends RefCounted
## Item presentation data and meshes.
##
## `Lore` owns what an item *is*; this class owns what it looks like. The same
## procedural model builder feeds both the inventory's rotating 3D preview and
## the offline icon renderer in `tools/render_item_icons.gd`, so an icon can never
## drift away from the model it represents.

const ICON_DIR := "res://assets/ui/items/"
const BUILD_ICON_DIR := "res://assets/ui/build/"
const ICON_SIZE := 128
const PREVIEW_TARGET_SIZE := 1.15

const MUSHROOM_IDS: Array[String] = [
	"konop", "glowcap", "emberstem", "venomveil", "sunheart", "blightroot", "geodecap"
]
## Crafted goods (`Lore.ITEMS`): drawn as a bottle tinted by the liquid inside.
const CRAFTED_IDS: Array[String] = [
	"weak_health_potion", "greater_health_potion", "regen_elixir", "stamina_tonic"
]
const RESOURCE_IDS: Array[String] = [
	"mycelium_fiber", "hardened_mycelium", "spore_crystals",
	"fossilized_caps", "infested_ore", "ancient_core"
]
const BUILD_IDS: Array[String] = ["hut", "farm", "workshop", "chest"]

## Rarity / identity colours. Matching `Lore.rarity_color` where a species has a
## rarity, but kept here for resources and build pieces too.
const COLORS := {
	"konop": Color(0.62, 0.72, 0.38),
	"weak_health_potion": Color(0.88, 0.28, 0.32),
	"greater_health_potion": Color(0.96, 0.20, 0.36),
	"regen_elixir": Color(0.45, 0.86, 0.40),
	"stamina_tonic": Color(0.96, 0.80, 0.26),
	"glowcap": Color(0.34, 0.90, 0.86),
	"emberstem": Color(0.96, 0.46, 0.18),
	"venomveil": Color(0.60, 0.30, 0.90),
	"sunheart": Color(1.00, 0.78, 0.24),
	"blightroot": Color(0.62, 0.06, 0.10),
	"geodecap": Color(0.34, 0.64, 0.82),
	"mycelium_fiber": Color(0.82, 0.84, 0.72),
	"hardened_mycelium": Color(0.48, 0.34, 0.20),
	"spore_crystals": Color(0.32, 0.86, 0.72),
	"fossilized_caps": Color(0.72, 0.62, 0.40),
	"infested_ore": Color(0.42, 0.55, 0.24),
	"ancient_core": Color(0.34, 0.82, 1.00),
	"gold": Color(0.98, 0.79, 0.32),
	"hut": Color(0.74, 0.52, 0.28),
	"farm": Color(0.62, 0.78, 0.32),
	"workshop": Color(0.58, 0.62, 0.66),
	"chest": Color(0.72, 0.50, 0.26),
}

const BUILD_NAMES := {
	"hut": "Spore Hut",
	"farm": "Mushroom Farm",
	"workshop": "Workshop",
	"chest": "Storage Chest",
}

static var _icon_cache: Dictionary = {}
static var _scene_cache: Dictionary = {}


static func all_ids() -> Array[String]:
	var ids: Array[String] = []
	ids.append_array(MUSHROOM_IDS)
	ids.append_array(CRAFTED_IDS)
	ids.append_array(RESOURCE_IDS)
	ids.append_array(BUILD_IDS)
	return ids


## Autoloads are looked up at call time. The icon renderer is a `--script` tool
## whose dependency graph is compiled before the autoloads exist, so a direct
## `Lore.` reference here would make the whole tool fail to compile.
static func _lore() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("Lore")
	return null


static func _mushroom_data(id: String) -> Dictionary:
	var lore := _lore()
	if lore == null:
		return {}
	var result: Variant = lore.call(&"get_mushroom", id)
	return result if result is Dictionary else {}


static func _crafted_data(id: String) -> Dictionary:
	var lore := _lore()
	if lore == null:
		return {}
	var result: Variant = lore.call(&"get_item", id)
	return result if result is Dictionary else {}


static func _resources() -> Dictionary:
	var lore := _lore()
	if lore == null:
		return {}
	var script: Script = lore.get_script() as Script
	if script == null:
		return {}
	var constants: Dictionary = script.get_script_constant_map()
	var result: Variant = constants.get("RESOURCES", {})
	return result if result is Dictionary else {}


static func display_name(id: String) -> String:
	if id == "gold":
		return "Gold"
	if BUILD_NAMES.has(id):
		return str(BUILD_NAMES[id])
	var lore := _lore()
	return str(lore.call(&"item_display_name", id)) if lore != null else id


static func color(id: String) -> Color:
	var mushroom := _mushroom_data(id)
	if mushroom.is_empty():
		mushroom = _crafted_data(id)
	if not mushroom.is_empty():
		var lore := _lore()
		if lore != null:
			return lore.call(&"rarity_color", str(mushroom.get("rarity", "")))
	return COLORS.get(id, UITheme.TEXT)


static func kind(id: String) -> String:
	if id == "gold":
		return "Currency"
	if BUILD_NAMES.has(id):
		return "Structure"
	var lore := _lore()
	if lore != null and bool(lore.call(&"is_mushroom", id)):
		var rarity := str(_mushroom_data(id).get("rarity", "common")).replace("_", " ")
		return "Mushroom  ·  %s" % rarity.capitalize()
	if _resources().has(id):
		return "Resource"
	var crafted := _crafted_data(id)
	if not crafted.is_empty():
		var tier := str(crafted.get("rarity", "common")).replace("_", " ")
		return "%s  ·  %s" % [str(crafted.get("kind", "item")).capitalize(), tier.capitalize()]
	return "Curiosity"


static func description(id: String) -> String:
	if id == "gold":
		return "Minted mushroom-cap coin, the common currency of Mycelia."
	if BUILD_NAMES.has(id):
		match id:
			"hut":
				return "A snug spore-woven shelter. Roofs keep the rain of spores off your head."
			"farm":
				return "A cultivated patch of edible caps. Tenders the soil while you are away."
			"workshop":
				return "A workbench for shaping hardened mycelium into tools and fittings."
			"chest":
				return "A sealed cache for keeping surplus finds out of the damp."
		return ""
	var mushroom := _mushroom_data(id)
	if not mushroom.is_empty():
		return str(mushroom.get("description", ""))
	var resource: Dictionary = _resources().get(id, {})
	if not resource.is_empty():
		return str(resource.get("description", ""))
	var crafted := _crafted_data(id)
	if not crafted.is_empty():
		var text := str(crafted.get("description", ""))
		var lore := _lore()
		var effect := str(lore.call(&"item_effect_text", id)) if lore != null else ""
		return text if effect.is_empty() else "%s %s" % [text, effect]
	return "An unfamiliar piece of the Mycelium."


static func uses_text(id: String) -> String:
	var mushroom := _mushroom_data(id)
	if mushroom.is_empty():
		return ""
	var uses: Array = mushroom.get("uses", [])
	var pretty: Array[String] = []
	for use: String in uses:
		pretty.append(use.replace("_", " ").capitalize())
	return " · ".join(pretty)


static func toxicity(id: String) -> int:
	return int(_mushroom_data(id).get("toxicity", 0))


static func is_edible(id: String) -> bool:
	return _mushroom_data(id).get("uses", []).has("food")


## The icon texture for a slot. Rendered icons live in `assets/ui/items/`; a
## species without an image gets a deterministic painted fallback so a new lore
## entry still shows something recognisable instead of a blank cell.
static func icon(id: StringName) -> Texture2D:
	var key := String(id)
	if _icon_cache.has(key):
		return _icon_cache[key] as Texture2D
	if key.is_empty():
		var empty := _paint_fallback("")
		_icon_cache[key] = empty
		return empty
	var path := BUILD_ICON_DIR if BUILD_NAMES.has(key) else ICON_DIR
	var full_path := "%s%s.png" % [path, key]
	var texture: Texture2D = (
		load(full_path) as Texture2D if ResourceLoader.exists(full_path) else null
	)
	if texture == null:
		texture = _paint_fallback(key)
	_icon_cache[key] = texture
	return texture


## A Node3D holding the item's presentation mesh, normalised so its base sits at
## y = 0 and its largest dimension is PREVIEW_TARGET_SIZE. The caller owns it.
static func build_model(id: String, target_size := PREVIEW_TARGET_SIZE) -> Node3D:
	var model: Node3D = null
	var scene := _model_scene(id)
	if scene != null:
		model = scene.instantiate() as Node3D
	if model == null:
		model = _procedural_model(id)
	_normalise(model, target_size)
	return model


static func _model_scene(id: String) -> PackedScene:
	if _scene_cache.has(id):
		return _scene_cache[id] as PackedScene
	var path := "res://assets/models/%s.gltf" % id
	if not ResourceLoader.exists(path):
		_scene_cache[id] = null
		return null
	var scene := load(path) as PackedScene
	_scene_cache[id] = scene
	return scene


static func _procedural_model(id: String) -> Node3D:
	match id:
		"venomveil", "sunheart", "blightroot", "geodecap":
			return _mushroom(id)
		"weak_health_potion", "greater_health_potion", "regen_elixir", "stamina_tonic":
			return _potion(id)
		"konop":
			return _mushroom(id)
		"mycelium_fiber":
			return _fiber()
		"hardened_mycelium":
			return _hardened()
		"spore_crystals":
			return _crystals()
		"fossilized_caps":
			return _fossil_caps()
		"infested_ore":
			return _infested_ore()
		"ancient_core":
			return _ancient_core()
		"hut", "farm", "workshop", "chest":
			return _building(id)
		"gold":
			return _coin()
	return _mushroom(id)


## --- procedural models ------------------------------------------------------


static func _mushroom(id: String) -> Node3D:
	var root := Node3D.new()
	root.name = "Model_%s" % id
	var tint: Color = COLORS.get(id, Color(0.70, 0.52, 0.32))
	var stem_color := tint.lerp(Color(0.88, 0.84, 0.70), 0.62).darkened(0.10)
	var cap_color := tint
	var glow := 0.0
	match id:
		"venomveil":
			stem_color = Color(0.58, 0.55, 0.72)
			cap_color = Color(0.34, 0.12, 0.52)
			glow = 0.55
		"sunheart":
			stem_color = Color(0.96, 0.84, 0.46)
			cap_color = Color(1.00, 0.70, 0.16)
			glow = 1.6
		"blightroot":
			stem_color = Color(0.34, 0.28, 0.24)
			cap_color = Color(0.28, 0.02, 0.05)
			glow = 0.35
		"geodecap":
			stem_color = Color(0.38, 0.44, 0.42)
			cap_color = Color(0.26, 0.48, 0.62)
			glow = 0.8

	var stem := _cylinder(0.16, 0.11, 0.64, stem_color, 8)
	stem.position.y = 0.32
	root.add_child(stem)

	var gills := _cylinder(0.31, 0.26, 0.055, stem_color.lightened(0.18), 16)
	gills.position.y = 0.60
	root.add_child(gills)

	var cap := _sphere(0.36, 0.30, cap_color, 16, 7, glow)
	cap.position.y = 0.68
	cap.scale = Vector3(1.0, 0.72, 1.0)
	root.add_child(cap)

	# A cap rim gives the silhouette a readable edge at 40 px.
	var rim := _cylinder(0.30, 0.33, 0.045, cap_color.darkened(0.18), 16)
	rim.position.y = 0.615
	root.add_child(rim)

	var spot_color := cap_color.lightened(0.35)
	if id == "venomveil":
		spot_color = Color(0.82, 0.45, 1.0)
	elif id == "sunheart":
		spot_color = Color(1.0, 0.95, 0.62)
	elif id == "blightroot":
		spot_color = Color(0.96, 0.18, 0.16)
	elif id == "geodecap":
		spot_color = Color(0.38, 0.95, 1.0)
	for index in 5:
		var angle := TAU * float(index) / 5.0 + 0.4
		var spot := _sphere(0.045, 0.030, spot_color, 8, 4, 1.2 if glow > 0.0 else 0.0)
		spot.position = Vector3(cos(angle) * 0.22, 0.79 + sin(angle * 1.7) * 0.025, sin(angle) * 0.22)
		root.add_child(spot)

	if id == "geodecap":
		for index in 3:
			var shard := _crystal(Color(0.34, 0.90, 1.0), 0.34 + index * 0.06)
			var angle := TAU * float(index) / 3.0
			shard.position = Vector3(cos(angle) * 0.19, 0.20, sin(angle) * 0.19)
			shard.rotation.z = -0.35
			shard.rotation.y = angle
			root.add_child(shard)
	elif id == "blightroot":
		for index in 4:
			var tendril := _cylinder(0.020, 0.012, 0.42, cap_color.lightened(0.10), 6)
			var angle := TAU * float(index) / 4.0
			tendril.position = Vector3(cos(angle) * 0.20, 0.20, sin(angle) * 0.20)
			tendril.rotation.z = 0.50
			tendril.rotation.y = angle
			root.add_child(tendril)
	return root


## A corked bottle of `id`'s liquid colour: round belly, short neck, cork.
static func _potion(id: String) -> Node3D:
	var root := Node3D.new()
	root.name = "Model_%s" % id
	var liquid: Color = COLORS.get(id, Color(0.8, 0.5, 0.5))
	var glass := Color(0.78, 0.92, 0.90)
	var body := _sphere(0.30, 0.56, liquid, 16, 8, 0.7)
	body.position.y = 0.30
	root.add_child(body)
	# A small gloss patch sitting on the belly's surface, not poking out of it.
	var shine := _sphere(0.055, 0.11, Color(1, 1, 1), 10, 5)
	shine.position = Vector3(0.10, 0.428, 0.234)
	root.add_child(shine)
	var neck := _cylinder(0.075, 0.085, 0.22, glass.darkened(0.10), 10)
	neck.position.y = 0.66
	root.add_child(neck)
	var lip := _cylinder(0.105, 0.105, 0.04, glass, 12)
	lip.position.y = 0.78
	root.add_child(lip)
	var cork := _cylinder(0.075, 0.065, 0.11, Color(0.60, 0.42, 0.24), 8)
	cork.position.y = 0.85
	root.add_child(cork)
	return root


static func _fiber() -> Node3D:
	var root := Node3D.new()
	root.name = "Model_mycelium_fiber"
	var color := Color(0.84, 0.85, 0.73)
	for index in 6:
		var strand := _cylinder(0.028, 0.020, 0.95, color.darkened(0.05 * float(index % 3)), 6)
		strand.position = Vector3((float(index) - 2.5) * 0.075, 0.44, 0.0)
		strand.rotation.z = 0.16 - float(index) * 0.055
		strand.rotation.x = 0.10 * sin(float(index) * 1.7)
		root.add_child(strand)
	var tie := _torus(0.17, 0.20, Color(0.56, 0.42, 0.24))
	tie.position.y = 0.48
	tie.rotation.x = PI * 0.5
	root.add_child(tie)
	return root


static func _hardened() -> Node3D:
	var root := Node3D.new()
	root.name = "Model_hardened_mycelium"
	var block := _box(Vector3(0.78, 0.48, 0.72), Color(0.43, 0.29, 0.16))
	block.position.y = 0.30
	root.add_child(block)
	for index in 3:
		var band := _box(Vector3(0.82, 0.035, 0.76), Color(0.66, 0.47, 0.25))
		band.position.y = 0.14 + index * 0.15
		root.add_child(band)
	var stamp := _cylinder(0.16, 0.16, 0.02, Color(0.76, 0.64, 0.32), 10)
	stamp.position = Vector3(0.0, 0.55, 0.0)
	root.add_child(stamp)
	return root


static func _crystals() -> Node3D:
	var root := Node3D.new()
	root.name = "Model_spore_crystals"
	var colors := [Color(0.30, 0.92, 0.78), Color(0.42, 0.62, 1.0), Color(0.68, 0.36, 0.94)]
	for index in 4:
		var shard := _crystal(colors[index % colors.size()], 0.62 + 0.13 * float(index))
		var angle := TAU * float(index) / 4.0
		shard.position = Vector3(cos(angle) * 0.16, 0.30, sin(angle) * 0.16)
		shard.rotation.z = 0.24 * cos(angle)
		shard.rotation.x = 0.24 * sin(angle)
		root.add_child(shard)
	var base := _sphere(0.34, 0.22, Color(0.16, 0.22, 0.18), 8, 4)
	base.position.y = 0.11
	root.add_child(base)
	return root


static func _fossil_caps() -> Node3D:
	var root := Node3D.new()
	root.name = "Model_fossilized_caps"
	for index in 3:
		var cap := _sphere(0.38 - index * 0.06, 0.16, Color(0.72, 0.61, 0.38).darkened(index * 0.05), 12, 5)
		cap.position.y = 0.14 + index * 0.20
		cap.scale = Vector3(1.0, 0.60, 1.0)
		root.add_child(cap)
	return root


static func _infested_ore() -> Node3D:
	var root := Node3D.new()
	root.name = "Model_infested_ore"
	var rock := _sphere(0.46, 0.42, Color(0.27, 0.30, 0.26), 6, 4)
	rock.position.y = 0.34
	rock.scale = Vector3(1.0, 0.82, 0.92)
	root.add_child(rock)
	for index in 4:
		var shard := _crystal(Color(0.42, 0.96, 0.34), 0.42 + 0.08 * float(index))
		var angle := TAU * float(index) / 4.0 + 0.3
		shard.position = Vector3(cos(angle) * 0.24, 0.48, sin(angle) * 0.24)
		shard.rotation.z = -0.20 * cos(angle)
		shard.rotation.x = 0.20 * sin(angle)
		root.add_child(shard)
	return root


static func _ancient_core() -> Node3D:
	var root := Node3D.new()
	root.name = "Model_ancient_core"
	var core := _sphere(0.34, 0.34, Color(0.26, 0.82, 1.0), 16, 8, 2.2)
	core.position.y = 0.54
	root.add_child(core)
	for index in 2:
		var ring := _torus(0.41 + index * 0.08, 0.44 + index * 0.08, Color(0.76, 0.92, 0.50), 2.0)
		ring.position.y = 0.54
		ring.rotation.x = PI * 0.5 + (0.35 if index == 1 else 0.0)
		ring.rotation.y = 0.55 * index
		root.add_child(ring)
	var plinth := _cylinder(0.30, 0.38, 0.18, Color(0.18, 0.26, 0.24), 8)
	plinth.position.y = 0.09
	root.add_child(plinth)
	return root


static func _building(id: String) -> Node3D:
	var root := Node3D.new()
	root.name = "Model_%s" % id
	match id:
		"hut":
			root.add_child(_box(Vector3(0.92, 0.62, 0.78), Color(0.70, 0.48, 0.26), Vector3(0.0, 0.31, 0.0)))
			var roof := _prism(Vector3(1.16, 0.50, 0.98), Color(0.38, 0.58, 0.24))
			roof.position.y = 0.82
			root.add_child(roof)
			root.add_child(_box(Vector3(0.24, 0.42, 0.04), Color(0.24, 0.16, 0.10), Vector3(0.0, 0.23, 0.40)))
			root.add_child(_cylinder(0.10, 0.12, 0.34, Color(0.52, 0.38, 0.24), 6, Vector3(0.34, 1.0, 0.18)))
		"farm":
			root.add_child(_box(Vector3(1.16, 0.16, 0.86), Color(0.30, 0.20, 0.12), Vector3(0.0, 0.08, 0.0)))
			for row in 3:
				for col in 4:
					var tiny := _mushroom("glowcap")
					tiny.scale = Vector3.ONE * 0.20
					tiny.position = Vector3(-0.38 + col * 0.25, 0.16, -0.26 + row * 0.26)
					root.add_child(tiny)
		"workshop":
			root.add_child(_box(Vector3(1.02, 0.52, 0.82), Color(0.55, 0.57, 0.56), Vector3(0.0, 0.26, 0.0)))
			var roof := _prism(Vector3(1.18, 0.32, 0.94), Color(0.35, 0.40, 0.38))
			roof.position.y = 0.68
			root.add_child(roof)
			root.add_child(_box(Vector3(0.30, 0.20, 0.20), Color(0.30, 0.32, 0.32), Vector3(-0.22, 0.64, 0.30)))
			root.add_child(_cylinder(0.045, 0.060, 0.55, Color(0.48, 0.32, 0.18), 6, Vector3(0.28, 0.78, 0.28)))
		"chest":
			root.add_child(_box(Vector3(0.92, 0.46, 0.62), Color(0.68, 0.44, 0.22), Vector3(0.0, 0.23, 0.0)))
			root.add_child(_box(Vector3(0.96, 0.22, 0.66), Color(0.48, 0.29, 0.14), Vector3(0.0, 0.55, 0.0)))
			root.add_child(_box(Vector3(0.12, 0.18, 0.06), Color(0.92, 0.74, 0.30), Vector3(0.0, 0.40, 0.34)))
			for x in [-0.33, 0.33]:
				root.add_child(_box(Vector3(0.06, 0.54, 0.68), Color(0.38, 0.24, 0.12), Vector3(x, 0.30, 0.0)))
	return root


static func _coin() -> Node3D:
	var root := Node3D.new()
	root.name = "Model_gold"
	var gold := Color(0.98, 0.79, 0.32)
	var coin := _cylinder(0.42, 0.42, 0.085, gold, 24)
	coin.rotation.x = PI * 0.5
	coin.rotation.z = 0.18
	coin.position.y = 0.44
	coin.material_override = _mat(gold, 0.35, 0.28)
	root.add_child(coin)
	var rim := _torus(0.38, 0.43, gold.lightened(0.18), 0.5)
	rim.rotation.x = PI * 0.5
	rim.rotation.z = 0.18
	rim.position.y = 0.44
	root.add_child(rim)
	var emblem := _sphere(0.18, 0.13, gold.darkened(0.18), 12, 5, 0.2)
	emblem.scale = Vector3(1.0, 0.35, 1.0)
	emblem.position = Vector3(0.0, 0.46, 0.06)
	emblem.rotation.x = PI * 0.5
	root.add_child(emblem)
	return root


## --- primitive helpers ------------------------------------------------------


static func _mat(color: Color, emission := 0.0, roughness := 0.82) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	if emission > 0.0:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = emission
	return material


static func _box(size: Vector3, color: Color, position := Vector3.ZERO) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _mesh(mesh, color, position)


static func _cylinder(
	top_radius: float,
	bottom_radius: float,
	height: float,
	color: Color,
	segments := 10,
	position := Vector3.ZERO
) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.height = height
	mesh.radial_segments = segments
	mesh.rings = 1
	return _mesh(mesh, color, position)


static func _sphere(
	radius: float,
	height: float,
	color: Color,
	segments := 12,
	rings := 6,
	emission := 0.0
) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.radial_segments = segments
	mesh.rings = rings
	var instance := _mesh(mesh, color)
	instance.material_override = _mat(color, emission)
	return instance


static func _torus(inner_radius: float, outer_radius: float, color: Color, emission := 0.0) -> MeshInstance3D:
	var mesh := TorusMesh.new()
	mesh.inner_radius = inner_radius
	mesh.outer_radius = outer_radius
	mesh.rings = 16
	mesh.ring_segments = 8
	var instance := _mesh(mesh, color)
	instance.material_override = _mat(color, emission, 0.55)
	return instance


static func _prism(size: Vector3, color: Color) -> MeshInstance3D:
	var mesh := PrismMesh.new()
	mesh.size = size
	return _mesh(mesh, color)


static func _crystal(color: Color, height: float) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = 0.10
	mesh.height = height
	mesh.radial_segments = 6
	mesh.rings = 2
	var instance := _mesh(mesh, color)
	instance.material_override = _mat(color, 1.1, 0.25)
	return instance


static func _mesh(mesh: Mesh, color: Color, position := Vector3.ZERO) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = position
	instance.material_override = _mat(color)
	return instance


## --- normalisation ----------------------------------------------------------


static func _normalise(model: Node3D, target_size: float) -> void:
	if model == null:
		return
	var bounds := _bounds(model)
	if bounds.size.length_squared() < 0.0001:
		return
	var largest := maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))
	if largest <= 0.0:
		return
	var factor := target_size / largest
	model.scale = Vector3.ONE * factor
	model.position = Vector3(
		-bounds.get_center().x * factor,
		-bounds.position.y * factor,
		-bounds.get_center().z * factor
	)


static func _bounds(model: Node3D) -> AABB:
	var result := AABB()
	var first := true
	var stack: Array = [[model, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var entry: Array = stack.pop_back()
		var node: Node = entry[0]
		var xform: Transform3D = entry[1]
		if node is Node3D and node != model:
			xform = xform * (node as Node3D).transform
		if node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			var box := xform * mesh_instance.get_aabb()
			if first:
				result = box
				first = false
			else:
				result = result.merge(box)
		for child in node.get_children():
			stack.append([child, xform])
	return result


## --- fallback icons ---------------------------------------------------------


static func _paint_fallback(id: String) -> Texture2D:
	var tint: Color = COLORS.get(id, Color(0.72, 0.78, 0.62))
	var image := Image.create_empty(ICON_SIZE, ICON_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	var center := Vector2(ICON_SIZE * 0.5, ICON_SIZE * 0.55)
	# Soft halo so the silhouette separates from a dark slot.
	for radius in range(52, 18, -1):
		var alpha := 0.012 * float(52 - radius)
		_ellipse(image, center + Vector2(0, 7), radius, radius * 0.78, Color(tint, alpha))
	if MUSHROOM_IDS.has(id) or id.is_empty():
		_rect(image, Rect2(center.x - 8, center.y - 6, 16, 38), Color(0.82, 0.78, 0.64, 0.96))
		_ellipse(image, center + Vector2(0, -14), 30, 18, tint)
		_ellipse(image, center + Vector2(0, 10), 18, 8, tint.darkened(0.24))
		for index in 3:
			_ellipse(image, center + Vector2(-16 + index * 16, -20 + (index % 2) * 5), 4, 3, tint.lightened(0.5))
	else:
		_ellipse(image, center, 28, 28, tint.darkened(0.25))
		_ellipse(image, center + Vector2(-8, -8), 12, 12, tint.lightened(0.22))
		_ellipse(image, center + Vector2(10, 8), 9, 9, Color(1, 1, 1, 0.30))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


static func _rect(image: Image, rect: Rect2, color: Color) -> void:
	var x0 := clampi(int(rect.position.x), 0, ICON_SIZE - 1)
	var y0 := clampi(int(rect.position.y), 0, ICON_SIZE - 1)
	var x1 := clampi(int(rect.end.x), 0, ICON_SIZE - 1)
	var y1 := clampi(int(rect.end.y), 0, ICON_SIZE - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			_blend(image, x, y, color)


static func _ellipse(image: Image, center: Vector2, rx: float, ry: float, color: Color) -> void:
	if rx <= 0.0 or ry <= 0.0:
		return
	var x0 := maxi(int(center.x - rx), 0)
	var x1 := mini(int(center.x + rx), ICON_SIZE - 1)
	var y0 := maxi(int(center.y - ry), 0)
	var y1 := mini(int(center.y + ry), ICON_SIZE - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var nx := (float(x) + 0.5 - center.x) / rx
			var ny := (float(y) + 0.5 - center.y) / ry
			if nx * nx + ny * ny <= 1.0:
				_blend(image, x, y, color)


static func _blend(image: Image, x: int, y: int, color: Color) -> void:
	var existing := image.get_pixel(x, y)
	var alpha := color.a + existing.a * (1.0 - color.a)
	if alpha <= 0.0:
		return
	var rgb := (color * color.a + existing * existing.a * (1.0 - color.a)) / alpha
	image.set_pixel(x, y, Color(rgb.r, rgb.g, rgb.b, alpha))
