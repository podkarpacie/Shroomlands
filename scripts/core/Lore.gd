class_name LoreData
extends Node
## Static lore database for Mycelia — the single source of truth for every
## biome, vocation, mushroom, resource, city, faction and progression bucket.
##
## Registered as the `Lore` autoload. `class_name LoreData` exists so headless
## `--script` tools (which have no autoloads) can preload and instantiate it.

const WORLD_NAME := "Mycelia"
const WORLD_DESCRIPTION := "A world grown entirely from fungi and mycelium — no ordinary trees, grass or metal ore. Gather mushrooms, craft, fight, build on plots and uncover what damaged the First Mycelium."

const GREAT_BLIGHT := {
	"name": "The Great Blight",
	"description": "Someone deliberately damaged the First Mycelium.",
}

const FIRST_MYCELIUM := {
	"name": "The First Mycelium",
	"description": "The source of the Mycelium, hidden beneath the Pale Crown. The Buried Choir hears it.",
}

const BIOMES := {
	"verdant_bloom": {
		"id": "verdant_bloom",
		"name": "Verdant Bloom",
		"description": "Starting biome. Green/orange edible mushrooms, settlements, farms, first mycelium mines. Relatively safe.",
		"danger": 1,
		"color": Color(0.25, 0.55, 0.20),
	},
	"violet_hollows": {
		"id": "violet_hollows",
		"name": "Violet Hollows",
		"description": "Hallucinogenic spores. Valuable but poisoning, visions, behavioural changes.",
		"danger": 3,
		"color": Color(0.45, 0.15, 0.55),
	},
	"crimson_rot": {
		"id": "crimson_rot",
		"name": "Crimson Rot",
		"description": "Infected red-black fungi with glowing growths. Rare toxins, upgrade materials.",
		"danger": 5,
		"color": Color(0.65, 0.08, 0.12),
	},
	"deep_mycelium": {
		"id": "deep_mycelium",
		"name": "The Deep Mycelium",
		"description": "Underground: mineral-capped mushrooms, glowing spores, mycelium veins.",
		"danger": 6,
		"color": Color(0.15, 0.25, 0.35),
	},
	"pale_crown": {
		"id": "pale_crown",
		"name": "The Pale Crown",
		"description": "Legendary giant white/golden mushrooms. Contains the source of the Mycelium.",
		"danger": 9,
		"color": Color(0.85, 0.85, 0.70),
	},
}

## RuneScape-style action skills. Every skill levels from *doing* the thing, and
## each one owns one concrete perk (see `Game` for the thresholds).
const SKILLS := {
	"foraging": {
		"id": "foraging",
		"name": "Foraging",
		"description": "Picking mushrooms. Each threshold adds +1 to every harvest.",
		"perk": "+1 mushroom per harvest at levels 5 / 10 / 15",
		"color": Color(0.55, 0.85, 0.45),
	},
	"alchemy": {
		"id": "alchemy",
		"name": "Alchemy",
		"description": "Brewing potions. Each level shaves 1 g off every recipe fee.",
		"perk": "-1 g brew fee per level (minimum 1 g)",
		"color": Color(0.80, 0.55, 0.95),
	},
	"combat": {
		"id": "combat",
		"name": "Combat",
		"description": "Killing creatures. Each level adds 2% melee damage.",
		"perk": "+2% melee damage per level",
		"color": Color(0.95, 0.55, 0.40),
	},
	"survival": {
		"id": "survival",
		"name": "Survival",
		"description": "Searching crates and extracting. The lamp lasts longer and searches are quicker.",
		"perk": "+5% lamp battery and -2% search time per level",
		"color": Color(0.55, 0.80, 0.95),
	},
}

const VOCATIONS := {
	"knight": {
		"id": "knight",
		"name": "Knight",
		"role": "Front line / Melee",
		"description": "Fights with the mycelium club and the heaviest armour the forest allows. Stands between the party and the dark.",
		"affinity": "combat",
	},
	"healer": {
		"id": "healer",
		"name": "Healer",
		"role": "Support / Alchemy",
		"description": "Turns mushrooms into draughts that keep the party standing. Reads a bad recipe before it reads a good fight.",
		"affinity": "alchemy",
	},
	"harvester": {
		"id": "harvester",
		"name": "Harvester",
		"role": "Gathering / Economy",
		"description": "Reads the forest floor for the species the run needs. A full satchel keeps the quota moving.",
		"affinity": "foraging",
	},
	"ranger": {
		"id": "ranger",
		"name": "Ranger",
		"role": "Scouting / Extraction",
		"description": "Carries the lamp, searches the crates and calls the way out. Quicker and quieter in the dark.",
		"affinity": "survival",
	},
}

