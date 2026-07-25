#!/usr/bin/env python3
"""Probe WMB list regions for WMB7-style block meshes."""
from __future__ import annotations

import struct
from pathlib import Path


def iter_lists(data: bytes):
    off = 4
    for i in range(20):
        if off + 8 > len(data):
            break
        lo, ln = struct.unpack_from("<II", data, off)
        off += 8
        if ln and lo < len(data) and lo + ln <= len(data):
            yield i, lo, ln
        elif lo == 0 and ln == 0:
            yield i, lo, ln
        else:
            break


def try_blocks(data: bytes, base: int, length: int) -> str | None:
    if length < 8:
        return None
    count = struct.unpack_from("<I", data, base)[0]
    if count == 0 or count > 50000:
        return None
    o = base + 4
    total_v = total_t = 0
    for _ in range(min(count, 8)):
        if o + 40 > base + length:
            return None
        mins = struct.unpack_from("<3f", data, o)
        o += 12
        maxs = struct.unpack_from("<3f", data, o)
        o += 12
        _content, nv, nt, ns = struct.unpack_from("<4I", data, o)
        o += 16
        if nv > 200000 or nt > 400000 or ns > 1000:
            return None
        if any(abs(x) > 1e7 for x in mins + maxs):
            return None
        vsize, tsize, ssize = nv * 32, nt * 12, ns * 20
        if o + vsize + tsize + ssize > base + length:
            return None
        total_v += nv
        total_t += nt
        o += vsize + tsize + ssize
    if total_v == 0:
        return None
    return f"BLOCKS count={count} sample_v={total_v} sample_t={total_t}"


def main() -> None:
    root = Path(__file__).resolve().parents[1] / "original" / "piposh3d" / "WMB"
    for name in ["Menu.wmb", "MenuObj.wmb", "Studio.WMB", "Town.WMB", "floor.wmb", "Ground.wmb"]:
        hits = [p for p in root.iterdir() if p.name.lower() == name.lower()]
        if not hits:
            print("missing", name)
            continue
        p = hits[0]
        data = p.read_bytes()
        print(f"\n=== {p.name} {data[:4]!r} size={len(data)} ===")
        for i, lo, ln in iter_lists(data):
            msg = try_blocks(data, lo, ln)
            extra = f" -> {msg}" if msg else ""
            print(f"  L{i}: off={lo} len={ln}{extra}")


if __name__ == "__main__":
    main()
