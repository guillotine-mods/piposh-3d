#!/usr/bin/env python3
"""Compare convert_mdl.parse_mdl vs mdl_geometry.parse_geometry (Godot frame)."""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(r"E:\RE_general\PiposhTools\mdl-texture-editor")))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import mdl_geometry  # noqa: E402
from convert_mdl import parse_mdl  # noqa: E402

MDL_DIR = ROOT / "original" / "piposh3d" / "MDL"
MODELS = ["Ami.MDL", "PipDog.MDL", "Yachdal.MDL", "StudioL.MDL"]


def expand_ours(mesh):
    return mesh.positions[mesh.indices], mesh.uvs[mesh.indices]


def ref_to_godot(geo):
    pos = np.asarray(geo["positions"], dtype=np.float32).reshape(-1, 3)
    uvs = np.asarray(geo["uvs"], dtype=np.float32).reshape(-1, 2)
    # Both IDPO (post Y-negate) and A5: app.js geo.rotateX(-90) → (x, z, -y)
    out = np.empty_like(pos)
    out[:, 0] = pos[:, 0]
    out[:, 1] = pos[:, 2]
    out[:, 2] = -pos[:, 1]
    uvs_godot = uvs.copy()
    uvs_godot[:, 1] = 1.0 - uvs[:, 1]  # undo Three.js flipY UV convention
    return out, uvs, uvs_godot


def undo_idpo_winding(pos, uvs):
    """Our IDPO emits (v0,v2,v1); restore (v0,v1,v2)."""
    p = pos.copy()
    u = uvs.copy()
    for i in range(len(pos) // 3):
        b, c = i * 3 + 1, i * 3 + 2
        p[b], p[c] = pos[c], pos[b]
        u[b], u[c] = uvs[c], uvs[b]
    return p, u


def face_normal(tri):
    a, b, c = tri
    return np.cross(b - a, c - a)


def main() -> None:
    for name in MODELS:
        path = MDL_DIR / name
        magic = path.read_bytes()[:4]
        mesh = parse_mdl(path)
        geo = mdl_geometry.parse_geometry(str(path))
        our_pos, our_uv = expand_ours(mesh)
        ref_pos, ref_uv_three, ref_uv_godot = ref_to_godot(geo)
        n = min(len(our_pos), len(ref_pos))
        nt = n // 3

        print("=" * 64)
        print(f"{name} magic={magic!r} format={geo['format']} skin={geo['skin_w']}x{geo['skin_h']}")
        print(f"corners ours={len(our_pos)} ref={len(ref_pos)} tris ours={len(mesh.indices)//3} ref={geo['numtris']}")

        dpos = np.linalg.norm(our_pos[:n] - ref_pos[:n], axis=1)
        print(f"POS direct max={dpos.max():.6g} mean={dpos.mean():.6g} gt1e-3={(dpos > 1e-3).sum()}/{n}")

        compare_pos, compare_uv = our_pos, our_uv
        if magic == b"IDPO":
            up, uu = undo_idpo_winding(our_pos, our_uv)
            d2 = np.linalg.norm(up[:n] - ref_pos[:n], axis=1)
            print(f"POS undo-wind max={d2.max():.6g} mean={d2.mean():.6g} gt1e-3={(d2 > 1e-3).sum()}/{n}")
            if d2.mean() < dpos.mean():
                compare_pos, compare_uv = up, uu
                print("-> using undo-winding for UV/winding stats")

        duv_g = np.linalg.norm(compare_uv[:n] - ref_uv_godot[:n], axis=1)
        duv_t = np.linalg.norm(compare_uv[:n] - ref_uv_three[:n], axis=1)
        print(f"UV vs ref_godot(1-V) max={duv_g.max():.6g} mean={duv_g.mean():.6g} gt1e-4={(duv_g > 1e-4).sum()}/{n}")
        print(f"UV vs ref_three      max={duv_t.max():.6g} mean={duv_t.mean():.6g} gt1e-4={(duv_t > 1e-4).sum()}/{n}")

        # Also raw ours (no undo) vs both
        if magic == b"IDPO":
            duv_raw_g = np.linalg.norm(our_uv[:n] - ref_uv_godot[:n], axis=1)
            print(f"UV raw ours vs godot max={duv_raw_g.max():.6g} gt1e-4={(duv_raw_g > 1e-4).sum()}")

        agree = agree_un = 0
        for i in range(nt):
            n_our = face_normal(our_pos[i * 3 : i * 3 + 3])
            n_ref = face_normal(ref_pos[i * 3 : i * 3 + 3])
            if np.dot(n_our, n_ref) > 0:
                agree += 1
            if magic == b"IDPO":
                a = our_pos[i * 3]
                b = our_pos[i * 3 + 1]
                c = our_pos[i * 3 + 2]
                # undo (a,b,c)=(v0,v2,v1) → (a,c,b)
                n_un = np.cross(c - a, b - a)
                if np.dot(n_un, n_ref) > 0:
                    agree_un += 1
        print(f"WINDING normal-dot>0: our={agree}/{nt}" + (f" undo={agree_un}/{nt}" if magic == b"IDPO" else ""))

        print("first tri our_pos", our_pos[0:3].round(4).tolist())
        print("first tri ref_pos", ref_pos[0:3].round(4).tolist())
        print("first tri our_uv ", our_uv[0:3].round(4).tolist())
        print("first tri ref_g  ", ref_uv_godot[0:3].round(4).tolist())
        print("first tri ref_t  ", ref_uv_three[0:3].round(4).tolist())

        # Per-corner UV delta summary if mismatch
        if duv_g.max() > 1e-4 and (magic != b"IDPO" or np.linalg.norm(compare_uv[:n] - ref_uv_godot[:n], axis=1).max() > 1e-4):
            diff = compare_uv[:n] - ref_uv_godot[:n]
            print(f"UV delta U: min={diff[:,0].min():.4g} max={diff[:,0].max():.4g}")
            print(f"UV delta V: min={diff[:,1].min():.4g} max={diff[:,1].max():.4g}")
            # Check if pure V flip residual
            flip_test = compare_uv[:n].copy()
            flip_test[:, 1] = 1.0 - flip_test[:, 1]
            dflip = np.linalg.norm(flip_test - ref_uv_godot[:n], axis=1)
            print(f"If we flip our V: max dist to ref_godot={dflip.max():.6g}")

        # Frame 0 bbox
        print(f"bbox our {our_pos.min(0).round(3)} .. {our_pos.max(0).round(3)}")
        print(f"bbox ref {ref_pos.min(0).round(3)} .. {ref_pos.max(0).round(3)}")
        print(f"frames ours={len(mesh.frames)} ref_numframes={geo['numframes']}")


if __name__ == "__main__":
    main()
