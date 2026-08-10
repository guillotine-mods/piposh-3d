#!/usr/bin/env python3
"""Empirically locate and validate the per-face PLANE INDEX in the WMB face record.

PORTING_MANUAL.md 3.3(a) hypothesised that bytes 0-3 of the 24-byte face
record hold the plane index. Measurement says otherwise:

    offset  0..1   uint16  unidentified (not a plane index)
    offset  2..3   uint16  SIDE flag, only ever 0 or 1
    offset  4..7   int32   firstedge      (already read by extract_wmb_mesh)
    offset  8..9   int16   numedges       (already read)
    offset 10..11  int16   texinfo        (already read)
    offset 12..15  4 bytes light styles   (0xFFFFFFFF == unused, Quake-style)
    offset 16..19  int32   lightmap offset (-1 == none)
    offset 20..23  int32   PLANE INDEX    <-- the authored normal lives here

List 1 is the plane list, 20 bytes per record: normal.xyz (float32),
dist (float32), type (int32).

The face's outward normal follows Quake's dface_t convention:

    n_gs = +plane.normal  if side == 0
    n_gs = -plane.normal  if side == 1

Checks performed here, over every WMB in original/piposh3d/WMB:
  1. every candidate offset scored for in-range-ness + normal agreement
  2. plane normals unit length
  3. plane equation residual against the face's own vertices
  4. Newell normal of the face winding vs the plane normal (sign + magnitude)
  5. side flag vs that sign (is the Quake convention obeyed?)
  6. physical sanity: for compact stand-alone prop brushes (a crate, a
     bridge, a road segment) every face of a solid must point AWAY from the
     brush centroid. This is the decisive test for the SIGN convention --
     unlike "floors point up", it has no ambiguity about which side is
     empty. Run with --props.
  7. does the triangle winding extract_wmb_mesh.py already emits agree with
     the plane-derived normal, i.e. would back-face culling be safe?
     Reported per triangle AND per face (fully reversed vs fan artefact).

Nothing is written. Report only.

Usage:
    python tools/normals_probe.py
    python tools/normals_probe.py --only Town Studio --per-file
    python tools/normals_probe.py --scan-offsets --only Town Studio Start
"""
from __future__ import annotations

import argparse
import struct
from collections import Counter
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]

PLANE_IDX_OFF = 20
SIDE_OFF = 2


def read_lists(data: bytes, n: int = 16) -> list[tuple[int, int]]:
    lists: list[tuple[int, int]] = []
    off = 4
    for _ in range(n):
        if off + 8 > len(data):
            break
        lo, ln = struct.unpack_from("<II", data, off)
        off += 8
        lists.append((lo, ln))
    return lists


def face_polys(data: bytes, lists: list[tuple[int, int]]):
    """(verts, [(face_index, [vertex indices] | None)]) — same walk as extract_wmb_mesh."""
    verts = np.frombuffer(
        data[lists[3][0] : lists[3][0] + lists[3][1]], dtype="<f4"
    ).reshape(-1, 3)
    nv = len(verts)
    e_off, e_len = lists[12]
    edges = np.frombuffer(data[e_off + 8 : e_off + e_len], dtype="<u4").reshape(-1, 2)
    surf = np.frombuffer(data[lists[13][0] : lists[13][0] + lists[13][1]], dtype="<i4")
    f_off, f_len = lists[7]
    n_faces = f_len // 24

    def edge_verts(ei: int) -> tuple[int, int]:
        if ei > 0:
            e = edges[ei - 1]
            return int(e[0]), int(e[1])
        e = edges[-ei - 1]
        return int(e[1]), int(e[0])

    def poly_verts(first: int, num: int):
        if num < 3 or first < 0 or first + num > len(surf):
            return None
        idxs = surf[first : first + num]
        a, b = edge_verts(int(idxs[0]))
        vs = [a]
        cur = b
        for ei in idxs[1:]:
            a, b = edge_verts(int(ei))
            if a == cur:
                vs.append(a)
                cur = b
            elif b == cur:
                vs.append(b)
                cur = a
            else:
                return None
        if cur != vs[0] or len(vs) != num:
            return None
        if any(v < 0 or v >= nv for v in vs):
            return None
        return vs

    out = []
    for fi in range(n_faces):
        base = f_off + fi * 24
        first = struct.unpack_from("<i", data, base + 4)[0]
        num = struct.unpack_from("<h", data, base + 8)[0]
        out.append((fi, poly_verts(first, num)))
    return verts, out


