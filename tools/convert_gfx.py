#!/usr/bin/env python3
"""Convert Piposh 3D GFX (PCX/BMP) to PNG for Godot.

Acknex panel/bmap `overlay` treats pure black as transparent — apply the same
color-key here so UI (Opt bars, subtitles, cursors) doesn't draw black boxes.

Only bitmaps actually used by a `panel { ... flags = ...overlay...; }` should
get this treatment -- a panel WITHOUT the `overlay` flag renders its bmap
opaque, black background and all (2026-07-31: Studio/Start's own subtitle
system, `panel pSom`/`panel pOvr`, has no `overlay` flag -- it's meant to
show as a solid black bar with green text, not just floating green glyphs;
blanket-colorkeying every GFX file made that black bar vanish, which read as
"the HUD text isn't showing" even though the (now much harder to spot,
low-contrast) glyphs were technically still being drawn). `NON_OVERLAY_BMAPS`
below is a real corpus measurement, not a guess: every `panel NAME { ... }`
block across every original `.wdl` file was parsed for its `bmap` and
whether `overlay` appears in its own `flags`, then resolved back to a real
filename via the matching `bmap SYM = <File.pcx>;` declaration. Zero
filenames were used both ways (with and without `overlay`) across the whole
corpus, so this split is unambiguous, not a per-level judgment call. Files
that never showed up in a panel block at all keep the historical (colorkey)
behavior — safer to keep matching current, unreported-as-broken output than
to guess a new default for something never measured. Regenerate this set
with `tools/gen_overlay_bmap_list.py` if `original/piposh3d/*.wdl` changes.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

# Corpus measurement (2026-07-31) — see module docstring. Every filename
# here was confirmed used ONLY by panels lacking `overlay` in their flags;
# it must render opaque, not colorkeyed. Lowercased for case-insensitive
# matching against the source file's stem.
NON_OVERLAY_BMAPS: frozenset[str] = frozenset(
    n.lower()
    for n in (
        "2Min", "A5", "Ami", "Credits", "Cube", "FIN", "Fatass1", "Fight",
        "GIR1", "Glf1", "LastLev", "Loading01", "Loading02", "Loading03",
        "Loading04", "Loading05", "Loading06", "Loading07", "Loading08",
        "Loading09", "Loading10", "Loading11", "Loading12", "Loading13",
        "Loading14", "Loading15", "Loading16", "Loading17", "Loading18",
        "Loading19", "Loading20", "Loading21", "Loading22", "Loading23",
        "Mov1", "N2", "NVision", "NoMap", "NoSave", "Piposh1", "Save",
        "Shkufit", "Shkufit1", "Skuf", "Someover", "Somewher", "Stage",
        "Wart1", "Zimimbk", "afri1", "afri2", "credits", "icn_vol1",
        "icn_vol2", "icn_vol3", "icn_vol4", "icn_vol5", "mod1", "mod2",
        "pigs", "temple", "txt1", "txt7",
    )
)


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
            if src.stem.lower() in NON_OVERLAY_BMAPS:
                out = im.convert("RGBA")
            else:
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
