#!/usr/bin/env python3
"""Verify JSON transforms match raw WMB + distance preservation."""
from __future__ import annotations

import json
import math
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gs_math import gs_euler_to_godot_deg, gs_pos_to_godot, gs_scale_to_godot  # noqa: E402


def read_raw_ents(wmb: Path):
    data = wmb.read_bytes()
    off = 4
    lists = []
    for _ in range(20):
        lo, ln = struct.unpack_from("<II", data, off)
        off += 8
        if lo == 0 and ln == 0:
            lists.append((lo, ln))
            continue
        if lo >= len(data) or lo + ln > len(data):
            break
        lists.append((lo, ln))
    base, length = lists[15]
    chunk = memoryview(data)[base : base + length]
    count = struct.unpack_from("<I", chunk, 0)[0]
    offsets = list(struct.unpack_from(f"<{count}I", chunk, 4))
    out = []
    for rel in offsets:
        o = rel
        typ = struct.unpack_from("<I", chunk, o)[0]
        o += 4
        if typ not in (3, 7):
            continue
        origin = struct.unpack_from("<3f", chunk, o)
        o += 12
        angle = struct.unpack_from("<3f", chunk, o)
        o += 12
        scale = struct.unpack_from("<3f", chunk, o)
        o += 12
        if typ == 3:
            name = bytes(chunk[o : o + 20]).split(b"\0")[0].decode("latin-1", "replace")
            o += 20
            file = bytes(chunk[o : o + 13]).split(b"\0")[0].decode("latin-1", "replace")
        else:
            name = bytes(chunk[o : o + 33]).split(b"\0")[0].decode("latin-1", "replace")
            o += 33
            file = bytes(chunk[o : o + 33]).split(b"\0")[0].decode("latin-1", "replace")
        out.append(
            {
                "file": file,
                "name": name,
                "origin": gs_pos_to_godot(*origin),
                "angle_deg": gs_euler_to_godot_deg(*angle),
                "scale": gs_scale_to_godot(*scale),
                "origin_gs": origin,
            }
        )
    return out


def dist(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    for level in ["Studio", "Town", "Menu"]:
        wmb = next(p for p in (root / "original/piposh3d/WMB").iterdir() if p.stem.lower() == level.lower())
        js = json.loads((root / "assets/converted/levels" / f"{wmb.stem}.json").read_text(encoding="utf-8"))
        raw = read_raw_ents(wmb)
        ents = [o for o in js["objects"] if o.get("type") == "entity"]
        print(f"\n=== {level}: raw={len(raw)} json={len(ents)} floor_y={js['bounds'].get('floor_y')} ===")
        errs = 0
        for i, (r, j) in enumerate(zip(raw, ents)):
            for key in ("origin", "angle_deg", "scale"):
                a, b = r[key], j[key]
                if any(abs(a[k] - b[k]) > 1e-3 for k in range(3)):
                    print(f" MISMATCH[{i}] {key} raw={a} json={b} file={r['file']}")
                    errs += 1
                    break
            if i >= 40:
                break
        # Distance preservation: GS distance == Godot distance (orthonormal map)
        if len(raw) >= 2:
            a, b = raw[0], raw[1]
            d_gs = dist(a["origin_gs"], b["origin_gs"])
            d_gd = dist(a["origin"], b["origin"])
            print(f" distance check pair0-1: gs={d_gs:.3f} godot={d_gd:.3f} delta={abs(d_gs-d_gd):.6f}")
        # Island scale
        island = next((e for e in ents if "island" in e.get("file", "").lower()), None)
        if island:
            print(f" Island scale={island['scale']} origin={island['origin']}")
        print(f" spawn={js['spawn']} errors_in_sample={errs}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
