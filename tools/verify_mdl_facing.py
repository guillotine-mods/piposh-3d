#!/usr/bin/env python3
"""Guard IDPO facing contract (docs/CONTRACT.md #2): one uniform rule for
every model, no heuristic, no per-model branching.

FIX_IDPO must be on and FACE_ORIENT must be off by default, and parse_mdl
must not re-yaw ANY model's geometry — authored facing + WED pan is the
only source of truth, exactly like A5. This test exists because a
heuristic-based "fix" was tried twice (2026-07-27) and both attempts
regressed real, previously-working models while every self-check they used
kept passing — see docs/SESSION_LOG.md. Checking "nothing gets re-yawed,
ever" directly is what would have caught both.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import convert_mdl as cm  # noqa: E402

MDL_DIR = ROOT / "original" / "piposh3d" / "MDL"

# A representative spread: models previously fought over by the heuristic
# (Ami, Crowd, Crowd2, Yachdal, Genia, Island, ShikFond, Wwheel), the one
# human-confirmed-correct case (Sfan), and two vehicles (Bus, B747).
SAMPLE_STEMS = [
    "Ami", "Crowd", "Crowd2", "Yachdal", "Genia", "Island",
    "ShikFond", "Wwheel", "Sfan", "Bus", "B747",
]


def main() -> int:
    if not MDL_DIR.is_dir():
        print(f"SKIP: no original MDL dir at {MDL_DIR}", file=sys.stderr)
        return 0

    failed = 0

    if not cm.FIX_IDPO:
        print("FAIL: FIX_IDPO default is False, must be True")
        failed += 1
    if cm.FACE_ORIENT:
        print("FAIL: FACE_ORIENT default is True, must be False (no heuristic)")
        failed += 1

    for stem in SAMPLE_STEMS:
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
            raw = cm.parse_quake_mdl(f)
        before = raw.positions.copy()
        oriented = cm.orient_mesh_face_plus_x(raw, stem=stem)
        if not np.allclose(oriented.positions, before):
            print(f"FAIL {stem}: geometry was re-yawed — heuristic must be a no-op")
            failed += 1
        else:
            print(f"OK {stem}: authored facing kept, not re-yawed")

    if failed:
        print(f"\n{failed} facing contract failure(s)", file=sys.stderr)
        return 1
    print("\nverify_mdl_facing: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
