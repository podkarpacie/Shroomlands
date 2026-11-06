#!/usr/bin/env python3
"""Render a contact sheet of the shipped mushroom models.

Headless Cycles CPU, no GPU and no display:

    blender --background --factory-startup --python tools/blender/render_sheet.py -- --out /tmp/sheet.png

Useful after regenerating models with ``mushroom_forge.py``: the sheet is the
visual half of the check, ``validate_models.py`` is the numeric half.
"""

import math
import os
import sys

import bpy
import mathutils

IDS = ["konop", "shitake", "motoko", "borowik", "kazar", "kora",
       "altak", "bedak", "celtus", "pesta", "fury"]
COLS = 6
CELL_X = 0.95
CELL_Z = 0.88

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MODEL_DIR = os.path.join(REPO, "assets", "models", "mushrooms")


def arg(name, default):
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return argv[argv.index(name) + 1] if name in argv else default


def main():
    out = arg("--out", "/tmp/opencode/mushroom_sheet.png")
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene

    for index, mid in enumerate(IDS):
        path = os.path.join(MODEL_DIR, "%s.gltf" % mid)
        before = set(bpy.data.objects)
        bpy.ops.import_scene.gltf(filepath=path)
        new = [o for o in bpy.data.objects if o not in before]
        roots = [o for o in new if o.parent is None]
        col, row = index % COLS, index // COLS
        for root in roots:
            root.location.x += col * CELL_X
            root.location.z += (1 - row) * CELL_Z

        # Small label under each model, facing the camera.
        curve = bpy.data.curves.new(type="FONT", name="label_" + mid)
        curve.body = mid
        curve.align_x = 'CENTER'
        curve.size = 0.075
        label = bpy.data.objects.new("label_" + mid, curve)
        scene.collection.objects.link(label)
        label.location = (col * CELL_X, -0.34, (1 - row) * CELL_Z - 0.075)
        label.rotation_euler = (math.radians(90), 0, 0)
        mat = bpy.data.materials.new("labelmat_" + mid)
        mat.use_nodes = True
        mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.75, 0.78, 0.70, 1)
        label.data.materials.append(mat)

    width = (COLS - 1) * CELL_X
    centre_x = width / 2.0
    centre_z = CELL_Z / 2.0

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = 'ORTHO'
    cam_data.ortho_scale = 6.35
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    cam.location = (centre_x, -9.0, centre_z + 1.0)
    target = mathutils.Vector((centre_x, 0.0, centre_z))
    direction = target - cam.location
    cam.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
    scene.camera = cam

    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", 'SUN'))
    sun.data.energy = 3.4
    sun.data.angle = math.radians(12)
    sun.rotation_euler = (math.radians(52), 0, math.radians(38))
    scene.collection.objects.link(sun)

    key = bpy.data.objects.new("Key", bpy.data.lights.new("Key", 'AREA'))
    key.data.energy = 420
    key.data.size = 7
    key.location = (centre_x - 3.0, -6.0, 5.0)
    key.rotation_euler = (math.radians(62), 0, math.radians(-25))
    scene.collection.objects.link(key)

    rim = bpy.data.objects.new("Rim", bpy.data.lights.new("Rim", 'AREA'))
    rim.data.energy = 260
    rim.data.size = 5
    rim.location = (centre_x + 4.0, 2.0, 3.0)
    rim.rotation_euler = (math.radians(75), 0, math.radians(160))
    scene.collection.objects.link(rim)

    world = bpy.data.worlds.new("World")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.045, 0.06, 0.05, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.8

    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = 64
    scene.cycles.use_denoising = True
    scene.render.resolution_x = 1920
    scene.render.resolution_y = 820
    scene.render.film_transparent = False
    scene.render.image_settings.file_format = 'PNG'
    scene.render.filepath = out
    bpy.ops.render.render(write_still=True)
    print("RENDERED", out)


if __name__ == "__main__":
    main()