## The eleven designed species (`docs/ITEMS.md`). `layers` is the authoritative
## depth list; `DEPTH_LAYERS.species` is derived from it. `eat` is applied by
## `InventorySystem.use_slot`, `brew` names the Alchemy Table output.
##
## Effect shape (see `PlayerStats.apply_effect`): `heal`, `heal_full`,
## `heal_over_time {amount, duration}`, `stamina`, `self_damage`, `cleanse`,
## `poison {damage, duration}`, `buff {id, duration, max_hp_flat?,
## max_stamina_flat?, damage_mult?, armor_mult?, vision?}`.
const MUSHROOMS := {
	"konop": {
		"id": "konop",
		"name": "Konop",
		"rarity": "common",
		"layers": [1, 2, 3, 4, 5],
		"description": "Pale, faintly sweet and found in every layer. The first mushroom every forager learns.",
		"toxicity": 0,
		"regrow_seconds": 30.0,
		"eat": {"heal": 15.0},
		"brew": {"potion": "konop_draught", "fee": 5},
		"uses": ["food", "healing"],
	},
	"shitake": {
		"id": "shitake",
		"name": "Shitake",
		"rarity": "common",
		"layers": [1, 2],
		"description": "A dense cap from the shallows and the thicket. Cooking it makes the most of it.",
		"toxicity": 0,
		"regrow_seconds": 40.0,
		"eat": {"heal": 10.0, "stamina": 5.0},
		"brew": {"potion": "hearty_stew", "fee": 5},
		"uses": ["food", "slow_healing"],
	},
	"motoko": {
		"id": "motoko",
		"name": "Motoko",
		"rarity": "common",
		"layers": [1, 2],
		"description": "A crisp little cap that dulls fatigue. Favoured by runners and woodcutters.",
		"toxicity": 0,
		"regrow_seconds": 40.0,
		"eat": {"stamina": 20.0},
		"brew": {"potion": "spore_tonic", "fee": 5},
		"uses": ["food", "stamina"],
	},
	"borowik": {
		"id": "borowik",
		"name": "Borowik",
		"rarity": "rare",
		"layers": [2, 3],
		"description": "A heavy, meaty cap. Alchemists make a tonic for those who expect a long fight.",
		"toxicity": 0,
		"regrow_seconds": 90.0,
		"eat": {
			"buff": {"id": "borowik_vigor", "duration": 120.0, "max_hp_flat": 25.0},
		},
		"brew": {"potion": "ironblood_tonic", "fee": 15},
		"uses": ["vigor", "tank"],
	},
	"kazar": {
		"id": "kazar",
		"name": "Kazar",
		"rarity": "rare",
		"layers": [2, 3],
		"description": "Red-veined and bitter. Raw it burns; processed it is the first real weapon of the forest.",
		"toxicity": 2,
		"regrow_seconds": 90.0,
		"eat": {"self_damage": 8.0},
		"brew": {"potion": "weapon_oil", "fee": 15},
		"uses": ["damage_buff", "weapon_oil"],
	},
	"kora": {
		"id": "kora",
		"name": "Kora",
		"rarity": "rare",
		"layers": [2, 3],
		"description": "Ringed and woody. The Harvester's mushroom: alchemists turn it into armour repair.",
		"toxicity": 1,
		"regrow_seconds": 120.0,
		"eat": {},
		"brew": {"potion": "armour_patch", "fee": 15},
		"uses": ["armour_repair", "alchemy"],
	},
	"altak": {
		"id": "altak",
		"name": "Altak",
		"rarity": "rare",
		"layers": [2, 3, 4],
		"description": "A dusky cap that clouds the eyes raw and opens them when brewed.",
		"toxicity": 2,
		"regrow_seconds": 120.0,
		"eat": {
			"buff": {"id": "altak_blur", "duration": 20.0, "vision": -0.5},
		},
		"brew": {"potion": "nighteye_draught", "fee": 15},
		"uses": ["vision", "nighteye"],
	},
	"bedak": {
		"id": "bedak",
		"name": "Bedak",
		"rarity": "rare",
		"layers": [2, 3],
		"description": "Warty and caustic. The base for spore bombs and a lesson in throwables.",
		"toxicity": 4,
		"regrow_seconds": 120.0,
		"eat": {"poison": {"damage": 10.0, "duration": 8.0}},
		"brew": {"potion": "spore_bomb", "fee": 20},
		"uses": ["throwable", "toxin"],
	},
	"celtus": {
		"id": "celtus",
		"name": "Celtus",
		"rarity": "epic",
		"layers": [3, 4],
		"description": "A pale halo of a cap. The panic button of the deep layers.",
		"toxicity": 0,
		"regrow_seconds": 240.0,
		"eat": {"heal": 60.0, "cleanse": true},
		"brew": {"potion": "elixir_of_renewal", "fee": 40},
		"uses": ["healing", "cleanse"],
	},
	"pesta": {
		"id": "pesta",
		"name": "Pesta",
		"rarity": "epic",
		"layers": [3, 4],
		"description": "Drooping and foul. High toxicity, and the antidote base for anyone with alchemy.",
		"toxicity": 6,
		"regrow_seconds": 240.0,
		"eat": {"poison": {"damage": 15.0, "duration": 10.0}},
		"brew": {"potion": "blight_flask", "fee": 30},
		"uses": ["debuff", "toxin"],
	},
	"fury": {
		"id": "fury",
		"name": "Fury",
		"rarity": "legendary",
		"layers": [4, 5],
		"description": "Ember-gold and hot to the touch. Legendary, and it will hurt you raw.",
		"toxicity": 5,
		"regrow_seconds": 600.0,
		"eat": {
			"self_damage": 20.0,
			"buff": {
				"id": "fury_rage",
				"duration": 20.0,
				"damage_mult": 1.5,
				"armor_mult": 1.3,
			},
		},
		"brew": {"potion": "fury_draught", "fee": 60},
		"uses": ["rage", "risk_reward"],
	},
}

