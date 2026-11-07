# Screenshots

Taken from the running game's own viewport (`1280×720`) on Godot 4.7.2, never from an OS
screenshot — this machine runs Windows at 150 % DPI scaling, where a Win32 capture is a top-left
crop of the real frame (see `AGENTS.md` → *Rules that matter*). They are committed copies of the
regenerated artifacts in `tests/` (those stay `.gitignore`d), so a reviewer can see the game
without installing Godot.

Set refreshed for **v0.5.1**. Frames were rendered with the software Vulkan driver, so lighting is
close to, but not identical with, a hardware GPU.

The player, blightling and mushroom scenes use Blockbench-authored glTF models. Hotbar and
satchel item icons are rendered from item models by `tools/render_item_icons.gd`, and the
satchel preview rotates the live model in a SubViewport.

| # | Screenshot | Source | What it shows |
| --- | --- | --- | --- |
| 01 | [01-lobby.png](01-lobby.png) | `tests/_review_lobby.png` | Entry scene: New Game / Host / Join / Settings / Quit, `v0.5.1` |
| 02 | [02-gameplay.png](02-gameplay.png) | `tests/_capture.png` | Mycoria at dusk in first person — vitals, progression, run line, compact party card, icon hotbar |
| 03 | [03-inventory.png](03-inventory.png) | `tests/_capture_inventory.png` | Satchel with item icons, rotating model preview, weapon detail and sorting |
| 04 | [04-gathering.png](04-gathering.png) | `tests/_capture_gather.png` | Timed harvest of a mushroom node with its prompt and progress bar |
| 05 | [05-combat.png](05-combat.png) | `tests/_capture_combat.png` | Melee hit on a blightling — swing, damage number, enemy HP bar |
| 06 | [06-death.png](06-death.png) | `tests/_capture_death.png` | Death overlay and respawn path |
| 07 | [07-plots-building.png](07-plots-building.png) | `tests/_capture_plots.png` | Plot row, fee status and the build palette |
| 08 | [08-vocation.png](08-vocation.png) | `tests/_capture_vocation.png` | Level-20 vocation picker (Knight / Healer / Harvester / Ranger) |
| 09 | [09-chat.png](09-chat.png) | `tests/_review_chat2.png` | Chat panel in a night layer, with the lamp/party HUD |
| 10 | [10-journal.png](10-journal.png) | `tests/_review_journal2.png` | Pause menu → Journal: a found chapter with its faction clue, the rest hidden |
| 11 | [11-skills.png](11-skills.png) | `tests/_review_skills2.png` | Pause menu → Skills: four action skills, perks and the worn gear slots |
| 12 | [12-workshop.png](12-workshop.png) | `tests/_review_workshop2.png` | Workshop recipes, material costs and the gold fee |
| 13 | [13-layer1.png](13-layer1.png) | `tests/_review_layer1_structure.png` | Layer 1 hut in fog — the new twilight dressing |
| 14 | [14-layer3.png](14-layer3.png) | `tests/_review_layer3_lamp.png` | Layer 3 with the spore-lamp on: the beam the dark hides without it |
| 15 | [15-layer4.png](15-layer4.png) | `tests/_review_layer4.png` | Layer 4 dungeon entrance, grain and the Choir stalker's layer |

Regenerate 02–08 with the windowed capture harness (it must **not** run `--headless`):

```bash
xvfb-run -a godot4 --path . --script res://tests/capture_frame.gd
```

The scenery/UI frames come from the small scripts in this set:

```bash
xvfb-run -a godot4 --path . --script res://tools/capture/lobby.gd          # 01
xvfb-run -a godot4 --path . --script res://tools/capture/review.gd        # 09-12, 14
xvfb-run -a godot4 --path . --script res://tools/capture/layer1.gd    # 13
```
