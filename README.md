# Shroomlands

**Mycelia** is a world grown entirely from fungi and mycelium — no ordinary trees, grass
or metal ore. Gather mushrooms, craft, fight, build on plots, and uncover what damaged the
First Mycelium. Someone deliberately caused the Great Blight.

A 3D multiplayer survival RPG built with **Godot 4.7.2** and **GDScript only**
(spec: [`docs/MVP_SPEC.md`](docs/MVP_SPEC.md)). This repository is the single-biome MVP:
Verdant Bloom, two to 32 players over ENet or WebSocket, and Windows/Web exports.

## Status

- 15 headless test suites, **695 assertions**, all green — including a run with a
  level-30 character save on disk (the suites redirect `SaveSystem` to a private file;
  see [Tests](#tests)).
- Desktop renderer: **Forward+**. Web renderer: **Compatibility (WebGL 2.0)** — see
  [known gaps](#known-gaps).
- Exports ship as a self-contained Windows EXE (embedded PCK), a static Web build, and a
  headless Windows dedicated server.
- Multiplayer speaks **ENet/UDP on desktop** and **WebSocket/TCP in a browser**. One server
  instance serves one transport; a browser joins a server started with
  `tools\run_server.ps1 -Transport websocket`.
- The `addons/godot_ai` MCP plugin is editor tooling only and is stripped from every
  export by `tools/export_all.ps1`.

## Features vs. the MVP spec

| Spec §10 | Status | What is there |
| --- | --- | --- |
| **A. PlayerController** | Done | `CharacterBody3D`, WASD + mouse, sprint, jump, interact (E), HP/stamina/XP/level, third-person spring arm |
| **B. GatheringSystem** | Done | Six mushroom species, gather time, regrow timer (45 s), species discovery/catalogue |
| **C. InventorySystem** | Done | 6×8 grid, stacking, use/equip/drop, 8-slot hotbar, server-synced mirror |
| **D. CombatSystem** | Done | Melee raycast/Area3D hitbox, damage, crit, death, respawn, four fungal creatures |
| **E. PlotSystem** | Done | Six 12 m plots, buy with gold, daily fee settled from wall-clock time (offline included), 3-day expiry, 1 m grid building (hut/farm/workshop/chest), server-authoritative, `user://plots.json` |
| **F. MultiplayerManager** | Done (ENet + WebSocket) | Host/join, player position sync, vitals sync, inventory sync, roster, global/local chat, server-side validation. ENet for desktop, WebSocket for browsers; one transport per server instance |
| **G. UI** | Done | HUD (HP, stamina, level, gold, hotbar), inventory, chat, vocation picker, lobby with Host/Join/Port/Settings/Continue |
| **H. World** | Done (one biome) | Verdant Bloom placeholder terrain, mushroom nodes, decorative props, plot row, four enemy spawns |
| **I. SaveSystem** | Done | Atomic JSON save: level, XP, gold, discoveries, vocation, position, HP/stamina, inventory. Plots live server-side |
| Vocation at level 20 | Done | Four vocations (Knight/Healer/Harvester/Ranger), modal picker, persisted choice |
| Export Web + Desktop | Done | Windows Desktop, Web (nothreads), Windows Server presets; all boot |
| Hosting (playit.gg) | Done | `tools/run_server.ps1` (ENet or WebSocket), `tools/serve_web.ps1`, [`docs/HOSTING.md`](docs/HOSTING.md); the lobby has a Port field for tunnelled public ports |

Not in this MVP: voice chat, full skill trees, the other four biomes, advanced crafting,
raids/endgame, the full story, mobile.

## Run from source

Requirements: the bundled Godot 4.7.2 console binary (or the editor GUI) and the
`4.7.2.stable` export templates for exporting.

```powershell
# Run the game (opens the lobby; Host / Join / New Game)
& ".\Godot Engine Latest\Godot_v4.7.2-stable_win64_console.exe" --path "."

# Open the editor
& ".\Godot Engine Latest\Godot_v4.7.2-stable_win64.exe" -e --path "."
```

Single-player: **New Game** or **Continue**. Multiplayer: **Host** starts a server on the
port in the **Port** field (ENet/UDP on desktop, WebSocket/TCP in a browser — browsers
cannot listen). A client types the host's address and port and presses **Join**; Enter in
either field joins too.

- Desktop ↔ desktop: the default server (`tools\run_server.ps1`, ENet/UDP).
- Browser → server: start the server with `-Transport websocket`, serve `build\web`, and
  enter the public host + port (or a full `wss://…` URL) in the lobby.
- A browser cannot host. A server process speaks one transport only, so a session is
  desktop-only or browser-only; see [known gaps](#known-gaps).

## Tests

Each suite is a `SceneTree` script and exits non-zero on failure:

```powershell
$godot = ".\Godot Engine Latest\Godot_v4.7.2-stable_win64_console.exe"
$suites = @(
  'test_lore','test_player','test_inventory','test_gathering','test_ui','test_network',
  'test_chat','test_lobby','test_combat','test_movement_block','test_plots','test_vocation',
  'test_save','test_sync','test_isolation'
)
foreach ($suite in $suites) {
  & $godot --headless --path . --script "res://tests/$suite.gd"
  if ($LASTEXITCODE -ne 0) { throw "suite failed: $suite" }
}
```

Current counts: `test_lore` 65, `test_player` 20, `test_inventory` 29,
`test_gathering` 38, `test_ui` 46, `test_network` 41, `test_chat` 24, `test_lobby` 81,
`test_combat` 32, `test_movement_block` 15, `test_plots` 86, `test_vocation` 70,
`test_save` 58, `test_sync` 68, `test_isolation` 22 — **695 assertions**.

### Test isolation

The suites never read or write the developer's profile. `SaveSystem` takes its file
from `SHROOMLANDS_SAVE_PATH` (or `--save-path=<path>` on the command line) and only
falls back to `user://player_save.json` when neither is set, so a suite gets a private
save **without** switching the feature off:

- `tests/test_env.gd` `isolate("<suite>")` sets `SHROOMLANDS_SAVE_PATH` to
  `user://tests/<suite>_save.json` and deletes it in `_initialize()`, before `main.tscn`
  loads. Every suite that instantiates the world or calls `SaveSystem` does this first,
  so a run always starts with no save.
- `Main.gd` still auto-loads an offline save and always registers autosave/close-save;
  only the path changes. `test_lobby` (Continue) and `test_save` (`WM_CLOSE_REQUEST`)
  therefore exercise the production path against their own probe save.
- `test_env.gd` `stash("user://plots.json")` keeps `PlotSystem` from rewriting the
  developer's plots; `restore_all()` puts that file back in `_finalize()`.
- `test_isolation` proves the redirect itself: writes land at the override, two
  overrides hold independent saves, and the default file is unchanged.

The per-suite files stay in `user://tests/` after a run (deleted again at the start of
the next one), so `Get-Content "$env:APPDATA\Godot\app_userdata\Shroomlands\tests\<suite>_save.json"`
shows where a suite's writes landed.

The acceptance run is a level-30 character save at the default path followed by every
suite exiting 0 with that file byte-identical afterwards.

Two-process / three-process network proofs:

```powershell
# ENet/UDP host + client (default)
powershell -ExecutionPolicy Bypass -File tests\run_network_test.ps1

# Same gameplay proof over WebSocket/TCP
powershell -ExecutionPolicy Bypass -File tests\run_network_test.ps1 -Transport websocket

# Websocket-only dedicated server + two real WebSocket clients (server reports players=2)
powershell -ExecutionPolicy Bypass -File tests\run_websocket_test.ps1
```

## Export

The supported path is one command. It snapshots `project.godot`, removes the editor-only
`[editor_plugins]` setting and the `_mcp_game_helper` autoload for the duration of the
export, runs all three presets, and restores the file in `finally`:

```powershell
powershell -ExecutionPolicy Bypass -File tools\export_all.ps1
```

Outputs:

| Preset | Output |
| --- | --- |
| `Windows Desktop` | `build\windows\Shroomlands.exe` (x86_64, release, embedded PCK) |
| `Web` | `build\web\index.html` (+ `.pck`, `.wasm`, `.js`) |
| `Windows Server` | `build\server\ShroomlandsServer.exe` |

The raw commands also work (they leave the inert `editor_plugins/enabled` setting in the
pack, which is why the wrapper is preferred):

```powershell
$godot = ".\Godot Engine Latest\Godot_v4.7.2-stable_win64_console.exe"
& $godot --headless --path . --export-release "Windows Desktop" "build/windows/Shroomlands.exe"
& $godot --headless --path . --export-release "Web" "build/web/index.html"
& $godot --headless --path . --export-release "Windows Server" "build/server/ShroomlandsServer.exe"
```

Export templates must be installed at
`%APPDATA%\Godot\export_templates\4.7.2.stable`. `build/` is gitignored.

The Web preset uses the **nothreads** template (`variant/thread_support=false`), so the
build runs from a plain static server with no COOP/COEP headers. Extensions and PWA are
off.

## Host

```powershell
# Dedicated server, UDP 7777 / ENet (desktop clients). Prints LAN IP + firewall command.
powershell -ExecutionPolicy Bypass -File tools\run_server.ps1

# Dedicated server, TCP 7777 / WebSocket (browser clients). One transport per process.
powershell -ExecutionPolicy Bypass -File tools\run_server.ps1 -Transport websocket

# Static web build on http://127.0.0.1:8000
powershell -ExecutionPolicy Bypass -File tools\serve_web.ps1

# Server + two headless clients, local smoke test (add -Transport websocket for TCP)
powershell -ExecutionPolicy Bypass -File tools\run_two_clients.ps1
```

Full details, playit.gg (UDP for ENet, TCP for WebSocket), Cloudflare Tunnel and VPS notes:
**[`docs/HOSTING.md`](docs/HOSTING.md)**.

The server entry point is `tools/dedicated_server.tscn`; `run_server.ps1` writes an
`override.cfg` next to the EXE because an exported release build cannot be told to start a
different scene with `--scene` and export presets cannot override `application/run/main_scene`.
`--transport=enet|websocket` selects the socket type and the server logs
`SHROOMLANDS_DEDICATED transport=websocket port=7777`.

## Project layout

```
project.godot            autoloads, input map, rendering (Forward+)
export_presets.cfg       Windows Desktop / Web / Windows Server
scenes/                  lobby, main, player, UI, world (tscn)
scripts/
  core/                  Lore, EventBus, Game, SaveSystem, Main (autoloads + entry scene)
  multiplayer/           Network.gd (ENet / WebSocket abstraction)
  player/                PlayerController, PlayerStats
  systems/               Gathering, Inventory, Combat, Plot
  ui/                    HUD, InventoryUI, ChatUI, VocationUI, LobbyUI, BuildMode
  world/                 MushroomNode, Enemy, PlotSign, VerdantBloom
resources/               MultiplayerSynchronizer replication configs
tests/                   14 headless suites, net_harness, capture_frame, network proofs
tools/                   export_all, run_server, serve_web, run_two_clients, server bootstrap
docs/                    MVP_SPEC.md, HOSTING.md
addons/godot_ai/         editor-only MCP plugin; never exported
build/                   export output (gitignored)
```

## Known gaps

1. **One transport per server instance.** A server listens with ENet/UDP **or**
   WebSocket/TCP, never both; mixing them would need a second `MultiplayerAPI`. A browser
   needs the websocket-mode server, and the lobby has no transport selector: desktop
   players join with the platform default (ENet), so a desktop and a browser player
   cannot share one session. Two server processes are two separate worlds. The engine
   path for a desktop client to dial a websocket server exists
   (`Network.join(ip, port, "websocket")`, proven by `tests\run_websocket_test.ps1`), but
   the lobby UI does not expose it yet.
2. **Browsers cannot host.** A browser cannot open a listening socket, so the web **Host**
   button reports an error and points at Join. Serve the web build and join a dedicated
   server instead.
3. **An HTTPS page needs `wss://`.** Browsers block plain `ws://` from an HTTPS origin.
   Serve `build\web` over plain HTTP on the LAN, or put a TLS tunnel in front and enter the
   full `wss://host/` URL in the lobby address field (the Port field is then unused).
4. **Web renderer is Compatibility, not Forward+.** Godot 4.7.2's Web template has no
   WebGPU backend; forcing `rendering/renderer/rendering_method.web="forward_plus"` still
   boots the Compatibility renderer. Desktop remains Forward+ as the spec requires. The
   spec's "Forward+ and a working web export" cannot both be literally true on this
   engine version.
5. **One biome.** Verdant Bloom is built; the other four biomes exist as lore data only.
6. **Placeholder art.** Characters, mushrooms and creatures are procedural primitives;
   no imported glTF/Blockbench models yet. One ground mound still z-fights slightly.
7. **No voice chat**, full skill trees, advanced crafting, raids/endgame, factions or the
   full Great Blight story. Vocation choice exists, but the trees behind it do not.
8. **No server browser or accounts.** Direct host/port only; no authentication, no
   character server, no anti-cheat.
9. **Plot persistence is a JSON file** (`user://plots.json`) owned by one server process.
   No database, no multi-instance coordination, no backups.
10. **Windows-only server preset.** There is no Linux/macOS export preset in the repo.
11. **Scale is unproven.** `MAX_PLAYERS` is 32 and the code enforces it, but the tests and
    smoke runs cover two clients.
12. **Web build is single-threaded** (nothreads variant, no GDExtension). It boots and
    renders, but expect lower performance than desktop.