## Alchemy Table outputs. One item id each, so the inventory needs no special
## cases. `armour_patch` and `spore_bomb` are data-only until armour and
## throwables exist; `use_slot` consumes them and their extra keys do nothing.
const POTIONS := {
	"konop_draught": {
		"id": "konop_draught",
		"name": "Konop Draught",
		"from": "konop",
		"fee": 5,
		"effect": {"heal": 45.0},
		"description": "A clean green draught that closes wounds fast.",
	},
	"hearty_stew": {
		"id": "hearty_stew",
		"name": "Hearty Stew",
		"from": "shitake",
		"fee": 5,
		"effect": {"heal_over_time": {"amount": 30.0, "duration": 10.0}},
		"description": "A slow, warming meal. Mends over time instead of all at once.",
	},
	"spore_tonic": {
		"id": "spore_tonic",
		"name": "Spore Tonic",
		"from": "motoko",
		"fee": 5,
		"effect": {"stamina": 50.0},
		"description": "A sharp, fizzy tonic that fills the lungs again.",
	},
	"ironblood_tonic": {
		"id": "ironblood_tonic",
		"name": "Ironblood Tonic",
		"from": "borowik",
		"fee": 15,
		"effect": {
			"buff": {"id": "ironblood", "duration": 180.0, "max_hp_flat": 50.0},
		},
		"description": "Thickens the blood for a while. Drink it before the fight, not during.",
	},
	"weapon_oil": {
		"id": "weapon_oil",
		"name": "Weapon Oil",
		"from": "kazar",
		"fee": 15,
		"effect": {
			"buff": {"id": "weapon_oil", "duration": 90.0, "damage_mult": 1.2},
		},
		"description": "Kazar rendered down to a caustic oil. Every swing lands harder.",
	},
	"armour_patch": {
		"id": "armour_patch",
		"name": "Armour Patch",
		"from": "kora",
		"fee": 15,
		"effect": {"repair_armor": 0.4},
		"description": "A fibrous paste that knits armour back together. No smith needed.",
	},
	"nighteye_draught": {
		"id": "nighteye_draught",
		"name": "Nighteye Draught",
		"from": "altak",
		"fee": 15,
		"effect": {
			"buff": {"id": "nighteye", "duration": 180.0, "vision": 1.0},
		},
		"description": "Turns the dark of the deep layers into a grey, readable half-light.",
	},
	"spore_bomb": {
		"id": "spore_bomb",
		"name": "Spore Bomb",
		"from": "bedak",
		"fee": 20,
		"effect": {"throwable": "spore_cloud", "radius": 3.0},
		"description": "A sealed caustic cap. Throw it and the cloud does the work.",
	},
	"elixir_of_renewal": {
		"id": "elixir_of_renewal",
		"name": "Elixir of Renewal",
		"from": "celtus",
		"fee": 40,
		"effect": {"heal_full": true, "cleanse": true},
		"description": "A full heal and a clean bloodstream. The Celtus spent for one moment.",
	},
	"blight_flask": {
		"id": "blight_flask",
		"name": "Blight Flask",
		"from": "pesta",
		"fee": 30,
		"effect": {
			"buff": {"id": "blight_flask", "duration": 15.0, "armor_mult": 0.7},
		},
		"description": "Blight vapours cling to the skin and dull every blow that lands.",
	},
	"fury_draught": {
		"id": "fury_draught",
		"name": "Fury Draught",
		"from": "fury",
		"fee": 60,
		"effect": {
			"buff": {
				"id": "fury_draught",
				"duration": 20.0,
				"damage_mult": 1.5,
				"armor_mult": 1.3,
			},
		},
		"description": "All offence, no guard. Everything hurts more, including you.",
	},
}

