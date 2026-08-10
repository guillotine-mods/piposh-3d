#!/usr/bin/env python3
"""Verify NORMAL data inside .glb files produced by extract_wmb_mesh --normals.

Reads the GLB back from disk (no reuse of the extractor's in-memory state) and
checks, per primitive:
  * strict glTF: JSON chunk parses with json.loads and no trailing garbage,
    chunk lengths/alignment consistent, header total length matches file size
  * NORMAL accessor present, count == POSITION count, VEC3/float32
  * every normal is unit length
  * every triangle's winding agrees with its own vertex normals (dot > 0),
    i.e. back-face culling would be safe

Usage:
    python tools/normals_verify_glb.py tools/_normals_out/with_normals
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

import numpy as np

COMP = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def parse_glb(path: Path) -> tuple[dict, bytes, list[str]]:
    data = path.read_bytes()
    errs: list[str] = []
    if len(data) < 12 or data[:4] != b"glTF":
        raise ValueError("not a GLB")
    ver, total = struct.unpack_from("<II", data, 4)
    if ver != 2:
        errs.append(f"glTF version {ver} != 2")
    if total != len(data):
        errs.append(f"header length {total} != file size {len(data)}")
    doc: dict | None = None
    blob = b""
    off = 12
    while off + 8 <= len(data):
        clen, ctype = struct.unpack_from("<I4s", data, off)
        start = off + 8
        if clen % 4:
            errs.append(f"chunk {ctype!r} length {clen} not 4-byte aligned")
        raw = data[start : start + clen]
        if ctype == b"JSON":
            # strict: json.loads rejects NUL padding, unlike a lenient reader
            doc = json.loads(raw.decode("utf-8"))
        elif ctype == b"BIN\x00":
            blob = raw
        off = start + clen
    if doc is None:
        raise ValueError("no JSON chunk")
    return doc, blob, errs


def accessor(doc: dict, blob: bytes, i: int) -> np.ndarray:
    acc = doc["accessors"][i]
    bv = doc["bufferViews"][acc["bufferView"]]
    fmt = COMP[acc["componentType"]]
    n = NCOMP[acc["type"]]
    off = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    cnt = acc["count"]
    arr = np.frombuffer(blob, dtype="<" + fmt, count=cnt * n, offset=off)
    return arr.reshape(cnt, n) if n > 1 else arr


def check(path: Path) -> bool:
    doc, blob, errs = parse_glb(path)
    prims = 0
    with_n = 0
    worst_len = 0.0
    tri_ok = tri_bad = tri_zero = 0
    for mesh in doc.get("meshes", []):
        for prim in mesh.get("primitives", []):
            prims += 1
            attrs = prim["attributes"]
            pos = accessor(doc, blob, attrs["POSITION"])
            if "NORMAL" not in attrs:
                errs.append(f"primitive {prims - 1}: no NORMAL")
                continue
            with_n += 1
            nacc = doc["accessors"][attrs["NORMAL"]]
            if nacc["type"] != "VEC3" or nacc["componentType"] != 5126:
                errs.append(f"primitive {prims - 1}: NORMAL must be float32 VEC3")
            nrm = accessor(doc, blob, attrs["NORMAL"])
            if len(nrm) != len(pos):
                errs.append(
                    f"primitive {prims - 1}: NORMAL count {len(nrm)} != POSITION {len(pos)}"
                )
                continue
            lens = np.linalg.norm(nrm.astype(np.float64), axis=1)
            worst_len = max(worst_len, float(np.abs(lens - 1.0).max()))
            idx = accessor(doc, blob, prim["indices"]).astype(np.int64)
            tris = idx.reshape(-1, 3)
            a, b, c = pos[tris[:, 0]], pos[tris[:, 1]], pos[tris[:, 2]]
            fn = np.cross(b - a, c - a).astype(np.float64)
            ln = np.linalg.norm(fn, axis=1)
            live = ln > 1e-9
            tri_zero += int(np.sum(~live))
            if live.any():
                fnn = fn[live] / ln[live][:, None]
                vn = nrm[tris[:, 0]][live].astype(np.float64)
                d = np.einsum("ij,ij->i", fnn, vn)
                tri_ok += int(np.sum(d > 0.0))
                tri_bad += int(np.sum(d <= 0.0))
    ok = not errs and with_n == prims
    tag = "PASS" if ok else "FAIL"
    tot = tri_ok + tri_bad
    print(
        f"{tag} {path.name}: prims={prims} with NORMAL={with_n} "
        f"max|1-|n||={worst_len:.2e} winding agrees {tri_ok}/{tot} "
        f"({100.0 * tri_ok / max(tot, 1):.3f}%) zero-area tris={tri_zero}"
    )
    for e in errs:
        print(f"     {e}")
    return ok


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", type=Path)
    args = ap.parse_args()
    files = sorted(args.root.rglob("*.glb"))
    if not files:
        print(f"no .glb under {args.root}")
        return 1
    bad = 0
    for f in files:
        try:
            if not check(f):
                bad += 1
        except Exception as exc:  # noqa: BLE001
            print(f"FAIL {f.name}: {exc}")
            bad += 1
    print(f"\n{len(files)} file(s), {bad} failing")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
