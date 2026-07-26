"""Gamestudio / Acknex A5 ↔ Godot transform helpers.

Acknex A5 / WED is **right-handed Z-up** (RHZUP): +X east, +Y north, +Z up.
Godot is right-handed Y-up.

Position:  (x, y, z)_gs  →  (x, z, -y)_godot
Scale:     (sx, sy, sz)   →  (sx, sz, sy)

Entity rotation: Conitec ``ang_to_matrix`` (DirectX Y-up) conjugated by
``S=diag(1,1,-1)`` into Godot RH. Do **not** use Euler ``(tilt, ±pan, roll)``
when tilt or roll is nonzero — that only matches for pure pan.

MDL meshes: axis remap matches mdl-texture-editor. A5/IDPO keep +X as
Acknex forward after convert; WED pan/tilt/roll then orients via the basis
above.

Cameras: Acknex ``vec_for_angle`` / ``ang_to_vec(pan,tilt)`` → Godot
``(x, z, -y)`` + look_at. Do **not** reuse the entity basis for Camera3D (−Z look).
"""
from __future__ import annotations

import math


def gs_pos_to_godot(x: float, y: float, z: float) -> list[float]:
    return [float(x), float(z), float(-y)]


def gs_scale_to_godot(sx: float, sy: float, sz: float) -> list[float]:
    return [float(sx), float(sz), float(sy)]


def _norm_tilt(tilt_deg: float) -> float:
    t = float(tilt_deg)
    if t > 180.0:
        t -= 360.0
    elif t < -180.0:
        t += 360.0
    return t


def ang_to_matrix_dx(pan_deg: float, tilt_deg: float, roll_deg: float) -> list[list[float]]:
    """Conitec ang_to_matrix — DirectX Y-up rotation (rows = entity axes)."""
    p = math.radians(float(pan_deg))
    t = math.radians(_norm_tilt(tilt_deg))
    r = math.radians(float(roll_deg))
    cp, sp = math.cos(p), math.sin(p)
    ct, st = math.cos(t), math.sin(t)
    cr, sr = math.cos(r), math.sin(r)
    return [
        [ct * cp, st, ct * sp],
        [-cr * st * cp + sr * sp, cr * ct, -cr * st * sp - sr * cp],
        [-sr * st * cp - cr * sp, sr * ct, cr * cp - sr * st * sp],
    ]


def gs_entity_basis_godot(
    pan_deg: float, tilt_deg: float, roll_deg: float
) -> list[float]:
    """3×3 Godot basis, column-major (9 floats): entity +X/+Y/+Z in world.

    ``R_g = S @ R_dx @ S`` with ``S=diag(1,1,-1)`` maps Conitec's DirectX
    ``ang_to_matrix`` into Godot right-handed Y-up without mirroring.
    """
    m = ang_to_matrix_dx(pan_deg, tilt_deg, roll_deg)
    xx, xy, xz = m[0][0], m[0][1], m[0][2]
    yx, yy, yz = m[1][0], m[1][1], m[1][2]
    zx, zy, zz = m[2][0], m[2][1], m[2][2]
    # columns: X=(xx,xy,-xz), Y=(yx,yy,-yz), Z=(-zx,-zy,zz)
    return [
        float(xx),
        float(xy),
        float(-xz),
        float(yx),
        float(yy),
        float(-yz),
        float(-zx),
        float(-zy),
        float(zz),
    ]


def gs_euler_to_godot_deg(pan: float, tilt: float, roll: float) -> list[float]:
    """Legacy approximate Euler for JSON dumps (accurate for pure pan only).

    Runtime spawn must use ``gs_entity_basis_godot`` / ang_to_matrix conjugation.
    """
    return [float(_norm_tilt(tilt)), float(pan), float(roll)]


def gs_view_forward_godot(pan_deg: float, tilt_deg: float) -> list[float]:
    """Acknex vec_for_angle / ang_to_vec(pan,tilt) remapped into Godot Y-up."""
    p = math.radians(pan_deg)
    t = math.radians(_norm_tilt(tilt_deg))
    x = math.cos(p) * math.cos(t)
    y = math.sin(p) * math.cos(t)
    z = math.sin(t)
    return [float(x), float(z), float(-y)]


def godot_pos_to_gs(x: float, y: float, z: float) -> list[float]:
    return [float(x), float(-z), float(y)]