def newell(pts: np.ndarray) -> np.ndarray:
    """Unit normal of a polygon loop, right-hand rule (CCW loop -> +normal)."""
    a = pts
    b = np.roll(pts, -1, axis=0)
    n = np.array(
        [
            float(np.sum((a[:, 1] - b[:, 1]) * (a[:, 2] + b[:, 2]))),
            float(np.sum((a[:, 2] - b[:, 2]) * (a[:, 0] + b[:, 0]))),
            float(np.sum((a[:, 0] - b[:, 0]) * (a[:, 1] + b[:, 1]))),
        ]
    )
    ln = float(np.linalg.norm(n))
    return n / ln if ln > 1e-12 else n


def read_planes(data: bytes, lists) -> tuple[np.ndarray, list[int]]:
    p_off, p_len = lists[1]
    n = p_len // 20
    planes = np.zeros((n, 4))
    types: list[int] = []
    for i in range(n):
        nx, ny, nz, dist, typ = struct.unpack_from("<4fi", data, p_off + i * 20)
        planes[i] = (nx, ny, nz, dist)
        types.append(typ)
    return planes, types


def scan_offsets(files: list[Path]) -> None:
    """Score every aligned offset in the 24-byte face record as a plane index."""
    cands = [(f"i32@{o}", "<i", o, 4) for o in range(0, 21)]
    cands += [(f"u16@{o}", "<H", o, 2) for o in range(0, 23)]
    stats: dict[str, list[int]] = {c[0]: [0, 0, 0] for c in cands}
    for p in files:
        data = p.read_bytes()
        lists = read_lists(data)
        if len(lists) < 14:
            continue
        planes, _ = read_planes(data, lists)
        npl = len(planes)
        if npl == 0:
            continue
        verts, polys = face_polys(data, lists)
        fo = lists[7][0]
        for fi, poly in polys:
            if poly is None:
                continue
            gn = newell(verts[poly].astype(np.float64))
            if np.linalg.norm(gn) < 0.5:
                continue
            for cn, fmt, off, _sz in cands:
                v = struct.unpack_from(fmt, data, fo + fi * 24 + off)[0]
                s = stats[cn]
                if 0 <= v < npl:
                    s[0] += 1
                    if abs(float(np.dot(gn, planes[v, :3]))) > 0.999:
                        s[2] += 1
                else:
                    s[1] += 1
    rows = []
    for cn, _f, _o, _s in cands:
        s = stats[cn]
        n = s[0] + s[1]
        if n:
            rows.append((s[0] / n * 100.0, s[2] / max(s[0], 1) * 100.0, cn, s))
    rows.sort(reverse=True)
    print("  in-range%  |dot|~1%  candidate   [in,out,agree]")
    for r in rows[:10]:
        print(f"  {r[0]:8.2f}  {r[1]:8.2f}  {r[2]:<10} {r[3]}")


