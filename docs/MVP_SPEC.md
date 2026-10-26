# MYCELIA — MVP SPECIFICATION (single source of truth)

Target: OpenCode + DeepSeek v4.1 · Engine: **Godot 4.7.2** · Language: **GDScript only (no C#)**
Export: Desktop + Web (HTML5) · Multiplayer: ENet (desktop) + WebSocket (browser)
Hosting: playit.gg (primary) + Cloudflare Tunnel / VPS (backup)

---

## 1. CONCEPT

- Name: **Shroomlands**
- Genre: 3D open-world survival RPG multiplayer
- World: everything built from fungi and mycelium (no ordinary trees, grass, or metal ore)

Player goal: gather mushrooms, craft, fight, build on plots, pick a vocation at level 20,
discover the Great Blight history, survive and grow with other players.

World secret: someone deliberately damaged the First Mycelium (The Great Blight).

---

## 2. BIOMES (5)

| # | id | Name | Polish | Lvl | Danger | Description |
|---|---|---|---|---|---|---|
| 1 | `verdant_bloom` | Verdant Bloom | Zielone Zagłębie | 1-20 | 1 | Starting biome. Green/orange edible mushrooms, settlements, farms, first mycelium mines. Relatively safe. Colour (0.25, 0.55, 0.20) |
| 2 | `violet_hollows` | Violet Hollows | Fioletowe Pustkowia | 15-35 | 3 | Hallucinogenic spores. Valuable but poisoning, visions, behavioural changes. Colour (0.45, 0.15, 0.55) |
| 3 | `crimson_rot` | Crimson Rot | Szkarłatny Rozkład | 30-50 | 5 | Infected red-black fungi with glowing growths. Rare toxins, upgrade materials. Colour (0.65, 0.08, 0.12) |
| 4 | `deep_mycelium` | The Deep Mycelium | Głęboka Grzybnia | 40-65 | 6 | Underground: mineral-capped mushrooms, glowing spores, mycelium veins. Colour (0.15, 0.25, 0.35) |
| 5 | `pale_crown` | The Pale Crown | Blada Korona | 60-100 | 9 | Legendary giant white/golden mushrooms. Contains the source of the Mycelium. Colour (0.85, 0.85, 0.70) |

MVP implements **Verdant Bloom only**.

---

## 3. VOCATIONS (4) — unlock at level 20, max 4

| id | Name | Polish | Role | Trees | Primary stat |
|---|---|---|---|---|---|
| `knight` | Knight | Rycerz | Tank / Melee | Guardian, Berserker, Weapon Master | vitality |
| `healer` | Healer | Uzdrowiciel | Healing / Alchemy / Control | Herbalist, Plague Doctor, Spore Alchemist | wisdom |
| `harvester` | Harvester | Zbieracz | Gathering / Economy | Miner, Cultivator, Forager | endurance |
| `ranger` | Ranger | Tropiciel | Ranged / Exploration / Hunting | Sharpshooter, Trapper, Beaststalker | agility |

Descriptions (Polish, verbatim from lore):
- **Knight**: "Specjalizuje się w mieczach, tarczach i ciężkiej zbroi z utwardzonej grzybni. Przyciąga uwagę przeciwników."
- **Healer**: "Najlepiej wykorzystuje mikstury i lecznicze grzyby. Tworzy trucizny, bomby zarodnikowe i antidota."
- **Harvester**: "Wydobywa grzybnię mineralną, sporoidy i złoża zarodników. Uprawia jadalne i rzadkie odmiany grzybów. Dostarcza surowce innym klasom."
- **Ranger**: "Posługuje się łukami z włókien grzybni. Tropi rzadkie stworzenia i lokalizuje zasoby. Używa pułapek oraz strzał zarodnikowych."

Below level 20 the player is a universal traveller.

---

## 4. MUSHROOMS (core resource system)

| id | Name | Rarity | Biomes | Toxicity | Uses |
|---|---|---|---|---|---|
| `glowcap` | Glowcap | common | verdant_bloom, deep_mycelium | 0 | light, vision_potion, basic_craft |
| `emberstem` | Emberstem | common | verdant_bloom | 0 | food, regen_elixir |
| `venomveil` | Venomveil | rare | violet_hollows, crimson_rot | 4 | poison, toxic_arrow, spore_bomb |
| `sunheart` | Sunheart | very_rare | pale_crown, verdant_bloom | 0 | powerful_heal, paladin_upgrade |
| `blightroot` | Blightroot | dangerous | crimson_rot | 8 | curse, mutation, blight_gear |
| `geodecap` | Geodecap | rare | deep_mycelium | 1 | mineral, artificer_craft, hard_fiber |

Descriptions:
- Glowcap: "Illuminates dark areas. Used in lamps, vision potions and basic crafting."
- Emberstem: "Edible mushroom used for cooking and basic regeneration elixirs."
- Venomveil: "Base for poisons, toxic arrows and spore bombs. Requires proper processing."
- Sunheart: "Used for powerful healing potions and Paladin equipment upgrades."
- Blightroot: "Infected fungus used to create curses, mutation potions and Great Blight related gear."
- Geodecap: "Mineral mushroom containing crystals and hard fibres. Mined by Harvesters, used by Artificers."

Each mushroom has: rarity, biome, toxicity, uses, **regrow time** (MVP: 45 s).

---

## 5. RESOURCES (instead of ores)

| id | Name | Description |
|---|---|---|
| `mycelium_fiber` | Mycelium Fiber | Fabrics, ropes, light armour |
| `hardened_mycelium` | Hardened Mycelium | Heavy armour, weapons, buildings |
| `spore_crystals` | Spore Crystals | Magic, potions, equipment upgrades |
| `fossilized_caps` | Fossilized Caps | Construction material and relics |
| `infested_ore` | Infested Ore | Advanced crafting, special weapons |
| `ancient_core` | Ancient Core | Legendary equipment and quests |

---

## 6. CITIES & FACTIONS

Cities: `mycoria` Mycoria (capital, trade, guilds, academy) · `amberhollow` Amberhollow (Harvester farms) ·
`violet_sanctum` Violet Sanctum (alchemists, healers, toxin research) · `ironcap_bastion` Ironcap Bastion
(knights, craftsmen, hardened mycelium) · `rotwatch` Rotwatch (last settlement before Crimson Rot,
bounty hunters) · `buried_choir` The Buried Choir (hidden underground, hears the First Mycelium).

Factions:
1. `verdant_covenant` The Verdant Covenant — "Restore natural balance of the Mycelium."
2. `sporebound` The Sporebound — "Believe mutations are the next stage of the world's evolution."
3. `pale_order` The Pale Order — "The First Mycelium should be completely isolated, even at the cost of destroying some biomes."

---

## 7. PROGRESSION

| Range | Content |
|---|---|
| 1-5 | Basic combat, gathering, first quests |
| 6-10 | New tools, crafting, local exploration |
| 11-15 | First dungeons, minibosses, side specialisations |
| 16-19 | Qualification quests and preparation for vocation |
| 20 | Choose main Vocation |
| 21-40 | Expand first skill tree |
| 41-60 | Harder biomes and advanced crafting |
| 61+ | Legendary mushrooms, raids, factions, endgame |

---

## 8. PLOT SYSTEM

- Player buys a plot with gold
- Daily fee (automatic, even offline)
- No gold → plot expires after X days
- Build on plot: house, mushroom farm, workshop, chests
- Building: simple (place object → snap to grid)
- Plot data stored server-side (persistent)

---

## 9. MULTIPLAYER

- Dedicated server (headless Godot)
- ENet for desktop
- WebSocket for browser
- Max 32 players per instance at start
- Text chat (global + local)
- Voice chat: LiveKit or WebRTC (later)
- Hosting: playit.gg primary, Cloudflare Tunnel / VPS backup

---

## 10. CORE SYSTEMS (MVP)

**A. PlayerController** (CharacterBody3D) — WASD + mouse (FPS/TPS), sprint, jump, interact (E),
placeholder animation, HP, Stamina, XP, Level.

**B. GatheringSystem** — interact with world mushrooms, gather time + animation, add to inventory,
species discovery (catalogue).

**C. InventorySystem** — 6x8 grid, stacking, use/equip/drop, hotbar.

**D. CombatSystem** (basic) — melee attack (LMB), simple raycast / Area3D hitbox, damage, crit, death, respawn.

**E. PlotSystem** — buy plot, daily fee (server timer), build objects, persistent save.

**F. MultiplayerManager** — host/join, player position sync, basic inventory sync, chat, spawning.

**G. UI** — HUD (HP, stamina, level, hotbar), inventory panel, chat window,
vocation selection screen (lvl 20), minimal main menu (Host / Join / Settings).

**H. World** — one starting biome (Verdant Bloom), several mushroom gathering points,
simple placeholder terrain, spawn point, 1-2 simple enemies (fungal creatures).

**I. SaveSystem** — local player save (level, xp, gold, discovered mushrooms, vocation);
server holds plots and world.

---

## 11. PROJECT STRUCTURE

```
Shroomlands/
├── project.godot
├── scenes/
│   ├── main.tscn
│   ├── player/player.tscn
│   ├── world/verdant_bloom.tscn
│   ├── ui/{hud,inventory,chat,vocation_select}.tscn
│   └── multiplayer/lobby.tscn
├── scripts/
│   ├── core/{Game,EventBus,Lore,SaveSystem}.gd      (autoloads)
│   ├── multiplayer/Network.gd                        (autoload)
│   ├── player/{PlayerController,PlayerStats}.gd
│   ├── systems/{GatheringSystem,InventorySystem,CombatSystem,PlotSystem}.gd
│   ├── world/{MushroomNode,Enemy}.gd
│   └── ui/{HUD,InventoryUI,ChatUI}.gd
├── resources/{items,classes,biomes}/
└── assets/{models,textures,audio}/
```

---

## 12. AUTOLOADS

```
Game        = res://scripts/core/Game.gd
Network     = res://scripts/multiplayer/Network.gd
Lore        = res://scripts/core/Lore.gd
EventBus    = res://scripts/core/EventBus.gd
SaveSystem  = res://scripts/core/SaveSystem.gd
```

---

## 13. LORE DATA

All of section 2-7 above goes into `Lore.gd` as `const Dictionary` / `const Array` — one source of truth.
Plus `WORLD_NAME = "Mycelia"`, `WORLD_DESCRIPTION`, `GREAT_BLIGHT`, `FIRST_MYCELIUM`.

---

## 14. IMPLEMENTATION PRIORITY

1. project.godot + autoloads (Game, Lore, EventBus, Network, SaveSystem)
2. PlayerController (movement + camera)
3. Basic world (Verdant Bloom placeholder)
4. MushroomNode + GatheringSystem
5. InventorySystem + hotbar
6. HUD
7. Network (Host/Join + position sync)
8. Chat
9. Combat (basic)
10. PlotSystem (buy + build)
11. Vocation selection (lvl 20)
12. Save/Load
13. Export Web + Desktop
14. playit.gg integration

---

## 15. TECHNICAL REQUIREMENTS

- Godot 4.7.2
- GDScript only
- Forward+ renderer
- Jolt Physics (optional)
- Web export must work (hence no C#)
- Player, mushroom and enemy models will be imported from Blender (glTF)
- Placeholder geometry at start (CapsuleMesh, BoxMesh, SphereMesh)

---

## 16. NOT IN MVP

- Voice chat (later)
- Full skill trees
- All biomes (Verdant Bloom only)
- Advanced crafting
- Raids / endgame
- Full story (only a Great Blight teaser)
- Mobile
