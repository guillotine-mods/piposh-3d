#!/usr/bin/env python3
"""Whole-corpus parsing/placement audit — the "one parse, not one bug at a
time" check requested after the facing/feet-snap regression loop documented
in docs/SESSION_LOG.md (2026-07-27/28). Existing tools/verify_*.py scripts
are correct but sample a handful of named models; this runs every check
against the *entire* asset set in one pass, so a gap shows up here instead
of via a playtest report weeks later.

Four sections, each grounded in a method already proven this project
(docs/CONTRACT.md), not a new heuristic:

1. Brush extraction — every WMB in the game must reconstruct with (near-)
   zero skipped faces (extract_wmb_mesh.extract_brush).
2. Prop coverage — every .wmb/.mdl any entity `file` field references must
   have a generated .glb (validate_levels.py only checks .mdl; this adds the
   .wmb half, which was previously uninstrumented and had to be checked by
   hand).
3. Feet-snap audit — for every stem currently excluded from feet-snap in
   wmb_level_loader.gd, print its measured GLB local-Y AABB fraction below
   the WED origin next to whether its real WDL `action` body ever assigns
   my.x/y/z at runtime. This is the same two-part method that found the
   Cockpit/TV/Hanger/TowerW bugs, kept as a standing tool instead of a
   one-off investigation.
4. Facing regression guard — replays the Yachdal/Crowd/Crowd2 bearing-
   consistency check from SESSION_LOG 2026-07-27. Building this check
   surfaced a real limitation worth recording: the metric's *sign* cannot
   be trusted (the human-confirmed-WRONG value and the human-confirmed-
   CORRECT value both score high concentration, ~180 deg apart) -- see the
   docstring on check_facing_regression() for the numbers. It therefore
   only guards against concentration collapsing or drifting far from
   today's confirmed baseline, not against an absolute direction.
5. Morph-target coverage — Acknex `morph(<File.mdl>, entity)` swaps an
   entity to a different MDL's mesh/anim/skin set at runtime (243 call
   sites across 28 level scripts, previously entirely unimplemented —
   see MdlAnimator.morph_to() / wdl_director.gd._morph(), added
   2026-07-28). Whatever level script logic ends up calling morph_to(), it
   can only ever succeed if the target actually has a converted .glb; this
   checks all 113 distinct morph targets in one pass instead of finding
   missing ones one broken cutscene at a time.
"""
from __future__ import annotations

import json
import math
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import convert_mdl as cm  # noqa: E402
from extract_wmb_mesh import extract_brush  # noqa: E402
import verify_feet_snap_policy as fsp  # noqa: E402

WMB_SRC = ROOT / "original" / "piposh3d" / "WMB"
MDL_SRC = ROOT / "original" / "piposh3d" / "MDL"
WDL_FILES = sorted((ROOT / "original" / "piposh3d").glob("*.wdl")) + sorted(
    (ROOT / "original" / "piposh3d" / "WDL").glob("*.wdl")
)
LEVELS_DIR = ROOT / "assets" / "converted" / "levels"
MDL_GLB_DIR = ROOT / "assets" / "converted" / "mdl"
WMB_GLB_DIR = ROOT / "assets" / "converted" / "wmb"


# ---------------------------------------------------------------------------
# 1. Brush extraction
# ---------------------------------------------------------------------------
def check_brush_extraction() -> list[str]:
    problems = []
    total = 0
    for p in sorted(WMB_SRC.glob("*.[Ww][Mm][Bb]")):
        data = p.read_bytes()
        if data[:4] not in (b"WMB4", b"WMB5", b"WMB6"):
            continue
        total += 1
        mesh = extract_brush(data)
        if mesh is None:
            problems.append(f"{p.name}: no brush geometry reconstructed at all")
            continue
        if mesh["faces"] and mesh["skipped"] / mesh["faces"] > 0.01:
            problems.append(
                f"{p.name}: {mesh['skipped']}/{mesh['faces']} faces skipped "
                f"({mesh['skipped'] / mesh['faces']:.1%})"
            )
    print(f"[brush] {total} WMB files parsed, {len(problems)} with >1% skipped faces")
    for msg in problems:
        print(f"  PROBLEM {msg}")
    return problems


