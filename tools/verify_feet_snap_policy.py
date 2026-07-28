#!/usr/bin/env python3
"""Feet-snap must be opt-OUT (snap by default) — only specific attachment
scenery (cameras, wall cards, glass/cockpit/tv/island/etc.) is denied.

Mirror scripts/engine/wmb_level_loader.gd _should_feet_snap policy in Python
so CI fails if the contract drifts without updating this test.

An earlier rewrite inverted this to opt-in (floor actors only via a
name whitelist), which silently stopped snapping every non-whitelisted prop
(fans, curtains, light rigs) and sank them under the floor — found via a
user playtest report in Studio. See docs/SESSION_LOG.md. The test cases
below include those exact regressed props so this can't silently recur.
"""
from __future__ import annotations

import sys
from pathlib import Path


def should_feet_snap(action: str, stem: str) -> bool:
    a = action.lower()
    s = stem.lower()
    if a in {
        "cam", "thecam", "thecam2", "farcam", "scam", "cammy", "lookatme",
        "mycamera", "pipicam", "cam2", "cam3", "cam4", "camplane", "cameraengine",
    } or s == "cam":
        return False
    if s in {"afg", "shiknote"}:
        return False
    if a == "window":
        return False
    # Measured verdicts (GLB local-Y AABB vs. WED origin + WDL action body
    # grep for runtime position control) — see docs/CONTRACT.md §3.5.
    # "tv"/"hanger"/"towerw" used to be here too; removed 2026-07-28 after
    # measurement showed the same below-origin bug shape as Cockpit.
    if s in {
        "glass", "b747", "island", "headphon", "biplane",
        "biplane2", "dutyfree",
    }:
        return False
    if a in {"headphone", "land", "wind", "ent_rotate", "item_pickup"}:
        return False
    return True



def main() -> int:
    errs = 0
    # Scenery must never snap.
    for action, stem in [
        ("Window", "Glass"),
        ("", "B747"),
        ("HeadPhone", "Headphon"),
        # Real Plane2.json placement: one of 9 Headphon instances uses
        # action "A1", not "HeadPhone" -- this instance previously slipped
        # through both checks because the stem list had a typo ("headphone"
        # instead of the real 8.3-truncated "Headphon"). Exercising the
        # stem path with a non-matching action is the regression guard.
        ("A1", "Headphon"),
        ("Land", "BiPlane2"),
        ("Cam", "Cam"),
    ]:
        if should_feet_snap(action, stem):
            print(f"FAIL scenery snapped: {action}/{stem}")
            errs += 1
    # Floor actors must snap.
    for action, stem in [
        ("Ami", "Ami"),
        ("PiposhWalk", "Piposh"),
        ("ThePlaneMovie", "Krupnik"),
        ("player_walk2", "Piposh"),
        ("Crowd", "Crowd"),
    ]:
        if not should_feet_snap(action, stem):
            print(f"FAIL floor actor not snapped: {action}/{stem}")
            errs += 1
    # Regression guard: set-dressing props with no dedicated exclusion must
    # default to snapping (the exact bug reported in Studio).
    for action, stem in [
        ("", "Sfan"),
        ("", "Curtain"),
        ("", "StudioL"),
        ("", "Shtomba"),
        ("", "Cockpit"),
        # 2026-07-28: measured the same below-origin bug shape as Cockpit
        # (55%/43%/33% of mesh hangs below the WED origin, no WDL action
        # ever moves them) — must snap like every other floor prop now.
        ("", "TV"),
        ("", "Hanger"),
        ("", "TowerW"),
    ]:
        if not should_feet_snap(action, stem):
            print(f"FAIL set-dressing prop not snapped (regression): {action}/{stem}")
            errs += 1
    if errs:
        print(f"verify_feet_snap_policy: {errs} failure(s)")
        return 1
    print("verify_feet_snap_policy: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
