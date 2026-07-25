#!/usr/bin/env python3
"""Scan level WDL scripts for load_level / Run() graph → levels.json."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

LOAD_RE = re.compile(r"load_level\s*\(\s*<([^>]+)>\s*\)", re.I)
RUN_RE = re.compile(r'Run\s*\(\s*"([^"]+)"\s*\)')
INCLUDE_RE = re.compile(r"include\s*<([^>]+)>", re.I)


def main() -> int:
    ap = argparse.ArgumentParser()
    root = Path(__file__).resolve().parents[1] / "original" / "piposh3d"
    ap.add_argument("--src", type=Path, default=root)
    ap.add_argument(
        "--dst",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "assets" / "converted" / "levels.json",
    )
    args = ap.parse_args()

    levels = {}
    for wdl in sorted(args.src.glob("*.wdl")):
        text = wdl.read_text(encoding="latin-1", errors="replace")
        loads = LOAD_RE.findall(text)
        runs = RUN_RE.findall(text)
        levels[wdl.stem] = {
            "script": wdl.name,
            "load_level": loads,
            "run": [r.replace(".exe", "") for r in runs],
            "includes": INCLUDE_RE.findall(text),
        }

    boot = {
        "boot": "Start",
        "flow_note": "Original game chained EXEs via Run.txt + loader; Godot maps names to scenes.",
        "levels": levels,
    }
    args.dst.parent.mkdir(parents=True, exist_ok=True)
    args.dst.write_text(json.dumps(boot, indent=2), encoding="utf-8")
    print(f"Wrote {args.dst} ({len(levels)} scripts)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
