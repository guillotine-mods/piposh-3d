#!/usr/bin/env python3
"""Fail if any committed GLB lacks a NORMAL vertex attribute (PORTING_MANUAL.md
Phase 0 item 6 / Phase 2 gate).

As of the 2026-07-29 audit, all 784 converted GLBs have zero NORMAL
attributes -- meshes rely on Godot's importer synthesizing flat normals from
face winding, which produces harsh faceting and, with culling disabled,
incorrectly lit back faces (PORTING_MANUAL.md §3.3a). This script is
expected to fail on every file until Phase 2 recovers real per-face normals
from the WMB plane list / MDL vertex data (PORTING_MANUAL.md §4 Phase 2 step
1). Wired into CI as a non-blocking status check until then; flip it to a
required gate once Phase 2 lands.

Runs only against committed assets/converted/**/*.glb -- no dependency on
the gitignored original/ dump, so it works on a clean clone.

Usage:
    python tools/verify_normals.py
    python tools/verify_normals.py --root assets/converted/mdl
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_json_chunk(path: Path) -> dict | None:
    data = path.read_bytes()
    if len(data) < 12 or data[:4] != b"glTF":
        return None
    off = 12
    length = struct.unpack_from("<I", data, 8)[0]
    while off < length:
        chunk_len, chunk_type = struct.unpack_from("<I4s", data, off)
        chunk_start = off + 8
        if chunk_type == b"JSON":
            try:
                return json.loads(data[chunk_start : chunk_start + chunk_len])
            except json.JSONDecodeError:
                return None
        off = chunk_start + chunk_len
    return None


def missing_normal_primitives(doc: dict) -> int:
    """Count primitives across all meshes that lack a NORMAL attribute."""
    count = 0
    for mesh in doc.get("meshes", []):
        for prim in mesh.get("primitives", []):
            if "NORMAL" not in prim.get("attributes", {}):
                count += 1
    return count


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--root",
        type=Path,
        default=ROOT / "assets" / "converted",
        help="directory to scan for .glb files (default: assets/converted)",
    )
    args = ap.parse_args()

    files = sorted(args.root.rglob("*.glb"))
    if not files:
        print(f"No .glb files found under {args.root}")
        return 1

    failures: list[Path] = []
    unparseable: list[Path] = []
    for f in files:
        doc = read_json_chunk(f)
        if doc is None:
            unparseable.append(f)
            continue
        if missing_normal_primitives(doc) > 0:
            failures.append(f)

    for f in unparseable:
        print(f"SKIP  {f.relative_to(ROOT)}: could not read JSON chunk (see verify_gltf_strict.py)")
    for f in failures:
        print(f"FAIL  {f.relative_to(ROOT)}: missing NORMAL attribute on at least one primitive")

    print(
        f"\n{len(files)} .glb file(s) checked, {len(failures)} missing normals, "
        f"{len(unparseable)} unparseable."
    )
    return 1 if failures or unparseable else 0


if __name__ == "__main__":
    raise SystemExit(main())
