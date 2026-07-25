#!/usr/bin/env python3
"""Extract WMB5 brush/BSP geometry to textured glTF (.glb) for Godot.

WMB5 list layout (Acknex A5):
  L1  planes (20 bytes: normal.xyz, dist, type)
  L2  textures (RGB565 + mipmaps, type 40)
  L3  vertices (float3, GS Z-up)
  L6  texinfo (64 bytes: s/t vec4 + texture index …)
  L7  faces (24 bytes: … firstedge, numedges, texinfo, …)
  L12 edges (8-byte header + uint32 v0,v1 pairs)
  L13 surfedges (int32, Quake-style signed edge refs)
"""
from __future__ import annotations

import argparse
import io
import json
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

from gs_math import gs_pos_to_godot

ROOT = Path(__file__).resolve().parents[1]


def _read_lists(data: bytes, n: int = 16) -> list[tuple[int, int]]:
    lists: list[tuple[int, int]] = []
    off = 4
    for _ in range(n):
        if off + 8 > len(data):
            break
        lo, ln = struct.unpack_from("<II", data, off)
        off += 8
        lists.append((lo, ln))
    return lists


def _c_str(raw: bytes) -> str:
    return raw.split(b"\x00", 1)[0].decode("latin-1", errors="replace")


def _rgb565_to_rgba(data: bytes, w: int, h: int) -> Image.Image:
    need = w * h * 2
    if len(data) < need:
        raise ValueError(f"RGB565 truncated: need {need}, got {len(data)}")
    arr = np.frombuffer(data[:need], dtype="<u2").reshape(h, w)
    r = ((arr >> 11) & 0x1F) * 255 // 31
    g = ((arr >> 5) & 0x3F) * 255 // 63
    b = (arr & 0x1F) * 255 // 31
    a = np.where(arr == 0, 0, 255).astype(np.uint8)
    rgba = np.stack([r.astype(np.uint8), g.astype(np.uint8), b.astype(np.uint8), a], axis=-1)
    return Image.fromarray(rgba, "RGBA")


def _load_textures(data: bytes, lists: list[tuple[int, int]]) -> list[tuple[str, Image.Image]]:
    o, ln = lists[2]
    if ln < 8:
        return []
    count = struct.unpack_from("<I", data, o)[0]
    if count == 0 or count > 4096:
        return []
    offs = struct.unpack_from(f"<{count}I", data, o + 4)
    out: list[tuple[str, Image.Image]] = []
    for rel in offs:
        to = o + rel
        if to + 40 > len(data):
            break
        name = _c_str(data[to : to + 16])
        w, h, typ = struct.unpack_from("<iii", data, to + 16)
        if w <= 0 or h <= 0 or w > 4096 or h > 4096:
            out.append((name, Image.new("RGBA", (4, 4), (128, 128, 128, 255))))
            continue
        base = typ & 7
        has_mips = bool(typ & 8)
        # A5 WMB often stores RGB565+mips as type 40 (0x28): treat low bits / size heuristic.
        pix = data[to + 40 :]
        try:
            if base in (2, 0) or typ in (10, 40, 42):
                img = _rgb565_to_rgba(pix, w, h)
            elif base == 4:
                raw = pix[: w * h * 3]
                arr = np.frombuffer(raw, dtype=np.uint8).reshape(h, w, 3)
                rgba = np.concatenate(
                    [arr, np.full((h, w, 1), 255, dtype=np.uint8)], axis=-1
                )
                img = Image.fromarray(rgba, "RGBA")
            elif base == 5:
                raw = pix[: w * h * 4]
                img = Image.frombytes("RGBA", (w, h), raw)
            else:
                # Fallback: assume RGB565 sized payload.
                img = _rgb565_to_rgba(pix, w, h)
        except Exception:  # noqa: BLE001
            img = Image.new("RGBA", (max(w, 1), max(h, 1)), (160, 80, 80, 255))
        out.append((name, img))
        _ = has_mips
    return out


