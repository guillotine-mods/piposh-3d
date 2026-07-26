#!/usr/bin/env python3
"""Convert 3D GameStudio / Quake MDL models to glTF (.glb) for Godot."""
from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path
from typing import BinaryIO

from PIL import Image

try:
    import numpy as np
except ImportError:
    print("numpy required: pip install numpy", file=sys.stderr)
    raise


@dataclass
class MeshData:
    name: str
    positions: np.ndarray  # (V,3) float32
    uvs: np.ndarray  # (V,2) float32
    indices: np.ndarray  # (T*3,) uint32
    skin_png: bytes
    frames: list[tuple[str, np.ndarray]]  # optional morph/anim frames
    skin_pngs: list[bytes] | None = None  # all skins for my.skin / Talk()


def _read_c_string(raw: bytes) -> str:
    return raw.split(b"\x00", 1)[0].decode("latin-1", errors="replace")


def _dilate_alpha(rgba: np.ndarray) -> np.ndarray:
    """Grow opaque mask 1px so nearest+scissor doesn't eat silhouette edges."""
    a = rgba[:, :, 3] > 0
    if not a.any() or a.all():
        return rgba
    padded = np.pad(a, 1, mode="constant", constant_values=False)
    grown = (
        padded[1:-1, 1:-1]
        | padded[:-2, 1:-1]
        | padded[2:, 1:-1]
        | padded[1:-1, :-2]
        | padded[1:-1, 2:]
    )
    out = rgba.copy()
    # Fill newly opaque edge texels from nearest opaque neighbour colour.
    edge = grown & ~a
    if edge.any():
        # Cheap fill: use average of 4-neighbour opaque colours where present.
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            src = np.roll(np.roll(rgba, -dy, axis=0), -dx, axis=1)
            take = edge & (src[:, :, 3] > 0) & (out[:, :, 3] == 0)
            out[take] = src[take]
        out[edge, 3] = 255
    return out


def _rgb565_to_rgba(data: bytes, w: int, h: int) -> Image.Image:
    arr = np.frombuffer(data, dtype="<u2").reshape(h, w)
    r = ((arr >> 11) & 0x1F) * 255 // 31
    g = ((arr >> 5) & 0x3F) * 255 // 63
    b = (arr & 0x1F) * 255 // 31
    a = np.where(arr == 0, 0, 255).astype(np.uint8)
    rgba = np.dstack([r.astype(np.uint8), g.astype(np.uint8), b.astype(np.uint8), a])
    rgba = _dilate_alpha(rgba)
    return Image.fromarray(rgba, "RGBA")


def _rgba4444_to_rgba(data: bytes, w: int, h: int) -> Image.Image:
    arr = np.frombuffer(data, dtype="<u2").reshape(h, w)
    a = ((arr >> 12) & 0xF) * 255 // 15
    r = ((arr >> 8) & 0xF) * 255 // 15
    g = ((arr >> 4) & 0xF) * 255 // 15
    b = (arr & 0xF) * 255 // 15
    rgba = np.dstack(
        [r.astype(np.uint8), g.astype(np.uint8), b.astype(np.uint8), a.astype(np.uint8)]
    )
    return Image.fromarray(rgba, "RGBA")


def _palette_skin(data: bytes, w: int, h: int) -> Image.Image:
    # No embedded palette in MDL — use grayscale + index0 transparent.
    idx = np.frombuffer(data, dtype=np.uint8).reshape(h, w)
    rgba = np.zeros((h, w, 4), dtype=np.uint8)
    rgba[..., 0] = idx
    rgba[..., 1] = idx
    rgba[..., 2] = idx
    rgba[..., 3] = np.where(idx == 0, 0, 255)
    return Image.fromarray(rgba, "RGBA")


def _image_to_png_bytes(im: Image.Image) -> bytes:
    from io import BytesIO

    buf = BytesIO()
    im.save(buf, format="PNG")
    return buf.getvalue()


# --- Orientation behaviour flags (set from CLI in main) --------------------
# FIX_IDPO: use a handedness-consistent Quake map (det +1, same as A5) plus a
#   compensating winding flip, instead of the legacy reflection (det -1). This
#   makes A5 and Quake models share one handedness so a single cull/winding
#   rule is correct for both. Opt-in + verify with tools/smoke_orient.gd on
#   one model before making it the default (see docs/CONTRACT.md #2).
# FACE_ORIENT: run the skin-pixel "find the painted face and snap to +X"
#   heuristic. Once FIX_IDPO is confirmed, this guessing should be turned off
#   (WED pan orients every entity uniformly, same as A5 models).
FIX_IDPO = False
FACE_ORIENT = True


def _assert_proper_rotation(m: np.ndarray) -> np.ndarray:
    """Guard: an axis remap for positions must preserve handedness (det +1).
    A det -1 map mirrors geometry (front faces become back faces) unless
    winding is also flipped — the source of hard-to-see orientation bugs."""
    d = round(float(np.linalg.det(m)))
    assert d == 1, f"axis map has det {d} (reflection); expected +1 (proper rotation)"
    return m


