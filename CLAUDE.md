# CLAUDE.md — reviewer orientation

**Shroomlands** is a 3D multiplayer survival RPG set in **Mycelia**, "a world grown entirely
from fungi and mycelium — no ordinary trees, grass or metal ore" (`Lore.WORLD_NAME` /
`Lore.WORLD_DESCRIPTION`). You gather mushrooms, craft, fight, build on plots, and uncover what
damaged the First Mycelium; someone deliberately caused the Great Blight. Godot 4.7.2,
**GDScript only**, one biome (Verdant Bloom) plus its walled town hub (Mycoria), 2–32 players
over ENet/UDP (desktop) or WebSocket/TCP (browsers + desktop), Windows and Web exports. This is
the single-biome MVP.
Esc opens an in-game pause menu (Resume / Settings / Controls / Players / Quit to Menu / Quit
Game) that shares the lobby's `settings.cfg`; it pauses the tree only offline.

## Read in this order

1. [`AGENTS.md`](AGENTS.md) — tooling, commands, architecture, hard rules. Source of truth for
   *how* to build and run; this file deliberately does not repeat it.
2. [`docs/MVP_SPEC.md`](docs/MVP_SPEC.md) — the design contract the code is graded against.
3. [`README.md`](README.md) — feature-vs-spec matrix, test isolation, export/hosting, known gaps.
4. The architecture tree in `AGENTS.md` → *Architecture*, then `scripts/core/Main.gd`,
   `scripts/multiplayer/Network.gd`, `scripts/systems/`.

Autoloads: `Lore`, `EventBus`, `Audio`, `Game`, `SaveSystem`, `Network` (+ editor-only
`_mcp_game_helper`).

## Commands

```powershell
$g = ".\Godot Engine Latest\Godot_v4.7.2-stable_win64_console.exe"

# All 28 test suites - each must exit 0 (1548 assertions).
# test_env.gd is the isolation helper, not a suite: run on its own it exits 1.
Get-ChildItem tests/test_*.gd | Where-Object { $_.BaseName -ne 'test_env' } | ForEach-Object {
  $n = $_.BaseName
  $o = & $g --headless --path "." --script "res://tests/$n.gd" 2>&1
  "{0,-20} EXIT={1} PASS={2}" -f $n, $LASTEXITCODE, ($o | Select-String '^PASS ').Count
}

# Real-process multiplayer proofs (not mocks)
powershell -ExecutionPolicy Bypass -File tests\run_network_test.ps1     # ENet/UDP, 2 processes
powershell -ExecutionPolicy Bypass -File tests\run_websocket_test.ps1   # WebSocket/TCP, 3 processes
```

The 180 MB engine binary is **not** committed (`.gitignore`d): install Godot 4.7.2 at
`Godot Engine Latest/` or point `$g` at your own binary. `build/` and `.godot/` are absent too.

## Highest-value review questions

- Is `scripts/core/Main.gd` doing too much — scene wiring, save/autosave, respawn, enemy spawns,
  UI composition in one entry script? Where should the seams be?
- Are the `plot` / `gold` / `inventory` trust boundaries sane, given there is **no server
  validation**: each peer reports its own gold, inventory, position and vitals, and the server
  relays? What breaks first if one peer lies?
- Will the `EventBus`-driven UI scale, or is it implicit coupling between systems and panels?
- Is the `MultiplayerSynchronizer` usage correct for late join (spawn state, authority, the
  `resources/net_*.tres` replication configs)?
- Are the 28 suites covering **behaviour** or just structure? Look for assertions that would
  fail on a regression — start with `test_sync`, `test_plots`, `test_save`, `test_isolation`.

## Explicit notes

