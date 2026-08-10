#!/usr/bin/env python3
"""Fail if any committed GLB lacks a usable NORMAL vertex attribute
(PORTING_MANUAL.md Phase 0 item 6 / Phase 2 gate).

As of the 2026-07-29 audit, all 784 converted GLBs have zero NORMAL
attributes -- meshes rely on Godot's importer synthesizing flat normals from
face winding, which produces harsh faceting and, with culling disabled,
incorrectly lit back faces (PORTING_MANUAL.md §3.3a). This script is
expected to fail on every file until the corpus is regenerated with real
normals. Wired into CI as a non-blocking status check until then; flip it to
a required gate once Phase 2 lands.

Source of brush normals (measured 2026-08-10, tools/normals_probe.py):
PORTING_MANUAL.md §3.3(a) guessed the WMB face record's plane index at bytes
0-3. It is actually at bytes **20-23**, with a side flag at bytes 2-3;
n_gs = +plane.normal when side==0, -plane.normal when side==1. All 312,196
faces across the 134 shipped WMBs resolve to an in-range plane with a unit
normal. `tools/extract_wmb_mesh.py --normals` emits them; that flag is OFF by
default, so the committed corpus is unchanged until someone regenerates it.

Checks per primitive: NORMAL present, float32 VEC3, count == POSITION count,
and every normal unit length (a NORMAL accessor full of zeros or unnormalized
vectors is worse than none at all).

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

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
UNIT_TOL = 1e-3


def _rel(path: Path) -> str:
    """Path relative to the repo root when possible; --root may be outside it."""
    try:
        return str(path.resolve().relative_to(ROOT))
    except ValueError:
        return str(path)


def read_chunks(path: Path) -> tuple[dict, bytes] | None:
    """(JSON document, BIN blob) or None if the container is unreadable."""
    data = path.read_bytes()
    if len(data) < 12 or data[:4] != b"glTF":
        return None
    off = 12
    length = struct.unpack_from("<I", data, 8)[0]
    doc: dict | None = None
    blob = b""
    while off + 8 <= min(length, len(data)):
        chunk_len, chunk_type = struct.unpack_from("<I4s", data, off)
        chunk_start = off + 8
        raw = data[chunk_start : chunk_start + chunk_len]
        if chunk_type == b"JSON":
            try:
                doc = json.loads(raw)
            except json.JSONDecodeError:
                return None
        elif chunk_type == b"BIN\x00":
            blob = raw
        off = chunk_start + chunk_len
    return None if doc is None else (doc, blob)


def read_json_chunk(path: Path) -> dict | None:
    """Backwards-compatible helper: JSON document only."""
    got = read_chunks(path)
    return got[0] if got else None


def missing_normal_primitives(doc: dict) -> int:
    """Count primitives across all meshes that lack a NORMAL attribute."""
    count = 0
    for mesh in doc.get("meshes", []):
        for prim in mesh.get("primitives", []):
            if "NORMAL" not in prim.get("attributes", {}):
                count += 1
    return count


def _read_vec3(doc: dict, blob: bytes, acc_i: int) -> np.ndarray | None:
    acc = doc["accessors"][acc_i]
    if acc.get("type") != "VEC3" or acc.get("componentType") != 5126:
        return None
    bv_i = acc.get("bufferView")
    if bv_i is None:
        return None
    bv = doc["bufferViews"][bv_i]
    off = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    cnt = int(acc["count"])
    if bv.get("byteStride") not in (None, 12):
        return None  # interleaved: not produced by this pipeline
    if off + cnt * 12 > len(blob):
        return None
    return np.frombuffer(blob, dtype="<f4", count=cnt * 3, offset=off).reshape(cnt, 3)


def normal_defects(doc: dict, blob: bytes) -> list[str]:
    """Problems with the NORMAL data of primitives that do have one."""
    out: list[str] = []
    for mi, mesh in enumerate(doc.get("meshes", [])):
        for pi, prim in enumerate(mesh.get("primitives", [])):
            attrs = prim.get("attributes", {})
            if "NORMAL" not in attrs:
                continue
            where = f"mesh {mi} primitive {pi}"
            n_acc = doc["accessors"][attrs["NORMAL"]]
            if "POSITION" in attrs:
                p_cnt = int(doc["accessors"][attrs["POSITION"]]["count"])
                if int(n_acc["count"]) != p_cnt:
                    out.append(
                        f"{where}: NORMAL count {n_acc['count']} != POSITION count {p_cnt}"
                    )
                    continue
            nrm = _read_vec3(doc, blob, attrs["NORMAL"])
            if nrm is None:
                out.append(f"{where}: NORMAL is not a plain float32 VEC3 accessor")
                continue
            lens = np.linalg.norm(nrm.astype(np.float64), axis=1)
            worst = float(np.abs(lens - 1.0).max()) if len(lens) else 0.0
            if worst > UNIT_TOL:
                out.append(f"{where}: normals not unit length (max |1-|n|| = {worst:.3e})")
    return out


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
    defective: list[tuple[Path, list[str]]] = []
    unparseable: list[Path] = []
    for f in files:
        got = read_chunks(f)
        if got is None:
            unparseable.append(f)
            continue
        doc, blob = got
        if missing_normal_primitives(doc) > 0:
            failures.append(f)
            continue
        bad = normal_defects(doc, blob)
        if bad:
            defective.append((f, bad))

    for f in unparseable:
        print(f"SKIP  {_rel(f)}: could not read JSON chunk (see verify_gltf_strict.py)")
    for f in failures:
        print(f"FAIL  {_rel(f)}: missing NORMAL attribute on at least one primitive")
    for f, bad in defective:
        print(f"FAIL  {_rel(f)}: unusable NORMAL data")
        for msg in bad:
            print(f"        {msg}")

    print(
        f"\n{len(files)} .glb file(s) checked, {len(failures)} missing normals, "
        f"{len(defective)} with unusable normals, {len(unparseable)} unparseable."
    )
    return 1 if failures or defective or unparseable else 0


if __name__ == "__main__":
    raise SystemExit(main())
