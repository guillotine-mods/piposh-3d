#!/usr/bin/env python3
"""Extract entities from WMB4/WMB5 levels to JSON with faithful GS→Godot transforms."""
from __future__ import annotations

import argparse
import json
import statistics
import struct
import sys
from pathlib import Path
from typing import Any

from gs_math import gs_euler_to_godot_deg, gs_pos_to_godot, gs_scale_to_godot


def _c_str(raw: bytes) -> str:
    return raw.split(b"\x00", 1)[0].decode("latin-1", errors="replace")


def _read_lists(data: bytes) -> list[tuple[int, int]]:
    lists: list[tuple[int, int]] = []
    off = 4
    for _ in range(20):
        if off + 8 > len(data):
            break
        lo, ln = struct.unpack_from("<II", data, off)
        off += 8
        if ln == 0 and lo == 0:
            lists.append((lo, ln))
            continue
        if lo >= len(data) or lo + ln > len(data):
            break
        lists.append((lo, ln))
    return lists


def _in_play_space(origin: list[float]) -> bool:
    # Acknex levels can be large (Town ~7k); only drop absurd skybox junk.
    return abs(origin[0]) <= 20000 and abs(origin[1]) <= 20000 and abs(origin[2]) <= 20000


def _compute_bounds(objects: list[dict[str, Any]]) -> dict[str, Any]:
    """Bounds from the dominant elevation cluster (e.g. Town streets @ y≈311)."""
    pts = [
        o["origin"]
        for o in objects
        if o.get("type") in ("entity", "light", "position")
        and o.get("origin")
        and _in_play_space(o["origin"])
    ]
    if not pts:
        return {
            "min": [-20.0, 0.0, -20.0],
            "max": [20.0, 5.0, 20.0],
            "center": [0.0, 1.0, 0.0],
            "size": [40.0, 5.0, 40.0],
            "floor_y": 0.0,
        }

    ys = sorted(p[1] for p in pts)
    med_y = statistics.median(ys)
    # Keep points near the median elevation band (street level).
    band = max(80.0, (ys[-1] - ys[0]) * 0.05)
    cluster = [p for p in pts if abs(p[1] - med_y) <= band]
    if len(cluster) < max(3, len(pts) // 10):
        cluster = pts

    xs = [p[0] for p in cluster]
    ys_c = [p[1] for p in cluster]
    zs = [p[2] for p in cluster]
    mn = [min(xs), min(ys_c), min(zs)]
    mx = [max(xs), max(ys_c), max(zs)]
    center = [(mn[i] + mx[i]) * 0.5 for i in range(3)]
    size = [max(mx[i] - mn[i], 4.0) for i in range(3)]
    floor_y = statistics.median(ys_c)
    return {"min": mn, "max": mx, "center": center, "size": size, "floor_y": floor_y}


def _pick_spawn(objects: list[dict[str, Any]], bounds: dict[str, Any]) -> list[float]:
    floor_y = float(bounds.get("floor_y", bounds["min"][1]))
    preferred: list[tuple[int, list[float]]] = []
    for o in objects:
        if o.get("type") != "entity":
            continue
        origin = o.get("origin") or [0.0, 0.0, 0.0]
        if not _in_play_space(origin):
            continue
        # Prefer entities on the main floor band
        if abs(origin[1] - floor_y) > 120.0:
            continue
        name = str(o.get("name", "")).lower()
        file = str(o.get("file", "")).lower()
        action = str(o.get("action", "")).lower()
        score = 0
        if "piposh" in file or "piposh" in name:
            score += 10
        if "player" in action or "walk" in action:
            score += 5
        if "house" in file or "road" in file:
            score += 1
        if score:
            preferred.append((score, origin))
    if preferred:
        preferred.sort(key=lambda x: -x[0])
        o = preferred[0][1]
        return [o[0], floor_y + 2.0, o[2] + 8.0]
    c = bounds["center"]
    return [c[0], floor_y + 2.0, c[2] + max(bounds["size"][2] * 0.15, 8.0)]


def parse_wmb(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    if len(data) < 140:
        raise ValueError("file too small")
    magic = data[:4]
    if magic not in (b"WMB4", b"WMB5", b"WMB6", b"WMB7"):
        raise ValueError(f"unsupported magic {magic!r}")

    lists = _read_lists(data)
    objects: list[dict[str, Any]] = []
    info: dict[str, Any] = {"type": "info"} if False else {}

    if len(lists) > 15 and lists[15][1] > 0:
        base, length = lists[15]
        chunk = memoryview(data)[base : base + length]
        if len(chunk) >= 4:
            count = struct.unpack_from("<I", chunk, 0)[0]
            if 0 < count < 100000 and 4 + count * 4 <= len(chunk):
                offsets = list(struct.unpack_from(f"<{count}I", chunk, 4))
                for rel in offsets:
                    o = rel
                    if o + 4 > len(chunk):
                        continue
                    typ = struct.unpack_from("<I", chunk, o)[0]
                    o += 4
                    if typ == 5:
                        info = {"type": "info"}
                    elif typ == 1:
                        origin = struct.unpack_from("<3f", chunk, o)
                        o += 12
                        angle = struct.unpack_from("<3f", chunk, o)
                        o += 12 + 8
                        name = _c_str(bytes(chunk[o : o + 20]))
                        objects.append(
                            {
                                "type": "position",
                                "name": name,
                                "origin_gs": list(origin),
                                "origin": gs_pos_to_godot(*origin),
                                "angle_gs": list(angle),
                                "angle_deg": gs_euler_to_godot_deg(*angle),
                            }
                        )
                    elif typ == 2:
                        origin = struct.unpack_from("<3f", chunk, o)
                        o += 12
                        r, g, b, rng = struct.unpack_from("<4f", chunk, o)
                        objects.append(
                            {
                                "type": "light",
                                "origin_gs": list(origin),
                                "origin": gs_pos_to_godot(*origin),
                                "color": [r / 100.0, g / 100.0, b / 100.0],
                                "range": float(rng),
                            }
                        )
                    elif typ == 3:
                        origin = struct.unpack_from("<3f", chunk, o)
                        o += 12
                        angle = struct.unpack_from("<3f", chunk, o)
                        o += 12
                        scale = struct.unpack_from("<3f", chunk, o)
                        o += 12
                        name = _c_str(bytes(chunk[o : o + 20]))
                        o += 20
                        filename = _c_str(bytes(chunk[o : o + 13]))
                        o += 13
                        action = _c_str(bytes(chunk[o : o + 20]))
                        o += 20
                        skills = list(struct.unpack_from("<8f", chunk, o))
                        objects.append(
                            {
                                "type": "entity",
                                "old": True,
                                "name": name,
                                "file": filename,
                                "action": action,
                                "origin_gs": list(origin),
                                "origin": gs_pos_to_godot(*origin),
                                "angle_gs": list(angle),
                                "angle_deg": gs_euler_to_godot_deg(*angle),
                                "scale_gs": list(scale),
                                "scale": gs_scale_to_godot(*scale),
                                "skills": skills,
                            }
                        )
                    elif typ == 7:
                        origin = struct.unpack_from("<3f", chunk, o)
                        o += 12
                        angle = struct.unpack_from("<3f", chunk, o)
                        o += 12
                        scale = struct.unpack_from("<3f", chunk, o)
                        o += 12
                        name = _c_str(bytes(chunk[o : o + 33]))
                        o += 33
                        filename = _c_str(bytes(chunk[o : o + 33]))
                        o += 33
                        action = _c_str(bytes(chunk[o : o + 33]))
                        o += 34
                        skills = list(struct.unpack_from("<20f", chunk, o))
                        objects.append(
                            {
                                "type": "entity",
                                "old": False,
                                "name": name,
                                "file": filename,
                                "action": action,
                                "origin_gs": list(origin),
                                "origin": gs_pos_to_godot(*origin),
                                "angle_gs": list(angle),
                                "angle_deg": gs_euler_to_godot_deg(*angle),
                                "scale_gs": list(scale),
                                "scale": gs_scale_to_godot(*scale),
                                "skills": skills,
                            }
                        )

    bounds = _compute_bounds(objects)
    spawn = _pick_spawn(objects, bounds)
    return {
        "source": path.name,
        "magic": magic.decode("ascii"),
        "coord_space": "godot_y_up_from_acknex_z_up",
        "info": info,
        "bounds": bounds,
        "spawn": spawn,
        "objects": objects,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--src",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "original" / "piposh3d" / "WMB",
    )
    ap.add_argument(
        "--dst",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "assets" / "converted" / "levels",
    )
    ap.add_argument("--only", nargs="*", default=[])
    args = ap.parse_args()

    files = sorted(args.src.glob("*.[Ww][Mm][Bb]"))
    if args.only:
        want = {n.lower() for n in args.only}
        files = [f for f in files if f.name.lower() in want or f.stem.lower() in want]

    ok = 0
    for src in files:
        try:
            level = parse_wmb(src)
            dst = args.dst / (src.stem + ".json")
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(json.dumps(level, indent=2), encoding="utf-8")
            print(
                f"OK {src.name}: ents={sum(1 for o in level['objects'] if o.get('type')=='entity')} "
                f"floor_y={level['bounds'].get('floor_y')} spawn={level['spawn']}"
            )
            ok += 1
        except Exception as exc:  # noqa: BLE001
            print(f"FAIL {src.name}: {exc}", file=sys.stderr)
    print(f"Extracted {ok}/{len(files)}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
