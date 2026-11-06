# Shroomlands — Progress

Status: MVP + items + rig + first person + hazard shipped. `main` is clean and CI green.

## Goal
Shroomlands — 3D multiplayer expedition RPG. Spawn in a fungi town, buy plots, craft, then push
into a layered RNG mushroom forest for better loot and worse enemies.

## Current state
- **32 test suites / 1701 assertions, all exit 0.** CI (`.github/workflows/tests.yml`) runs them on
  every push. Two real-process multiplayer proofs (ENet 2-process, WebSocket 3-process) pass.
- Exports: Windows ~107 MB (Forward+, launches and plays), Web ~40 MB (Compatibility/WebGL2).

## The town hub (done)
- **Mycoria** — walled settlement, the spawn area, plot row just outside the north gate.
- **Area switching**: `Main.enter_area()` swaps worlds without losing the HUD; offline-only in
  multiplayer (a client asks the server and is refused, so a session cannot desync).
- **Shop**: buy potions at fee × 3, sell mushrooms at rarity value (5/20/60/150 g).
- **Alchemy Table**: brew 1 mushroom + fee into its potion — the potion data is finally usable.
- **Repair Bench**: `weapon_condition` (0-100, −1 per swing, damage halved at 0) repaired at 2 g/point.
- **Plot Board**: read-only plot summary.
- Two potions are deliberately gated in the UI: `Armour Patch` needs an equipment system,
  `Nighteye Draught` needs darkness. Their buttons are disabled rather than charging gold for nothing.

## Items — `docs/ITEMS.md` is the source of truth
- 11 mushrooms: **Konop** (common, universal tutorial heal), **Shitake**, **Motoko** (commons),
  **Borowik**, **Kazar**, **Kora**, **Altak**, **Bedak** (rares), **Celtus**, **Pesta** (epics),
  **Fury** (legendary).
- Four rarity tiers with fixed colours: common `#cfd8d0`, rare `#4a86c8`, epic `#a25bd0`,
  legendary `#e08a2e`.
- **Eat raw** (weak, sometimes toxic) vs **brew** at an Alchemy Table (strong, costs gold).
  Konop is the teaching example: +15 HP raw, **Konop Draught** +45 HP brewed.
- Effect engine on `PlayerStats`: heal, heal-over-time, stamina, self-damage, cleanse, poison and
  timed buffs (max HP/stamina, damage, armour, vision) that **refresh, never stack**.
- 11 unique low-poly models in `assets/models/mushrooms/`, one per species, regenerated
  from `tools/blender/mushroom_forge.py` (see below).
