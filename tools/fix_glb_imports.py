#!/usr/bin/env python3
"""Patch Godot .import files for converted GLBs so MDL skins stay crisp.

Godot 4.7 defaults (LOD + extracted/compressed textures) scramble low-poly
Acknex skins. Force: no LODs, embed uncompressed, disable mesh compression.
"""
from __future__ import annotations

import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REPLACEMENTS = {
    "meshes/generate_lods=true": "meshes/generate_lods=false",
    "meshes/force_disable_compression=false": "meshes/force_disable_compression=true",
    "gltf/embedded_image_handling=1": "gltf/embedded_image_handling=3",
    "gltf/embedded_image_handling=0": "gltf/embedded_image_handling=3",
    "gltf/embedded_image_handling=2": "gltf/embedded_image_handling=3",
}


def patch(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    orig = text
    for a, b in REPLACEMENTS.items():
        text = text.replace(a, b)
    if "gltf/texture_map_mode=" not in text:
        text = text.rstrip() + "\ngltf/texture_map_mode=1\n"
    if text == orig:
        return False
    path.write_text(text, encoding="utf-8")
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--dirs",
        nargs="*",
        default=[
            "assets/converted/mdl",
            "assets/converted/wmb",
            "assets/converted/levels",
        ],
    )
    args = ap.parse_args()
    n = 0
    for d in args.dirs:
        root = ROOT / d
        if not root.is_dir():
            continue
        for p in root.glob("*.glb.import"):
            if patch(p):
                n += 1
    print(f"patched {n} import files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
