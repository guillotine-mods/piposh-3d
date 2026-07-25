#!/usr/bin/env python3
"""Full WMB extract: entities (with skills), paths, positions, lights → JSON."""
from __future__ import annotations

import argparse
import json
import statistics
import struct
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
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


def _in_play(o: list[float]) -> bool:
    return all(abs(v) <= 20000 for v in o)


def parse_wmb(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    magic = data[:4]
    lists = _read_lists(data)
    objects: list[dict[str, Any]] = []
    paths: list[dict[str, Any]] = []
    info: dict[str, Any] = {}

    if len(lists) <= 15 or lists[15][1] == 0:
        raise ValueError("no objects list")

    base, length = lists[15]
    chunk = memoryview(data)[base : base + length]
    count = struct.unpack_from("<I", chunk, 0)[0]
    offsets = list(struct.unpack_from(f"<{count}I", chunk, 4))

    for rel in offsets:
        o = rel
        if o + 4 > len(chunk):
            continue
        typ = struct.unpack_from("<I", chunk, o)[0]
        o += 4

        if typ == 5:
            info = {"type": "info"}
            continue

        if typ == 1:  # POSITION
            origin = struct.unpack_from("<3f", chunk, o)
            o += 12
            angle = struct.unpack_from("<3f", chunk, o)
            o += 20
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
            continue

        if typ == 2:  # LIGHT
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
            continue

        if typ == 6:  # PATH (WMB5 often stores point-count in num_edges, fNumPoints=0)
            try:
                name = _c_str(bytes(chunk[o : o + 20]))
                o += 20
                fnum = struct.unpack_from("<f", chunk, o)[0]
                o += 4
                o += 12  # unused[3]
                num_edges = struct.unpack_from("<I", chunk, o)[0]
                o += 4
                npoints = int(fnum) if fnum >= 1.0 else int(num_edges)
                # Clamp by remaining object bytes if possible
                points = []
                for _ in range(max(npoints, 0)):
                    if o + 12 > len(chunk):
                        break
                    pt = struct.unpack_from("<3f", chunk, o)
                    o += 12
                    points.append(gs_pos_to_godot(*pt))
                # WMB7-style edges/skills only if fNumPoints was set and bytes remain
                edges: list[dict[str, Any]] = []
                skills: list[list[float]] = []
                if fnum >= 1.0:
                    for _ in range(npoints):
                        if o + 24 > len(chunk):
                            break
                        skills.append(list(struct.unpack_from("<6f", chunk, o)))
                        o += 24
                    for _ in range(num_edges):
                        if o + 24 > len(chunk):
                            break
                        n1, n2, length_e, bezier, weight, skill = struct.unpack_from("<6f", chunk, o)
                        o += 24
                        edges.append(
                            {
                                "a": int(n1) - 1,
                                "b": int(n2) - 1,
                                "length": float(length_e),
                                "bezier": float(bezier),
                                "weight": float(weight),
                                "skill": float(skill),
                            }
                        )
                else:
                    # Sequential loop path (Town cars): connect i -> i+1 -> 0
                    for i in range(len(points)):
                        edges.append({"a": i, "b": (i + 1) % len(points), "length": 0.0})
                # Start.wmb has two paths both named path_001 — keep unique keys
                # so Godot can bind each LookAtMe to the nearest path.
                base = name or f"path_{len(paths) + 1:03d}"
                unique = base
                suffix = 2
                existing = {p["name"] for p in paths}
                while unique in existing:
                    unique = f"{base}_{suffix}"
                    suffix += 1
                paths.append(
                    {"name": unique, "points": points, "skills": skills, "edges": edges}
                )
            except struct.error:
                pass
            continue

        if typ == 3:  # OLD ENTITY
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
            o += 32
            flags = struct.unpack_from("<I", chunk, o)[0] if o + 4 <= len(chunk) else 0
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
                    "flags": int(flags),
                }
            )
            continue

        if typ == 7:  # ENTITY
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
            o += 80
            flags = struct.unpack_from("<I", chunk, o)[0]
            o += 4
            ambient = struct.unpack_from("<f", chunk, o)[0]
            o += 4
            albedo = struct.unpack_from("<f", chunk, o)[0]
            o += 4
            path_idx = struct.unpack_from("<i", chunk, o)[0]
            o += 4
            ent2 = struct.unpack_from("<I", chunk, o)[0]
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
                    "flags": int(flags),
                    "ambient": float(ambient),
                    "albedo": float(albedo),
                    "path": int(path_idx),
                    "attached": int(ent2),
                }
            )
            continue

    # bounds / spawn (street-band)
    pts = [
        o["origin"]
        for o in objects
        if o.get("type") in ("entity", "light", "position") and _in_play(o.get("origin", [0, 0, 0]))
    ]
    if pts:
        ys = sorted(p[1] for p in pts)
        med_y = statistics.median(ys)
        band = max(80.0, (ys[-1] - ys[0]) * 0.05)
        cluster = [p for p in pts if abs(p[1] - med_y) <= band] or pts
        xs = [p[0] for p in cluster]
        ys_c = [p[1] for p in cluster]
        zs = [p[2] for p in cluster]
        mn = [min(xs), min(ys_c), min(zs)]
        mx = [max(xs), max(ys_c), max(zs)]
        center = [(mn[i] + mx[i]) * 0.5 for i in range(3)]
        size = [max(mx[i] - mn[i], 4.0) for i in range(3)]
        floor_y = statistics.median(ys_c)
    else:
        mn, mx, center, size, floor_y = [-20, 0, -20], [20, 5, 20], [0, 1, 0], [40, 5, 40], 0.0

    # Prefer Cam entities / Piposh for spawn
    spawn = [center[0], floor_y + 2.0, center[2] + 8.0]
    cams = [o for o in objects if o.get("type") == "entity" and o.get("action", "").lower() == "cam"]
    if cams:
        # skill1 often view index; prefer skill1==1 or first
        cams.sort(key=lambda e: abs((e.get("skills") or [1])[0] - 1.0))
        c = cams[0]["origin"]
        spawn = [c[0], c[1], c[2]]

    # Level script hint
    script_name = path.stem + ".wdl"
    return {
        "source": path.name,
        "magic": magic.decode("ascii", "replace"),
        "script": script_name,
        "coord_space": "godot_y_up_from_acknex_z_up",
        "info": info,
        "bounds": {"min": mn, "max": mx, "center": center, "size": size, "floor_y": floor_y},
        "spawn": spawn,
        "paths": paths,
        "objects": objects,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    root = Path(__file__).resolve().parents[1]
    ap.add_argument("--src", type=Path, default=root / "original" / "piposh3d" / "WMB")
    ap.add_argument("--dst", type=Path, default=root / "assets" / "converted" / "levels")
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
            dst.write_text(json.dumps(level, indent=2), encoding="utf-8")
            ents = sum(1 for o in level["objects"] if o.get("type") == "entity")
            acts = {}
            for o in level["objects"]:
                if o.get("type") == "entity":
                    a = o.get("action") or "(none)"
                    acts[a] = acts.get(a, 0) + 1
            print(
                f"OK {src.name}: ents={ents} paths={len(level['paths'])} "
                f"actions={sorted(acts.items(), key=lambda x: -x[1])[:8]}"
            )
            ok += 1
        except Exception as exc:  # noqa: BLE001
            print(f"FAIL {src.name}: {exc}", file=sys.stderr)
    print(f"Extracted {ok}/{len(files)}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
