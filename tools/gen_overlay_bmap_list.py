#!/usr/bin/env python3
"""Regenerate `convert_gfx.py`'s `NON_OVERLAY_BMAPS` set from the real WDL
corpus. Prints the sorted list (paste into `convert_gfx.py` by hand — kept
as a plain literal there, not imported, so a corpus re-scan can't silently
change conversion output without a reviewed diff).

Parses every `panel NAME { ... }` block across every original `.wdl` file
for its `bmap` and whether `overlay` appears in that panel's own `flags`,
then resolves the symbolic bmap name back to a real filename via the
matching `bmap SYM = <File.pcx>;` declaration (or an inline
`bmap = <File.pcx>;` inside the panel itself). A bitmap used by ANY
overlay panel is excluded from the non-overlay set, even if some other
panel uses it without `overlay` -- exits with an error listing the
ambiguous names instead of guessing, since none have been observed in this
corpus (2026-07-31) and a real one would need a human decision, not an
automatic pick.

Run: python tools/gen_overlay_bmap_list.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "original" / "piposh3d"

_BMAP_DECL = re.compile(r"(?i)\bbmap\s+(\w+)\s*=\s*<([^,>]+)", re.MULTILINE)
_PANEL_BLOCK = re.compile(r"(?i)\bpanel\s+\w+\s*\{([^}]*)\}", re.DOTALL)
_INLINE_BMAP = re.compile(r"(?i)\bbmap\s*=\s*<([^,>]+)")
_SYMBOL_BMAP = re.compile(r"(?i)\bbmap\s*=\s*(\w+)\s*;")


def main() -> int:
    wdl_files = sorted(SRC.glob("*.wdl")) + sorted((SRC / "WDL").glob("*.wdl"))

    bmap_to_files: dict[str, set[str]] = {}
    for f in wdl_files:
        text = f.read_text(encoding="latin-1")
        for m in _BMAP_DECL.finditer(text):
            sym, fname = m.group(1).lower(), m.group(2).strip()
            stem = fname.rsplit(".", 1)[0]
            bmap_to_files.setdefault(sym, set()).add(stem)

    overlay_files: set[str] = set()
    non_overlay_files: set[str] = set()
    for f in wdl_files:
        text = f.read_text(encoding="latin-1")
        for m in _PANEL_BLOCK.finditer(text):
            body = m.group(1)
            has_overlay = bool(re.search(r"(?i)\boverlay\b", body))
            files_here: set[str] = set()
            sym_m = _SYMBOL_BMAP.search(body)
            if sym_m:
                files_here |= bmap_to_files.get(sym_m.group(1).lower(), set())
            for im in _INLINE_BMAP.finditer(body):
                files_here.add(im.group(1).strip().rsplit(".", 1)[0])
            (overlay_files if has_overlay else non_overlay_files).update(files_here)

    ambiguous = overlay_files & non_overlay_files
    if ambiguous:
        print(f"ERROR: {len(ambiguous)} bmap(s) used both with and without "
              f"`overlay` -- needs a human decision, not an automatic pick:",
              file=sys.stderr)
        for n in sorted(ambiguous):
            print(f"  {n}", file=sys.stderr)
        return 1

    clean = sorted(non_overlay_files - overlay_files)
    print(f"# {len(clean)} non-overlay bmaps (render opaque, no colorkey):")
    for n in clean:
        print(f'    "{n}",')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
