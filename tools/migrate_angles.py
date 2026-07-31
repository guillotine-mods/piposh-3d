#!/usr/bin/env python3
"""Repair contaminated entity angles in converted level JSON.

Why this exists
---------------
`angle_deg` in the committed level JSON was written by two different
generations of the extractor: some entities use Godot euler [tilt, +pan, roll]
and others use the older [tilt, -pan, roll]. The two are mixed *within* single
files (Studio, Town, Menu, Start, Credits). That is the root cause of "assets
point the wrong way" for a subset of entities.

`angle_gs` (the raw Acknex [pan, tilt, roll] straight from the WMB) is the only
field that is consistent everywhere it exists. This tool makes `angle_gs` the
single source of truth:

  * For every entity it (re)writes `angle_gs` from the source WMB (authoritative),
    matched by entity order — the same order verify_transforms.py uses.
  * It rewrites `angle_deg` to the ONE correct convention [tilt, +pan, roll] so
    nothing downstream can read a stale sign again.
  * It only touches angle fields. origin, scale, skills, action, and any manual
    edits are left exactly as-is.

Levels whose source WMB is missing, or whose entity count no longer matches the
WMB, are reported and skipped (never silently guessed).

Usage
-----
    python tools/migrate_angles.py                 # migrate every level
    python tools/migrate_angles.py --only Studio Town
    python tools/migrate_angles.py --check         # report only, write nothing
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from extract_wmb_full import parse_wmb  # noqa: E402
from gs_math import gs_euler_to_godot_deg  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]


def _entities(objs: list[dict]) -> list[dict]:
    return [o for o in objs if o.get("type") == "entity"]


def migrate_level(json_path: Path, wmb_dir: Path, write: bool) -> str:
    data = json.loads(json_path.read_text(encoding="utf-8"))
    stem = json_path.stem

    wmb = next(
        (p for p in wmb_dir.glob("*.[Ww][Mm][Bb]") if p.stem.lower() == stem.lower()),
        None,
    )
    if wmb is None:
        return f"SKIP  {stem}: no source WMB (angle_gs cannot be regenerated)"

    try:
        raw = parse_wmb(wmb)
    except Exception as exc:  # noqa: BLE001
        return f"SKIP  {stem}: WMB parse failed ({exc})"

    raw_ents = _entities(raw["objects"])
    json_ents = _entities(data.get("objects", []))
    if len(raw_ents) != len(json_ents):
        return (
            f"SKIP  {stem}: entity count drift raw={len(raw_ents)} "
            f"json={len(json_ents)} (re-extract this level fully instead)"
        )

    fixed = 0
    for r, j in zip(raw_ents, json_ents):
        pan, tilt, roll = r["angle_gs"]
        good_gs = [float(pan), float(tilt), float(roll)]
        good_deg = gs_euler_to_godot_deg(pan, tilt, roll)  # [tilt, +pan, roll]
        if j.get("angle_gs") != good_gs or j.get("angle_deg") != good_deg:
            fixed += 1
        j["angle_gs"] = good_gs
        j["angle_deg"] = good_deg

    if write and fixed:
        json_path.write_text(json.dumps(data, indent=2), encoding="utf-8")
    verb = "would fix" if not write else "fixed"
    return f"OK    {stem}: entities={len(json_ents)} {verb}={fixed}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--levels", type=Path, default=ROOT / "assets" / "converted" / "levels")
    ap.add_argument("--wmb", type=Path, default=ROOT / "original" / "piposh3d" / "WMB")
    ap.add_argument("--only", nargs="*", default=[])
    ap.add_argument("--check", action="store_true", help="report only; write nothing")
    args = ap.parse_args()

    files = sorted(p for p in args.levels.glob("*.json") if p.name != "levels.json")
    if args.only:
        want = {n.lower() for n in args.only}
        files = [f for f in files if f.stem.lower() in want]

    skips = 0
    for f in files:
        line = migrate_level(f, args.wmb, write=not args.check)
        if line.startswith("SKIP"):
            skips += 1
        print(line)
    print(f"\n{len(files)} level(s), {skips} skipped.")
    if skips:
        print("Skipped levels still lack a clean angle_gs — fix their source path or")
        print("run tools/extract_wmb_full.py --only <level> to regenerate them fully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
