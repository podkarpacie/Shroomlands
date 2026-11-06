# Shroomlands — Progress

Status: MVP + items + rig + first person + hazard shipped. `main` is clean and CI green.

## Goal
Shroomlands — 3D multiplayer expedition RPG. Spawn in a fungi town, buy plots, craft, then push
into a layered RNG mushroom forest for better loot and worse enemies.

## Current state
- **39 test suites / 1874 assertions, all exit 0.** CI (`.github/workflows/tests.yml`) runs them on
  every push. Two real-process multiplayer proofs (ENet 2-process, WebSocket 3-process) pass.
- Exports: Windows ~107 MB (Forward+, launches and plays), Web ~40 MB (Compatibility/WebGL2).

## The town hub (done)
- **Mycoria** — walled settlement, the spawn area, plot row just outside the north gate.
- **Area switching**: `Main.enter_area()` swaps worlds without losing the HUD. In a session the
  server owns the swap and broadcasts `apply_area`; clients rebuild the same deterministic area.
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

## Party handoff and structure variety
- **Party HUD**: a `PartyBackdrop/PartyLabel` panel lists every body and marks the leader with
  `[LAMP]`; `(you)` marks the local body. It polls the player group every 0.5 s and reacts to
  `Party.leader_changed`.
- **Handoff**: `L` is `pass_lamp`; `PartyActions` asks `Party.pass_to_nearest` for the nearest
  living body within 8 m. The server accepts a client's request only from the current leader
  (the host may also correct it). The lamp and HUD follow immediately.
- **Structures by depth**: `ForestRun.structure_kind` is HUT on layer 1, CASTLE on 2-3 and
  DUNGEON on 4-5. `LayeredForest` builds a pyramid-roof hut, a battlemented courtyard with
  corner towers/battlements/torches, or a pillared stone vault; all share the chest + three
  crates.
- Tests: `test_party_ui.gd` (18), `test_forest_run.gd` (67), `test_layered_forest.gd` (43),
  and the two-process harness now proves `handoff=1 back=1` in a real session.

## Presentation pass
- **First person is the default** (`camera_distance = 0.05`): the eye offset and FP state are applied
  in `_ready`, so the first frame is already at the eyes; the wheel still zooms to 8 m.
- **Screen grade** (`ScreenFX.gd` + `screen_fx.gdshader`): a layer-5 screen pass with a biome/layer
  tint, a danger vignette, film grain and a small chroma split. Danger comes from the same
  `Atmosphere` node as the heartbeat.
- **Dynamic quiet ambience** (`Atmosphere.gd`): random creaks/whispers/drips (`tools/generate_audio.py`),
  a heartbeat that quickens near creatures or low HP, and a pitch drop on the ambient bed.
- Verified with a Forward+ first-person capture in The Rotting Hollow (lamp beam, crimson tint,
  vignette, arms) and `test_atmosphere.gd` (19 assertions).

## Model review pass
- **Contact sheets**: rendered all eleven species + the Spore Bloom in Blender, the player and
  blightling as a character sheet, and in-engine captures of a mushroom, bloom, blightling and the
  third-person player.
- **Mushrooms**: every cap now has a small overhanging rim (the stacked tiers read as one cone
  before), and spots/veins/warts sit inside the surface instead of floating as tabs. Glow energy was
  reduced from 1.6/1.4 (harvest/decor) and 2.0 (bloom) to 0.65/0.65/1.0 so the species colours are
  not washed out in daylight.
- **Spore Bloom**: fatter three-tier cap, fewer (7 warts + 7 veins), embedded, 288 tris.
- **Structures**: hut posts, castle walls/towers and dungeon walls/pillars now have collision;
  `test_layered_forest` verifies 4/8/6+ solids and layer 1.
- **Player / blightling**: reviewed; the meshes are clean blocky art, no missing parts. The club is
  the equippable item from the previous pass.

