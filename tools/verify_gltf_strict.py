#!/usr/bin/env python3
"""Strict-glTF check over every committed .glb (PORTING_MANUAL.md Phase 0).

Godot's glTF importer tolerates a NUL-padded JSON chunk (see docs/CONTRACT.md
§2.5) and other looseness a spec-strict consumer will not. This walks the
binary chunk header exactly per the glTF 2.0 spec and runs `json.loads` on
the JSON chunk, so a file that only "works in Godot" fails here the same way
it fails in `tools/wmb_web_viewer.py`, a browser, or any other real glTF
consumer -- catching the class of bug that produced the stale
`assets/converted/wmb/Shiks.glb` (PORTING_MANUAL.md §3.4) before it reaches
that stage.

Runs only against committed assets/converted/**/*.glb -- no dependency on
the gitignored original/ dump, so it works on a clean clone.

Usage:
    python tools/verify_gltf_strict.py
    python tools/verify_gltf_strict.py --root assets/converted/mdl
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GLTF_MAGIC = b"glTF"


def check_glb(path: Path) -> str | None:
    """Return an error string, or None if the file is strictly valid."""
    data = path.read_bytes()
    if len(data) < 12:
        return "file shorter than the 12-byte glTF header"

    magic, version, length = struct.unpack_from("<4sII", data, 0)
    if magic != GLTF_MAGIC:
        return f"bad magic {magic!r}, expected b'glTF'"
    if version != 2:
        return f"unsupported glTF version {version}"
    if length != len(data):
        return f"header length {length} != actual file size {len(data)}"

    off = 12
    saw_json = False
    while off < length:
        if off + 8 > length:
            return f"truncated chunk header at offset {off}"
        chunk_len, chunk_type = struct.unpack_from("<I4s", data, off)
        chunk_start = off + 8
        chunk_end = chunk_start + chunk_len
        if chunk_end > length:
            return f"chunk at {off} claims length {chunk_len}, overruns file"

        if chunk_type == b"JSON":
            if off != 12:
                return "JSON chunk must be first"
            saw_json = True
            try:
                json.loads(data[chunk_start:chunk_end])
            except json.JSONDecodeError as exc:
                return f"JSON chunk fails strict parse: {exc}"
        elif chunk_type == b"BIN\x00":
            pass
        else:
            return f"unknown chunk type {chunk_type!r} at offset {off}"

        off = chunk_end

    if not saw_json:
        return "no JSON chunk found"
    return None


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

    failures: list[tuple[Path, str]] = []
    for f in files:
        err = check_glb(f)
        if err is not None:
            failures.append((f, err))

    for f, err in failures:
        print(f"FAIL  {f.relative_to(ROOT)}: {err}")

    print(f"\n{len(files)} .glb file(s) checked, {len(failures)} failed strict parse.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
