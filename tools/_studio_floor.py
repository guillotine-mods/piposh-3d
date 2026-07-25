import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, "tools")
from convert_mdl import parse_mdl
from extract_wmb_mesh import extract_brush

m = extract_brush(Path("original/piposh3d/WMB/Studio.WMB").read_bytes())
ys = []
for ti, b in m["buckets"].items():
    p = np.asarray(b["pos"])
    tname = m["textures"][ti][0]
    ys.append(p[:, 1])
    print(
        f"tex {tname!r} tris={len(b['idx'])//3} "
        f"Y={p[:,1].min():.1f}..{p[:,1].max():.1f} mean={p[:,1].mean():.1f}"
    )
Y = np.concatenate(ys)
print("brush Y", float(Y.min()), float(Y.max()), "p5", float(np.percentile(Y, 5)))

d = json.loads(Path("assets/converted/levels/Studio.json").read_text(encoding="utf-8"))
print("json floor_y", d["bounds"].get("floor_y"), "spawn", d.get("spawn"))
for o in d["objects"]:
    if o.get("type") != "entity":
        continue
    fname = Path(str(o.get("file", ""))).name
    print(
        f"  {str(o.get('action')):12s} {fname:16s} "
        f"y={o['origin'][1]:.1f} scale={o.get('scale')}"
    )

for stem in ["Ami", "StudioL", "PipDog", "Curtain"]:
    mesh = parse_mdl(Path(f"original/piposh3d/MDL/{stem}.MDL"))
    print(
        f"{stem} localY {mesh.positions[:,1].min():.1f}..{mesh.positions[:,1].max():.1f} "
        f"center={mesh.positions.mean(0)}"
    )
