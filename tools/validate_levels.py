#!/usr/bin/env python3
"""Validate converted level JSON against available GLB models."""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    levels = root / "assets" / "converted" / "levels"
    mdl = root / "assets" / "converted" / "mdl"
    src_mdl = root / "original" / "piposh3d" / "MDL"
    glbs = {p.stem.lower(): p.name for p in mdl.glob("*.glb")}
    src_models = {p.stem.lower(): p.name for p in src_mdl.glob("*.[Mm][Dd][Ll]")}

    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*", default=[])
    args = ap.parse_args()

    files = sorted(levels.glob("*.json"))
    if args.only:
        want = {n.lower() for n in args.only}
        files = [f for f in files if f.stem.lower() in want]

    total_missing = 0
    for f in files:
        if f.name == "levels.json":
            continue
        data = json.loads(f.read_text(encoding="utf-8"))
        ents = [o for o in data.get("objects", []) if o.get("type") == "entity"]
        missing = []
        wmb_props = []
        for o in ents:
            file = str(o.get("file", ""))
            stem = Path(file).stem.lower()
            ext = Path(file).suffix.lower()
            if ext == ".wmb":
                wmb_props.append(file)
                continue
            if stem and stem not in glbs:
                missing.append(file)
        print(
            f"{f.stem}: entities={len(ents)} missing_mdl={len(missing)} nested_wmb={len(wmb_props)}"
        )
        if missing:
            total_missing += len(set(missing))
            for m in sorted(set(missing))[:12]:
                stem = Path(m).stem.lower()
                hint = " (not in source either)" if stem not in src_models else " (source exists)"
                print(f"  - {m}{hint}")
    print(f"Unique missing model refs: {total_missing}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
