# Shroomlands — Progress

Status: MVP + items + rig + first person shipped. `main` = `b251d4f` (+ this doc commit), clean, CI green.

## Goal
Shroomlands — 3D multiplayer expedition RPG. Spawn in a fungi town, buy plots, craft, then push
into a layered RNG mushroom forest for better loot and worse enemies.

## Current state
- **25 test suites / 1432 assertions, all exit 0.** CI (`.github/workflows/tests.yml`) runs them on
  every push. Two real-process multiplayer proofs (ENet 2-process, WebSocket 3-process) pass.
- Exports: Windows ~107 MB (Forward+, launches and plays), Web ~40 MB (Compatibility/WebGL2).

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
- 11 unique blocky models in `assets/models/mushrooms/`, one per species.
- Not built yet: **Alchemy Table object + brewing UI**, equipment/armour (Kora's repair is data only),
  throwables (Bedak's Spore Bomb is data only), darkness (Altak's vision is data only).

## Player
- 20-bone Blockbench rig, six keyframed clips (idle/walk/run/attack/draw/**holster**), unskinned
  rigid-segment animation. `PlayerAnimator` picks the clip from measured position deltas so
  replicated players animate. `swing_seq` replicates attacks; `held_item` drives draw/holster.
- **First person**: wheel zoom 0.05-8 m, exponential easing, FP below 0.6 m with hysteresis, head/cap
  hidden, ±85° pitch, arms + club + held item visible (`FpArms.gd` overrides arm bones after the
  AnimationPlayer). Limit: the FP arms are the third-person block arms, and attack/draw one-shots do
  not move them.

## Next (the design the user described)
1. **The town** — spawn hub with a shop, alchemy table, repair bench, plot access, and one exit.
2. **Layered RNG forest** — path graph with forks, dead ends, hazard blooms, and random structures
   (house / mini-castle / dungeon) with loot; deeper layers = stronger enemies + better mushrooms.
3. **Spore Bloom hazard** — proximity-detonated toxic cloud, destroyable at range.
4. Then: equipment + armour repair, throwables, darkness/vision, shop economy.

## Known gaps
- No anti-cheat: peers report their own HP, gold, inventory, position; the server validates shape only.
- One transport per server instance (ENet XOR WebSocket).
- Web renderer is Compatibility/WebGL2 — Forward+ is impossible in 4.7.2's web template.
- No voice chat, skill trees, accounts, server browser, TLS.
- Local branch `model-wiring-pre-upstream` still holds discarded early wiring work.
