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
		"polish": "Zielone Zagłębie",
		"level_range": [1, 20],
		"description": "Starting biome. Green/orange edible mushrooms, settlements, farms, first mycelium mines. Relatively safe.",
		"danger": 1,
		"color": Color(0.25, 0.55, 0.20),
	},
	"violet_hollows": {
		"id": "violet_hollows",
		"name": "Violet Hollows",
		"polish": "Fioletowe Pustkowia",
		"level_range": [15, 35],
		"description": "Hallucinogenic spores. Valuable but poisoning, visions, behavioural changes.",
		"danger": 3,
		"color": Color(0.45, 0.15, 0.55),
	},
	"crimson_rot": {
		"id": "crimson_rot",
		"name": "Crimson Rot",
		"polish": "Szkarłatny Rozkład",
		"level_range": [30, 50],
		"description": "Infected red-black fungi with glowing growths. Rare toxins, upgrade materials.",
		"danger": 5,
		"color": Color(0.65, 0.08, 0.12),
	},
	"deep_mycelium": {
		"id": "deep_mycelium",
		"name": "The Deep Mycelium",
		"polish": "Głęboka Grzybnia",
		"level_range": [40, 65],
		"description": "Underground: mineral-capped mushrooms, glowing spores, mycelium veins.",
		"danger": 6,
		"color": Color(0.15, 0.25, 0.35),
	},
	"pale_crown": {
		"id": "pale_crown",
		"name": "The Pale Crown",
		"polish": "Blada Korona",
		"level_range": [60, 100],
		"description": "Legendary giant white/golden mushrooms. Contains the source of the Mycelium.",
		"danger": 9,
		"color": Color(0.85, 0.85, 0.70),
	},
}

const VOCATIONS := {
	"knight": {
		"id": "knight",
		"name": "Knight",
		"polish": "Rycerz",
		"role": "Tank / Melee",
		"description": "Specjalizuje się w mieczach, tarczach i ciężkiej zbroi z utwardzonej grzybni. Przyciąga uwagę przeciwników.",
		"trees": ["Guardian", "Berserker", "Weapon Master"],
		"primary_stat": "vitality",
	},
	"healer": {
		"id": "healer",
		"name": "Healer",
		"polish": "Uzdrowiciel",
		"role": "Healing / Alchemy / Control",
		"description": "Najlepiej wykorzystuje mikstury i lecznicze grzyby. Tworzy trucizny, bomby zarodnikowe i antidota.",
		"trees": ["Herbalist", "Plague Doctor", "Spore Alchemist"],
		"primary_stat": "wisdom",
	},
	"harvester": {
		"id": "harvester",
		"name": "Harvester",
		"polish": "Zbieracz",
		"role": "Gathering / Economy",
		"description": "Wydobywa grzybnię mineralną, sporoidy i złoża zarodników. Uprawia jadalne i rzadkie odmiany grzybów. Dostarcza surowce innym klasom.",
		"trees": ["Miner", "Cultivator", "Forager"],
		"primary_stat": "endurance",
	},
	"ranger": {
		"id": "ranger",
		"name": "Ranger",
		"polish": "Tropiciel",
		"role": "Ranged / Exploration / Hunting",
		"description": "Posługuje się łukami z włókien grzybni. Tropi rzadkie stworzenia i lokalizuje zasoby. Używa pułapek oraz strzał zarodnikowych.",
		"trees": ["Sharpshooter", "Trapper", "Beaststalker"],
		"primary_stat": "agility",
	},
}

