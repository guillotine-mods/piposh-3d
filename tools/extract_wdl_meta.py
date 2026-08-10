#!/usr/bin/env python3
"""Scan original WDL for scene_map / sky_map and write wdl_meta.json.

Uniform background pipeline: AcknexSky reads this instead of hardcoding.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WDL_DIRS = [
    ROOT / "original" / "piposh3d",
    ROOT / "original" / "piposh3d" / "WDL",
]
OUT = ROOT / "assets" / "converted" / "wdl_meta.json"

# bmap Name = <file.ext>;
BMAP_RE = re.compile(
    r"bmap\s+(\w+)\s*=\s*<([^>]+)>",
    re.IGNORECASE,
)
# scene_map = bmapBack1;  / Scene_map = …
SCENE_RE = re.compile(
    r"scene_map\s*=\s*(\w+)",
    re.IGNORECASE,
)
SKY_RE = re.compile(
    r"sky_map\s*=\s*(\w+)",
    re.IGNORECASE,
)

# Known IO.wdl defaults
DEFAULT_BMAPS = {
    "bsky": "sky.bmp",
    "bclouds": "clds.pcx",
    "bhorizon": "horizon.pcx",
    "bmapback1": "Horizon1.pcx",
    "bmapback2": "Horizon2.pcx",
    "bmapback3": "Horizon3.pcx",
    "bmapback4": "Horizon4.pcx",
    "bmapback5": "Horizon5.pcx",
    "bmapback6": "Horizon6.pcx",
}


def _png_name(src: str) -> str:
    stem = Path(src).stem
    return f"{stem}.png".lower() if stem.lower() == stem.lower() else f"{stem}.png"


# Strips `//` line comments and `/* ... */` block comments before any regex
# scan runs. Found 2026-08-10 (GB-20 continued): AfterRac.wdl has a
# commented-out `//bmap sky = <GOlfSKY.pcx>;` line that BMAP_RE matched
# anyway (comments were never stripped), poisoning the single shared
# `bmaps` dict this whole scan mutates across every file in corpus order
# -- `Desert.wdl`/`Final.wdl`/`Intro3.wdl` all resolve their own real
# `SKY_MAP = sky;` assignments to that poisoned "sky" -> GOlfSKY.pcx
# entry instead of `WDL/Weather.wdl`'s real `BMAP sky = <sky.pcx>;`
# (scanned later, too late to correct files already processed), silently
# swapping in a fully-opaque, wrong-looking sky texture (a light cyan sky
# with soft white clouds) in place of the intended one (99.9% transparent,
# a handful of star-dot pixels) for those three levels specifically.
_LINE_COMMENT_RE = re.compile(r"//[^\n]*")
_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)


def _strip_comments(text: str) -> str:
    text = _BLOCK_COMMENT_RE.sub("", text)
    text = _LINE_COMMENT_RE.sub("", text)
    return text


def main() -> int:
    bmaps: dict[str, str] = dict(DEFAULT_BMAPS)
    levels: dict[str, dict] = {}

    files: list[Path] = []
    for d in WDL_DIRS:
        if d.is_dir():
            files.extend(sorted(d.glob("*.wdl")))
            files.extend(sorted(d.glob("*.WDL")))

    for path in files:
        text = _strip_comments(path.read_text(encoding="latin-1", errors="replace"))
        for m in BMAP_RE.finditer(text):
            bmaps[m.group(1).lower()] = m.group(2)

        scenes = SCENE_RE.findall(text)
        skys = SKY_RE.findall(text)
        if not scenes and not skys:
            continue
        # Level name from Script.wdl → Script
        stem = path.stem
        if stem.lower() in ("io", "dialog", "diialog", "weather", "movie1", "movie2", "movie3"):
            continue
        entry = levels.setdefault(stem.lower(), {"script": path.name})
        if scenes:
            # Last assignment in file wins (matches typical main())
            sym = scenes[-1].lower()
            src = bmaps.get(sym, "")
            entry["scene_map_symbol"] = sym
            entry["scene_map"] = _png_name(src) if src else ""
            if sym in ("null", "none"):
                entry["scene_map"] = ""
                entry["indoor"] = True
        if skys:
            sym = skys[-1].lower()
            src = bmaps.get(sym, "")
            entry["sky_map_symbol"] = sym
            entry["sky_map"] = _png_name(src) if src else "sky.png"

    # Indoor defaults
    for name in ("studio", "menu", "credits", "vilend"):
        levels.setdefault(name, {})["indoor"] = True

    out = {
        "bmaps": {k: _png_name(v) for k, v in sorted(bmaps.items())},
        "levels": dict(sorted(levels.items())),
        "defaults": {
            "sky_map": "sky.png",
            "cloud_map": "clds.png",
            "scene_map": "horizon.png",
        },
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, indent=2), encoding="utf-8")
    print(f"Wrote {OUT} ({len(levels)} level entries, {len(bmaps)} bmaps)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