def _gs_to_godot(pos: np.ndarray) -> np.ndarray:
    """Acknex/A5 Z-up (X,Y,Z) → Godot Y-up via rotateX(-90): (X, Z, -Y).

    Matches mdl-texture-editor `geo.rotateX(-Math.PI/2)`. det = +1.
    """
    out = np.empty_like(pos)
    out[:, 0] = pos[:, 0]
    out[:, 1] = pos[:, 2]
    out[:, 2] = -pos[:, 1]
    return out


def _idpo_to_godot(pos: np.ndarray) -> np.ndarray:
    """IDPO/Quake → Godot.

    LEGACY (FIX_IDPO=False): (x, y, z) → (x, z, y). Matches the reference
        mdl-texture-editor but is a REFLECTION (det -1): Quake models come
        out mirrored/opposite-handed vs A5 models, which is why facing was
        unreliable and why the skin-pixel face heuristic got bolted on.
    FIXED  (FIX_IDPO=True):  (x, y, z) → (x, z, -y), identical handedness to
        A5 (det +1). `parse_quake_mdl` flips triangle winding to compensate,
        so the two model families finally share one convention.
    """
    out = np.empty_like(pos)
    out[:, 0] = pos[:, 0]
    out[:, 1] = pos[:, 2]
    out[:, 2] = -pos[:, 1] if FIX_IDPO else pos[:, 1]
    return out


def _yaw_rotate_y(pos: np.ndarray, yaw_deg: float) -> np.ndarray:
    if abs(yaw_deg) < 1e-6:
        return pos
    a = math.radians(yaw_deg)
    c, s = math.cos(a), math.sin(a)
    out = np.empty_like(pos)
    x, z = pos[:, 0], pos[:, 2]
    out[:, 0] = x * c + z * s
    out[:, 1] = pos[:, 1]
    out[:, 2] = -x * s + z * c
    return out


def _soft_render_plus_x(
    positions: np.ndarray, indices: np.ndarray, uvs: np.ndarray, skin: np.ndarray, size: int = 64
) -> tuple[np.ndarray, np.ndarray]:
    """Orthographic soft-raster looking from +X toward origin. Returns (hit, rgb)."""
    w = h = size
    zbuf = np.full((h, w), 1e9, np.float32)
    hit = np.zeros((h, w), dtype=np.uint8)
    rgb = np.zeros((h, w, 3), dtype=np.float32)
    if positions.size == 0 or indices.size < 3 or skin.size == 0:
        return hit, rgb
    c = (positions.max(0) + positions.min(0)) * 0.5
    v = positions - c
    scale = (w * 0.42) / max(float(np.ptp(v)), 1.0)
    sh, sw = int(skin.shape[0]), int(skin.shape[1])
    for i in range(0, len(indices) - 2, 3):
        i0, i1, i2 = int(indices[i]), int(indices[i + 1]), int(indices[i + 2])
        pts = []
        depths = []
        uvs3 = [uvs[i0], uvs[i1], uvs[i2]]
        for vi in (i0, i1, i2):
            p = v[vi]
            pts.append((w * 0.5 + float(p[2]) * scale, h * 0.5 - float(p[1]) * scale))
            depths.append(float(-p[0]))
        ax, ay = pts[1][0] - pts[0][0], pts[1][1] - pts[0][1]
        bx, by = pts[2][0] - pts[0][0], pts[2][1] - pts[0][1]
        if ax * by - ay * bx <= 0.0:
            continue
        y0 = max(0, int(min(p[1] for p in pts)))
        y1 = min(h, int(max(p[1] for p in pts)) + 1)
        x0 = max(0, int(min(p[0] for p in pts)))
        x1 = min(w, int(max(p[0] for p in pts)) + 1)
        for py in range(y0, y1):
            for px in range(x0, x1):
                p0, p1, p2 = pts
                den = (p1[1] - p2[1]) * (p0[0] - p2[0]) + (p2[0] - p1[0]) * (p0[1] - p2[1])
                if abs(den) < 1e-6:
                    continue
                a = ((p1[1] - p2[1]) * (px + 0.5 - p2[0]) + (p2[0] - p1[0]) * (py + 0.5 - p2[1])) / den
                b = ((p2[1] - p0[1]) * (px + 0.5 - p2[0]) + (p0[0] - p2[0]) * (py + 0.5 - p2[1])) / den
                c3 = 1.0 - a - b
                if a < 0.0 or b < 0.0 or c3 < 0.0:
                    continue
                depth = a * depths[0] + b * depths[1] + c3 * depths[2]
                if depth >= zbuf[py, px]:
                    continue
                zbuf[py, px] = depth
                hit[py, px] = 1
                u = a * float(uvs3[0][0]) + b * float(uvs3[1][0]) + c3 * float(uvs3[2][0])
                vv = a * float(uvs3[0][1]) + b * float(uvs3[1][1]) + c3 * float(uvs3[2][1])
                pix = skin[int(vv * sh) % sh, int(u * sw) % sw]
                if pix.shape[0] >= 3 and (len(pix) < 4 or pix[3] > 8):
                    rgb[py, px] = pix[:3]
    return hit, rgb