## Model review pass 2 (character close-ups)
Full-body front/back and hand close-up renders of the player rig and blightling found three real
defects that the first contact sheet missed:
- **The player had no face.** Both eye meshes sample a single atlas texel each ((38,76) and
  (43,76)), those texels were fully transparent, and the material uses `alphaMode: MASK` with
  `alphaCutoff 0.05` — so both eyes were cut out and the head rendered blank. The texels are now
  near-black (`#261A16`) in the glTF texture, the sidecar PNG and the `.bbmodel`; in-engine capture
  shows the eyes clearly.
- **The hands were plain boxes.** Each hand now carries a second primitive with a thumb box
  (+12 triangles per hand) on the inner-front edge; the 21-mesh contract is unchanged.
- **The blightling's eyes did not glow.** They shared the body material, so in daylight they read
  as flat brown squares. `Enemy._setup_materials` now gives the `eye*` meshes their own emissive
  material (`EYE_COLOR = (1.0, 0.38, 0.08)`, energy 1.7) that survives the hit flash; the claws
  were scaled 1.35x so they read at a distance.
- **Colour check, not just eyeballing**: `konop` cap average is (179,214,166) against its
  (156-182, 203-216, 150-168) albedo, `fury` (161,61,43) vs (194,67,42), `borowik` (243,187,95) vs
  (224,144,80) — the earlier "washed out" caps were the 1.6 glow energy, and 0.65 now tracks the
  texture.
- `player.gltf`, `glowcap.gltf` and `emberstem.gltf` were rendered and reviewed; all three are
  unreferenced legacy props with no defects, so they were left alone and documented as such.

## Weapon item and player-model review
- **The "rod" was not in the player glTF.** The character mesh has no club; `SwingWeapon.gd` built a
  procedural club and welded it to the right hand every frame. It is now an inventory item:
  `Lore.WEAPONS["mycelium_club"]`, carried in slot 0, equipped by default, with 12/22 light/heavy
  damage (4/7 bare-handed). Double-click in the satchel equips/unequips, right-click drops it, and
  the hand is visibly empty when unequipped. The club has a matching item icon/preview and a
  knotted hand model.
- **Replication**: `PlayerController.equipped_weapon` is replicated, so remote bodies show the
  owner's equip state. The left-hand `held_item` excludes weapons, and inventory payload
  validation accepts weapon ids.
- **Bugs found and fixed by the review**: the club leaking into `held_item` (spurious draw/holster
  animations), the server rejecting any inventory containing the club, remote bodies always
  showing the starting club, and two test fixtures assuming slot 0 was empty.
- Visuals checked with first-person captures: club in hand, empty hand after unequip, and the
  town spawn/party HUD.
- Test: `test_weapon.gd` (28 assertions).

## Run goal, death stakes and summary
- Each forest layer starts a quota: `run_quota = 40 + 20*layer` gold of loot value.
  Chests/crates add through `Game.add_run_gold`; mushrooms add their shop value. The HUD
  shows `LOOT X / Y g`.
- Dying in the forest costs half of every carried stack (`PlayerStats._drop_run_loot`) and
  increments the run's death count. The purse and weapon survive, so a bad run is painful
  but not a wipe.
- Leaving for town calls `Game.finish_run`: `last_run` stores layer/loot/quota/met/bonus/
  mushrooms/deaths/time, meeting the quota pays a 50% bonus, and the `RunSummary` panel
  shows the result with a Continue button.
- `test_run_goal.gd` (37 assertions) covers quota sources, the HUD, death loss, a met run
  with bonus, and an empty run reported as `QUOTA MISSED`.

## Multiplayer horror run (server-authoritative)
- **Area travel**: `Main.enter_area(path, layer)` is server-authoritative. A client requests, the
  server validates the path (allow-list) and the forest return rule (living leader within 14 m),
  swaps, and broadcasts `apply_area`; each peer builds the same `LayeredForest` from the layer.
- **Leader**: `Party.set_leader()` uses `request_leader`/`apply_leader` RPCs; `Main` syncs the
  current leader to a peer on connect. The HUD shows `LEADER - carry the lamp` or `FOLLOW THE LAMP`.
- **Voice**: `Network.report_disturbance()` sends a client's voice/lamp/search to the server, which
  emits locally so its authoritative enemies investigate. No more local-only hearing.
