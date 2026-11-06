#!/usr/bin/env python3
"""Validate the generated glTFs against the contract the game relies on.

Runs on plain CPython (no Blender): reads the JSON, checks node naming,
single material/texture, embedded buffers, triangle budget, UVs and the
feet-at-origin / height rules. Exit code 1 on any failure.

    python3 tools/blender/validate_models.py
    python3 tools/blender/validate_models.py --set hazards
    python3 tools/blender/validate_models.py --gltf /some/dir   # mushrooms only
"""

import argparse
import base64
import json
import math
import os
import sys

SPECIES = [
    "konop", "shitake", "motoko", "borowik", "kazar", "kora",
    "altak", "bedak", "celtus", "pesta", "fury",
]
HAZARDS = ["spore_bloom"]

MAX_TRIS = 400
MIN_HEIGHT = 0.30
MUSHROOM_MAX_HEIGHT = 0.85
HAZARD_MAX_HEIGHT = 1.00

ROOT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "models")


def node_matrix(node):
    """TRS -> 4x4, column-major as glTF stores it."""
    if "matrix" in node:
        m = node["matrix"]
        return [[m[0], m[4], m[8], m[12]],
                [m[1], m[5], m[9], m[13]],
                [m[2], m[6], m[10], m[14]],
                [m[3], m[7], m[11], m[15]]]
    tx, ty, tz = node.get("translation", [0, 0, 0])
    qx, qy, qz, qw = node.get("rotation", [0, 0, 0, 1])
    sx, sy, sz = node.get("scale", [1, 1, 1])
    xx, yy, zz = qx * qx, qy * qy, qz * qz
    xy, xz, yz = qx * qy, qx * qz, qy * qz
    wx, wy, wz = qw * qx, qw * qy, qw * qz
    r = [
        [1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy)],
        [2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx)],
        [2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy)],
    ]
    return [
        [r[0][0] * sx, r[0][1] * sy, r[0][2] * sz, tx],
        [r[1][0] * sx, r[1][1] * sy, r[1][2] * sz, ty],
        [r[2][0] * sx, r[2][1] * sy, r[2][2] * sz, tz],
        [0, 0, 0, 1],
    ]


def mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def apply(m, p):
    return [sum(m[i][j] * p[j] for j in range(3)) + m[i][3] for i in range(3)]


