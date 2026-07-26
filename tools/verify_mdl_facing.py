#!/usr/bin/env python3
"""Guard IDPO face→+X convert contract (docs/CONTRACT.md).

Fails if convert_mdl facing drift returns for known models.
"""
from __future__ import annotations

import sys
from io import BytesIO
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from convert_mdl import (  # noqa: E402
    _face_uv_forward_yaw,
    orient_mesh_face_plus_x,
    parse_quake_mdl,
)

MDL_DIR = ROOT / "original" / "piposh3d" / "MDL"
# Expected face-UV yaw *before* bake (authored Quake→Godot mesh), with
# FIX_IDPO's det+1 handedness map + the matching 180 compensation in
# _face_uv_forward_yaw (winding flip negates the cross-product normal, so
# the heuristic adds 180 back — see convert_mdl.py). These numbers were
# re-derived after making FIX_IDPO the default 2026-07-27: they equal what
# the OLD legacy-winding numbers used to be, which is the expected result
# of a winding-independent heuristic (Island differs — its raw parse is
# already face-forward under the new convention, needing no rotation).
# After orient_mesh_face_plus_x, face-UV yaw must be ~0 (or None if skipped).
EXPECT_PRE_YAW = {
    "Ami": 180.0,
    "Crowd": 90.0,
    "Crowd2": 90.0,
    "Yachdal": 270.0,
    "Genia": 90.0,
    "Island": 0.0,
    "Sfan": None,  # faceless — must stay unoriented
}


def _yaw(mesh) -> float | None:
    skin = np.array(Image.open(BytesIO(mesh.skin_png)).convert("RGBA"))
    return _face_uv_forward_yaw(mesh.positions, mesh.indices, mesh.uvs, skin)


def _ang_diff(a: float, b: float) -> float:
    d = abs(a - b) % 360.0
    return min(d, 360.0 - d)


def main() -> int:
    if not MDL_DIR.is_dir():
        print(f"SKIP: no original MDL dir at {MDL_DIR}", file=sys.stderr)
        return 0

    failed = 0
    for stem, expect in EXPECT_PRE_YAW.items():
        path = MDL_DIR / f"{stem}.MDL"
        if not path.exists():
            print(f"FAIL {stem}: missing {path}")
            failed += 1
            continue
        with path.open("rb") as f:
            magic = f.read(4)
            f.seek(0)
            if magic != b"IDPO":
                print(f"SKIP {stem}: magic {magic!r}")
                continue
            raw = parse_quake_mdl(f)
        pre = _yaw(raw)
        if expect is None:
            if pre is not None:
                # Still OK if thin/faceless path leaves mesh alone after orient
                pass
            oriented = orient_mesh_face_plus_x(raw)
            # Faceless: positions must be unchanged
            if not np.allclose(oriented.positions, raw.positions):
                print(f"FAIL {stem}: faceless prop was re-yawed (pre={pre})")
                failed += 1
            else:
                print(f"OK {stem}: faceless left alone (pre={pre})")
            continue

        if pre is None or _ang_diff(pre, expect) > 5.0:
            print(f"FAIL {stem}: pre face-UV yaw {pre} expected ~{expect}")
            failed += 1
            continue

        oriented = orient_mesh_face_plus_x(raw)
        post = _yaw(oriented)
        if post is None or _ang_diff(post, 0.0) > 15.0:
            print(f"FAIL {stem}: after orient face-UV yaw {post} (want ~0)")
            failed += 1
        else:
            print(f"OK {stem}: pre={pre:.1f} -> post={post:.1f}")

    if failed:
        print(f"\n{failed} facing contract failure(s)", file=sys.stderr)
        return 1
    print("\nverify_mdl_facing: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
