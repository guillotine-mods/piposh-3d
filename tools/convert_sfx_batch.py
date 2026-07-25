#!/usr/bin/env python3
"""Copy WAVs into assets/converted/sfx (Godot imports WAV natively).

Default: copy every WAV from original/piposh3d/SFX (needed for full scene
playback — Shiks alone uses dozens of SHK/PIP lines). Use --priority for a
tiny menu-only subset.
"""
from __future__ import annotations

import argparse
import shutil
from pathlib import Path

PRIORITY = [
    "SNG032.WAV",
    "MenuNew.wav",
    "MenuLoad.wav",
    "MenuExit.wav",
    "MenuCred.wav",
    "klick.wav",
    "click.wav",
    "Laugh.wav",
]


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    src = root / "original" / "piposh3d" / "SFX"
    dst = root / "assets" / "converted" / "sfx"
    dst.mkdir(parents=True, exist_ok=True)

    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--priority",
        action="store_true",
        help="Copy only a tiny menu SFX set (default copies ALL wavs)",
    )
    args = ap.parse_args()

    index = {p.name.lower(): p for p in src.iterdir() if p.is_file()}
    copied = 0
    if args.priority:
        for name in PRIORITY:
            p = index.get(name.lower())
            if p:
                shutil.copy2(p, dst / p.name)
                copied += 1
                print("copied", p.name)
            else:
                print("missing", name)
    else:
        for p in sorted(src.iterdir()):
            if p.is_file() and p.suffix.lower() in {".wav", ".aif", ".aiff"}:
                shutil.copy2(p, dst / p.name)
                copied += 1
    print(f"SFX files in {dst}: {copied}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