# ---------------------------------------------------------------------------
# 2. Prop coverage (.wmb + .mdl referenced by any entity, generalizes
#    validate_levels.py which only checks the .mdl half)
# ---------------------------------------------------------------------------
def check_prop_coverage() -> list[str]:
    mdl_glbs = {p.stem.lower() for p in MDL_GLB_DIR.glob("*.glb")}
    wmb_glbs = {p.stem.lower() for p in WMB_GLB_DIR.glob("*.glb")}
    refs_wmb: set[str] = set()
    refs_mdl: set[str] = set()
    for jf in sorted(LEVELS_DIR.glob("*.json")):
        if jf.name == "levels.json":
            continue
        data = json.loads(jf.read_text(encoding="utf-8", errors="replace"))
        for o in data.get("objects", []):
            if o.get("type") != "entity":
                continue
            file = str(o.get("file", ""))
            if not file:
                continue
            ext = Path(file).suffix.lower()
            stem = Path(file).stem.lower()
            if not stem:
                continue
            if ext == ".wmb":
                refs_wmb.add(stem)
            elif ext == ".mdl":
                refs_mdl.add(stem)

    problems = []
    for stem in sorted(refs_wmb - wmb_glbs):
        problems.append(f"{stem}.wmb: referenced by an entity, no assets/converted/wmb/{stem}.glb")
    for stem in sorted(refs_mdl - mdl_glbs):
        problems.append(f"{stem}.mdl: referenced by an entity, no assets/converted/mdl/{stem}.glb")
    print(
        f"[coverage] {len(refs_wmb)} distinct .wmb + {len(refs_mdl)} distinct .mdl "
        f"props referenced, {len(problems)} missing"
    )
    for msg in problems:
        print(f"  PROBLEM {msg}")
    return problems


# ---------------------------------------------------------------------------
# 3. Feet-snap audit (measured, not asserted)
# ---------------------------------------------------------------------------
def _glb_y_span(stem: str) -> tuple[float, float] | None:
    p = MDL_GLB_DIR / f"{stem}.glb"
    if not p.is_file():
        return None
    data = p.read_bytes()
    if data[:4] != b"glTF":
        return None
    off = 12
    gltf = None
    while off < len(data):
        clen, ctype = struct.unpack_from("<I4s", data, off)
        off += 8
        chunk = data[off : off + clen]
        off += clen
        if ctype == b"JSON":
            gltf = json.loads(chunk.decode("utf-8"))
    if gltf is None:
        return None
    ymins, ymaxs = [], []
    for mesh in gltf.get("meshes", []):
        for prim in mesh.get("primitives", []):
            acc = gltf["accessors"][prim["attributes"]["POSITION"]]
            if "min" in acc and "max" in acc:
                ymins.append(acc["min"][1])
                ymaxs.append(acc["max"][1])
    if not ymins:
        return None
    return min(ymins), max(ymaxs)


def _action_moves_position(action: str) -> bool:
    """Grep every real WDL definition of this action for my.x/y/z writes."""
    if not action:
        return False
    pat_def = re.compile(rf"^\s*action\s+{re.escape(action)}\b", re.IGNORECASE | re.MULTILINE)
    pat_move = re.compile(r"\bmy\.[xyz]\s*[+\-*/]?=", re.IGNORECASE)
    for wdl in WDL_FILES:
        text = wdl.read_text(encoding="latin-1", errors="replace")
        for m in pat_def.finditer(text):
            start = text.find("{", m.end())
            if start < 0:
                continue
            depth = 0
            end = start
            for i, ch in enumerate(text[start:], start):
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        end = i
                        break
            body = text[start:end]
            if pat_move.search(body):
                return True
    return False


