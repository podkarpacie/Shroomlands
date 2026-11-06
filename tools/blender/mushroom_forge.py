#!/usr/bin/env python3
"""Headless Blender forge for Shroomlands mushroom models.

Builds one low-poly, palette-textured glTF per species into
``assets/models/mushrooms/<id>.gltf`` using only bpy -- no GUI, no add-ons
beyond the bundled glTF exporter.

    blender --background --factory-startup --python tools/blender/mushroom_forge.py

Why this exists: the shipped species models came from Blockbench on Windows,
which left no editable source in the repo. This script is the source of truth
and runs on any Linux/CI box with Blender installed.

Asset contract enforced by ``tools/blender/validate_models.py`` (and by the
game's own code):
  * one mesh node per part, every node name starts with ``stem`` or ``cap``
    (``ModelGlow`` treats ``cap*``/``glow*`` as the emissive cap)
  * exactly one material and one embedded palette texture per model, so
    ``ModelGlow.merge`` can bake a two-surface MultiMesh
  * feet at z = 0, +Z up, roughly 0.35-0.75 m tall
  * a handful of triangles (the whole set should stay in the low thousands)
"""

import base64
import json
import math
import os
import shutil
import sys
import tempfile

import bpy

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_DIR = os.path.join(REPO, "assets", "models", "mushrooms")

PALETTE_COLS = 4
PALETTE_ROWS = 2
PALETTE_CELL = 16
PALETTE_W = PALETTE_COLS * PALETTE_CELL
PALETTE_H = PALETTE_ROWS * PALETTE_CELL

# Slots, in order. Every model uses the same 8-slot palette so the texture
# layout is identical across species.
BODY, BODY_DARK, CAP, CAP_DARK, CAP_LIGHT, GILL, ACCENT, EMBER = range(8)


def hex_rgb(value):
    """Hex -> 0..1 sRGB.

    Blender's byte-image ``pixels`` are normalised sRGB bytes (not scene
    linear), so no transfer-function conversion belongs here; doing one
    darkens the exported palette twice.
    """
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


