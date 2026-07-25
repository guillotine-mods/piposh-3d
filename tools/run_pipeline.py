#!/usr/bin/env python3
"""Run the minimal conversion pipeline for a playable menu shell."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PY = sys.executable


def run(args: list[str]) -> None:
    print(">", " ".join(args))
    subprocess.check_call(args, cwd=ROOT)


def main() -> int:
    run([PY, "tools/convert_gfx.py"])
    run([PY, "tools/build_level_index.py"])
    run([PY, "tools/extract_wmb_full.py"])
    try:
        run([PY, "tools/extract_wmb_mesh.py"])
    except subprocess.CalledProcessError:
        print("WMB brush extract had failures; continuing.")
    # Priority models for menu / player
    # Best-effort model batch (do not fail the whole pipeline)
    try:
        run([PY, "tools/convert_mdl.py", "--limit", "80"])
    except subprocess.CalledProcessError:
        print("MDL batch had failures; continuing.")
    run([PY, "tools/fix_glb_imports.py"])
    run([PY, "tools/convert_sfx_batch.py"])
    print("Pipeline done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
