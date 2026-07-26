#!/usr/bin/env python3
"""Verify entity basis matches Conitec ang_to_matrix (not naive Euler)."""
from __future__ import annotations

import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gs_math import gs_entity_basis_godot  # noqa: E402


def _mat(cols9: list[float]):
    # column-major → 3x3 rows
    return [
        [cols9[0], cols9[3], cols9[6]],
        [cols9[1], cols9[4], cols9[7]],
        [cols9[2], cols9[5], cols9[8]],
    ]


def _det(m) -> float:
    return (
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    )


def _euler_yxz_x_axis(pitch: float, yaw: float, roll: float) -> list[float]:
    p = math.radians(pitch)
    y = math.radians(yaw)
    r = math.radians(roll)
    cy, sy = math.cos(y), math.sin(y)
    cp, sp = math.cos(p), math.sin(p)
    cr, sr = math.cos(r), math.sin(r)
    # R = Ry * Rx * Rz ; local +X = first column
    # simplified: (Ry*Rx*Rz)*e0
    rx = [1.0, 0.0, 0.0]
    # apply Rz
    x0 = rx[0] * cr - rx[1] * sr
    y0 = rx[0] * sr + rx[1] * cr
    z0 = rx[2]
    # apply Rx
    x1, y1, z1 = x0, y0 * cp - z0 * sp, y0 * sp + z0 * cp
    # apply Ry
    x2 = x1 * cy + z1 * sy
    y2 = y1
    z2 = -x1 * sy + z1 * cy
    return [x2, y2, z2]


def main() -> int:
    errs = 0
    # Pure pan: must match Euler (tilt, +pan, 0)
    for pan in (0.0, 90.0, 180.0, 270.0, 334.0, 266.0):
        b = gs_entity_basis_godot(pan, 0.0, 0.0)
        m = _mat(b)
        if abs(_det(m) - 1.0) > 1e-6:
            print(f"FAIL det pan={pan}: {_det(m)}")
            errs += 1
        ex = _euler_yxz_x_axis(0.0, pan, 0.0)
        bx = [m[0][0], m[1][0], m[2][0]]
        if any(abs(bx[i] - ex[i]) > 1e-5 for i in range(3)):
            print(f"FAIL pure-pan mismatch pan={pan}: basis={bx} euler={ex}")
            errs += 1

    # Tilted: Euler must NOT match (regression for old spawn bug)
    b = gs_entity_basis_godot(90.0, 23.0, 0.0)
    m = _mat(b)
    bx = [m[0][0], m[1][0], m[2][0]]
    ex = _euler_yxz_x_axis(23.0, 90.0, 0.0)
    dist = math.sqrt(sum((bx[i] - ex[i]) ** 2 for i in range(3)))
    if dist < 0.2:
        print(f"FAIL expected tilt divergence, got dist={dist}")
        errs += 1
    # Forward should gain +Y from tilt (ang_to_vec)
    if abs(bx[1] - math.sin(math.radians(23.0))) > 1e-5:
        print(f"FAIL tilt Y component: {bx}")
        errs += 1

    # Plane Cam2-ish: roll+tilt must stay orthonormal det=+1
    b = gs_entity_basis_godot(144.0, 339.0, 352.0)
    if abs(_det(_mat(b)) - 1.0) > 1e-5:
        print("FAIL Cam2-like det", _det(_mat(b)))
        errs += 1

    if errs:
        print(f"verify_entity_basis: {errs} failure(s)")
        return 1
    print("verify_entity_basis: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
