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

REBASELINE 2026-08-10 -- four entries (final/race/weather/war) were RAISED.
Read this before assuming a bug was papered over.
-------------------------------------------------------------------------
This was NOT "the numbers moved, so update the numbers". The four counts
below rose because commit a378bc0 (2026-08-01) made parse_wdl.py parse two
constructs it had previously thrown away *silently*; the recorded baselines
were last written in commit 0937726 (2026-07-28) and were never updated with
it, so they had been describing a parser that no longer exists for nine days.
Four independent checks, each of which alone would settle it:

1. The committed assets already agree with the new numbers. Every one of the
   85 files parses today to exactly the `skip_count` stored in the committed
   `assets/converted/wdl_ast/<Stem>.json` (Final 2/2, Race 3/3, Weather
   19/19, war 33/33 -- 0 files differing, and the stored `skipped` lists are
   element-for-element identical too). The verifier's baselines disagreed
   with the very artifacts the parser produces.
2. Running the PRE-a378bc0 parser (`git show a378bc0^:tools/parse_wdl.py`)
   over the same four sources reproduces 0 / 1 / 17 / 27 -- the four stale
   baseline values, exactly. The baselines are a fingerprint of the old
   parser, not of a healthy corpus.
3. `verify_wdl_parse.py` itself is byte-identical (modulo line endings) to
   its 0937726 version, i.e. nothing here was edited between then and now --
   the drift is entirely on the parser side.
4. Diffing the old and new skip LISTS shows only additions, never a lost
   line: the parser did not start failing on anything it used to handle.

What actually changed, per file, from that list diff:

* final (0 -> 2), race (1 -> 3), weather (17 -> 19) -- a378bc0 added
  `Parser.parse_panel()`, so `panel NAME { ... }` blocks now become real AST
  data (they previously fell through the generic "unknown top-level
  construct" path, which consumes a balanced brace group and records
  NOTHING). Each of these three files has one panel field whose value is a
  dotted engine reference -- `window ...,player.health` (Final.wdl:86),
  `digits ...,player.lap` (Race.wdl:85), `DIGITS ...,camera.fog`
  (Weather.wdl:43). `_parse_panel_atom()` has no dotted-reference form, so
  the field errors out ("expected a name, got '.'") and the panel's own
  closing `}` is then left at top level, producing the paired "stray '}'".
  Hence exactly +2 each, in the same panel, every time.
* war (27 -> 33) -- a378bc0 also added the bare top-level assignment branch
  (`ident` followed by `=`/`+=`/...) so bindings like Range's
  `on_mouse_left = Fire;` become executable statements. All six new war
  entries are that shape and all are bit shifts the expression grammar does
  not implement: `pap_pack1 += temp << 6;` (1977), `<< 12` (1986),
  `<< 10` (2003), `<< 15` (2021), `<< 5` (2030), `>> 10` (2040). These lines
  sit inside function bodies and are only seen at top level because an
  earlier recovery already resynced there; before a378bc0 they were eaten by
  the same silent unknown-decl skip.

So both deltas are previously-INVISIBLE discards becoming visible, plus two
genuine grammar gaps now named out loud: (a) dotted refs as panel field
values, (b) the `<<`/`>>` operators. Neither is a parse regression, and
neither is newly broken -- the data was being dropped before, just without a
number attached. Fixing either gap is a parse_wdl.py change; when that
happens these counts will DROP, and dropping is always allowed here.

`war` is recorded as 33, NOT 20. The AST's `"skipped"` array is truncated by
`p.skipped[:20]` in parse_wdl.py's `to_json()`, so `war.json` lists only 20
lines -- but its sibling `"skip_count"` field records the true 33, and this
verifier compares against `len(p.skipped)`, the uncapped in-memory list.
Baselining war at 20 would leave the gate permanently red for no reason.
Same cap applies to adept2/animate/venture, whose existing entries (38/29/32)
are likewise the true counts, not the stored 20.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import parse_wdl as pw  # noqa: E402

# Recorded 2026-07-28 after the stray-top-level-`}` recovery fix; four
# entries refreshed 2026-08-10 for the a378bc0 parser changes (see the
# REBASELINE note in the module docstring -- each of those four is marked
# inline below). A file not listed here must parse with 0 skips; a listed
# file may not regress past its recorded count.
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
    # 2026-08-10: 0 -> 2 (was absent, i.e. implicitly 0). `panel bpwr`'s
    # `window 5,5,19,346,bpwr,0,player.health;` (Final.wdl:86) -- dotted ref
    # in a panel field, + the panel's orphaned `}`. Not a regression; see
    # the REBASELINE note above.
    "final": 2,
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
    # 2026-08-10: 1 -> 3. `digits 250,60,1,standard_font,1,player.lap;`
    # (Race.wdl:85) -- same dotted-ref-in-panel gap as final/weather, + the
    # panel's orphaned `}`. Not a regression; see the REBASELINE note above.
    "race": 3,
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
    # 2026-08-10: 27 -> 33, and 33 is deliberate -- the AST's `skipped` list
    # is capped at 20 by parse_wdl.py's `p.skipped[:20]`, but its
    # `skip_count` field and this check both use the true, uncapped count.
    # The six added lines are all `pap_pack1/2 += temp <</>> N;` bit shifts
    # (war.wdl:1977/1986/2003/2021/2030/2040), newly *visible* via a378bc0's
    # top-level bare-assignment branch. Not a regression; see above.
    "war": 33,
    # 2026-08-10: 17 -> 19. `DIGITS 065,25,3,standard_font,1,camera.fog;`
    # (Weather.wdl:43) -- same dotted-ref-in-panel gap as final/race, + the
    # panel's orphaned `}`. Not a regression; see the REBASELINE note above.
    "weather": 19,
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