def _find_face_uv_bbox(skin: np.ndarray) -> tuple[float, float, float, float] | None:
    """Locate the painted face on a Quake-style skin (flesh blob with eye ink)."""
    sh, sw = int(skin.shape[0]), int(skin.shape[1])
    if sh < 8 or sw < 8:
        return None
    r = skin[:, :, 0].astype(np.float32)
    g = skin[:, :, 1].astype(np.float32)
    b = skin[:, :, 2].astype(np.float32)
    a = skin[:, :, 3] if skin.shape[2] > 3 else np.full((sh, sw), 255, np.uint8)
    flesh = (a > 8) & (r > g * 0.85) & (r > b) & (r > 50) & ((r - b) > 8) & (r < 245)
    gray = (r + g + b) / 3.0
    # Line art on the face — exclude pure black backdrop
    ink = (a > 8) & (gray > 8) & (gray < 100)
    # Eye/mouth: ink touching flesh
    features = np.zeros((sh, sw), dtype=bool)
    for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0), (1, 1), (1, -1), (-1, 1), (-1, -1)):
        features |= ink & np.roll(np.roll(flesh, dy, 0), dx, 1)
    win_h = max(14, sh // 7)
    win_w = max(14, sw // 9)
    best = -1.0
    best_box = None
    # Skip hair strip at the very top; faces sit a bit lower
    y_start = max(2, sh // 20)
    y_lim = max(y_start + win_h, sh * 45 // 100)
    for y0 in range(y_start, y_lim - win_h + 1, max(2, win_h // 5)):
        for x0 in range(0, sw - win_w + 1, max(2, win_w // 5)):
            f = flesh[y0 : y0 + win_h, x0 : x0 + win_w]
            flesh_n = int(f.sum())
            if flesh_n < win_h * win_w * 0.2:
                continue
            feat_n = float(np.count_nonzero(features[y0 : y0 + win_h, x0 : x0 + win_w]))
            if feat_n < 4:
                continue
            patch = gray[y0 : y0 + win_h, x0 : x0 + win_w]
            contrast = float(patch[f].std()) if f.any() else 0.0
            # Prefer compact flesh (faces) over long hair strips
            ys_f, xs_f = np.where(f)
            fw = float(xs_f.max() - xs_f.min() + 1)
            fh = float(ys_f.max() - ys_f.min() + 1)
            compact = (flesh_n / max(fw * fh, 1.0)) * min(fw, fh) / max(fw, fh)
            score = feat_n * 12.0 + contrast * 4.0 + compact * 40.0
            if score > best:
                best = score
                best_box = (x0, y0, x0 + win_w, y0 + win_h)
    if best_box is None or best < 20.0:
        return None
    x0, y0, x1, y1 = best_box
    pad_x = (x1 - x0) * 0.2
    pad_y = (y1 - y0) * 0.25
    return (
        max(0.0, (x0 - pad_x) / sw),
        min(1.0, (x1 + pad_x) / sw),
        max(0.0, (y0 - pad_y) / sh),
        min(1.0, (y1 + pad_y) / sh),
    )


def _face_uv_forward_yaw(
    positions: np.ndarray, indices: np.ndarray, uvs: np.ndarray, skin: np.ndarray
) -> float | None:
    """Yaw that aims triangles textured with the face toward +X."""
    box = _find_face_uv_bbox(skin)
    if box is None:
        return None
    u0, u1, v0, v1 = box
    acc = np.zeros(3, dtype=np.float64)
    wsum = 0.0
    for i in range(0, len(indices) - 2, 3):
        i0, i1, i2 = int(indices[i]), int(indices[i + 1]), int(indices[i + 2])
        uc = (float(uvs[i0][0]) + float(uvs[i1][0]) + float(uvs[i2][0])) / 3.0
        vc = (float(uvs[i0][1]) + float(uvs[i1][1]) + float(uvs[i2][1])) / 3.0
        if not (u0 <= uc <= u1 and v0 <= vc <= v1):
            continue
        n = np.cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
        area = float(np.linalg.norm(n))
        if area < 1e-8:
            continue
        acc += n
        wsum += area
    if wsum < 1e-6:
        return None
    avg = acc / wsum
    hx, hz = float(avg[0]), float(avg[2])
    if abs(hx) + abs(hz) < 1e-8:
        return None
    # Outward face normal at atan2(hz,hx); yaw-rotate by that angle → +X.
    ang = math.degrees(math.atan2(hz, hx))
    return float((round(ang / 90.0) * 90.0) % 360.0)


def _face_score_plus_x(
    positions: np.ndarray, indices: np.ndarray, uvs: np.ndarray, skin: np.ndarray
) -> float:
    """Fallback soft-raster score when UV face detection fails."""
    hit, rgb = _soft_render_plus_x(positions, indices, uvs, skin)
    ys, xs = np.where(hit > 0)
    if xs.size == 0:
        return -1e9
    x0, x1 = int(xs.min()), int(xs.max())
    y0, y1 = int(ys.min()), int(ys.max())
    width = float(x1 - x0 + 1)
    height = float(y1 - y0 + 1)
    r, g, b = rgb[:, :, 0], rgb[:, :, 1], rgb[:, :, 2]
    skin_like = (hit > 0) & (r > g * 0.9) & (r > b) & (r > 55) & ((r - b) > 10) & (r < 240)
    y_cut = y0 + int(0.42 * height)
    fx0 = x0 + int(0.18 * width)
    fx1 = x0 + int(0.82 * width)
    face_skin = float(np.count_nonzero(skin_like[y0 : y_cut + 1, fx0 : fx1 + 1]))
    dark = (hit > 0) & ((r + g + b) < 150)
    features = 0.0
    for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        features += float(
            np.count_nonzero(
                dark[y0 : y_cut + 1, fx0 : fx1 + 1]
                & np.roll(np.roll(skin_like, dy, 0), dx, 1)[y0 : y_cut + 1, fx0 : fx1 + 1]
            )
        )
    aspect = width / max(height, 1.0)
    return aspect * 800.0 + width * 15.0 + face_skin * 10.0 + features * 40.0


def orient_mesh_face_plus_x(mesh: MeshData) -> MeshData:
    """Snap IDPO painted face to Godot +X (Acknex forward). Deterministic.

    Face-UV triangle normals only — no soft-raster front/back (that flipped
    Crowds 180°). Props with no face UV bbox are left as authored.
    IDPO only — do not run on A5/MED meshes (WED pans assume authored facing).
    """
    if not FACE_ORIENT:
        return mesh  # deterministic: rely on WED pan, not skin-pixel guessing
    if mesh.positions.size == 0:
        return mesh
    ext = mesh.positions.max(0) - mesh.positions.min(0)
    # Paper-thin / stick meshes: face-orient would edge-on them.
    if float(ext.min()) < max(float(ext.max()) * 0.04, 0.5):
        return mesh
    try:
        skin = np.array(Image.open(BytesIO(mesh.skin_png)).convert("RGBA"))
    except Exception:  # noqa: BLE001
        return mesh
    best_yaw = _face_uv_forward_yaw(mesh.positions, mesh.indices, mesh.uvs, skin)
    if best_yaw is None:
        return mesh
    if abs(best_yaw) < 1e-3:
        return mesh
    mesh.positions = _yaw_rotate_y(mesh.positions, best_yaw).astype(np.float32)
    mesh.frames = [(n, _yaw_rotate_y(p, best_yaw).astype(np.float32)) for n, p in mesh.frames]
    return mesh


def _game_palette():
    """256×3 RGB palette (mdl-texture-editor game_palette.raw / GFX palette)."""
    for name in ("game_palette.raw", "palette.lmp"):
        pal_path = Path(__file__).with_name(name)
        if pal_path.exists() and pal_path.stat().st_size >= 768:
            return np.frombuffer(pal_path.read_bytes()[:768], dtype=np.uint8).reshape(256, 3)
    pcx = Path(__file__).resolve().parents[1] / "original" / "piposh3d" / "GFX" / "palette.pcx"
    if pcx.exists():
        im = Image.open(pcx)
        if im.mode == "P" and im.palette:
            raw = im.getpalette()[:768]
            if raw and len(raw) >= 768:
                return np.array(raw[:768], dtype=np.uint8).reshape(256, 3)
    return None


def _apply_quake_palette(data: bytes, w: int, h: int) -> Image.Image:
    """Map 8-bit indexed skin through the game palette (index 0 transparent)."""
    idx = np.frombuffer(data, dtype=np.uint8).reshape(h, w)
    pal = _game_palette()
    if pal is not None:
        rgb = pal[idx]
        a = np.where(idx == 0, 0, 255).astype(np.uint8)
        rgba = np.dstack([rgb[..., 0], rgb[..., 1], rgb[..., 2], a])
        rgba = _dilate_alpha(rgba)
        return Image.fromarray(rgba, "RGBA")
    return _palette_skin(data, w, h)


def _uv_half_pixel(u: float, v: float, skin_w: int, skin_h: int) -> tuple[float, float]:
    """UVs for Godot/glTF (origin top-left, V down).

    mdl-texture-editor uses `1 - (v+0.5)/h` because Three.js loads the skin with
    `flipY=true`. glTF / Godot do **not** flip the embedded PNG, so we keep the
    half-texel offset but do **not** invert V — otherwise skins appear upside-down
    / scrambled in-engine.
    """
    return ((u + 0.5) / max(skin_w, 1), (v + 0.5) / max(skin_h, 1))


def parse_conitec_mdl(f: BinaryIO, magic: bytes) -> MeshData:
    header = f.read(84)
    if len(header) != 84:
        raise ValueError("truncated header")
    (
        _ver,
        _u1,
        sx,
        sy,
        sz,
        ox,
        oy,
        oz,
        _u2,
        _e0,
        _e1,
        _e2,
        numskins,
        skinwidth,
        skinheight,
        numverts,
        numtris,
        numframes,
        numskinverts,
        _flags,
    ) = struct.unpack("<4si6fi3f8i", header[:80])

    scale = np.array([sx, sy, sz], dtype=np.float32)
    offset = np.array([ox, oy, oz], dtype=np.float32)
    is_mdl5 = magic == b"MDL5"

    skins: list[Image.Image] = []
    for _ in range(numskins):
        skintype = struct.unpack("<i", f.read(4))[0]
        if is_mdl5:
            w, h = struct.unpack("<ii", f.read(8))
        else:
            w, h = skinwidth, skinheight
        base = skintype & 7
        has_mips = bool(skintype & 8)
        if base == 0:
            bpp = 1
        elif base in (2, 3):
            bpp = 2
        elif base == 4:
            bpp = 3
        elif base == 5:
            bpp = 4
        else:
            bpp = 2
        nbytes = bpp * w * h
        raw = f.read(nbytes)
        if base == 0:
            skins.append(_apply_quake_palette(raw, w, h))
        elif base == 2:
            skins.append(_rgb565_to_rgba(raw, w, h))
        elif base == 3:
            skins.append(_rgba4444_to_rgba(raw, w, h))
        elif base == 4:
            arr = np.frombuffer(raw, dtype=np.uint8).reshape(h, w, 3)
            rgba = np.dstack([arr[..., 2], arr[..., 1], arr[..., 0], np.full((h, w), 255, np.uint8)])
            skins.append(Image.fromarray(rgba, "RGBA"))
        elif base == 5:
            arr = np.frombuffer(raw, dtype=np.uint8).reshape(h, w, 4)
            rgba = np.dstack([arr[..., 2], arr[..., 1], arr[..., 0], arr[..., 3]])
            skins.append(Image.fromarray(rgba, "RGBA"))
        else:
            skins.append(Image.new("RGBA", (max(w, 1), max(h, 1)), (200, 200, 200, 255)))
        if has_mips:
            for div in (2, 4, 8):
                mw, mh = max(w // div, 1), max(h // div, 1)
                f.read(bpp * mw * mh)

    if not skins:
        skins.append(Image.new("RGBA", (4, 4), (180, 180, 180, 255)))

    skin_w, skin_h = skins[0].size
    if numskinverts <= 0 or numtris <= 0 or numverts <= 0:
        raise ValueError(f"degenerate mesh verts={numverts} tris={numtris} uvs={numskinverts}")
    uv_raw = f.read(numskinverts * 4)
    if len(uv_raw) < numskinverts * 4:
        raise ValueError("truncated UV block")
    uvs_src = np.frombuffer(uv_raw, dtype="<i2").reshape(numskinverts, 2).astype(np.float32)

    tri_raw = f.read(numtris * 12)
    if len(tri_raw) < numtris * 12:
        raise ValueError("truncated triangle block")
    tris = np.frombuffer(tri_raw, dtype="<i2").reshape(numtris, 6)

    # Expand to unique vertex attributes (pos index + uv index).
    corner_map: dict[tuple[int, int], int] = {}
    indices: list[int] = []
    pos_idx_list: list[int] = []
    uv_list: list[tuple[float, float]] = []

    for t in tris:
        for k in range(3):
            pi = int(t[k])
            ui = int(t[k + 3])
            if pi < 0 or pi >= numverts or ui < 0 or ui >= numskinverts:
                continue
            key = (pi, ui)
            if key not in corner_map:
                corner_map[key] = len(pos_idx_list)
                pos_idx_list.append(pi)
                uv_list.append(
                    _uv_half_pixel(float(uvs_src[ui, 0]), float(uvs_src[ui, 1]), skin_w, skin_h)
                )
            indices.append(corner_map[key])
    if not indices:
        raise ValueError("no valid triangles after index clamp")

    frames: list[tuple[str, np.ndarray]] = []
    base_positions = None
    for _fi in range(max(numframes, 1)):
        if numframes <= 0:
            break
        header_type = f.read(4)
        if len(header_type) < 4:
            break
        ftype = struct.unpack("<i", header_type)[0]
        if ftype == 2:
            vsize = 8
            unpack_v = lambda b: np.frombuffer(b, dtype="<u2").reshape(-1, 4)[:, :3].astype(np.float32)
        else:
            vsize = 4
            unpack_v = lambda b: np.frombuffer(b, dtype=np.uint8).reshape(-1, 4)[:, :3].astype(np.float32)
        f.read(vsize * 2)  # bbox min/max
        name = _read_c_string(f.read(16))
        raw = f.read(vsize * numverts)
        if len(raw) < vsize * numverts or numverts <= 0:
            break
        packed = unpack_v(raw)
        pos = packed * scale + offset
        pos = _gs_to_godot(pos)
        frames.append((name or f"frame_{_fi}", pos))
        if base_positions is None:
            base_positions = pos

    if base_positions is None:
        # Degenerate model — emit a tiny placeholder triangle.
        base_positions = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0]], dtype=np.float32)
        indices = [0, 1, 2]
        pos_idx_list = [0, 1, 2]
        uv_list = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0)]
        frames = [("frame_0", base_positions)]

    positions = base_positions[np.array(pos_idx_list, dtype=np.int32)]
    uvs = np.array(uv_list, dtype=np.float32)
    remapped_frames = []
    idx_arr = np.array(pos_idx_list, dtype=np.int32)
    for name, pos in frames:
        if len(pos) > int(idx_arr.max()):
            remapped_frames.append((name, pos[idx_arr]))

    return MeshData(
        name="model",
        positions=positions.astype(np.float32),
        uvs=uvs,
        indices=np.array(indices, dtype=np.uint32),
        skin_png=_image_to_png_bytes(skins[0]),
        frames=remapped_frames,
        skin_pngs=[_image_to_png_bytes(s) for s in skins],
    )


def parse_quake_mdl(f: BinaryIO) -> MeshData:
    """Quake 1 MDL (IDPO)."""
    header = f.read(84)
    (
        _ident,
        version,
        sx,
        sy,
        sz,
        ox,
        oy,
        oz,
        _radius,
        _ex,
        _ey,
        _ez,
        numskins,
        skinwidth,
        skinheight,
        numverts,
        numtris,
        numframes,
        _synctype,
        _flags,
        _size,
    ) = struct.unpack("<4si10f9i", header)
    if version not in (6,):
        # Still attempt — some exporters vary.
        pass
    scale = np.array([sx, sy, sz], dtype=np.float32)
    offset = np.array([ox, oy, oz], dtype=np.float32)

    skin_imgs: list[Image.Image] = []
    for _ in range(numskins):
        group = struct.unpack("<i", f.read(4))[0]
        # Classic Quake: 0=single 8-bit, 1=group. This game also stores
        # Conitec-style skintypes (2=565, 3=4444) under the IDPO header.
        if group == 0:
            raw = f.read(skinwidth * skinheight)
            img = _apply_quake_palette(raw, skinwidth, skinheight)
        elif group == 1:
            nb = struct.unpack("<i", f.read(4))[0]
            f.read(4 * nb)  # times
            raw = f.read(skinwidth * skinheight * nb)
            img = _apply_quake_palette(raw[: skinwidth * skinheight], skinwidth, skinheight)
        elif group in (2, 10):
            raw = f.read(skinwidth * skinheight * 2)
            img = _rgb565_to_rgba(raw, skinwidth, skinheight)
            if group == 10:
                for div in (2, 4, 8):
                    mw, mh = max(skinwidth // div, 1), max(skinheight // div, 1)
                    f.read(2 * mw * mh)
        elif group in (3, 11):
            raw = f.read(skinwidth * skinheight * 2)
            img = _rgba4444_to_rgba(raw, skinwidth, skinheight)
            if group == 11:
                for div in (2, 4, 8):
                    mw, mh = max(skinwidth // div, 1), max(skinheight // div, 1)
                    f.read(2 * mw * mh)
        else:
            # Unknown — skip one 8-bit skin worth to stay aligned if possible.
            raw = f.read(skinwidth * skinheight)
            img = _palette_skin(raw, skinwidth, skinheight) if raw else Image.new(
                "RGBA", (skinwidth or 4, skinheight or 4), (180, 180, 180, 255)
            )
        skin_imgs.append(img)
    if not skin_imgs:
        skin_imgs.append(
            Image.new("RGBA", (skinwidth or 4, skinheight or 4), (180, 180, 180, 255))
        )
    skin_img = skin_imgs[0]

    # onseam + s,t per vert
    stverts = []
    for _ in range(numverts):
        onseam, s, t = struct.unpack("<iii", f.read(12))
        stverts.append((onseam, s, t))

    tris = []
    for _ in range(numtris):
        facesfront, v0, v1, v2 = struct.unpack("<iiii", f.read(16))
        tris.append((facesfront, v0, v1, v2))

    frames: list[tuple[str, np.ndarray]] = []
    for _ in range(numframes):
        typ = struct.unpack("<i", f.read(4))[0]
        if typ == 0:
            f.read(8)  # bbox
            name = _read_c_string(f.read(16))
            raw = f.read(4 * numverts)
            packed = np.frombuffer(raw, dtype=np.uint8).reshape(numverts, 4)[:, :3].astype(np.float32)
            pos = _idpo_to_godot(packed * scale + offset)
            frames.append((name, pos))
        else:
            # group frame
            n = struct.unpack("<i", f.read(4))[0]
            f.read(8)  # min/max
            f.read(4 * n)
            name = "group"
            for gi in range(n):
                f.read(8)
                nm = _read_c_string(f.read(16))
                raw = f.read(4 * numverts)
                packed = np.frombuffer(raw, dtype=np.uint8).reshape(numverts, 4)[:, :3].astype(np.float32)
                pos = _idpo_to_godot(packed * scale + offset)
                if gi == 0:
                    name = nm
                    frames.append((name, pos))
                else:
                    frames.append((nm, pos))

    # Build UVs like mdl-texture-editor (onseam + half-texel + V flip)
    sw, sh = skinwidth, skinheight
    corner_map: dict[tuple[int, int], int] = {}
    indices: list[int] = []
    pos_idx_list: list[int] = []
    uv_list: list[tuple[float, float]] = []

    for facesfront, v0, v1, v2 in tris:
        # Legacy map (det -1) is a reflection, so authored winding already
        # reads correct after mirroring — do not swap. The FIX_IDPO map
        # (det +1) is a proper rotation, so winding must flip once to keep
        # faces outward.
        corners = (v0, v2, v1) if FIX_IDPO else (v0, v1, v2)
        for vi in corners:
            onseam, s, t = stverts[vi]
            ss, tt = s, t
            if onseam and not facesfront:
                ss += sw // 2
            key = (vi, ss, tt, facesfront)
            if key not in corner_map:
                corner_map[key] = len(pos_idx_list)
                pos_idx_list.append(vi)
                uv_list.append(_uv_half_pixel(float(ss), float(tt), sw, sh))
            indices.append(corner_map[key])

    base = frames[0][1]
    positions = base[np.array(pos_idx_list, dtype=np.int32)]
    uvs = np.array(uv_list, dtype=np.float32)
    idx_arr = np.array(pos_idx_list, dtype=np.int32)
    remapped = [(n, p[idx_arr]) for n, p in frames]
    return MeshData(
        name="quake_mdl",
        positions=positions.astype(np.float32),
        uvs=uvs,
        indices=np.array(indices, dtype=np.uint32),
        skin_png=_image_to_png_bytes(skin_img),
        frames=remapped,
        skin_pngs=[_image_to_png_bytes(s) for s in skin_imgs],
    )


def parse_mdl(path: Path) -> MeshData:
    """Uniform MDL → Godot convert:

    1. Axis remap (A5 → `_gs_to_godot`, IDPO → `_idpo_to_godot`) — same as
       mdl-texture-editor.
    2. **A5 (MDL2–5):** keep authored +X forward — WED pans were authored
       against MED orientation. Face-UV re-yaw breaks those entities.
    3. **IDPO:** Quake meshes often do not face +X after remap; snap painted
       face → +X via face-UV normals. Faceless props are left alone.
    """
    with path.open("rb") as f:
        magic = f.read(4)
        f.seek(0)
        if magic in (b"MDL3", b"MDL4", b"MDL5", b"MDL2"):
            return parse_conitec_mdl(f, magic)
        if magic == b"IDPO":
            return orient_mesh_face_plus_x(parse_quake_mdl(f))
        raise ValueError(f"Unsupported MDL magic {magic!r}")


def _clip_name(frame_name: str) -> str:
    """Acknex frame 'Walk3' / 'Frame 1' / '$Duck' → clip key used by ent_cycle."""
    n = frame_name.strip()
    if n.startswith("$"):
        n = n[1:]
    # Drop trailing digits and spaces: Walk3 -> Walk, Frame 10 -> Frame
    while n and (n[-1].isdigit() or n[-1] in " _"):
        n = n[:-1]
    return n or frame_name


def write_mdlanim(mesh: MeshData, dst: Path) -> None:
    """Binary vertex-frame animation sidecar for Godot MdlAnimator.

    Layout:
      magic 'MDLA' + u32 version=1
      u32 vert_count, u32 frame_count
      frame_count * char[16] names (nul-padded)
      frame_count * vert_count * 3 * f32 positions
      u32 clip_count
      per clip: char[16] name, u32 start, u32 count
    """
    if len(mesh.frames) <= 1:
        return
    verts = int(mesh.frames[0][1].shape[0])
    names = [fn for fn, _ in mesh.frames]
    # Build clips in first-seen order
    clips: dict[str, list[int]] = {}
    for i, name in enumerate(names):
        key = _clip_name(name)
        clips.setdefault(key, []).append(i)

    blob = bytearray()
    blob += b"MDLA"
    blob += struct.pack("<I", 1)
    blob += struct.pack("<II", verts, len(mesh.frames))
    for name in names:
        raw = name.encode("ascii", "replace")[:16]
        blob += raw + b"\x00" * (16 - len(raw))
    for _name, pos in mesh.frames:
        if pos.shape[0] != verts:
            # pad / truncate
            arr = np.zeros((verts, 3), dtype=np.float32)
            n = min(verts, pos.shape[0])
            arr[:n] = pos[:n]
            blob += arr.astype("<f4").tobytes()
        else:
            blob += pos.astype("<f4").tobytes()
    blob += struct.pack("<I", len(clips))
    for cname, idxs in clips.items():
        raw = cname.encode("ascii", "replace")[:16]
        blob += raw + b"\x00" * (16 - len(raw))
        blob += struct.pack("<II", idxs[0], len(idxs))
        # store index list for non-contiguous clips
        blob += struct.pack(f"<{len(idxs)}I", *idxs)

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(blob)


def write_glb(mesh: MeshData, dst: Path) -> None:
    """Minimal glTF 2.0 binary with POSITION/TEXCOORD_0/INDICES + base color texture."""
    # Bind pose = frame 0; full frame data goes to .mdlanim sidecar.
    pos = mesh.positions.astype("<f4")
    uvs = mesh.uvs.astype("<f4")
    indices = mesh.indices.astype("<u4")

    # Pad helpers
    def align4(b: bytes) -> bytes:
        pad = (4 - (len(b) % 4)) % 4
        return b + (b"\x00" * pad)

    bin_blob = bytearray()
    # accessors layout
    pos_offset = 0
    bin_blob += pos.tobytes()
    uv_offset = len(bin_blob)
    bin_blob += uvs.tobytes()
    idx_offset = len(bin_blob)
    bin_blob += indices.tobytes()
    img_offset = len(bin_blob)
    img_bytes = mesh.skin_png
    bin_blob += img_bytes
    bin_blob = bytearray(align4(bytes(bin_blob)))

    mins = pos.min(axis=0).tolist()
    maxs = pos.max(axis=0).tolist()

    gltf = {
        "asset": {"version": "2.0", "generator": "piposh3d-convert_mdl"},
        "scenes": [{"nodes": [0]}],
        "scene": 0,
        "nodes": [{"mesh": 0, "name": mesh.name}],
        "meshes": [
            {
                "name": mesh.name,
                "primitives": [
                    {
                        "attributes": {"POSITION": 0, "TEXCOORD_0": 1},
                        "indices": 2,
                        "material": 0,
                    }
                ],
            }
        ],
        "materials": [
            {
                "name": "skin",
                "pbrMetallicRoughness": {
                    "baseColorTexture": {"index": 0},
                    "metallicFactor": 0.0,
                    "roughnessFactor": 1.0,
                },
                "alphaMode": "MASK",
                "alphaCutoff": 0.5,
                "doubleSided": True,
            }
        ],
        "textures": [{"source": 0}],
        "images": [{"bufferView": 3, "mimeType": "image/png"}],
        "buffers": [{"byteLength": len(bin_blob)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": pos_offset, "byteLength": pos.nbytes, "target": 34962},
            {"buffer": 0, "byteOffset": uv_offset, "byteLength": uvs.nbytes, "target": 34962},
            {"buffer": 0, "byteOffset": idx_offset, "byteLength": indices.nbytes, "target": 34963},
            {"buffer": 0, "byteOffset": img_offset, "byteLength": len(img_bytes)},
        ],
        "accessors": [
            {
                "bufferView": 0,
                "componentType": 5126,
                "count": len(pos),
                "type": "VEC3",
                "max": maxs,
                "min": mins,
            },
            {
                "bufferView": 1,
                "componentType": 5126,
                "count": len(uvs),
                "type": "VEC2",
            },
            {
                "bufferView": 2,
                "componentType": 5125,
                "count": len(indices),
                "type": "SCALAR",
            },
        ],
    }

    json_bytes = align4(json.dumps(gltf, separators=(",", ":")).encode("utf-8"))
    bin_aligned = align4(bytes(bin_blob))

    # GLB container
    total_len = 12 + 8 + len(json_bytes) + 8 + len(bin_aligned)
    out = bytearray()
    out += struct.pack("<4sII", b"glTF", 2, total_len)
    out += struct.pack("<I4s", len(json_bytes), b"JSON")
    out += json_bytes
    out += struct.pack("<I4s", len(bin_aligned), b"BIN\x00")
    out += bin_aligned
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(out)


def write_skins(mesh: MeshData, dst: Path) -> None:
    """Sidecar with all MDL skins for runtime my.skin / Talk() switching.

    Layout: 'MDLS' + u32 ver=1 + u32 count + per skin: u32 png_bytes_len + png
    """
    skins = mesh.skin_pngs or ([mesh.skin_png] if mesh.skin_png else [])
    if len(skins) <= 1:
        return
    blob = bytearray()
    blob += b"MDLS"
    blob += struct.pack("<II", 1, len(skins))
    for png in skins:
        blob += struct.pack("<I", len(png))
        blob += png
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(blob)


def convert_one(src: Path, dst: Path) -> bool:
    try:
        mesh = parse_mdl(src)
        mesh.name = src.stem
        write_glb(mesh, dst)
        if len(mesh.frames) > 1:
            write_mdlanim(mesh, dst.with_suffix(".mdlanim"))
        write_skins(mesh, dst.with_suffix(".skins"))
        return True
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL {src.name}: {exc}", file=sys.stderr)
        return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--src",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "original" / "piposh3d" / "MDL",
    )
    ap.add_argument(
        "--dst",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "assets" / "converted" / "mdl",
    )
    ap.add_argument("--only", nargs="*", default=[])
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument(
        "--magic",
        default="",
        help="Only convert models with this 4-byte magic (e.g. IDPO, MDL3)",
    )
    ap.add_argument(
        "--fix-idpo",
        action="store_true",
        help="Use handedness-consistent Quake map (det +1) + winding flip. Verify "
        "with tools/smoke_orient.gd, then make it the default once confirmed.",
    )
    ap.add_argument(
        "--no-face-orient",
        action="store_true",
        help="Disable the skin-pixel face heuristic (recommended with --fix-idpo).",
    )
    args = ap.parse_args()

    global FIX_IDPO, FACE_ORIENT
    FIX_IDPO = bool(args.fix_idpo)
    FACE_ORIENT = not args.no_face_orient
    print(f"[orient] FIX_IDPO={FIX_IDPO} FACE_ORIENT={FACE_ORIENT}")

    files = sorted(args.src.glob("*.[Mm][Dd][Ll]"))
    if args.only:
        want = {n.lower() for n in args.only}
        files = [f for f in files if f.name.lower() in want or f.stem.lower() in want]
    if args.magic:
        mag = args.magic.encode("ascii")[:4]
        files = [f for f in files if f.read_bytes()[:4] == mag]
    if args.limit:
        files = files[: args.limit]

    ok = 0
    for src in files:
        dst = args.dst / (src.stem + ".glb")
        if convert_one(src, dst):
            ok += 1
            print(f"OK {src.name} -> {dst.name}")
    print(f"Converted {ok}/{len(files)}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
