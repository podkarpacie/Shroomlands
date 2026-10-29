# Shroomlands

**Mycelia** is a world grown entirely from fungi and mycelium — no ordinary trees, grass
or metal ore. Gather mushrooms, craft, fight, build on plots, and uncover what damaged the
First Mycelium. Someone deliberately caused the Great Blight.

A 3D multiplayer survival RPG built with **Godot 4.7.2** and **GDScript only**
(spec: [`docs/MVP_SPEC.md`](docs/MVP_SPEC.md)). This repository is the single-biome MVP:
Verdant Bloom, two to 32 players over ENet or WebSocket, and Windows/Web exports.

## Status

- 22 headless test suites, **1036 assertions**, all green - including a run with a
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
| **A. PlayerController** | Done | `CharacterBody3D`, WASD + mouse, sprint, jump, interact (E), HP/stamina/XP/level, third-person spring arm with wheel zoom; tight acceleration, coyote time, jump buffer, variable jump height, sprint-jump keeps speed |
| **B. GatheringSystem** | Done | Six mushroom species, gather time, regrow timer (45 s), species discovery/catalogue |
| **C. InventorySystem** | Done | 6×8 satchel with 3D-rendered item icons, rotating model preview, sorting, drag/drop, 8-slot hotbar, server-synced mirror |
| **D. CombatSystem** | Done | Box hitbox + enemy hurtboxes, knockback/stagger, crits, hit sparks, camera shake, keyframed player swing, procedural enemy bite/flinch |
| **E. PlotSystem** | Done | Six 12 m plots, buy with gold, daily fee settled from wall-clock time (offline included), 3-day expiry, 1 m grid building (hut/farm/workshop/chest), server-authoritative, `user://plots.json` |
| **F. MultiplayerManager** | Done (ENet + WebSocket) | Host/join, player position sync, vitals sync, inventory sync, roster, global/local chat, server-side validation. ENet for desktop, WebSocket for browsers; one transport per server instance |
| **G. UI** | Done | Themed HUD (vitals, biome, progression, icon hotbar, damage numbers), satchel, chat, build palette, vocation picker, lobby, pause menu |
| Pause menu | Done | Esc opens Resume / Settings / Controls / Players / Quit to Menu / Quit Game. Settings are the lobby's (`settings.cfg`, same ranges and defaults), Controls is generated from `InputMap` at runtime, Players mirrors `Main.get_roster()`. Pauses the SceneTree only OFFLINE; a networked peer keeps simulating and shows "Paused (local)". Escape closes chat, satchel or build mode first, and never opens the menu on top of them |
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
  'test_audio','test_chat','test_combat','test_gathering','test_holding','test_inventory',
  'test_isolation','test_limbs','test_lobby','test_lore','test_models','test_movement',
  'test_movement_block','test_network','test_pause','test_player','test_plots','test_rig',
  'test_save','test_sync','test_ui','test_vocation'
)
foreach ($suite in $suites) {
  & $godot --headless --path . --script "res://tests/$suite.gd"
  if ($LASTEXITCODE -ne 0) { throw "suite failed: $suite" }
}
```

Current counts: `test_audio` 78, `test_chat` 24, `test_combat` 38, `test_gathering` 38,
`test_holding` 24, `test_inventory` 31, `test_isolation` 22, `test_limbs` 15,
`test_lobby` 98, `test_lore` 65, `test_models` 40, `test_movement` 30,
`test_movement_block` 15, `test_network` 41, `test_pause` 76, `test_player` 20,
`test_plots` 86, `test_rig` 48, `test_save` 58, `test_sync` 68, `test_ui` 51,
`test_vocation` 70 - **1036 assertions**.

### Continuous integration

[![Tests](https://github.com/podkarpacie/Shroomlands/actions/workflows/tests.yml/badge.svg)](https://github.com/podkarpacie/Shroomlands/actions/workflows/tests.yml)

[`.github/workflows/tests.yml`](.github/workflows/tests.yml) runs on every push to `main` and
every pull request: it downloads the official Godot 4.7.2 Linux binary (cached between runs),
does one `--import` pass because a fresh checkout has no `.godot/` cache, then runs the same
22 suites. `tests/test_env.gd` is skipped - it is the isolation helper and exits 1 when
run on its own. The job fails on a non-zero exit **or** a `FAIL` line, and prints the per-suite
`PASS` counts plus the total (1036). It needs no secrets, no export templates and no network
access beyond the Godot release download.

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
  core/                  Lore, EventBus, Audio, Game, SaveSystem, Main (autoloads + entry scene)
  multiplayer/           Network.gd (ENet / WebSocket abstraction)
  player/                PlayerController, PlayerStats, PlayerAnimator, SwingWeapon, HeldItem
  systems/               Gathering, Inventory, Combat, Plot
  ui/                    HUD, InventoryUI, ChatUI, VocationUI, LobbyUI, PauseMenu, BuildMode
  world/                 MushroomNode, Enemy, PlotSign, VerdantBloom
resources/               MultiplayerSynchronizer replication configs
tests/                   22 headless suites, net_harness, capture_frame, network proofs
tools/                   export_all, run_server, serve_web, run_two_clients,
                         generate_audio, server bootstrap
docs/                    MVP_SPEC.md, HOSTING.md
addons/godot_ai/         editor-only MCP plugin; never exported
build/                   export output (gitignored)
```

