#!/usr/bin/env python3
"""Soft-render front views: our mesh vs reference (Godot frame)."""
from __future__ import annotations

import io
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(r"E:\RE_general\PiposhTools\mdl-texture-editor")))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import mdl_geometry  # noqa: E402
from convert_mdl import parse_mdl  # noqa: E402

MDL_DIR = ROOT / "original" / "piposh3d" / "MDL"
OUT = ROOT / "tools"
MODELS = ["Ami.MDL", "PipDog.MDL", "Yachdal.MDL", "StudioL.MDL"]


def ref_to_godot(geo):
    pos = np.asarray(geo["positions"], dtype=np.float32).reshape(-1, 3)
    uvs = np.asarray(geo["uvs"], dtype=np.float32).reshape(-1, 2)
    out = np.empty_like(pos)
    out[:, 0] = pos[:, 0]
    out[:, 1] = pos[:, 2]
    out[:, 2] = -pos[:, 1]
    uvs_g = uvs.copy()
    uvs_g[:, 1] = 1.0 - uvs[:, 1]
    return out, uvs_g


def soft_render(pos, uvs, skin_rgba: np.ndarray, size=512, view="front"):
    """Painter's algorithm soft render. view: front=+Z camera looking -Z."""
    h, w = skin_rgba.shape[:2]
    img = np.zeros((size, size, 4), dtype=np.float32)
    zbuf = np.full((size, size), -1e30, dtype=np.float32)

    # Project X/Y (Godot Y-up); front = look down -Z
    xs, ys, zs = pos[:, 0], pos[:, 1], pos[:, 2]
    # Fit in frame
    pad = 1.08
    minx, maxx = xs.min(), xs.max()
    miny, maxy = ys.min(), ys.max()
    cx, cy = (minx + maxx) * 0.5, (miny + maxy) * 0.5
    span = max(maxx - minx, maxy - miny, 1e-3) * pad

    def to_px(x, y):
        u = (x - cx) / span + 0.5
        v = 0.5 - (y - cy) / span  # image y down
        return u * (size - 1), v * (size - 1)

    ntris = len(pos) // 3
    # Sort by average Z ascending so farther drawn first
    order = np.argsort([pos[i * 3 : i * 3 + 3, 2].mean() for i in range(ntris)])

    for ti in order:
        i0 = ti * 3
        tri = pos[i0 : i0 + 3]
        tuv = uvs[i0 : i0 + 3]
        # Backface (optional): skip if facing away (+Z toward camera)
        nrm = np.cross(tri[1] - tri[0], tri[2] - tri[0])
        if nrm[2] <= 0:
            continue
        pts = [to_px(tri[k, 0], tri[k, 1]) for k in range(3)]
        min_px = int(max(0, np.floor(min(p[0] for p in pts))))
        max_px = int(min(size - 1, np.ceil(max(p[0] for p in pts))))
        min_py = int(max(0, np.floor(min(p[1] for p in pts))))
        max_py = int(min(size - 1, np.ceil(max(p[1] for p in pts))))
        (x0, y0), (x1, y1), (x2, y2) = pts
        denom = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2)
        if abs(denom) < 1e-8:
            continue
        for py in range(min_py, max_py + 1):
            for px in range(min_px, max_px + 1):
                w0 = ((y1 - y2) * (px - x2) + (x2 - x1) * (py - y2)) / denom
                w1 = ((y2 - y0) * (px - x2) + (x0 - x2) * (py - y2)) / denom
                w2 = 1.0 - w0 - w1
                if w0 < 0 or w1 < 0 or w2 < 0:
                    continue
                z = w0 * tri[0, 2] + w1 * tri[1, 2] + w2 * tri[2, 2]
                if z < zbuf[py, px]:
                    continue
                uu = w0 * tuv[0, 0] + w1 * tuv[1, 0] + w2 * tuv[2, 0]
                vv = w0 * tuv[0, 1] + w1 * tuv[1, 1] + w2 * tuv[2, 1]
                sx = int(np.clip(uu * w, 0, w - 1))
                sy = int(np.clip(vv * h, 0, h - 1))
                col = skin_rgba[sy, sx].astype(np.float32) / 255.0
                if col[3] < 0.5:
                    continue
                zbuf[py, px] = z
                img[py, px] = col
    out = (np.clip(img, 0, 1) * 255).astype(np.uint8)
    # checker bg for transparency
    bg = np.zeros_like(out)
    for y in range(size):
        for x in range(size):
            c = 40 if ((x // 16) ^ (y // 16)) & 1 else 70
            bg[y, x] = (c, c, c, 255)
    a = out[:, :, 3:4].astype(np.float32) / 255.0
    comp = (out[:, :, :3].astype(np.float32) * a + bg[:, :, :3].astype(np.float32) * (1 - a)).astype(
        np.uint8
    )
    return Image.fromarray(comp)


def skin_from_mesh(mesh) -> np.ndarray:
    im = Image.open(io.BytesIO(mesh.skin_png)).convert("RGBA")
    return np.asarray(im)


def main() -> None:
    for name in MODELS:
        path = MDL_DIR / name
        mesh = parse_mdl(path)
        geo = mdl_geometry.parse_geometry(str(path))
        our_pos = mesh.positions[mesh.indices]
        our_uv = mesh.uvs[mesh.indices]
        ref_pos, ref_uv = ref_to_godot(geo)
        skin = skin_from_mesh(mesh)

        # For fair front render of IDPO, also render with corrected winding
        magic = path.read_bytes()[:4]
        our_pos_fix = our_pos.copy()
        our_uv_fix = our_uv.copy()
        if magic == b"IDPO":
            for i in range(len(our_pos) // 3):
                b, c = i * 3 + 1, i * 3 + 2
                our_pos_fix[b], our_pos_fix[c] = our_pos[c], our_pos[b]
                our_uv_fix[b], our_uv_fix[c] = our_uv[c], our_uv[b]

        print(f"rendering {name} ...")
        a = soft_render(our_pos, our_uv, skin)  # as shipped (may cull wrong faces)
        b = soft_render(our_pos_fix, our_uv_fix, skin)
        c = soft_render(ref_pos, ref_uv, skin)
        # side-by-side: ours_shipped | ours_fix_wind | ref
        canvas = Image.new("RGB", (512 * 3 + 8, 512 + 24), (20, 20, 20))
        canvas.paste(a, (0, 24))
        canvas.paste(b, (512 + 4, 24))
        canvas.paste(c, (1024 + 8, 24))
        stem = Path(name).stem
        out = OUT / f"audit_{stem}.png"
        canvas.save(out)
        print(f"  wrote {out}")

        # Skin alpha stats
        rgba = skin
        black = (rgba[:, :, 0] == 0) & (rgba[:, :, 1] == 0) & (rgba[:, :, 2] == 0)
        a0 = rgba[:, :, 3] == 0
        print(
            f"  skin {rgba.shape[1]}x{rgba.shape[0]} black={black.sum()} a0={a0.sum()} "
            f"black_but_opaque={((black) & (rgba[:,:,3]>0)).sum()} "
            f"nonblack_a0={((~black) & a0).sum()}"
        )


if __name__ == "__main__":
    main()