# Stems currently excluded from feet-snap in wmb_level_loader.gd /
# verify_feet_snap_policy.py, each with the WDL action(s) actually used on
# its placements (from assets/converted/levels/*.json), so the "moves at
# runtime" column reflects the real game data, not a guess at the action name.
_AUDIT_STEMS = [
    "glass", "b747", "island", "headphon", "biplane", "biplane2", "dutyfree",
    # Regression watch: previously-excluded, now-included stems. If a level
    # ever needs them excluded again, this print is where to look first.
    "tv", "hanger", "towerw", "cockpit",
]


def check_feet_snap_audit() -> None:
    print("[feet-snap audit] stem: below-origin% | moves-at-runtime? | currently excluded?")
    action_by_stem: dict[str, set[str]] = {}
    for jf in sorted(LEVELS_DIR.glob("*.json")):
        if jf.name == "levels.json":
            continue
        data = json.loads(jf.read_text(encoding="utf-8", errors="replace"))
        for o in data.get("objects", []):
            if o.get("type") != "entity":
                continue
            stem = Path(str(o.get("file", ""))).stem.lower()
            if stem in _AUDIT_STEMS:
                action_by_stem.setdefault(stem, set()).add(str(o.get("action", "")))

    for stem in _AUDIT_STEMS:
        span = _glb_y_span(stem)
        pct = "?"
        if span is not None:
            ymin, ymax = span
            if ymax > ymin:
                pct = f"{-ymin / (ymax - ymin):.1%}" if ymin < 0 else "0.0%"
        actions = action_by_stem.get(stem, set())
        moves = any(_action_moves_position(a) for a in actions if a)
        excluded = fsp.should_feet_snap("", stem) is False
        print(
            f"  {stem:10s} below={pct:>7s}  moves={'yes' if moves else 'no':3s}  "
            f"actions={sorted(a for a in actions if a) or ['(blank)']}  excluded={excluded}"
        )


