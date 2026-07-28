#!/usr/bin/env python3
"""Whole-corpus WDL parse check (docs/CONTRACT.md, tools/parse_wdl.py).

Fails only on regressions against a recorded per-file skip baseline, not on
an absolute zero-skip bar. Most of the corpus (~55 files, updated
2026-07-28) has 1-2 skipped decls each: `function Blink()` (and its twin
`Blink2()`) has one extra closing brace, a genuine authoring bug shared
across the game's WDL corpus (verified byte-for-byte by counting `{`/`}`
depth through the real source in several files -- it goes to -1, not 0, not
a guess). The parser recovers from a stray top-level `}` by consuming just
that one token, so this no longer eats the next function/action's body the
way it silently did before that recovery path was added -- see
docs/SESSION_LOG.md 2026-07-28 for how the original silent-data-loss bug was
found (Intro2.wdl's `Blink2`/`DoDialog` were completely missing from the
parsed output with zero recorded errors).

A handful of files (the unused Conitec SDK template scripts:
Menu/venture/adept2/auftrag.wdl -- note `menu.wdl`/`Menu.wdl` name-collide;
this baseline is for the *unused* `WDL/menu.wdl` copy, see parse_wdl.py's
top-level-file-wins dedup) are known-imperfect and out of scope; confirmed
via include-graph search that none of these are referenced by any real
level script.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import parse_wdl as pw  # noqa: E402

# Recorded 2026-07-28 after the stray-top-level-`}` recovery fix. A file not
# listed here must parse with 0 skips; a listed file may not regress past
# its recorded count.
KNOWN_SKIPS = {
    "adept2": 38,
    "aftermin": 1,
    "afterrac": 1,
    "animate": 29,
    "asyact1": 2,
    "asyact2": 2,
    "auftrag": 16,
    "cardgame": 2,
    "cards": 1,
    "credits": 1,
    "desert": 2,
    "doors": 18,
    "dutyfree": 2,
    "ending": 1,
    # Genuine source typo, not a grammar gap: `if (player.health) > 0 { ... }`
    # -- an extra `)` after the condition, which then desyncs a few
    # subsequent stray-`}` recoveries. Confirmed 2026-07-27/28, not chasing
    # further (see docs/SESSION_LOG.md).
    "fight": 8,
    "golf": 1,
    "inn": 2,
    "inshrine": 2,
    "intro10": 1,
    "intro11": 1,
    "intro12": 1,
    "intro13": 1,
    "intro14": 1,
    "intro16": 1,
    "intro2": 2,
    "intro3": 2,
    "intro5": 2,
    "intro6": 1,
    "intro7": 1,
    "intro8": 1,
    "io": 1,
    "mansion": 2,
    "menu": 1,
    "moi": 1,
    "mount": 1,
    "move": 11,
    "movement": 1,
    "olympic": 2,
    "outro": 5,
    "particle": 2,
    "plane": 2,
    "plane2": 2,
    "plane3": 1,
    "race": 1,
    "range": 1,
    "shiks": 1,
    "shooter": 1,
    "smash": 2,
    "start": 1,
    "studio": 1,
    "taxi": 2,
    "temple": 2,
    "travel": 2,
    "venture": 32,
    "vilend": 3,
    "vilint": 1,
    "war": 27,
    "weather": 17,
    "ziggy": 1,
}


def main() -> int:
    src = ROOT / "original" / "piposh3d"
    # Same top-level-wins dedup as parse_wdl.py's main() -- e.g. the real
    # `Menu.wdl` vs. the unused SDK template `WDL/menu.wdl` share a stem;
    # checking both under one baseline entry is meaningless since only the
    # top-level one ever reaches assets/converted/wdl_ast/.
    by_stem: dict[str, Path] = {}
    for f in sorted((src / "WDL").glob("*.wdl")):
        by_stem[f.stem.lower()] = f
    for f in sorted(src.glob("*.wdl")):
        by_stem[f.stem.lower()] = f
    files = sorted(by_stem.values(), key=lambda p: p.name)
    failed = 0
    total_skip = 0
    for f in files:
        p = pw.parse_file(f)
        n = len(p.skipped)
        total_skip += n
        allowed = KNOWN_SKIPS.get(f.stem.lower(), 0)
        if n > allowed:
            failed += 1
            print(f"FAIL {f.name}: {n} skipped decls (baseline allows {allowed})")
            for s in p.skipped[:5]:
                print(f"   {s}")
        elif n > 0:
            print(f"OK {f.name}: {n} skipped decls (within recorded baseline {allowed})")
    print(f"\n{len(files)} files, {total_skip} total skipped decls")
    if failed:
        print(f"verify_wdl_parse: {failed} file(s) regressed past baseline")
        return 1
    print("verify_wdl_parse: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