## 3D models

Five glTF 2.0 models live in `assets/models/` and the scenes use them (see
[Wiring them in](#wiring-them-in)). Their Blockbench sources are in `assets/models/source/`
(`.gdignore`d, so Godot does not import them); the rigged player's editable source is
`assets/models/source/player_rigged.bbmodel`. Each `.gltf` is self-contained: its buffer and
texture are embedded as base64, and the sidecar `<name>_0.png` plus the generated `.import`
files sit next to it.

| File | Height | Geometry | Contents |
| --- | --- | --- | --- |
| `assets/models/player_rigged.gltf` | 1.80 m | 21 boxes, 252 triangles, 20 bones | rigged mushroom humanoid: crimson domed cap, cream stem body, arms/hands, dark eyes; six keyframed clips (`idle`, `walk`, `run`, `attack`, `draw`, `holster`) |
| `assets/models/player.gltf` | 1.80 m | 15 boxes, 180 triangles | static pre-rig mushroom humanoid; no scene instantiates it any more, `player_rigged.gltf` replaced it |
| `assets/models/blightling.gltf` | 1.50 m | 15 boxes, 180 triangles | hostile fungal creature: squat olive body, violet thorned cap, glowing orange eyes, claws |
| `assets/models/glowcap.gltf` | 0.57 m | 10 boxes, 120 triangles | small teal-capped glowing mushroom, cream stem |
| `assets/models/emberstem.gltf` | 0.74 m | 8 boxes, 96 triangles | orange conical cap, cream stem, small skirt ring |

Heights are metres: Blockbench works in 16-unit blocks, so 16 units = 1 m and the glTF needs no
scaling on import.

### How they were produced

Blockbench **5.2.2** (`C:\Users\Acer\Tools\Blockbench\Blockbench_5.2.2_portable.exe`) driven by
the `blockbench-mcp` bridge on `127.0.0.1:8787` — keep the Blockbench window open while it runs.
Each model is a `free`-format project built from cubes, then textured and exported entirely
through the bridge: `pack_uv` (one UV island per cube) → `create_texture` (a single 16 px-wide
texture, auto-grown by the pack) → `detail_cubes` (per-cube colour map plus glow regex, so no
face is left untextured) → `export_model` with the `gltf` codec (embedded buffer and texture).

`player_rigged.gltf` is the exception: it is a rigged project, not a set of loose cubes. Its
20-bone skeleton has six keyframed clips (`idle`, `walk`, `run`, `attack`, `draw`, `holster`)
authored in Blockbench. The exporter writes **no skin** (`skins=0`): the bones are plain nodes
and each cube mesh is parented to the bone that drives it, so the animation is rigid per
segment — a blocky, Minecraft-like rig rather than a deforming one. That is also why the club
can follow a bone with a plain transform copy instead of a `BoneAttachment3D`. The editable
source is `assets/models/source/player_rigged.bbmodel`.

### Regeneration recipe

`<name>` is `player`, `blightling`, `glowcap` or `emberstem`; cube coordinates are Blockbench
units, so 16 = 1 m. `player_rigged` is the rigged exception described above, not this static
recipe. Every call is a `blockbench-mcp` tool:

```
new_project({ format: "free", name: "<name>" })

# Shape: add_cubes({ cubes: [...] }) for the masses, add_mesh / add_hollow_volume for domed caps,
# thorns and claws. Keep the total height from the table above (16 units = 1 m).

pack_uv({ cubes: "all", padding: 1, auto_resize: true })      # REQUIRED before texturing
create_texture({ name: "<name>_0", fill: "<base colour>" })   # project size, grown by pack_uv
detail_cubes({                                                # smooth per-cube colour, no gaps
  cubes: "all",
  texture: "<name>_0",
  base: "<base colour>",
  colors: [
    { match: "stem|body", color: "<light colour>" },
    { match: "cap|thorns", color: "<accent colour>" }
  ],
  glow_regex: "glow_[abc]$"                                   # emissive cells (glowcap)
})
check_model()                                                 # untextured faces, bad UVs, z-fighting

export_model({
  path: "C:/Users/Acer/Desktop/AI/Shroomlands/assets/models/<name>.gltf",
  codec: "gltf"                                               # embeds buffer + texture
})
```

Re-import and check the log for errors:

```powershell
& ".\Godot Engine Latest\Godot_v4.7.2-stable_win64_console.exe" --headless --editor --quit --path "."
```

Commit the four files together: `<name>.gltf`, `<name>.gltf.import`, `<name>_0.png` and
`<name>_0.png.import`.

### Wiring them in

- **Player** (`player.tscn`): `assets/models/player_rigged.gltf` is instanced as `Model/Visual`,
  with `PlayerAnimator` as a sibling (`Animator`) driving its `AnimationPlayer`. `Model` stays the
  node the controller turns. The model faces -Z, the game's forward, and stands on the collision
  capsule.
- **Blightling** (`enemy.tscn`): `blightling.gltf` is instanced as `Model/Visual`; `Model` stays
  the node the enemy shrinks on death. It has no rig and still uses the procedural
  `LimbAnimator`.
- **Enemy hit flash** (`Enemy.gd`): one private material copy per creature, flashed through
  emission (an albedo tint is invisible on a texture).
- **Gatherable mushrooms** (`MushroomNode.gd`): a species uses `assets/models/<mushroom_id>.gltf`
  when that file exists, so a new species only needs its model dropped in. A species without
  one keeps the primitive stem + cap, tinted by rarity.
- **Scenery** (`VerdantBloom.gd`): groves of giant glowcap / emberstem plus a ring of far
  landmarks, drawn as a few `MultiMeshInstance3D` (each model merged into one mesh by
  `ModelGlow.merge`), so ~125 mushrooms cost a handful of draw calls. No collision, as before.
- **Glow** (`ModelGlow.gd`): the models have no emissive channel, so the cap pieces (nodes
  named `cap*` / `glow*`) get a material copy that uses the albedo as emission. Name a cap
  piece that way in Blockbench and it glows; the environment's bloom does the rest.
- **Player animation** (`PlayerAnimator.gd`): the imported rig's six clips are the whole
  animation. `idle`/`walk`/`run` loop as gaits and are chosen from the distance the body
  actually moved between physics ticks, not from `velocity`, so a remote player that only
  receives a position still animates. `attack` is a one-shot triggered on the owner by
  `CombatSystem` and on every other peer by the replicated `swing_seq` counter. `draw` and
  `holster` are real equip animations: `held_item` entering or leaving the hand plays them
  (debounced so scrolling the hotbar does not rattle the arm), and both are replicated, so
  other peers see the prop come out and go away. The importer brings every clip in as
  `LOOP_NONE`, so the three gaits are switched to `LOOP_LINEAR` at runtime. Footfalls are
  reported on `stepped` for `AudioManager`, at fixed phases of the gait clip.
- **Enemy animation** (`LimbAnimator.gd`): the blightling is still a rigid cube model with no
  rig, so its limbs swing about hip and shoulder pivots taken from each mesh's bounds:
  walk/run, idle breathing, jump tuck, landing squash, forward lean and a lagging cap. It
  overlays transient bite and flinch poses triggered by `Enemy` / `CombatSystem`, and reads
  movement from position, so remote creatures animate too. Name limbs `leg_l`, `leg_r`,
  `arm_l`, `arm_r`, `hand_l`, `hand_r`. Do not put it back on the player: it would fight
  `PlayerAnimator`.
- **Club** (`SwingWeapon.gd`): a procedural mycelium club, parented beside the model and copying
  the animated right-hand bone (`hand_right2`) every frame, so it follows the authored
  `walk`/`run`/`attack` arm swing exactly without joining the glTF mesh count.

### UI and item presentation

- `UITheme.gd` installs one runtime theme (Inter, palette, panels, bars, buttons, tooltips) on
  the root Window. The HUD, satchel, chat, build palette, vocation picker and lobby all read
  from it, so they cannot drift apart. Inter is SIL Open Font Licensed; the licence text ships
  in `assets/fonts/OFL.txt`.
- `ItemVisuals.gd` owns the presentation of every item: a procedural 3D model for resources
  and the species without a glTF, plus the icon lookup. `tools/render_item_icons.gd` renders
  those same models into `assets/ui/items/*.png` and `assets/ui/build/*.png`; the satchel's
  `ItemPreview.gd` rotates the live model in a SubViewport (icons on headless runs).
- Combat exposes a real `AttackHitbox` (`BoxShape3D`, mask `16 | 32`) and every creature has a
  `Hurtbox` Area3D on layer 32. Hits apply knockback, stagger, a particle/light burst, camera
  shake and floating damage numbers.

### Look and feel

- **Lighting** (`verdant_bloom.tscn`): ACES tonemapping, bloom, SSAO and light-shaft volumetric
  fog on Forward+, a 3/4 sun with soft shadows. SSAO and volumetric fog are Forward+ only; on
  Compatibility the scene still renders, a little brighter and flatter.
- **Ground** (`assets/shaders/ground.gdshader`): world-space moss, spore patches and mycelium
  threads from two noise textures, shared by the plain and the mounds so there are no seams.
- **Spores**: slow motes in a box that follows the local player.

`tests/test_movement.gd` pins the movement feel: acceleration and braking, the sprint-jump fix,
coyote time, jump buffer, variable jump height, camera zoom/FOV, and the imported bone animation
(legs and arms swing from the `walk`/`run` clips).

`tests/test_rig.gd` covers the rig itself: the six clips, gait selection from position deltas,
`attack` from `swing_seq`, `draw`/`holster` from `held_item`, the hand bones the club and prop
hang from, and a body nobody owns animating from positions alone. `tests/test_pause.gd` covers
the pause menu contract.

`tests/test_models.gd` checks all of the above, including model height, foot position and facing.

## Audio

Every sound is generated, not sourced. `tools/generate_audio.py` writes `assets/audio/*.wav` —
mono 16-bit PCM at 44.1 kHz — using only the Python standard library. It is deterministic: each
cue seeds its own `random.Random` from its file name, no clock or OS state is read, and the WAV
header carries no timestamp, so running it twice leaves every file byte-identical. One-shots are
peak-normalised to about -3 dBFS with 10 ms fades at both ends; `ambient_mycelia.wav` is built as
a seamless loop. Regenerate with `python tools/generate_audio.py`.

The mixer is `default_bus_layout.tres`: **Master** (0 dB) with **Music** (-12 dB) and **SFX**
(-4 dB) sending into it. The `Audio` autoload (`scripts/core/AudioManager.gd`) owns eight SFX
voices plus one ambient player, resolves a cue by id (`Audio.play_sfx(&"gather")`) and listens
to `EventBus` for hits, gathering, pickups, level-ups, death, building and vocation events. The
ambient bed starts when `main.tscn` (group `main`) enters the tree and stops when the last world
leaves, so the lobby is silent apart from the UI click.

The lobby's settings panel has **Music volume** and **SFX volume** sliders (0-100 %). They apply
live through `Audio.set_music_volume()` / `Audio.set_sfx_volume()` and persist to
`user://settings.cfg`; 0 % is a floored -80 dB, never `-inf`. The pause menu's Settings page is
the same panel — it calls the lobby's `read_settings`/`write_settings` helpers, so both views
share one file, one set of ranges and one set of defaults.

Headless runs — CI, the dedicated server — keep audio output disabled on purpose: there is no
listener, and a player still sounding when the process quits is reported by Godot 4.7 as a
leaked resource (`godotengine/godot#76745`). `Audio.set_output_enabled(true)` turns the pool
back on for tools and tests.

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
6. **Temporary art.** The five glTF models are stopgaps (see [3D models](#3d-models)); species
   without a model still render primitives, and the rig is unskinned, so a joint cannot bend
   the cubes it drives — the export animates rigid segments. One ground mound still z-fights
   slightly.
7. **No voice chat**, full skill trees, advanced crafting, raids/endgame, factions or the
   full Great Blight story. Vocation choice exists, but the trees behind it do not.
8. **No server browser or accounts.** Direct host/port only; no authentication, no
   character server, no anti-cheat. The server relays what each peer reports for
   player position, gold, inventory, vitals and discoveries, so there is no server-side
   validation of that state.
9. **Plot persistence is a JSON file** (`user://plots.json`) owned by one server process.
   No database, no multi-instance coordination, no backups.
10. **Windows-only server preset.** There is no Linux/macOS export preset in the repo.
11. **Scale is unproven.** `MAX_PLAYERS` is 32 and the code enforces it, but the tests and
    smoke runs cover two clients.
12. **Web build is single-threaded** (nothreads variant, no GDExtension). It boots and
    renders, but expect lower performance than desktop.