const MUSHROOMS := {
	"glowcap": {
		"id": "glowcap",
		"name": "Glowcap",
		"rarity": "common",
		"biomes": ["verdant_bloom", "deep_mycelium"],
		"description": "Illuminates dark areas. Used in lamps, vision potions and basic crafting.",
		"toxicity": 0,
		"uses": ["light", "vision_potion", "basic_craft"],
		"regrow_seconds": 45.0,
	},
	"emberstem": {
		"id": "emberstem",
		"name": "Emberstem",
		"rarity": "common",
		"biomes": ["verdant_bloom"],
		"description": "Edible mushroom used for cooking and basic regeneration elixirs.",
		"toxicity": 0,
		"uses": ["food", "regen_elixir"],
		"regrow_seconds": 45.0,
	},
	"venomveil": {
		"id": "venomveil",
		"name": "Venomveil",
		"rarity": "rare",
		"biomes": ["violet_hollows", "crimson_rot"],
		"description": "Base for poisons, toxic arrows and spore bombs. Requires proper processing.",
		"toxicity": 4,
		"uses": ["poison", "toxic_arrow", "spore_bomb"],
		"regrow_seconds": 45.0,
	},
	"sunheart": {
		"id": "sunheart",
		"name": "Sunheart",
		"rarity": "very_rare",
		"biomes": ["pale_crown", "verdant_bloom"],
		"description": "Used for powerful healing potions and Paladin equipment upgrades.",
		"toxicity": 0,
		"uses": ["powerful_heal", "paladin_upgrade"],
		"regrow_seconds": 45.0,
	},
	"blightroot": {
		"id": "blightroot",
		"name": "Blightroot",
		"rarity": "dangerous",
		"biomes": ["crimson_rot"],
		"description": "Infected fungus used to create curses, mutation potions and Great Blight related gear.",
		"toxicity": 8,
		"uses": ["curse", "mutation", "blight_gear"],
		"regrow_seconds": 45.0,
	},
	"geodecap": {
		"id": "geodecap",
		"name": "Geodecap",
		"rarity": "rare",
		"biomes": ["deep_mycelium"],
		"description": "Mineral mushroom containing crystals and hard fibres. Mined by Harvesters, used by Artificers.",
		"toxicity": 1,
		"uses": ["mineral", "artificer_craft", "hard_fiber"],
		"regrow_seconds": 45.0,
	},
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

## Spawn-table ordering: common first, dangerous last.
const RARITY_ORDER := {
	"common": 0,
	"rare": 1,
	"very_rare": 2,
	"dangerous": 3,
}


func get_mushroom(id: String) -> Dictionary:
	var mushroom: Dictionary = MUSHROOMS.get(id, {})
	return mushroom


func get_vocation(id: String) -> Dictionary:
	var vocation: Dictionary = VOCATIONS.get(id, {})
	return vocation


func get_biome(id: String) -> Dictionary:
	var biome: Dictionary = BIOMES.get(id, {})
	return biome


func is_mushroom(id: String) -> bool:
	return MUSHROOMS.has(id)


## Mushroom ids that spawn in a biome, ordered by rarity and then id so spawn
## tables and the catalogue stay deterministic.
func mushrooms_in_biome(biome_id: String) -> Array[String]:
	var found: Array[String] = []
	for id: String in MUSHROOMS:
		var mushroom: Dictionary = MUSHROOMS[id]
		var biomes: Array = mushroom.get("biomes", [])
		if biomes.has(biome_id):
			found.append(id)
	found.sort_custom(_sort_by_rarity)
	return found


func item_display_name(id: String) -> String:
	if MUSHROOMS.has(id):
		return str(MUSHROOMS[id]["name"])
	if RESOURCES.has(id):
		return str(RESOURCES[id]["name"])
	return id


func rarity_color(rarity: String) -> Color:
	match rarity:
		"common":
			return Color(0.85, 0.85, 0.85)
		"rare":
			return Color(0.35, 0.60, 1.00)
		"very_rare":
			return Color(0.72, 0.38, 1.00)
		"dangerous":
			return Color(0.92, 0.18, 0.18)
	return Color.WHITE


func rarity_rank(rarity: String) -> int:
	return int(RARITY_ORDER.get(rarity, 99))


func _sort_by_rarity(a: String, b: String) -> bool:
	var rank_a := rarity_rank(str(MUSHROOMS[a].get("rarity", "")))
	var rank_b := rarity_rank(str(MUSHROOMS[b].get("rarity", "")))
	if rank_a == rank_b:
		return a < b
	return rank_a < rank_b
