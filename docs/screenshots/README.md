# Screenshots

Taken from the running game's own viewport (`1280×720`), never from an OS screenshot — this
machine runs Windows at 150 % DPI scaling, where a Win32 capture is a top-left crop of the real
frame (see `AGENTS.md` → *Rules that matter*). They are committed copies of the regenerated
artifacts in `tests/` (those stay `.gitignore`d), so a reviewer can see the game without
installing Godot 4.7.2.

All geometry is **placeholder primitives** (`BoxMesh` / `CapsuleMesh` / `CylinderMesh`) defined
in the `.tscn` files — this repository contains no 3D model files.

| # | Screenshot | Source | What it shows |
| --- | --- | --- | --- |
| 01 | [01-lobby.png](01-lobby.png) | `tests/_capture_lobby.png` | Entry scene: Host / address + Join / Settings / Quit, `v0.1.0` on Godot 4.7.2 |
| 02 | [02-gameplay.png](02-gameplay.png) | `tests/_capture.png` | Verdant Bloom in third person — HP/stamina bars, level, gold, hotbar, mushroom nodes |
| 03 | [03-inventory.png](03-inventory.png) | `tests/_capture_inventory.png` | 6×8 inventory panel with stacks gathered in the run |
| 04 | [04-gathering.png](04-gathering.png) | `tests/_capture_gather.png` | Timed harvest of a mushroom node with its progress feedback |
| 05 | [05-combat.png](05-combat.png) | `tests/_capture_combat.png` | Melee hit on a fungal enemy, damage numbers / HP feedback |
| 06 | [06-death.png](06-death.png) | `tests/_capture_death.png` | Death overlay and respawn path |
| 07 | [07-plots-building.png](07-plots-building.png) | `tests/_capture_plots.png` | Plot row (Plot 1–6, 100 g), owned Plot 5 with fee countdown, build-mode menu |
| 08 | [08-vocation.png](08-vocation.png) | `tests/_capture_vocation.png` | Level-20 vocation picker (Knight / Healer / Harvester / Ranger) |
| 09 | [09-chat.png](09-chat.png) | `tests/_capture_chat.png` | Global / local chat panel driven by `ChatUI` and the server relay |

Regenerate 02–08 with the windowed capture harness (it must **not** run `--headless`):

```powershell
& ".\Godot Engine Latest\Godot_v4.7.2-stable_win64.exe" --path "." --script "res://tests/capture_frame.gd"
```

`01-lobby.png` and `09-chat.png` came from manual windowed runs of the lobby and the chat panel;
no committed script regenerates those two.