def _png_bytes(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def extract_brush(data: bytes) -> dict | None:
    if data[:4] not in (b"WMB4", b"WMB5", b"WMB6"):
        return None
    lists = _read_lists(data)
    if len(lists) < 14:
        return None
    if lists[3][1] < 12 or lists[7][1] < 24 or lists[12][1] < 16 or lists[13][1] < 4:
        return None

    verts_gs = np.frombuffer(
        data[lists[3][0] : lists[3][0] + lists[3][1]], dtype="<f4"
    ).reshape(-1, 3)
    nv = len(verts_gs)
    if nv == 0:
        return None

    e_off, e_len = lists[12]
    edges = np.frombuffer(data[e_off + 8 : e_off + e_len], dtype="<u4").reshape(-1, 2)
    surf = np.frombuffer(
        data[lists[13][0] : lists[13][0] + lists[13][1]], dtype="<i4"
    )

    textures = _load_textures(data, lists)
    if not textures:
        textures = [("_default", Image.new("RGBA", (8, 8), (140, 140, 140, 255)))]

    t_off, t_len = lists[6]
    n_texinfo = t_len // 64 if t_len >= 64 else 0
    texinfos: list[tuple[np.ndarray, np.ndarray, int]] = []
    for i in range(n_texinfo):
        base = t_off + i * 64
        s = np.array(struct.unpack_from("<4f", data, base), dtype=np.float64)
        t = np.array(struct.unpack_from("<4f", data, base + 16), dtype=np.float64)
        tex_idx = struct.unpack_from("<i", data, base + 32)[0]
        if tex_idx < 0 or tex_idx >= len(textures):
            tex_idx = 0
        texinfos.append((s, t, tex_idx))

    f_off, f_len = lists[7]
    n_faces = f_len // 24
    # Per-texture mesh buckets
    buckets: dict[int, dict[str, list]] = {}

    def edge_verts(ei: int) -> tuple[int, int]:
        if ei > 0:
            e = edges[ei - 1]
            return int(e[0]), int(e[1])
        e = edges[-ei - 1]
        return int(e[1]), int(e[0])

    def poly_verts(first: int, num: int) -> list[int] | None:
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

    def uv_for(p: np.ndarray, s: np.ndarray, t: np.ndarray, tw: int, th: int) -> tuple[float, float]:
        u = float(np.dot(p, s[:3]) + s[3])
        v = float(np.dot(p, t[:3]) + t[3])
        # Vectors are typically texel-scale; normalize to 0..1 for glTF.
        if tw > 0:
            u /= float(tw)
        if th > 0:
            v /= float(th)
        return u, v

    skipped = 0
    for fi in range(n_faces):
        base = f_off + fi * 24
        first = struct.unpack_from("<i", data, base + 4)[0]
        num = struct.unpack_from("<h", data, base + 8)[0]
        ti = struct.unpack_from("<h", data, base + 10)[0]
        poly = poly_verts(first, num)
        if poly is None:
            skipped += 1
            continue
        if 0 <= ti < len(texinfos):
            s_vec, t_vec, tex_idx = texinfos[ti]
        else:
            s_vec = np.array([1.0, 0.0, 0.0, 0.0])
            t_vec = np.array([0.0, 1.0, 0.0, 0.0])
            tex_idx = 0
        name, img = textures[tex_idx]
        tw, th = img.size
        bucket = buckets.setdefault(tex_idx, {"pos": [], "uv": [], "idx": [], "name": name})
        base_idx = len(bucket["pos"])
        for vi in poly:
            p = verts_gs[vi]
            g = gs_pos_to_godot(float(p[0]), float(p[1]), float(p[2]))
            bucket["pos"].append(g)
            u, v = uv_for(p, s_vec, t_vec, tw, th)
            bucket["uv"].append([u, v])
        # Fan triangulate; flip winding for RH Godot after axis remap.
        for k in range(1, len(poly) - 1):
            bucket["idx"].extend([base_idx, base_idx + k + 1, base_idx + k])

    if not buckets:
        return None

    return {
        "buckets": buckets,
        "textures": textures,
        "faces": n_faces,
        "skipped": skipped,
        "verts": nv,
    }


def write_multi_glb(mesh: dict, dst: Path, name: str) -> None:
    def align4(b: bytes) -> bytes:
        pad = (4 - (len(b) % 4)) % 4
        return b + (b"\x00" * pad)

    bin_blob = bytearray()
    buffer_views: list[dict] = []
    accessors: list[dict] = []
    images: list[dict] = []
    textures_gltf: list[dict] = []
    materials: list[dict] = []
    primitives: list[dict] = []

    # Stable order by texture index
    for tex_idx in sorted(mesh["buckets"].keys()):
        bucket = mesh["buckets"][tex_idx]
        if not bucket["idx"]:
            continue
        pos = np.asarray(bucket["pos"], dtype="<f4")
        uvs = np.asarray(bucket["uv"], dtype="<f4")
        indices = np.asarray(bucket["idx"], dtype="<u4")

        pos_off = len(bin_blob)
        bin_blob += pos.tobytes()
        uv_off = len(bin_blob)
        bin_blob += uvs.tobytes()
        idx_off = len(bin_blob)
        bin_blob += indices.tobytes()

        bv_pos = len(buffer_views)
        buffer_views.append(
            {"buffer": 0, "byteOffset": pos_off, "byteLength": pos.nbytes, "target": 34962}
        )
        bv_uv = len(buffer_views)
        buffer_views.append(
            {"buffer": 0, "byteOffset": uv_off, "byteLength": uvs.nbytes, "target": 34962}
        )
        bv_idx = len(buffer_views)
        buffer_views.append(
            {
                "buffer": 0,
                "byteOffset": idx_off,
                "byteLength": indices.nbytes,
                "target": 34963,
            }
        )

        acc_pos = len(accessors)
        accessors.append(
            {
                "bufferView": bv_pos,
                "componentType": 5126,
                "count": len(pos),
                "type": "VEC3",
                "max": pos.max(axis=0).tolist(),
                "min": pos.min(axis=0).tolist(),
            }
        )
        acc_uv = len(accessors)
        accessors.append(
            {"bufferView": bv_uv, "componentType": 5126, "count": len(uvs), "type": "VEC2"}
        )
        acc_idx = len(accessors)
        accessors.append(
            {
                "bufferView": bv_idx,
                "componentType": 5125,
                "count": len(indices),
                "type": "SCALAR",
            }
        )

        tex_name, img = mesh["textures"][tex_idx]
        png = _png_bytes(img)
        img_off = len(bin_blob)
        bin_blob += png
        bv_img = len(buffer_views)
        buffer_views.append({"buffer": 0, "byteOffset": img_off, "byteLength": len(png)})

        img_i = len(images)
        images.append({"bufferView": bv_img, "mimeType": "image/png", "name": tex_name})
        tex_i = len(textures_gltf)
        textures_gltf.append({"source": img_i})
        mat_i = len(materials)
        materials.append(
            {
                "name": tex_name or f"tex_{tex_idx}",
                "pbrMetallicRoughness": {
                    "baseColorTexture": {"index": tex_i},
                    "metallicFactor": 0.0,
                    "roughnessFactor": 1.0,
                },
                "doubleSided": True,
            }
        )
        primitives.append(
            {
                "attributes": {"POSITION": acc_pos, "TEXCOORD_0": acc_uv},
                "indices": acc_idx,
                "material": mat_i,
            }
        )

    bin_blob = bytearray(align4(bytes(bin_blob)))
    gltf = {
        "asset": {"version": "2.0", "generator": "piposh3d-extract_wmb_mesh"},
        "scenes": [{"nodes": [0]}],
        "scene": 0,
        "nodes": [{"mesh": 0, "name": name}],
        "meshes": [{"name": name, "primitives": primitives}],
        "materials": materials,
        "textures": textures_gltf,
        "images": images,
        "buffers": [{"byteLength": len(bin_blob)}],
        "bufferViews": buffer_views,
        "accessors": accessors,
    }
    json_bytes = align4(json.dumps(gltf, separators=(",", ":")).encode("utf-8"))
    bin_aligned = align4(bytes(bin_blob))
    total_len = 12 + 8 + len(json_bytes) + 8 + len(bin_aligned)
    out = bytearray()
    out += struct.pack("<4sII", b"glTF", 2, total_len)
    out += struct.pack("<I4s", len(json_bytes), b"JSON")
    out += json_bytes
    out += struct.pack("<I4s", len(bin_aligned), b"BIN\x00")
    out += bin_aligned
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(out)


def convert_one(src: Path, dst: Path) -> bool:
    data = src.read_bytes()
    mesh = extract_brush(data)
    if mesh is None:
        print(f"SKIP {src.name}: no brush mesh")
        return False
    write_multi_glb(mesh, dst, src.stem)
    ntri = sum(len(b["idx"]) // 3 for b in mesh["buckets"].values())
    print(
        f"OK {src.name}: verts={mesh['verts']} faces={mesh['faces']} "
        f"skipped={mesh['skipped']} tris={ntri} mats={len(mesh['buckets'])} -> {dst.name}"
    )
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--src",
        type=Path,
        default=ROOT / "original" / "piposh3d" / "WMB",
    )
    ap.add_argument(
        "--dst-levels",
        type=Path,
        default=ROOT / "assets" / "converted" / "levels",
    )
    ap.add_argument(
        "--dst-wmb",
        type=Path,
        default=ROOT / "assets" / "converted" / "wmb",
    )
    ap.add_argument(
        "--only",
        nargs="*",
        default=["Studio", "Start", "Town", "Menu", "floor", "Ground", "MenuObj"],
        help="Level/prop stems to convert (default: key set)",
    )
    ap.add_argument("--all", action="store_true", help="Convert every WMB in src")
    args = ap.parse_args()

    files = sorted(args.src.glob("*.[Ww][Mm][Bb]"))
    if not args.all:
        want = {s.lower() for s in args.only}
        files = [p for p in files if p.stem.lower() in want]

    # Playable levels get *_brush.glb beside JSON; map-entity WMBs → converted/wmb/.
    playable = {
        "studio",
        "start",
        "town",
        "menu",
        "credits",
        "map",
        "desert",
        "travel",
        "mansion",
        "olympic",
        "shiks",
        "plane",
        "plane2",
        "plane3",
    }

    ok = 0
    for src in files:
        stem = src.stem
        if stem.lower() in playable:
            dst = args.dst_levels / f"{stem}_brush.glb"
        else:
            dst = args.dst_wmb / f"{stem}.glb"
        if convert_one(src, dst):
            ok += 1
    print(f"Done: {ok}/{len(files)}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