## The forest's five layers. `species` is the exact set derived from every
## mushroom's `layers`, so the two can never drift apart.
const DEPTH_LAYERS := {
	"1": {
		"id": 1,
		"name": "The Shallows",
		"species": ["konop", "shitake", "motoko"],
		"danger": "Sparring enemies, teaching traps",
	},
	"2": {
		"id": 2,
		"name": "The Thicket",
		"species": [
			"altak", "bedak", "borowik", "kazar", "konop", "kora", "motoko", "shitake"
		],
		"danger": "Packs, first toxic blooms",
	},
	"3": {
		"id": 3,
		"name": "The Rotting Hollow",
		"species": [
			"altak", "bedak", "borowik", "celtus", "kazar", "konop", "kora", "pesta"
		],
		"danger": "Spore clouds, ambush",
	},
	"4": {
		"id": 4,
		"name": "The Gloomroot",
		"species": ["altak", "celtus", "fury", "konop", "pesta"],
		"danger": "Low light, elites",
	},
	"5": {
		"id": 5,
		"name": "The Pale Depths",
		"species": ["fury", "konop"],
		"danger": "Legendary spawns, raids",
	},
}

## Equippable weapons. `damage`/`heavy_damage` are the base melee values; the
## club is the starting weapon and can be unequipped or dropped like any item.
const WEAPONS := {
	"mycelium_club": {
		"id": "mycelium_club",
		"name": "Mycelium Club",
		"description": "A knotted club of hardened mycelium. One good swing, or a slower heavy blow.",
		"damage": 12.0,
		"heavy_damage": 22.0,
		"max_condition": 100,
	},
}

## Craftable gear. One item per equipment slot; the multipliers are read by the
## system that owns the number (`PlayerStats` armour, `SporeLamp`, noise) so an
## item change takes effect without baking values into the player scene.
const GEAR := {
	"quiet_boots": {
		"id": "quiet_boots",
		"name": "Quiet Boots",
		"slot": "feet",
		"description": "Spore-felt soles. The forest hears less of you.",
		"noise_mult": 0.6,
		"recipe": {"resources": {"mycelium_fiber": 3}, "fee": 20},
	},
	"muffled_pack": {
		"id": "muffled_pack",
		"name": "Muffled Pack",
		"slot": "back",
		"description": "A padded satchel. Searching a crate no longer rings the whole layer.",
		"search_noise_mult": 0.5,
		"recipe": {"resources": {"mycelium_fiber": 4, "fossilized_caps": 1}, "fee": 25},
	},
	"bright_lamp": {
		"id": "bright_lamp",
		"name": "Bright Lamp",
		"slot": "light",
		"description": "A crystal-cored lamp: a longer beam and a bigger battery.",
		"lamp_range_mult": 1.35,
		"lamp_energy_mult": 1.25,
		"battery_mult": 1.25,
		"recipe": {"resources": {"spore_crystals": 2, "mycelium_fiber": 1}, "fee": 30},
	},
	"mycelium_vest": {
		"id": "mycelium_vest",
		"name": "Mycelium Vest",
		"slot": "body",
		"description": "Layered hardened mycelium. Blows land softer.",
		"armor_mult": 0.85,
		"recipe": {"resources": {"hardened_mycelium": 3, "mycelium_fiber": 2}, "fee": 35},
	},
}