- **Models are wired in.** `assets/models/` holds five glTF models authored in Blockbench 5.2.2
  and exported through `blockbench-mcp`, already imported by Godot without errors:

  | File | Height | Contents |
  | --- | --- | --- |
  | `assets/models/player_rigged.gltf` | 1.80 m | rigged mushroom humanoid: crimson domed cap, cream stem body, arms/hands, dark eyes; 20 bones, six keyframed clips |
  | `assets/models/player.gltf` | 1.80 m | static pre-rig mushroom humanoid; no scene instantiates it any more |
  | `assets/models/blightling.gltf` | 1.50 m | hostile fungal creature: squat olive body, violet thorned cap, glowing orange eyes, claws |
  | `assets/models/glowcap.gltf` | 0.57 m | small teal-capped glowing mushroom, cream stem |
  | `assets/models/emberstem.gltf` | 0.74 m | orange conical cap, cream stem, small skirt ring |

  **The scenes use them** (player, enemy, gatherable mushrooms, decor), checked by
  `tests/test_models.gd`; `docs/screenshots/` predates this and still shows primitives. Blockbench
  exports in metres (16 units = 1 m), so they need no scaling on import. Regeneration recipe and
  wiring notes: `README.md` → *3D models*.
- **The player is keyframed, the blightling is procedural.** `player.tscn` instances
  `player_rigged.gltf`; `scripts/player/PlayerAnimator.gd` drives its imported `AnimationPlayer`
  through six clips — `idle`, `walk`, `run` (gaits, forced to `LOOP_LINEAR` at runtime) and
  `attack`, `draw`, `holster` (one-shots). Gait comes from measured position deltas, not
  `velocity`, so replicated players animate too; `attack` is replicated via `swing_seq` and
  `draw`/`holster` fire on `held_item` transitions, so remote peers see equip and swings. The
  exporter writes **no skin** (`skins=0`): the 20 bones are plain nodes with the cube meshes
  parented to them, so animation is rigid per segment (no joint deformation). Editable source:
  `assets/models/source/player_rigged.bbmodel`. The enemy has no rig and still uses
  `scripts/world/LimbAnimator.gd`; do not add `LimbAnimator` back to the player, it would fight
  `PlayerAnimator`.
- **First person is a camera, not a second rig.** The wheel runs the spring arm from 8 m down
  to the rig's eye point (`zoom_min` 2.2 m starts the dolly, `first_person_threshold` 0.6 m
  enters first person with `fp_exit_margin` 0.15 m of hysteresis, `zoom_smoothing` is the
  exponential ease). In first person `PlayerController` hides and exactly restores the seven
  head/cap/eye meshes, widens the pitch clamp to -85..85, stops the arm colliding, turns the
  model to the view, and `scripts/player/FpArms.gd` poses the arms at `process_priority` 100
  so the pose wins over the `AnimationPlayer`; `Weapon`/`HeldItem` are bumped one step above
  that so they follow the posed hands. Limits worth knowing: the arms are the third-person
  block arms, pulled forward and down out of the near plane rather than scaled, and
  `attack`/`draw`/`holster` are clip one-shots the pose overrides, so they do not move the
  first-person arms. `tests/test_fp_camera.gd` pins the range, the ease, the hide/restore,
  the pitch and the attached props.
- **The town hub is a separate area scene, and travel is offline-only.** `main.tscn` starts in
  `scenes/world/town.tscn` (`Town.gd`, `display_name` "Mycoria"); the north gate frees and
  re-instances the `World` node with `verdant_bloom.tscn`, and the forest gate comes back.
  `Main.enter_area` moves the local body to the new `PlayerSpawn`, sets `Game.current_biome` and
  emits `EventBus.area_changed` with the area's own `display_name`; `HUD` follows that caption
  (and seeds it at startup). The world is not replicated, so in multiplayer a gate refuses and a
  client's request is answered with the same denial. The stations (shop, alchemy, repair, plot
  board) are `Station.gd` interactables opening `StationPanelUI` panels. Weapon condition lives
  on `PlayerController` (one point per swing, half damage at 0) and the repair bench restores it
  at 2 g/point. Armour Patch and Nighteye Draught are still in `Lore.POTIONS` but gated in both
  panels: there is no armour system and no darkness yet.
- **Verification rules.** Never trust an OS screenshot on Windows at 150 % DPI scaling — a Win32
  capture is a top-left *crop* of the real frame; use `tests/capture_frame.gd` (in-engine
  viewport, windowed, never `--headless`). Every suite must exit `0`; see `README.md` → *Tests*.
