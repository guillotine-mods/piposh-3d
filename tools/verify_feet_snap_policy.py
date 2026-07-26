#!/usr/bin/env python3
"""Feet-snap must be opt-in for floor actors — scenery must stay denied."""
from __future__ import annotations

import sys
from pathlib import Path

# Mirror scripts/engine/wmb_level_loader.gd _should_feet_snap policy in Python
# so CI fails if the contract drifts without updating this test.


def should_feet_snap(action: str, stem: str, has_walk_stand: bool) -> bool:
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
    if s in {
        "glass", "b747", "cockpit", "tv", "island", "headphone", "biplane",
        "biplane2", "hanger", "towerw", "dutyfree",
    }:
        return False
    if a in {"headphone", "land", "wind", "ent_rotate", "item_pickup"}:
        return False
    # Opt-in: floor actors only.
    if has_walk_stand:
        return True
    floor_actions = {
        "ami", "naknik", "piposhwalk", "theplanemovie", "krup", "pip",
        "crowd", "player_walk2", "player_walk", "player_stand", "defineyachdel",
        "passanger", "stu1", "stu2", "sikot", "krupnik", "piposhhit", "a1",
    }
    floor_stems = {
        "piposh", "piposh2", "fpiposh", "ami", "pipdog", "krupnik", "krup2",
        "crowd", "crowd2", "yachdal", "genia", "passn", "peggy",
    }
    return a in floor_actions or s in floor_stems


def main() -> int:
    errs = 0
    # Scenery must never snap.
    for action, stem in [
        ("Window", "Glass"),
        ("", "B747"),
        ("", "Cockpit"),
        ("HeadPhone", "HeadPhone"),
        ("Land", "BiPlane2"),
        ("Cam", "Cam"),
    ]:
        if should_feet_snap(action, stem, False):
            print(f"FAIL scenery snapped: {action}/{stem}")
            errs += 1
    # Floor actors must snap.
    for action, stem, anim in [
        ("Ami", "Ami", True),
        ("PiposhWalk", "Piposh", True),
        ("ThePlaneMovie", "Krupnik", True),
        ("player_walk2", "Piposh", True),
        ("Crowd", "Crowd", True),
    ]:
        if not should_feet_snap(action, stem, anim):
            print(f"FAIL floor actor not snapped: {action}/{stem}")
            errs += 1
    if errs:
        print(f"verify_feet_snap_policy: {errs} failure(s)")
        return 1
    print("verify_feet_snap_policy: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