## What each structure kind drops. 0 = hut, 1 = castle, 2 = dungeon. The ancient
## core is appended only to a layer-5 dungeon (`LayeredForest._resource_pool`).
const STRUCTURE_RESOURCES := {
	0: ["mycelium_fiber", "mycelium_fiber", "fossilized_caps"],
	1: ["hardened_mycelium", "spore_crystals", "fossilized_caps", "mycelium_fiber"],
	2: ["infested_ore", "infested_ore", "spore_crystals", "hardened_mycelium"],
}

const RESOURCES := {
	"mycelium_fiber": {
		"id": "mycelium_fiber",
		"name": "Mycelium Fiber",
		"description": "Fabrics, ropes, light armour",
	},
	"hardened_mycelium": {
		"id": "hardened_mycelium",
		"name": "Hardened Mycelium",
		"description": "Heavy armour, weapons, buildings",
	},
	"spore_crystals": {
		"id": "spore_crystals",
		"name": "Spore Crystals",
		"description": "Magic, potions, equipment upgrades",
	},
	"fossilized_caps": {
		"id": "fossilized_caps",
		"name": "Fossilized Caps",
		"description": "Construction material and relics",
	},
	"infested_ore": {
		"id": "infested_ore",
		"name": "Infested Ore",
		"description": "Advanced crafting, special weapons",
	},
	"ancient_core": {
		"id": "ancient_core",
		"name": "Ancient Core",
		"description": "Legendary equipment and quests",
	},
}

const CITIES := {
	"mycoria": {
		"id": "mycoria",
		"name": "Mycoria",
		"description": "Capital, trade, guilds, academy",
	},
	"amberhollow": {
		"id": "amberhollow",
		"name": "Amberhollow",
		"description": "Harvester farms",
	},
	"violet_sanctum": {
		"id": "violet_sanctum",
		"name": "Violet Sanctum",
		"description": "Alchemists, healers, toxin research",
	},
	"ironcap_bastion": {
		"id": "ironcap_bastion",
		"name": "Ironcap Bastion",
		"description": "Knights, craftsmen, hardened mycelium",
	},
	"rotwatch": {
		"id": "rotwatch",
		"name": "Rotwatch",
		"description": "Last settlement before Crimson Rot, bounty hunters",
	},
	"buried_choir": {
		"id": "buried_choir",
		"name": "The Buried Choir",
		"description": "Hidden underground, hears the First Mycelium",
	},
}

const FACTIONS := {
	"verdant_covenant": {
		"id": "verdant_covenant",
		"name": "The Verdant Covenant",
		"goal": "Restore natural balance of the Mycelium.",
	},
	"sporebound": {
		"id": "sporebound",
		"name": "The Sporebound",
		"goal": "Believe mutations are the next stage of the world's evolution.",
	},
	"pale_order": {
		"id": "pale_order",
		"name": "The Pale Order",
		"goal": "The First Mycelium should be completely isolated, even at the cost of destroying some biomes.",
	},
}

const PROGRESSION := {
	"1-5": {
		"id": "1-5",
		"level_range": [1, 5],
		"content": "Basic combat, gathering, first quests",
	},
	"6-10": {
		"id": "6-10",
		"level_range": [6, 10],
		"content": "New tools, crafting, local exploration",
	},
	"11-15": {
		"id": "11-15",
		"level_range": [11, 15],
		"content": "First dungeons, minibosses, side specialisations",
	},
	"16-19": {
		"id": "16-19",
		"level_range": [16, 19],
		"content": "Qualification quests and preparation for vocation",
	},
	"20": {
		"id": "20",
		"level_range": [20, 20],
		"content": "Choose main Vocation",
	},
	"21-40": {
		"id": "21-40",
		"level_range": [21, 40],
		"content": "Expand first skill tree",
	},
	"41-60": {
		"id": "41-60",
		"level_range": [41, 60],
		"content": "Harder biomes and advanced crafting",
	},
	"61+": {
		"id": "61+",
		"level_range": [61, 100],
		"content": "Legendary mushrooms, raids, factions, endgame",
	},
}

