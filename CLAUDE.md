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

Autoloads: `Lore`, `EventBus`, `Game`, `SaveSystem`, `Network` (+ editor-only `_mcp_game_helper`).

## Commands

```powershell
$g = ".\Godot Engine Latest\Godot_v4.7.2-stable_win64_console.exe"

# All 15 test suites — each must exit 0 (695 assertions)
Get-ChildItem tests/test_*.gd | ForEach-Object {
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
- Are the 15 suites covering **behaviour** or just structure? Look for assertions that would
  fail on a regression — start with `test_sync`, `test_plots`, `test_save`, `test_isolation`.

## Two explicit notes

- **No 3D models yet.** All art is placeholder primitives (`BoxMesh` / `CapsuleMesh` /
  `CylinderMesh`) defined inline in the `.tscn` scenes. There are no glTF, `.glb` or Blockbench
  files here, and `docs/screenshots/` shows exactly that.
- **Verification rules.** Never trust an OS screenshot on Windows at 150 % DPI scaling — a Win32
  capture is a top-left *crop* of the real frame; use `tests/capture_frame.gd` (in-engine
  viewport, windowed, never `--headless`). Every suite must exit `0`; see `README.md` → *Tests*.