- Not built yet: **Alchemy Table object + brewing UI**, equipment/armour (Kora's repair is data only),
  throwables (Bedak's Spore Bomb is data only), darkness (Altak's vision is data only).

## Art pipeline (Blender)
- `tools/blender/mushroom_forge.py` is the editable source of truth for all eleven species:
  one headless `bpy` run rebuilds every `<id>.gltf` with no GUI, GPU, Blockbench or MCP.
- Shape and colour live in a `SPECIES` table (height, stem/cap radius, tiers, dome, rings,
  spots, warts, spikes, halo, droop). Palettes are the original Blockbench hex values, so
  each species keeps its identity; one embedded palette texture + one material per model.
- `tools/blender/validate_models.py` gates the asset contract (node naming for the glow,
  single material/texture, embedded buffers, feet at y=0, height, ≤400 tris).
  `tools/blender/render_sheet.py` produces a Cycles contact sheet for visual review.
- Contract held: 0.35-0.71 m tall, feet at origin, ~2.1k tris for the whole set.
  `test_models.gd` still passes, including the merged two-surface scenery MultiMesh.

## Horror search (first pass, YAPYAP-style)
- Night layers: `LayeredForest.is_dark` on 3-5, sun 0.10, low ambient, dim sky, thick fog.
- **Spore-lamp** (`SporeLamp.gd`): `F` toggles a 22 m spotlight at chest height; 90 s battery,
  drains while on, recharges while off, flickers under 20%. The lit beam pulses a 16 m
  disturbance every 1.2 s.
- **Searchable crates**: three per structure, 1.2 s hold, one species plus `5 + 3*layer` gold,
  14 m noise, one-shot.
- **Creatures investigate**: `Enemy` listens for `disturbance_emitted` and walks to it for 4 s
  from outside its 12 m aggro range, so light and searching are risks.
- `test_horror_search.gd` (33 assertions) covers night lighting, battery drain/recharge,
  crate payout/noise, and a distant creature investigating.
- Not yet: extraction timer/ghost, loot loss on death, a dedicated sound-only stalker.

## The layered forest (first pass)
- **Run layout**: `scripts/world/ForestRun.gd` is a deterministic graph for one depth layer:
  a winding spine from entry to exit plus `2 + layer` side branches, so forks and dead ends are
  guaranteed. Hazard and structure ids are overlays, keeping the structural kinds clean.
- **One scene, five layers**: `scenes/world/layered_forest.tscn` + `LayeredForest.gd` build
  ground, path strips, layer-correct mushroom nodes, Spore Blooms, a hut with a one-shot
  `LootChest`, and the gates. `Game.forest_layer` selects 1-5 and tints the fog per layer.
- **Travel**: a second town gate ("Descent to The Shallows"), a descent gate at each exit
  (`target_layer = layer + 1`, absent on 5) and a return gate at each entry. `AreaGate.target_layer`
  drives `Game.forest_layer`; `Main` maps the layer to a biome and scales enemy HP/damage/XP.
- Tests: `test_forest_run.gd` (62 assertions, pure data) and `test_layered_forest.gd`
  (36 assertions, town -> layer 1 -> chest -> layer 2 -> town).
- Not yet: mini-castle/dungeon structures, per-structure loot tables, enemies placed on paths,
  and saving the active area (a forest save restores its coordinates in town).

## Hazards (done)
- **Spore Bloom** — `scenes/world/spore_bloom.tscn` + `scripts/world/SporeBloom.gd`, model
  `assets/models/hazards/spore_bloom.gltf` (262 tris, Blender-forged by the same pipeline).
- Arms at 2.5 m, swells 0.6 s, bursts into a 3 m toxic cloud for 6 s at 3 damage per 0.75 s;
  leaving the radius stops the damage. 20 HP, so two light swings destroy it before it bursts;
  no loot either way.
- `CombatSystem` now accepts the `hazard` group alongside `enemy`; the bloom sits on layer 32
  so it is hittable but never blocks movement. Server-authoritative like `Enemy`, with remote
  players damaged through `Stats.apply_damage_rpc`; `state`/`dead` replicate so clients see
  the swell and the cloud.
- `test_spore_bloom.gd` (22 assertions) covers arming, burst, ticking, leaving the cloud,
  two real swings destroying it, and the no-loot rule.

## Player
- 20-bone Blockbench rig, six keyframed clips (idle/walk/run/attack/draw/**holster**), unskinned
  rigid-segment animation. `PlayerAnimator` picks the clip from measured position deltas so
  replicated players animate. `swing_seq` replicates attacks; `held_item` drives draw/holster.
- **First person**: wheel zoom 0.05-8 m, exponential easing, FP below 0.6 m with hysteresis, head/cap
  hidden, ±85° pitch, arms + club + held item visible (`FpArms.gd` overrides arm bones after the
  AnimationPlayer). Limit: the FP arms are the third-person block arms, and attack/draw one-shots do
  not move them.

## Next (the design the user described)
1. ~~**The town**~~ — done, see "The town hub" above.
2. **Layered RNG forest** — path graph with forks, dead ends, hazard blooms, and random structures
   (house / mini-castle / dungeon) with loot; deeper layers = stronger enemies + better mushrooms.
3. ~~**Spore Bloom hazard**~~ — done, see "Hazards" above.
4. Then: equipment + armour repair (unlocks Armour Patch), throwables (Spore Bomb), darkness
   (unlocks Nighteye), deeper-layer enemies, shop economy depth.

## Known gaps
- Area state is not in the save file: a save taken in the layered forest restores those
  coordinates while the session starts in town.
- No anti-cheat: peers report their own HP, gold, inventory, position; the server validates shape only.
- One transport per server instance (ENet XOR WebSocket).
- Web renderer is Compatibility/WebGL2 — Forward+ is impossible in 4.7.2's web template.
- No voice chat, skill trees, accounts, server browser, TLS.
- Local branch `model-wiring-pre-upstream` still holds discarded early wiring work.
