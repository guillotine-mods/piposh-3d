#!/usr/bin/env python3
"""Verify level pack readiness for the uniform pipeline."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LEVELS_DIR = ROOT / "assets" / "converted" / "levels"
MDL_DIR = ROOT / "assets" / "converted" / "mdl"
FLOW = ROOT / "assets" / "converted" / "levels.json"
META = ROOT / "assets" / "converted" / "wdl_meta.json"

# Spine that must be playable end-to-end
SPINE = [
    "Start",
    "Menu",
    "Studio",
    "Shiks",
    "Plane",
    "Plane2",
    "Town",
    "Travel",
    "Map",
    "Desert",
]


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def check_level(name: str, require_brush: bool) -> list[str]:
    errs: list[str] = []
    jp = LEVELS_DIR / f"{name}.json"
    if not jp.exists():
        # case-insensitive
        hits = list(LEVELS_DIR.glob("*.json"))
        jp2 = next((p for p in hits if p.stem.lower() == name.lower()), None)
        if jp2 is None:
            return [f"{name}: missing JSON"]
        jp = jp2
    data = _load_json(jp)
    if "angle_gs" not in json.dumps(data):
        # at least one entity should have angle_gs after fresh extract
        ents = [o for o in data.get("objects", []) if o.get("type") == "entity"]
        if ents and not any("angle_gs" in e for e in ents):
            errs.append(f"{name}: entities lack angle_gs (stale extract)")
    if not data.get("script") and not data.get("coord_space"):
        errs.append(f"{name}: missing script/coord_space (stale extract)")

    brush = LEVELS_DIR / f"{jp.stem}_brush.glb"
    if require_brush and not brush.exists():
        # Menu may be special; still warn
        errs.append(f"{name}: missing {brush.name}")

    # Spot-check a few MDL stems resolve
    missing_mdl = 0
    for o in data.get("objects", []):
        if o.get("type") != "entity":
            continue
        f = str(o.get("file", ""))
        if not f.lower().endswith(".mdl"):
            continue
        stem = Path(f).stem
        if not (MDL_DIR / f"{stem}.glb").exists():
            # case-insensitive
            if not any(p.stem.lower() == stem.lower() for p in MDL_DIR.glob("*.glb")):
                missing_mdl += 1
    if missing_mdl:
        errs.append(f"{name}: {missing_mdl} entity MDL GLBs missing")
    return errs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--spine", action="store_true", help="Only check SPINE levels")
    ap.add_argument("--all-json", action="store_true", help="Check every JSON")
    args = ap.parse_args()

    names = list(SPINE)
    if args.all_json:
        names = sorted({p.stem for p in LEVELS_DIR.glob("*.json")})

    # Prefer flow file names when present
    if FLOW.exists() and not args.spine and not args.all_json:
        flow = _load_json(FLOW)
        names = sorted(flow.get("levels", {}).keys())

    if args.spine:
        names = list(SPINE)

    failed = 0
    for name in names:
        require_brush = name.lower() not in ("credits", "ending", "outro", "boot")
        # Credits often has no WMB
        errs = check_level(name, require_brush=require_brush and name.lower() in {
            s.lower() for s in SPINE
        })
        if errs:
            failed += 1
            for e in errs:
                print(f"FAIL {e}")
        else:
            print(f"OK {name}")

    if META.exists():
        meta = _load_json(META)
        print(f"wdl_meta levels: {len(meta.get('levels', {}))}")
    else:
        print("WARN: wdl_meta.json missing — run tools/extract_wdl_meta.py")

    if failed:
        print(f"\n{failed} level pack failure(s)", file=sys.stderr)
        return 1
    print("\nverify_level_pack: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