def probe(path: Path) -> dict | None:
    data = path.read_bytes()
    if data[:4] not in (b"WMB4", b"WMB5", b"WMB6"):
        return None
    lists = read_lists(data)
    if len(lists) < 14:
        return None
    if lists[3][1] < 12 or lists[7][1] < 24 or lists[12][1] < 16 or lists[13][1] < 4:
        return None

    planes, ptypes = read_planes(data, lists)
    n_planes = len(planes)
    verts, polys = face_polys(data, lists)
    f_off = lists[7][0]

    r: dict = {
        "file": path.name,
        "magic": data[:4].decode(),
        "n_planes": n_planes,
        "n_faces": len(polys),
        "plane_mod20": 1 if lists[1][1] % 20 else 0,
        "idx_in": 0,
        "idx_out": 0,
        "unit_ok": 0,
        "unit_bad": 0,
        "unit_min": 2.0,
        "unit_max": 0.0,
        "side_sign": Counter(),
        "abs_dot_ge_999": 0,
        "abs_dot_lt_999": 0,
        "worst_abs_dot": 2.0,
        "resid_max": 0.0,
        "degenerate": 0,
        "unparsed": 0,
        "tri_agree": 0,
        "tri_disagree": 0,
        "tri_zero": 0,
        "tri_worst": 2.0,
        "face_all_good": 0,
        "face_mixed": 0,
        "face_all_bad": 0,
        "prop_out": 0,
        "prop_in": 0,
        "ptypes": Counter(ptypes),
        "lightofs_present": 0,
        "lightofs_none": 0,
    }
    if n_planes:
        lens = np.linalg.norm(planes[:, :3], axis=1)
        r["unit_min"] = float(lens.min())
        r["unit_max"] = float(lens.max())
        r["unit_ok"] = int(np.sum(np.abs(lens - 1.0) < 1e-4))
        r["unit_bad"] = n_planes - r["unit_ok"]

    extent = float(np.abs(verts).max()) if len(verts) else 1.0
    centroid = verts.mean(axis=0).astype(np.float64) if len(verts) else np.zeros(3)
    n_real = sum(1 for _fi, q in polys if q)
    is_prop = 0 < n_real <= 40  # compact stand-alone brush

    for fi, poly in polys:
        base = f_off + fi * 24
        pidx = struct.unpack_from("<i", data, base + PLANE_IDX_OFF)[0]
        side = struct.unpack_from("<H", data, base + SIDE_OFF)[0]
        lofs = struct.unpack_from("<i", data, base + 16)[0]
        if lofs >= 0:
            r["lightofs_present"] += 1
        else:
            r["lightofs_none"] += 1
        if 0 <= pidx < n_planes:
            r["idx_in"] += 1
        else:
            r["idx_out"] += 1
            continue
        if poly is None:
            r["unparsed"] += 1
            continue
        pts = verts[poly].astype(np.float64)
        gn = newell(pts)
        if np.linalg.norm(gn) < 0.5:
            r["degenerate"] += 1
            continue

        pn = planes[pidx, :3]
        pl = float(np.linalg.norm(pn))
        if pl < 1e-9:
            continue
        pn = pn / pl
        d = float(np.dot(gn, pn))
        r["worst_abs_dot"] = min(r["worst_abs_dot"], abs(d))
        if abs(d) > 0.999:
            r["abs_dot_ge_999"] += 1
        else:
            r["abs_dot_lt_999"] += 1
        r["side_sign"][(side, 1 if d > 0 else -1)] += 1
        r["resid_max"] = max(
            r["resid_max"],
            float(np.abs(pts @ pn - planes[pidx, 3] / pl).max()) / max(extent, 1.0),
        )

        # Quake convention: side==0 -> +plane.n, side==1 -> -plane.n
        n_gs = pn if side == 0 else -pn
        n_god = np.array([n_gs[0], n_gs[2], -n_gs[1]])

        # Winding actually emitted by extract_wmb_mesh: (v0, v[k+1], v[k])
        gpts = np.stack([pts[:, 0], pts[:, 2], -pts[:, 1]], axis=1)
        good = bad = 0
        for k in range(1, len(poly) - 1):
            a, b, c = gpts[0], gpts[k + 1], gpts[k]
            tn = np.cross(b - a, c - a)
            ln = float(np.linalg.norm(tn))
            if ln < 1e-9:
                r["tri_zero"] += 1
                continue
            dd = float(np.dot(tn / ln, n_god))
            r["tri_worst"] = min(r["tri_worst"], dd)
            if dd > 0.99:
                good += 1
            else:
                bad += 1
        r["tri_agree"] += good
        r["tri_disagree"] += bad
        if bad == 0:
            r["face_all_good"] += 1
        elif good == 0:
            r["face_all_bad"] += 1
        else:
            r["face_mixed"] += 1

        if is_prop:
            if float(np.dot(n_gs, pts.mean(axis=0) - centroid)) > 0:
                r["prop_out"] += 1
            else:
                r["prop_in"] += 1
    return r


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", type=Path, default=ROOT / "original" / "piposh3d" / "WMB")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--per-file", action="store_true")
    ap.add_argument("--scan-offsets", action="store_true")
    ap.add_argument("--props", action="store_true", help="per-prop outward-normal table")
    args = ap.parse_args()

    files = sorted(args.src.glob("*.[Ww][Mm][Bb]"))
    if args.only:
        want = {s.lower() for s in args.only}
        files = [p for p in files if p.stem.lower() in want]

    if args.scan_offsets:
        print(f"=== candidate offset scan over {len(files)} file(s) ===")
        scan_offsets(files)
        print()

    tot = Counter()
    side_sign = Counter()
    ptypes = Counter()
    unit_min, unit_max = 2.0, 0.0
    worst_dot, worst_dot_f = 2.0, ""
    worst_res, worst_res_f = 0.0, ""
    worst_tri, worst_tri_f = 2.0, ""
    n_ok = 0
    prop_rows: list[tuple[str, int, int]] = []
    rev_faces: Counter = Counter()
    for p in files:
        r = probe(p)
        if r is None:
            print(f"SKIP {p.name}")
            continue
        n_ok += 1
        for k in (
            "n_planes",
            "n_faces",
            "plane_mod20",
            "idx_in",
            "idx_out",
            "unit_ok",
            "unit_bad",
            "abs_dot_ge_999",
            "abs_dot_lt_999",
            "degenerate",
            "unparsed",
            "tri_agree",
            "tri_disagree",
            "tri_zero",
            "face_all_good",
            "face_mixed",
            "face_all_bad",
            "prop_out",
            "prop_in",
            "lightofs_present",
            "lightofs_none",
        ):
            tot[k] += r[k]
        side_sign.update(r["side_sign"])
        ptypes.update(r["ptypes"])
        if r["n_planes"]:
            unit_min = min(unit_min, r["unit_min"])
            unit_max = max(unit_max, r["unit_max"])
        if r["worst_abs_dot"] < worst_dot:
            worst_dot, worst_dot_f = r["worst_abs_dot"], r["file"]
        if r["resid_max"] > worst_res:
            worst_res, worst_res_f = r["resid_max"], r["file"]
        if r["tri_worst"] < worst_tri:
            worst_tri, worst_tri_f = r["tri_worst"], r["file"]
        if r["prop_out"] or r["prop_in"]:
            prop_rows.append((r["file"], r["prop_out"], r["prop_in"]))
        if r["face_all_bad"]:
            rev_faces[r["file"]] = r["face_all_bad"]
        if args.per_file:
            ss = dict(r["side_sign"])
            print(
                f"{r['file']:<16} planes={r['n_planes']:<6} faces={r['n_faces']:<6} "
                f"idx_out={r['idx_out']:<4} |dot|<.999={r['abs_dot_lt_999']:<4} "
                f"rev_faces={r['face_all_bad']:<4} side/sign={ss}"
            )

    print(f"\n=== {n_ok} WMB files ===")
    print(f"faces total                     : {tot['n_faces']}")
    print(f"planes total                    : {tot['n_planes']}  (files with list1 len not %20: {tot['plane_mod20']})")
    print(f"plane index @20 in-range / out  : {tot['idx_in']} / {tot['idx_out']}")
    print(
        f"plane |normal| == 1 ok / bad    : {tot['unit_ok']} / {tot['unit_bad']}"
        f"   min={unit_min:.9f} max={unit_max:.9f}"
    )
    print(f"|newell . plane_n| > .999       : {tot['abs_dot_ge_999']}  (< .999: {tot['abs_dot_lt_999']})")
    print(f"   worst |dot| = {worst_dot:.6f}  ({worst_dot_f})")
    print(f"worst relative plane residual   : {worst_res:.3e}  ({worst_res_f})")
    print(f"polys unparseable / degenerate  : {tot['unparsed']} / {tot['degenerate']}")
    print(f"(side, sign of newell.plane_n)  : {dict(side_sign)}")
    print(f"plane 'type' values             : {dict(ptypes.most_common(10))}")
    print(f"faces with lightmap offset >= 0 : {tot['lightofs_present']}  (== -1: {tot['lightofs_none']})")
    print()
    print("--- sign convention: compact prop brushes, faces pointing outward ---")
    print(
        f"  {tot['prop_out']} outward / {tot['prop_in']} inward "
        f"over {len(prop_rows)} prop brushes"
    )
    inward = [t for t in prop_rows if t[2] > t[1]]
    print(f"  brushes that are majority-INWARD: {[t[0] for t in inward]}")
    if args.props:
        for f, o, i in prop_rows:
            print(f"    {f:<16} out={o:<4} in={i}")
    print()
    print("--- winding of the triangles extract_wmb_mesh.py already emits ---")
    print(
        f"  triangles: agree {tot['tri_agree']}, disagree {tot['tri_disagree']}, "
        f"zero-area {tot['tri_zero']}  (worst dot {worst_tri:.4f} in {worst_tri_f})"
    )
    print(
        f"  faces: all-agree {tot['face_all_good']}, mixed (fan artefact) "
        f"{tot['face_mixed']}, fully reversed {tot['face_all_bad']}"
    )
    print(f"  fully-reversed faces by file: {dict(rev_faces.most_common(20))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
