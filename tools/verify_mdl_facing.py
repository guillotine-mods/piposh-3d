#!/usr/bin/env python3
"""Guard IDPO face->+X convert contract (docs/CONTRACT.md #2).

Verifies _convert_idpo()'s per-model decision directly, not just a yaw
metric. A det -1 (legacy) vs det +1 (FIX_IDPO) mesh are mirror images of
each other, not two rotations of the same shape — a "does the heuristic's
own yaw metric read as ~0" check can pass while the model is silently
mirrored (this happened for real: 2026-07-27, a "180 compensation" broke
Ami/Crowd/Yachdal/Genia/ShikFond/Wwheel while every yaw-metric check kept
passing). So this test checks WHICH winding convention _convert_idpo
actually used, by comparing its output against a manually-forced parse of
each convention, for both classes of model.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import convert_mdl as cm  # noqa: E402

MDL_DIR = ROOT / "original" / "piposh3d" / "MDL"

# Heuristic-dependent: the face-orient heuristic finds and re-yaws a painted
# face on these, so _convert_idpo must keep them on the legacy (det -1)
# winding that heuristic was tuned and playtest-validated against.
EXPECT_LEGACY = ["Ami", "Crowd", "Crowd2", "Yachdal", "Genia", "Island", "ShikFond", "Wwheel"]

# Faceless / heuristic-excluded: nothing depends on chirality, so
# _convert_idpo should use the corrected det +1 handedness.
EXPECT_FIXED = ["Sfan", "Bus", "B747"]


def _force_parse(stem: str, fix_idpo: bool):
    saved = cm.FIX_IDPO
    try:
        cm.FIX_IDPO = fix_idpo
        with (MDL_DIR / f"{stem}.MDL").open("rb") as f:
            return cm.orient_mesh_face_plus_x(cm.parse_quake_mdl(f), stem=stem)
    finally:
        cm.FIX_IDPO = saved


def _check(stem: str, expect_legacy: bool) -> str | None:
    path = MDL_DIR / f"{stem}.MDL"
    if not path.exists():
        return f"missing {path}"
    with path.open("rb") as f:
        magic = f.read(4)
        if magic != b"IDPO":
            return None  # not applicable, skip silently
    with path.open("rb") as f:
        actual = cm._convert_idpo(f, stem)
    legacy_ref = _force_parse(stem, fix_idpo=False)
    fixed_ref = _force_parse(stem, fix_idpo=True)
    matches_legacy = np.allclose(actual.positions, legacy_ref.positions)
    matches_fixed = np.allclose(actual.positions, fixed_ref.positions)
    if expect_legacy and not matches_legacy:
        return "expected legacy (det -1) winding, got fixed (det +1) — model silently mirrored"
    if not expect_legacy and not matches_fixed:
        return "expected fixed (det +1) handedness, got legacy (det -1) winding"
    if matches_legacy and matches_fixed:
        # Only possible if the heuristic was a no-op under both conventions
        # (a truly symmetric/faceless mesh) — fine either way, not a failure.
        return None
    return None


def main() -> int:
    if not MDL_DIR.is_dir():
        print(f"SKIP: no original MDL dir at {MDL_DIR}", file=sys.stderr)
        return 0

    failed = 0
    for stem in EXPECT_LEGACY:
        err = _check(stem, expect_legacy=True)
        if err:
            print(f"FAIL {stem}: {err}")
            failed += 1
        else:
            print(f"OK {stem}: legacy winding (heuristic-corrected)")
    for stem in EXPECT_FIXED:
        err = _check(stem, expect_legacy=False)
        if err:
            print(f"FAIL {stem}: {err}")
            failed += 1
        else:
            print(f"OK {stem}: fixed handedness (faceless/excluded)")

    if failed:
        print(f"\n{failed} facing contract failure(s)", file=sys.stderr)
        return 1
    print("\nverify_mdl_facing: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