## Spawn-table ordering: common first, legendary last.
const RARITY_ORDER := {
	"common": 0,
	"rare": 1,
	"epic": 2,
	"legendary": 3,
}
## Shop base value for one mushroom of a rarity. Vendors buy in bulk and pay
## less than the alchemy fee, so foraging is worth the walk but not a gold farm.
const MUSHROOM_VALUES := {
	"common": 5,
	"rare": 20,
	"epic": 60,
	"legendary": 150,
}
## A bought potion costs this multiple of the fee the Alchemy Table charges for
## the same recipe: the vendor's margin for doing the brewing for you.
const POTION_SHOP_MARKUP := 3


func get_mushroom(id: String) -> Dictionary:
	var mushroom: Dictionary = MUSHROOMS.get(id, {})
	return mushroom


func get_potion(id: String) -> Dictionary:
	var potion: Dictionary = POTIONS.get(id, {})
	return potion


func get_vocation(id: String) -> Dictionary:
	var vocation: Dictionary = VOCATIONS.get(id, {})
	return vocation


func get_biome(id: String) -> Dictionary:
	var biome: Dictionary = BIOMES.get(id, {})
	return biome


func is_mushroom(id: String) -> bool:
	return MUSHROOMS.has(id)


func is_potion(id: String) -> bool:
	return POTIONS.has(id)


func is_weapon(id: String) -> bool:
	return WEAPONS.has(id)


func is_gear(id: String) -> bool:
	return GEAR.has(id)


func get_gear(id: String) -> Dictionary:
	return GEAR.get(id, {})


func get_weapon(id: String) -> Dictionary:
	return WEAPONS.get(id, {})


## Mushroom ids that grow in a depth layer, ordered by rarity and then id so
## spawn tables and the catalogue stay deterministic.
func mushrooms_in_layer(layer: int) -> Array[String]:
	var found: Array[String] = []
	for id: String in MUSHROOMS:
		var layers: Array = MUSHROOMS[id].get("layers", [])
		if layers.has(layer):
			found.append(id)
	found.sort_custom(_sort_by_rarity)
	return found


## The potion brewed from `mushroom_id`, or "" when it has no recipe.
func potion_for(mushroom_id: String) -> String:
	var brew: Dictionary = get_mushroom(mushroom_id).get("brew", {})
	return str(brew.get("potion", ""))


## Gold a shop pays for one mushroom of `rarity`; 0 for an unknown tier.
func mushroom_value(rarity: String) -> int:
	return int(MUSHROOM_VALUES.get(rarity, 0))


## Gold the shop charges for `potion_id` (`fee x POTION_SHOP_MARKUP`); 0 when the
## id is not a potion.
func potion_price(potion_id: String) -> int:
	var potion := get_potion(potion_id)
	if potion.is_empty():
		return 0
	return int(potion.get("fee", 0)) * POTION_SHOP_MARKUP


## Rarity of an item: a mushroom's own tier, or the tier of the mushroom a
## potion was brewed from. "" for resources and unknown ids.
func item_rarity(id: String) -> String:
	var mushroom := get_mushroom(id)
	if not mushroom.is_empty():
		return str(mushroom.get("rarity", ""))
	var potion := get_potion(id)
	if not potion.is_empty():
		return str(get_mushroom(str(potion.get("from", ""))).get("rarity", ""))
	return ""


func item_display_name(id: String) -> String:
	if MUSHROOMS.has(id):
		return str(MUSHROOMS[id]["name"])
	if POTIONS.has(id):
		return str(POTIONS[id]["name"])
	if RESOURCES.has(id):
		return str(RESOURCES[id]["name"])
	if WEAPONS.has(id):
		return str(WEAPONS[id]["name"])
	if GEAR.has(id):
		return str(GEAR[id]["name"])
	return id


func rarity_color(rarity: String) -> Color:
	match rarity:
		"common":
			return Color("#cfd8d0")
		"rare":
			return Color("#4a86c8")
		"epic":
			return Color("#a25bd0")
		"legendary":
			return Color("#e08a2e")
	return Color.WHITE


func rarity_rank(rarity: String) -> int:
	return int(RARITY_ORDER.get(rarity, 99))


func _sort_by_rarity(a: String, b: String) -> bool:
	var rank_a := rarity_rank(str(MUSHROOMS[a].get("rarity", "")))
	var rank_b := rarity_rank(str(MUSHROOMS[b].get("rarity", "")))
	if rank_a == rank_b:
		return a < b
	return rank_a < rank_b
