#!/usr/bin/env python3
"""Convert Piposh 3D GFX (PCX/BMP) to PNG for Godot.

Acknex panel/bmap `overlay` treats pure black as transparent — apply the same
color-key here so UI (Opt bars, subtitles, cursors) doesn't draw black boxes.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def color_key_black(im: Image.Image, threshold: int = 0) -> Image.Image:
    """Make near-black pixels transparent (A5 overlay)."""
    rgba = np.array(im.convert("RGBA"), dtype=np.uint8)
    if threshold <= 0:
        mask = (rgba[:, :, 0] == 0) & (rgba[:, :, 1] == 0) & (rgba[:, :, 2] == 0)
    else:
        mask = (
            (rgba[:, :, 0] <= threshold)
            & (rgba[:, :, 1] <= threshold)
            & (rgba[:, :, 2] <= threshold)
        )
    rgba[mask, 3] = 0
    return Image.fromarray(rgba, "RGBA")


def convert_one(src: Path, dst: Path) -> bool:
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        with Image.open(src) as im:
            out = color_key_black(im, threshold=0)
            out.save(dst, "PNG")
        return True
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL {src.name}: {exc}", file=sys.stderr)
        return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--src",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "original" / "piposh3d" / "GFX",
    )
    ap.add_argument(
        "--dst",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "assets" / "converted" / "gfx",
    )
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--only", nargs="*", default=[])
    args = ap.parse_args()

    files = sorted(
        [p for p in args.src.iterdir() if p.suffix.lower() in {".pcx", ".bmp", ".tga", ".png"}]
    )
    if args.only:
        want = {n.lower().removesuffix(".pcx").removesuffix(".png").removesuffix(".bmp") for n in args.only}
        files = [f for f in files if f.stem.lower() in want]
    if args.limit:
        files = files[: args.limit]

    ok = 0
    for src in files:
        dst = args.dst / (src.stem + ".png")
        if convert_one(src, dst):
            ok += 1
    print(f"Converted {ok}/{len(files)} -> {args.dst}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