# ---------------------------------------------------------------------------
# 4. Facing regression guard (Yachdal / Crowd / Crowd2 bearing consistency)
# ---------------------------------------------------------------------------
def check_facing_regression() -> list[str]:
    """IMPORTANT CAVEAT, found while building this check (2026-07-28): this
    metric's absolute *sign* cannot be trusted as "0 deg = correct". Running
    it against the OLD, human-confirmed-WRONG allowlist value (Crowd=90,
    reverted 2026-07-28) reproduces the exact number SESSION_LOG already
    recorded for it (mean_dev=-2.9 deg, R=0.906) -- i.e. the WRONG facing
    scores as "pointing at Yachdal" by this metric, and the CURRENT,
    human-confirmed-CORRECT value (270) scores mean_dev=+177.1 deg instead.
    docs/PLAYTEST.md already warned about exactly this: a bearing check can
    prove *some* vector points at the landmark, never that the rendered
    face does -- it cannot resolve a 180-degree ambiguity, only a human
    render can (CONTRACT.md rule 3). So this check does NOT assert an
    absolute "faces the landmark" direction. It asserts two things that
    don't require resolving that ambiguity: (a) concentration R stays high
    (the crowd's facings stay *coherent* relative to Yachdal -- a collapse
    would mean pan reading itself broke), and (b) mean_dev doesn't drift far
    from today's human-confirmed baseline (177.1 deg) -- catching an
    accidental revert to the old value (which would jump it back to ~-2.9)
    without claiming to know which absolute value "looks right".
    """
    problems = []
    start_json = LEVELS_DIR / "Start.json"
    if not start_json.is_file():
        print("[facing] SKIP: no Start.json")
        return problems
    data = json.loads(start_json.read_text(encoding="utf-8"))
    ents = [o for o in data.get("objects", []) if o.get("type") == "entity"]

    def stem_of(o: dict) -> str:
        return Path(str(o.get("file", ""))).stem.lower()

    yachdal = next((o for o in ents if stem_of(o) == "yachdal"), None)
    crowd = [o for o in ents if stem_of(o) in ("crowd", "crowd2")]
    if yachdal is None or len(crowd) < 3:
        print("[facing] SKIP: Yachdal/Crowd placements not found as expected")
        return problems

    yx, yy = yachdal["origin_gs"][0], yachdal["origin_gs"][1]
    allow = cm._yaw_allowlist()
    diffs = []
    for o in crowd:
        cx, cy = o["origin_gs"][0], o["origin_gs"][1]
        pan = float(o["angle_gs"][0])
        extra = allow.get(stem_of(o), 0.0)
        facing = math.radians(pan + extra)
        bearing = math.atan2(yy - cy, yx - cx)
        diffs.append(math.atan2(math.sin(facing - bearing), math.cos(facing - bearing)))

    mean_cos = sum(math.cos(d) for d in diffs) / len(diffs)
    mean_sin = sum(math.sin(d) for d in diffs) / len(diffs)
    r = math.hypot(mean_cos, mean_sin)
    mean_dev = math.degrees(math.atan2(mean_sin, mean_cos))
    print(
        f"[facing] Crowd/Crowd2 -> Yachdal bearing check: n={len(diffs)} "
        f"mean_dev={mean_dev:.1f} deg  R={r:.3f}  (see docstring: sign is NOT "
        f"validated, only drift-from-baseline is checked)"
    )
    baseline_mean_dev = 177.1
    drift = abs(math.degrees(math.atan2(
        math.sin(math.radians(mean_dev - baseline_mean_dev)),
        math.cos(math.radians(mean_dev - baseline_mean_dev)),
    )))
    if r < 0.7:
        problems.append(f"Crowd/Crowd2 facing no longer converges on Yachdal (R={r:.3f})")
    if drift > 45.0:
        problems.append(
            f"Crowd/Crowd2 mean facing offset drifted {drift:.1f} deg from the "
            f"2026-07-28 human-confirmed baseline ({baseline_mean_dev} deg) -- "
            f"re-verify visually via tools/wmb_web_viewer.py before trusting "
            f"either the old or new number"
        )
    return problems


# ---------------------------------------------------------------------------
# 5. Morph-target coverage
# ---------------------------------------------------------------------------
def check_morph_coverage() -> list[str]:
    targets: set[str] = set()
    for wdl in WDL_FILES:
        text = wdl.read_text(encoding="latin-1", errors="replace")
        for m in re.finditer(r"morph\s*\(\s*<([^>]+)>", text, re.IGNORECASE):
            targets.add(m.group(1).strip())

    mdl_glbs = {p.stem.lower() for p in MDL_GLB_DIR.glob("*.glb")}
    problems = []
    checked = 0
    for t in sorted(targets):
        stem = Path(t).stem
        ext = Path(t).suffix.lower()
        if ext != ".mdl":
            # A few morph() targets are .wmb (brush/road-segment swaps, e.g.
            # Desert's DRoad*/DesGr* set) -- a different mechanism than the
            # MdlAnimator.morph_to() primitive this checks, out of scope here.
            continue
        checked += 1
        if stem.lower() not in mdl_glbs:
            problems.append(f"{t}: morph() target, no assets/converted/mdl/{stem}.glb")
    print(
        f"[morph] {len(targets)} distinct morph() targets ({checked} .mdl), "
        f"{len(problems)} missing a converted .glb"
    )
    for msg in problems:
        print(f"  PROBLEM {msg}")
    return problems


def main() -> int:
    all_problems: list[str] = []
    all_problems += check_brush_extraction()
    all_problems += check_prop_coverage()
    check_feet_snap_audit()
    all_problems += check_facing_regression()
    all_problems += check_morph_coverage()

    if all_problems:
        print(f"\nverify_corpus: {len(all_problems)} problem(s)")
        return 1
    print("\nverify_corpus: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