# ---------------------------------------------------------------------------
# Species table
# ---------------------------------------------------------------------------
# Colours are lifted from the shipped 64x64 palette textures so every species
# keeps the identity players already know. Shape params are in metres.
#
#   height   total height, feet (z=0) to cap top
#   stem_r   stem radius at the base        cap_r   widest cap radius
#   cap_h    cap height                     tiers   stacked cap rings
#   dome     1 = tall dome, 0 = flat disc   rings   stem rings
#   spots    cap speckles
#   warts    blocky warts (bedak)           spikes  rim spikes (fury)
#   veins    red veins on the cap (kazar)   halo    separate flat halo ring
#   droop    lower the outer cap ring       tilt    cap lean, radians
SPECIES = {
    "konop": dict(
        body="#d8d2b4", body_dark="#b8b190", cap="#7aae75", cap_dark="#4d6f4a",
        cap_light="#9ccb96", gill="#8f8a6a", accent="#e6e2c8", ember="#b6d8a8",
        height=0.52, stem_r=0.075, cap_r=0.215, cap_h=0.135, tiers=3,
        dome=0.95, rings=2, spots=4,
    ),
    "shitake": dict(
        body="#e3d9bd", body_dark="#c3b795", cap="#7f5837", cap_dark="#543a24",
        cap_light="#a97b52", gill="#d8c7a4", accent="#efe7cf", ember="#c69a6a",
        height=0.40, stem_r=0.052, cap_r=0.285, cap_h=0.085, tiers=2,
        dome=0.32, rings=1, spots=0, gills=True,
    ),
    "motoko": dict(
        body="#cfd6d8", body_dark="#aeb9bb", cap="#9fb6bd", cap_dark="#737c7d",
        cap_light="#cfd6d8", gill="#8b9799", accent="#eaf0f1", ember="#bcd2d8",
        height=0.36, stem_r=0.044, cap_r=0.155, cap_h=0.105, tiers=2,
        dome=1.0, rings=1, spots=0,
    ),
    "borowik": dict(
        body="#e8dcc0", body_dark="#c8b998", cap="#c96f2e", cap_dark="#945122",
        cap_light="#e09050", gill="#e6d5b2", accent="#6f3c18", ember="#ffb066",
        height=0.60, stem_r=0.102, cap_r=0.295, cap_h=0.185, tiers=3,
        dome=0.9, rings=2, spots=0,
    ),
    "kazar": dict(
        body="#d9c9a8", body_dark="#b9a785", cap="#ae2232", cap_dark="#791723",
        cap_light="#d04450", gill="#a58e6c", accent="#f0c9a0", ember="#ff6a5a",
        height=0.58, stem_r=0.074, cap_r=0.235, cap_h=0.165, tiers=3,
        dome=1.0, rings=2, veins=True,
    ),
    "kora": dict(
        body="#cbbd9a", body_dark="#8a7551", cap="#65553b", cap_dark="#574a33",
        cap_light="#8f7a58", gill="#b8a684", accent="#e0d3b2", ember="#a89068",
        height=0.55, stem_r=0.088, cap_r=0.245, cap_h=0.105, tiers=4,
        dome=0.42, rings=4, spots=0, bracket=True,
    ),
    "altak": dict(
        body="#cfc6e0", body_dark="#a99ec2", cap="#5b3586", cap_dark="#3d2259",
        cap_light="#7d4fae", gill="#9b8fb4", accent="#d9c8ea", ember="#a878e0",
        height=0.70, stem_r=0.062, cap_r=0.185, cap_h=0.235, tiers=4,
        dome=1.0, rings=2, spots=2, droop=0.012,
    ),
    "bedak": dict(
        body="#cfcfc4", body_dark="#a8a89a", cap="#6f6f5f", cap_dark="#4f4f43",
        cap_light="#8e8e7a", gill="#9a9a85", accent="#3f3f36", ember="#b9bf7a",
        height=0.44, stem_r=0.092, cap_r=0.235, cap_h=0.125, tiers=2,
        warts=7, rings=2, spots=0,
    ),
    "celtus": dict(
        body="#f4efe0", body_dark="#d9d1bb", cap="#e5e1ca", cap_dark="#cdc6b1",
        cap_light="#fffdf2", gill="#d8d2be", accent="#ffffff", ember="#fff6c8",
        height=0.72, stem_r=0.055, cap_r=0.265, cap_h=0.105, tiers=2,
        dome=0.75, rings=2, halo=True,
    ),
    "pesta": dict(
        body="#cfd3a8", body_dark="#a8ad82", cap="#a9b032", cap_dark="#808526",
        cap_light="#c3c95a", gill="#8e9358", accent="#4d5020", ember="#d8e070",
        height=0.56, stem_r=0.078, cap_r=0.255, cap_h=0.130, tiers=3,
        dome=0.55, rings=2, spots=5, droop=0.045,
    ),
    "fury": dict(
        body="#3a2a26", body_dark="#241816", cap="#881b0f", cap_dark="#5e0f08",
        cap_light="#c2432a", gill="#6b2418", accent="#ffb028", ember="#ff7a1a",
        height=0.64, stem_r=0.084, cap_r=0.245, cap_h=0.195, tiers=3,
        dome=1.0, rings=3, spikes=7, veins=True,
    ),
}


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------
def ring(n, radius, z, rot=0.0):
    return [
        (radius * math.cos(rot + math.tau * i / n),
         radius * math.sin(rot + math.tau * i / n), z)
        for i in range(n)
    ]