- Proven by `tests/run_horror_net_test.sh` + `tests/horror_net_harness.gd` (two processes over
  ENet): both peers reach the forest and return to town, the client is replicated as leader, its
  lamp works, its voice is heard on the host, and the HUD marker matches.
- Crate loot and the Blight are server-authoritative: the server validates/opens/pays a crate,
  and the Blight spawns via a MultiplayerSpawner on every peer.

## Extraction pressure (YAPYAP ghost)
- Every forest layer starts a 180 s run clock; the HUD `RunLabel` counts down and turns red in
  the last 30 s.
- At zero `expire_run()` releases one `Blight`: 100k HP, 400 m aggro, 6.4 m/s, 90 damage, no
  respawn. It is not a fight — it is the reason to leave.
- Leaving the forest stops the clock (-1 hides the HUD) and frees the Blight with the world.
- `test_run_timer.gd` (20 assertions) covers the clock, HUD text, one-time release, Blight stats
  and the stopped clock on return.

## Voice hearing & the leader (YAPYAP loop)
- **The monster hears you**: `VoiceInput.gd` captures microphone RMS on a private, muted bus and
  emits a 5-24 m disturbance every 0.4 s while loud. `Enemy` investigates it, so speech is a real
  aggro source. `V` toggles it; the HUD has a six-bar mic meter; `push_voice()` is the tested path.
- **One leader, one lamp**: `Party.gd` (autoload) names the leader (peer 1 by default, the local
  player offline). Only that player's `SporeLamp` toggles, drains and beams; a passed lamp dies.
- **No going back without them**: forest `ReturnGate` and the layer-5 `ExitGate` set
  `requires_leader`; the gate refuses unless a living leader is within 14 m.
- `test_voice_and_leader.gd` (21 assertions) covers loud/quiet radii, leader-only lamp, and the
  blocked/allowed return.

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
- **First person**: now the default at 0.05 m; the wheel zooms out to 8 m with exponential easing,
  head/cap
  hidden, ±85° pitch, arms + club + held item visible (`FpArms.gd` overrides arm bones after the
  AnimationPlayer). Limit: the FP arms are the third-person block arms, and attack/draw one-shots do
  not move them.

## Horror game loop (objective checklist)
- [x] Spore/mushroom horror setting, many paths, five depth layers
- [x] Monster hears the player (microphone loudness -> disturbances -> investigation)
- [x] One leader with the only lamp; return gate refuses without them
- [x] Dark layers, searchable crates, light/noise aggro, extraction gates
- [x] Group play: server-authoritative forest travel, replicated leader, networked voice
- [x] Extraction timer and an inescapable "Blight" if the party overstays
- [x] Carried loot can be lost (death stakes), with a quota and results screen
- [x] Crate loot and the Blight replicated through the server
- [x] Active area (path + forest_layer) persisted and restored from saves
- [x] First-person default, screen grade and dynamic ambience
- [x] Club is an equippable item; the hand is empty when unequipped
- [x] Leader handoff UI and a party HUD marker
- [x] Structure variety (castle / dungeon)

## Next (the design the user described)
1. ~~**The town**~~ — done, see "The town hub" above.
2. **Layered RNG forest** — path graph with forks, dead ends, hazard blooms, and random structures
   (house / mini-castle / dungeon) with loot; deeper layers = stronger enemies + better mushrooms.
3. ~~**Spore Bloom hazard**~~ — done, see "Hazards" above.
4. Then: equipment + armour repair (unlocks Armour Patch), throwables (Spore Bomb), darkness
   (unlocks Nighteye), deeper-layer enemies, shop economy depth.

## Known gaps
- No dedicated sound-only stalker: creatures investigate noise/light and the Blight is
  time-based; no hunter tracks voice loudness alone.
- No anti-cheat: peers report their own HP, gold, inventory, position; the server validates shape only.
- One transport per server instance (ENet XOR WebSocket).
- Web renderer is Compatibility/WebGL2 — Forward+ is impossible in 4.7.2's web template.
- No voice chat, skill trees, accounts, server browser, TLS.
- Local branch `model-wiring-pre-upstream` still holds discarded early wiring work.
