# CLAUDE.md — reviewer orientation

**Shroomlands** is a 3D multiplayer survival RPG set in **Mycelia**, "a world grown entirely
from fungi and mycelium — no ordinary trees, grass or metal ore" (`Lore.WORLD_NAME` /
`Lore.WORLD_DESCRIPTION`). You gather mushrooms, craft, fight, build on plots, and uncover what
damaged the First Mycelium; someone deliberately caused the Great Blight. Godot 4.7.2,
**GDScript only**, one biome (Verdant Bloom), 2–32 players over ENet/UDP (desktop) or
WebSocket/TCP (browsers + desktop), Windows and Web exports. This is the single-biome MVP.

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

# All 18 test suites - each must exit 0 (867 assertions).
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
- Are the 18 suites covering **behaviour** or just structure? Look for assertions that would
  fail on a regression — start with `test_sync`, `test_plots`, `test_save`, `test_isolation`.

## Two explicit notes

- **Models exist, but nothing references them yet.** `assets/models/` holds four glTF models
  authored in Blockbench 5.2.2 and exported through `blockbench-mcp`, already imported by Godot
  without errors:

  | File | Height | Contents |
  | --- | --- | --- |
  | `assets/models/player.gltf` | 1.80 m | mushroom humanoid: crimson domed cap, cream stem body, arms/hands, dark eyes |
  | `assets/models/blightling.gltf` | 1.50 m | hostile fungal creature: squat olive body, violet thorned cap, glowing orange eyes, claws |
  | `assets/models/glowcap.gltf` | 0.57 m | small teal-capped glowing mushroom, cream stem |
  | `assets/models/emberstem.gltf` | 0.74 m | orange conical cap, cream stem, small skirt ring |

  **The scenes use them** (player, enemy, gatherable mushrooms, decor), checked by
  `tests/test_models.gd`; `docs/screenshots/` predates this and still shows primitives. Blockbench
  exports in metres (16 units = 1 m), so they need no scaling on import. Regeneration recipe and
  wiring notes: `README.md` → *3D models*.
- **Verification rules.** Never trust an OS screenshot on Windows at 150 % DPI scaling — a Win32
  capture is a top-left *crop* of the real frame; use `tests/capture_frame.gd` (in-engine
  viewport, windowed, never `--headless`). Every suite must exit `0`; see `README.md` → *Tests*.