def check_file(path, max_height):
    errors = []
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)

    nodes = data.get("nodes", [])
    meshes = data.get("meshes", [])
    if not nodes:
        return ["no nodes"], None

    names = [n.get("name", "") for n in nodes]
    if len(names) != len(set(names)):
        errors.append("duplicate node names: %s" % names)
    for name in names:
        if not (name.startswith("cap") or name.startswith("stem") or name.startswith("glow")):
            errors.append("node %r is neither cap*/stem*/glow* (ModelGlow would mis-handle it)" % name)
    if not any(n.startswith("cap") for n in names):
        errors.append("no cap* node (nothing would glow)")

    if len(data.get("materials", [])) != 1:
        errors.append("expected exactly 1 material, found %d" % len(data.get("materials", [])))
    images = data.get("images", [])
    if len(images) != 1:
        errors.append("expected exactly 1 embedded texture, found %d" % len(images))
    for img in images:
        uri = img.get("uri", "")
        if not uri.startswith("data:image/") or ";base64," not in uri:
            errors.append("texture is not an embedded data URI")
        else:
            try:
                base64.b64decode(uri.split(",", 1)[1])
            except Exception:
                errors.append("texture data URI is not valid base64")
    for buf in data.get("buffers", []):
        if not buf.get("uri", "").startswith("data:"):
            errors.append("buffer is external (must be embedded)")

    for i, mesh in enumerate(meshes):
        prims = mesh.get("primitives", [])
        if len(prims) != 1:
            errors.append("mesh %d has %d primitives (ModelGlow merges surface 0 only)"
                          % (i, len(prims)))
        for prim in prims:
            attrs = prim.get("attributes", {})
            if "POSITION" not in attrs or "TEXCOORD_0" not in attrs:
                errors.append("mesh %d lacks POSITION/TEXCOORD_0" % i)

    tris = 0
    for mesh in meshes:
        for prim in mesh.get("primitives", []):
            if "indices" in prim:
                count = data["accessors"][prim["indices"]]["count"]
            else:
                count = data["accessors"][prim["attributes"]["POSITION"]]["count"]
            tris += count // 3
    if tris > MAX_TRIS:
        errors.append("triangle budget: %d > %d" % (tris, MAX_TRIS))

    # World-space vertical extent. Nodes are flat in these files, but walk
    # children properly in case a future export nests parts.
    mins = [math.inf] * 3
    maxs = [-math.inf] * 3
    scene = data["scenes"][data.get("scene", 0)]
    stack = [(root, None) for root in scene.get("nodes", [])]
    while stack:
        index, parent = stack.pop()
        node = nodes[index]
        local = node_matrix(node)
        world = local if parent is None else mul(parent, local)
        if "mesh" in node:
            for prim in meshes[node["mesh"]].get("primitives", []):
                acc = data["accessors"][prim["attributes"]["POSITION"]]
                lo, hi = acc["min"], acc["max"]
                for cx in (lo[0], hi[0]):
                    for cy in (lo[1], hi[1]):
                        for cz in (lo[2], hi[2]):
                            p = apply(world, [cx, cy, cz])
                            for k in range(3):
                                mins[k] = min(mins[k], p[k])
                                maxs[k] = max(maxs[k], p[k])
        for child in node.get("children", []):
            stack.append((child, world))

    if not math.isfinite(mins[1]):
        return errors + ["no mesh geometry"], None
    height = maxs[1] - mins[1]
    if abs(mins[1]) > 0.01:
        errors.append("feet are at y=%.3f, not 0 (the model would float/sink)" % mins[1])
    if not (MIN_HEIGHT <= height <= max_height):
        errors.append("height %.3f outside %.2f-%.2f m" % (height, MIN_HEIGHT, max_height))

    return errors, {"tris": tris, "height": height, "parts": len(names)}


def validate_set(name, ids, directory, max_height):
    failures = 0
    total_tris = 0
    for mid in ids:
        path = os.path.join(directory, "%s.gltf" % mid)
        if not os.path.exists(path):
            print("FAIL %-11s missing %s" % (mid, path))
            failures += 1
            continue
        errors, stats = check_file(path, max_height)
        if errors:
            failures += 1
            print("FAIL %-11s %s" % (mid, "; ".join(errors)))
        else:
            total_tris += stats["tris"]
            print("OK   %-11s parts=%2d tris=%3d height=%.3fm" % (
                mid, stats["parts"], stats["tris"], stats["height"]))
    print("%s: total_tris %d" % (name, total_tris))
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--set", default="all", choices=["all", "mushrooms", "hazards"])
    parser.add_argument("--gltf", default=None,
                        help="validate the mushroom contract against one directory")
    args = parser.parse_args()

    if args.gltf:
        failures = validate_set("models", SPECIES, args.gltf, MUSHROOM_MAX_HEIGHT)
    else:
        failures = 0
        if args.set in ("all", "mushrooms"):
            failures += validate_set("mushrooms", SPECIES,
                                     os.path.join(ROOT, "mushrooms"), MUSHROOM_MAX_HEIGHT)
        if args.set in ("all", "hazards"):
            failures += validate_set("hazards", HAZARDS,
                                     os.path.join(ROOT, "hazards"), HAZARD_MAX_HEIGHT)

    if failures:
        print("FAILED %d model(s)" % failures)
        return 1
    print("OK all models")
    return 0


if __name__ == "__main__":
    sys.exit(main())