class MeshBuilder:
    """Accumulates verts/faces/slots, then bakes one Blender object."""

    def __init__(self, name):
        self.name = name
        self.verts = []
        self.faces = []
        self.slots = []

    def add_frustum(self, z0, z1, r0, r1, n=8, rot=0.0,
                    side=BODY, top=None, bottom=None):
        base = len(self.verts)
        self.verts += ring(n, max(r0, 1e-4), z0, rot)
        self.verts += ring(n, max(r1, 1e-4), z1, rot)
        for i in range(n):
            j = (i + 1) % n
            self.faces.append((base + i, base + j, base + n + j, base + n + i))
            self.slots.append(side)
        if top is not None:
            self.faces.append(tuple(base + n + i for i in range(n)))
            self.slots.append(top)
        if bottom is not None:
            self.faces.append(tuple(base + i for i in range(n - 1, -1, -1)))
            self.slots.append(bottom)

    def add_box(self, cx, cy, cz, sx, sy, sz, slot=BODY, rotz=0.0):
        base = len(self.verts)
        corners = []
        for dz in (-1, 1):
            for dy in (-1, 1):
                for dx in (-1, 1):
                    x, y = dx * sx * 0.5, dy * sy * 0.5
                    c, s = math.cos(rotz), math.sin(rotz)
                    corners.append((cx + x * c - y * s, cy + x * s + y * c, cz + dz * sz * 0.5))
        self.verts += corners
        # Counter-clockwise seen from outside, so glTF normals face out and
        # Godot's backface culling keeps them.
        quads = [
            (base + 0, base + 2, base + 3, base + 1),  # bottom (-Z)
            (base + 4, base + 5, base + 7, base + 6),  # top (+Z)
            (base + 0, base + 1, base + 5, base + 4),  # -Y
            (base + 2, base + 6, base + 7, base + 3),  # +Y
            (base + 0, base + 4, base + 6, base + 2),  # -X
            (base + 1, base + 3, base + 7, base + 5),  # +X
        ]
        self.faces += quads
        self.slots += [slot] * 6

    def add_pyramid(self, cx, cy, cz, radius, height, slot=ACCENT, n=4, rot=0.0):
        base = len(self.verts)
        self.verts += ring(n, radius, cz, rot)
        self.verts.append((cx, cy, cz + height))
        for i in range(n):
            j = (i + 1) % n
            self.faces.append((base + i, base + j, base + n))
            self.slots.append(slot)
        self.faces.append(tuple(base + i for i in range(n - 1, -1, -1)))
        self.slots.append(slot)

    def add_annulus(self, z, r_in, r_out, n=8, slot=CAP, rot=0.0):
        base = len(self.verts)
        self.verts += ring(n, r_in, z, rot) + ring(n, r_out, z, rot)
        for i in range(n):
            j = (i + 1) % n
            # +Z normal: inner -> outer -> outer -> inner.
            self.faces.append((base + i, base + n + i, base + n + j, base + j))
            self.slots.append(slot)

    def build(self, collection):
        if not self.faces:
            return None
        mesh = bpy.data.meshes.new(self.name)
        mesh.from_pydata(self.verts, [], self.faces)
        mesh.validate(verbose=False)
        uv = mesh.uv_layers.new(name="UVMap")
        for poly, slot in zip(mesh.polygons, self.slots):
            for li in poly.loop_indices:
                uv.data[li].uv = slot_uv(slot)
            poly.use_smooth = False
        obj = bpy.data.objects.new(self.name, mesh)
        collection.objects.link(obj)
        return obj


def slot_uv(slot):
    col, row = slot % PALETTE_COLS, slot // PALETTE_COLS
    return ((col + 0.5) / PALETTE_COLS, (row + 0.5) / PALETTE_ROWS)


# ---------------------------------------------------------------------------
# Texture + material
# ---------------------------------------------------------------------------
def build_palette(spec):
    img = bpy.data.images.new("0", PALETTE_W, PALETTE_H, alpha=True)
    px = [0.0] * (PALETTE_W * PALETTE_H * 4)
    colors = [
        spec["body"], spec["body_dark"], spec["cap"], spec["cap_dark"],
        spec["cap_light"], spec["gill"], spec["accent"], spec["ember"],
    ]
    for slot, value in enumerate(colors):
        rgb = hex_rgb(value)
        col, row = slot % PALETTE_COLS, slot // PALETTE_COLS
        for y in range(PALETTE_CELL):
            for x in range(PALETTE_CELL):
                i = ((row * PALETTE_CELL + y) * PALETTE_W + col * PALETTE_CELL + x) * 4
                px[i:i + 4] = [rgb[0], rgb[1], rgb[2], 1.0]
    img.pixels = px
    img.filepath_raw = "/tmp/0.png"
    img.file_format = 'PNG'
    img.pack()
    return img


def build_material(img):
    mat = bpy.data.materials.new("mushroom")
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    bsdf = nodes.get("Principled BSDF")
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = img
    tex.interpolation = 'Closest'
    tex.location = (-320, 240)
    links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.82
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.25
    return mat


