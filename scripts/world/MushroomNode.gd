class_name MushroomNode
extends StaticBody3D
## A single harvestable mushroom. It only answers "can I be gathered and what do
## I give"; the gather timer, inventory and sprint lock live in GatheringSystem.
##
## Physics layer 3: the interaction ray (mask 5 = world + harvestables) still
## sees the shape, while the camera's SpringArm3D, masked to layer 1, ignores
## it, so a mushroom can never collapse the third-person camera. The player
## walks through mushrooms instead of snagging on them.

## Species placed by this node; unknown ids still harvest (they just have no
## Lore name, colour or regrow entry).
@export var mushroom_id: StringName = &"glowcap"
@export var harvest_seconds := 1.2
@export var yield_min := 1
@export var yield_max := 2
## 0 derives a stable seed from the node name, so every placement yields the
## same amount across runs without giving every mushroom the same number.
@export var yield_seed := 0

## Amount handed out by the last `harvest()`, read by GatheringSystem to fill the
## inventory (the node itself owns no inventory).
var last_yield := 0

var _depleted := false
var _rng := RandomNumberGenerator.new()

@onready var _collision: CollisionShape3D = $CollisionShape3D
@onready var _stem: MeshInstance3D = $Stem
@onready var _cap: MeshInstance3D = $Cap
@onready var _regrow_timer: Timer = $RegrowTimer


func _ready() -> void:
	add_to_group(&"interactable")
	_rng.seed = yield_seed if yield_seed != 0 else hash("%s:%s" % [mushroom_id, name])
	_apply_visuals()
	_regrow_timer.timeout.connect(_on_regrow_timeout)


func get_interaction_text() -> String:
	return "Gather %s  [E]" % Lore.item_display_name(str(mushroom_id))


## Starts gathering through the player's component; a missing component just
## means this mushroom cannot be gathered right now, never an error.
func interact(player: Node) -> void:
	if not is_available() or player == null:
		return
	var gathering: Node = player.get_node_or_null("GatheringSystem")
	if gathering != null and gathering.has_method(&"begin"):
		gathering.call(&"begin", self)


## Rolls the yield, records the species and starts the regrow cooldown.
func harvest() -> void:
	if not is_available():
		return
	last_yield = _rng.randi_range(maxi(yield_min, 1), maxi(yield_max, yield_min))
	var id := str(mushroom_id)
	Game.discover_mushroom(id)
	EventBus.mushroom_gathered.emit(id, last_yield)
	_set_depleted(true)


func is_available() -> bool:
	return not _depleted


func seconds_until_ready() -> float:
	if not _depleted:
		return 0.0
	return maxf(_regrow_timer.time_left, 0.0)


func regrow_seconds() -> float:
	return float(Lore.get_mushroom(str(mushroom_id)).get("regrow_seconds", 45.0))


func _set_depleted(value: bool) -> void:
	if value == _depleted:
		return
	_depleted = value
	_stem.visible = not value
	_cap.visible = not value
	_collision.disabled = value
	if value:
		_regrow_timer.start(regrow_seconds())
	else:
		_regrow_timer.stop()


## Cap colour comes from the species rarity, so a sunheart reads at a glance.
func _apply_visuals() -> void:
	var mushroom := Lore.get_mushroom(str(mushroom_id))
	var material := StandardMaterial3D.new()
	material.albedo_color = Lore.rarity_color(str(mushroom.get("rarity", "")))
	material.roughness = 0.8
	_cap.material_override = material


func _on_regrow_timeout() -> void:
	_set_depleted(false)
