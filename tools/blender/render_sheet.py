#!/usr/bin/env python3
"""Render a contact sheet of the shipped mushroom or hazard models.

Headless Cycles CPU, no GPU and no display:

    blender --background --factory-startup --python tools/blender/render_sheet.py -- --out /tmp/sheet.png
    blender --background --factory-startup --python tools/blender/render_sheet.py -- --set hazards --out /tmp/hazards.png

Useful after regenerating models: the sheet is the visual half of the check,
``validate_models.py`` is the numeric half.
"""

import math
import os
import sys

import bpy
import mathutils

SETS = {
    "mushrooms": (
        ["konop", "shitake", "motoko", "borowik", "kazar", "kora",
         "altak", "bedak", "celtus", "pesta", "fury"],
        os.path.join("assets", "models", "mushrooms"),
    ),
    "hazards": (["spore_bloom"], os.path.join("assets", "models", "hazards")),
}
CELL_X = 0.95
CELL_Z = 0.88
RES_X = 1920
RES_Y = 820

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def arg(name, default):
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return argv[argv.index(name) + 1] if name in argv else default


def main():
    out = arg("--out", "/tmp/opencode/mushroom_sheet.png")
    set_name = arg("--set", "mushrooms")
    ids, relative_dir = SETS[set_name]
    model_dir = os.path.join(REPO, relative_dir)
    cols = min(6, len(ids))

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene

    min_x, max_x = math.inf, -math.inf
    min_z, max_z = math.inf, -math.inf

    for index, mid in enumerate(ids):
        before = set(bpy.data.objects)
        bpy.ops.import_scene.gltf(filepath=os.path.join(model_dir, "%s.gltf" % mid))
        new = [o for o in bpy.data.objects if o not in before]
        roots = [o for o in new if o.parent is None]
        col, row = index % cols, index // cols
        for root in roots:
            root.location.x += col * CELL_X
            root.location.z += (1 - row) * CELL_Z
        # matrix_world is stale until the depsgraph updates after a move.
        bpy.context.view_layer.update()

        for obj in new:
            if obj.type != 'MESH':
                continue
            for corner in obj.bound_box:
                point = obj.matrix_world @ mathutils.Vector(corner)
                min_x, max_x = min(min_x, point.x), max(max_x, point.x)
                min_z, max_z = min(min_z, point.z), max(max_z, point.z)

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
        min_z = min(min_z, (1 - row) * CELL_Z - 0.12)

    centre_x = (min_x + max_x) / 2.0
    centre_z = (min_z + max_z) / 2.0
    content_w = max(max_x - min_x, 0.4)
    content_h = max(max_z - min_z, 0.4)
    ortho = max(content_w, content_h * RES_X / RES_Y) * 1.18

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = 'ORTHO'
    cam_data.ortho_scale = ortho
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    cam.location = (centre_x, -9.0, centre_z + 0.9)
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
    key.location = (centre_x - 3.0, -6.0, centre_z + 5.0)
    key.rotation_euler = (math.radians(62), 0, math.radians(-25))
    scene.collection.objects.link(key)

    rim = bpy.data.objects.new("Rim", bpy.data.lights.new("Rim", 'AREA'))
    rim.data.energy = 260
    rim.data.size = 5
    rim.location = (centre_x + 4.0, 2.0, centre_z + 3.0)
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
    scene.render.resolution_x = RES_X
    scene.render.resolution_y = RES_Y
    scene.render.image_settings.file_format = 'PNG'
    scene.render.filepath = out
    bpy.ops.render.render(write_still=True)
    print("RENDERED", out)


if __name__ == "__main__":
    main()
