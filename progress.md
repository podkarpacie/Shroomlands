# Shroomlands — Progress

Status: **MVP complete and verified.** 17 suites / 778 assertions green; ENet + WebSocket
multiplayer proven with real processes; Windows and Web exports built and boot-tested.

## Goal
Shroomlands MVP — 3D multiplayer survival RPG, Godot 4.7.2, GDScript only, per `docs/MVP_SPEC.md`.

## Done (spec §14 build order)
- [x] 1. Autoloads (Lore, EventBus, Game, SaveSystem, Network) + full lore data layer
- [x] 2. PlayerController (WASD, sprint, jump, spring-arm camera, interact ray)
- [x] 3. Verdant Bloom world (600x600 ground, mounds, fog, seeded mushroom groves)
- [x] 4. MushroomNode + GatheringSystem (timed harvest, discovery, 45 s regrow)
- [x] 5. InventorySystem (48 slots, stacks of 64) + 8-slot hotbar
- [x] 6. Themed HUD, satchel with 3D-rendered item icons/preview, chat, gather progress, toasts,
  damage numbers, hit marker, damage vignette, death overlay
- [x] 7. Network: host/join, server-authoritative spawning, position + vitals sync
- [x] 8. Chat (global + local 25 m), server-relayed
- [x] 9. Combat: box attack hitbox + enemy hurtboxes, light/heavy attacks, crits, knockback/stagger,
  swing/bite/flinch poses, hit sparks, camera shake, stamina cost, fungal enemies, XP, death/respawn
- [x] 10. PlotSystem: 6 plots, buy/fee/expiry on wall clock, grid building, persistence
- [x] 11. Vocation selection at level 20 with four stat bonuses
- [x] 12. Save/load: full state, autosave, Continue / New Game
- [x] 13. Exports: Windows (Forward+, 105 MB) and Web (Compatibility/WebGL2, 37.7 MB wasm)
- [x] 14. Hosting: dedicated server, playit.gg docs, web server script

## Verification snapshot (all re-run by me, not taken on report)
| Check | Result |
| --- | --- |
| 17 test suites | 778 assertions, 0 failures, all exit 0 |
| ENet 2-process | PASS — players=2, walk synced, chat, HP_DROP, INV_RECV, enemies=4 |
| WebSocket 3-process | PASS — 2 WS clients on a WS-only dedicated server |
| Web build in Firefox | Renders lobby from plain `python -m http.server`, no special headers |
| Windows exe | 105 MB, Vulkan Forward+, window opens and closes cleanly |
| Export hygiene | No `addons/godot_ai` in any shipped pack |

## Blocked
- (none)

## Deliberate deviations from spec
- **Forward+ on Web is impossible in 4.7.2** (no WebGPU backend in the web template). Desktop stays
  Forward+; web ships Compatibility/WebGL2. Spec §15 wanted both — they cannot both be true.
- **Blender replaced by Blockbench** (105 MB, AI-native MCP, glTF into Godot). Blender only if
  sculpting/high-poly is ever needed.
- **One transport per server instance.** ENet (desktop) and WebSocket (browsers) cannot share a
  server process in the MVP; two servers = two worlds.
- **playit.gg** needs a port field (added) but assigns a random public port, so desktop clients must
  be told the mapped port; a fixed VPS/router forward on 7777 is the frictionless path.

## Known gaps (deliberate MVP scope)
- No anti-cheat: peers report their own HP, gold, inventory, position.
- Plots/currency are not reconciled server-side; one gold pool per session, plots are a JSON file.
- Enemies are one type, server-spawned; no HP bars on clients, no loot, no attack telegraph.
- No voice chat, full skill trees, other biomes, raids, accounts, server browser, TLS (`wss://`).
- Art is low-poly by design: authored Blockbench models for player, blightling and mushrooms,
  procedural 3D item icons; no high-poly sculpting or skeletal animation yet.

## Follow-ups
- Add a second creature silhouette, loot drops and a ranged/thrown option so combat has more than
  one melee rhythm.
- Server-side validation pass before any economy or PvP work.