# ---------------------------------------------------------------------------
# Species construction
# ---------------------------------------------------------------------------
def build_species(mid, s):
    parts = []

    stem_top = s["height"] - s["cap_h"]
    stem_r = s["stem_r"]

    stem = MeshBuilder("stem")
    # Two tapered segments read better than one cone and cost 12 quads.
    stem.add_frustum(0.0, stem_top * 0.55, stem_r * 1.18, stem_r, 6, side=BODY,
                     bottom=BODY_DARK)
    stem.add_frustum(stem_top * 0.55, stem_top, stem_r, stem_r * 0.86, 6,
                     side=BODY, top=BODY_DARK)
    parts.append(stem)

    if s.get("rings"):
        for i in range(s["rings"]):
            z = stem_top * (0.18 + 0.62 * i / max(1, s["rings"] - 1 or 1))
            h = 0.022 if mid != "kora" else 0.030
            ring_r = stem_r * (1.28 if mid == "kora" else 1.16)
            r = MeshBuilder("stem_ring_%d" % i)
            r.add_frustum(z, z + h, ring_r, ring_r * 0.94, 6,
                          side=BODY_DARK, top=BODY_DARK, bottom=BODY_DARK)
            parts.append(r)

    cap_base = stem_top - 0.012
    cap_h = s["cap_h"]
    cap_r = s["cap_r"]
    tiers = max(1, s["tiers"])
    rot = math.radians(11)
    # Cap profile: r(f) shrinks from cap_r at the base to 0 at the top.
    profile_k = 1.0 + s.get("dome", 1.0) * 0.55

    def surface_r(f):
        return cap_r * (1.0 - max(0.0, min(f, 1.0)) ** profile_k)

    def surface_z(radius):
        f = (1.0 - min(radius / cap_r, 1.0)) ** (1.0 / profile_k)
        return cap_base + cap_h * f

    for t in range(tiers):
        f0, f1 = t / tiers, (t + 1) / tiers
        z0 = cap_base + cap_h * f0
        z1 = cap_base + cap_h * f1
        r0 = surface_r(f0)
        r1 = surface_r(f1)
        # A small overhang at the bottom of each tier gives the blocky
        # stepped silhouette instead of one smooth cone.
        if t > 0:
            r0 *= 1.07
        if s.get("droop") and t == 0:
            z0 -= s["droop"]
        if s.get("bracket"):
            # Bracket fungus: each tier steps in and hangs slightly.
            z0 -= 0.018 * (1 - f0)
        last = t == tiers - 1
        # The widest tier carries the species' real cap colour; the light
        # tint is only a top-face highlight. Putting the tint on tier 0
        # washes every species out.
        if t == 0:
            tier_name = "cap_rim"
        elif last:
            tier_name = "cap_top"
        else:
            tier_name = "cap_mid_%d" % t
        m = MeshBuilder(tier_name)
        m.add_frustum(z0, z1, r0, r1, 8, rot=rot, side=CAP,
                      top=(CAP_LIGHT if last else None),
                      bottom=(GILL if t == 0 else None))
        parts.append(m)

    # Gills: a dark disc tucked under the rim, its own non-glowing node.
    if s.get("gills", True):
        g = MeshBuilder("stem_gills")
        g.add_frustum(cap_base - 0.012, cap_base + 0.002,
                      cap_r * 0.80, cap_r * 0.70, 8, rot=rot,
                      side=GILL, bottom=GILL, top=GILL)
        parts.append(g)

    if s.get("veins"):
        for i in range(7):
            a = math.tau * i / 7 + rot
            rad = surface_r(0.28) * 0.62
            v = MeshBuilder("cap_vein_%d" % i)
            v.add_box(math.cos(a) * rad, math.sin(a) * rad,
                      surface_z(rad) - 0.002, 0.045, 0.018, 0.010,
                      slot=EMBER, rotz=a)
            parts.append(v)

    if s.get("spots"):
        for i in range(s["spots"]):
            a = math.tau * (i + 0.35) / s["spots"] + rot
            rad = surface_r(0.48 + 0.16 * (i % 2)) * 0.55
            sp = MeshBuilder("cap_spot_%d" % i)
            sp.add_box(math.cos(a) * rad, math.sin(a) * rad,
                       surface_z(rad) - 0.001, 0.042, 0.042, 0.012,
                       slot=ACCENT, rotz=a)
            parts.append(sp)

    if s.get("warts"):
        for i in range(s["warts"]):
            a = math.tau * i / s["warts"] + 0.3
            rad = surface_r(0.56) * (0.40 + 0.22 * (i % 2))
            w = MeshBuilder("cap_wart_%d" % i)
            w.add_pyramid(math.cos(a) * rad, math.sin(a) * rad,
                          surface_z(rad) - 0.006, 0.042, 0.05,
                          slot=CAP_DARK, n=4, rot=rot)
            parts.append(w)

    if s.get("spikes"):
        for i in range(s["spikes"]):
            a = math.tau * i / s["spikes"] + rot
            rad = cap_r * 0.88
            sp = MeshBuilder("cap_spike_%d" % i)
            sp.add_pyramid(math.cos(a) * rad, math.sin(a) * rad,
                           surface_z(rad) - 0.008, 0.035, 0.075,
                           slot=CAP_DARK, n=4, rot=a)
            parts.append(sp)

    if s.get("halo"):
        h = MeshBuilder("cap_halo")
        h.add_annulus(cap_base + cap_h * 0.06, cap_r * 0.94, cap_r * 1.24, 8,
                      slot=CAP_LIGHT, rot=rot)
        parts.append(h)

    return parts


