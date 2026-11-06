# Blender art pipeline

Headless, reproducible source for the eleven mushroom models. No GUI, no GPU,
no Blockbench and no MCP session — just `bpy` and the bundled glTF exporter.

Tested with **Blender 4.5.15 LTS** on Linux (`/opt/blender-4.5.15`).
Godot 4.7.2 is the consumer.

## Commands

```bash
# Build all eleven assets/models/mushrooms/<id>.gltf
blender --background --factory-startup --python tools/blender/mushroom_forge.py

# One species only
blender --background --factory-startup --python tools/blender/mushroom_forge.py -- --only fury

# Hazards (Spore Bloom) into assets/models/hazards/
blender --background --factory-startup --python tools/blender/mushroom_forge.py -- --set hazards
python3 tools/blender/validate_models.py --set hazards
blender --background --factory-startup --python tools/blender/render_sheet.py -- --set hazards --out /tmp/hazards.png

# Contract check (plain CPython, exits 1 on failure)
python3 tools/blender/validate_models.py

# Visual contact sheet (Cycles CPU, no display)
blender --background --factory-startup --python tools/blender/render_sheet.py -- --out /tmp/sheet.png

# Reimport and test in the engine
godot4 --headless --path . --import
godot4 --headless --path . --script res://tests/test_models.gd
```

`mushroom_forge.py` writes the glTF itself and then inlines the buffer and the
palette PNG as base64 data URIs. Blender 4.x only exports `GLB` or
`GLTF_SEPARATE`; the game (and the Blockbench-era files) expect one
self-contained `.gltf`, so the separate export is repacked in-process.

## Asset contract

The game code, not the artist, defines what a valid model is:

| Rule | Why |
| --- | --- |
| Mesh nodes named `stem*`, `cap*` or `glow*` | `scripts/world/ModelGlow.gd` treats `cap*`/`glow*` as the emissive cap |
| Exactly one material and one embedded texture | `ModelGlow.merge` bakes surface 0 (body) and surface 1 (cap) into a MultiMesh |
| Feet at y = 0, +Y up | `MushroomNode` and `HeldItem` place the model by its origin |
| Height 0.30–0.85 m (hazards up to 1.00 m) | Matches the harvest collider and the hand/item scale |
| ≤ 400 triangles, one primitive per mesh | Scenery is instanced; the whole set is ~2.1k tris |

`validate_models.py` enforces all of it. Run it before committing; a model that
fails it may still load in Godot and look wrong only in the merged scenery.

## Colours

The palette is a 16×8 PNG, eight 4×4 cells, one material, one texture:

`body · body_dark · cap · cap_dark · cap_light · gill · accent · ember`

Every face samples its cell centre, so the model stays flat-shaded and the
palette survives the glTF round trip byte-for-byte. Colours in `SPECIES` are the
hex values from the original 64×64 Blockbench palettes, so species identity is
preserved.

## Adding or retuning a species

Edit `SPECIES` in `mushroom_forge.py`. Shape knobs, in metres:

```
height  stem_r  cap_r  cap_h  tiers  dome  rings  spots
warts   spikes  veins   halo   droop  bracket  gills  tilt
```

Then run the forge, the validator and the render sheet, look at the sheet, and
`git add` the `.gltf` plus the regenerated `<id>_0.png` texture (Godot extracts
the embedded image on import).

## Hazard set

`--set hazards` builds `assets/models/hazards/` instead of the species models. The Spore Bloom
reuses the same node/material contract (`cap*` parts glow, one embedded palette texture), so
`ModelGlow`, the hitbox and the render sheet all work unchanged; the validator allows it up to
1.00 m and the same 400-triangle budget. Gameplay lives in `scripts/world/SporeBloom.gd`.

## Scope

This pipeline covers the mushroom props. The rigged player and the blightling
are still authored in Blockbench (`assets/models/source/*.bbmodel`); porting
those to Blender would be a separate change, and `test_models.gd` pins the
player at exactly 21 cube meshes and the enemy at 15.