# ---------------------------------------------------------------------------
# Build / export
# ---------------------------------------------------------------------------
def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = 'METRIC'
    return scene


def build_model(mid, spec, out_dir):
    scene = reset_scene()
    coll = bpy.data.collections.new("model")
    scene.collection.children.link(coll)

    parts = build_species(mid, spec)
    img = build_palette(spec)
    mat = build_material(img)
    objs = []
    for part in parts:
        obj = part.build(coll)
        if obj is not None:
            obj.data.materials.append(mat)
            objs.append(obj)

    for obj in bpy.context.view_layer.objects:
        obj.select_set(False)
    for obj in objs:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]

    path = os.path.join(out_dir, "%s.gltf" % mid)
    export_embedded(objs, mid, path)
    return path, objs


def export_embedded(objs, mid, path):
    """Export glTF + bin + png, then inline both into one ``.gltf``.

    Blender 4.x no longer offers ``GLTF_EMBEDDED``; the game (and the
    Blockbench-era assets) expect a single self-contained text glTF, so the
    separate export is repacked here as base64 data URIs.
    """
    tmp = tempfile.mkdtemp(prefix="shroomlands_forge_")
    try:
        tmp_gltf = os.path.join(tmp, "%s.gltf" % mid)
        bpy.ops.export_scene.gltf(
            filepath=tmp_gltf,
            export_format='GLTF_SEPARATE',
            use_selection=True,
            export_apply=True,
            export_yup=True,
            export_texcoords=True,
            export_normals=True,
            export_materials='EXPORT',
            export_cameras=False,
            export_lights=False,
            export_extras=False,
        )
        with open(tmp_gltf, encoding="utf-8") as handle:
            data = json.load(handle)

        for buf in data.get("buffers", []):
            uri = buf.get("uri", "")
            if uri and not uri.startswith("data:"):
                with open(os.path.join(tmp, uri), "rb") as handle:
                    raw = handle.read()
                buf["uri"] = "data:application/octet-stream;base64," + base64.b64encode(raw).decode("ascii")

        for img in data.get("images", []):
            uri = img.get("uri", "")
            if uri and not uri.startswith("data:"):
                with open(os.path.join(tmp, uri), "rb") as handle:
                    raw = handle.read()
                mime = "image/png" if uri.lower().endswith(".png") else "image/jpeg"
                img["uri"] = "data:%s;base64,%s" % (mime, base64.b64encode(raw).decode("ascii"))

        with open(path, "w", encoding="utf-8") as handle:
            json.dump(data, handle, separators=(",", ":"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    only = argv[argv.index("--only") + 1] if "--only" in argv else None
    out_dir = os.path.join(OUT_DIR)
    os.makedirs(out_dir, exist_ok=True)

    for mid, spec in SPECIES.items():
        if only and mid != only:
            continue
        path, objs = build_model(mid, spec, out_dir)
        tris = sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in objs)
        print("FORGED %-9s parts=%2d tris=%3d -> %s" % (mid, len(objs), tris, path))


if __name__ == "__main__":
    main()
