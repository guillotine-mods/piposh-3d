"""Gamestudio / Acknex ↔ Godot transform helpers.

Acknex is left-handed with **Z up** (WED top view = X/Y).
Godot is right-handed with **Y up**.

Position:  (x, y, z)_gs  →  (x, z, -y)_godot
Scale:     (sx, sy, sz)   →  (sx, sz, sy)
Rotation (entity mesh):  pan/tilt/roll
           → Godot Euler degrees (pitch=tilt, yaw=+pan, roll=roll)

MDL meshes: axis remap matches mdl-texture-editor. A5 keeps authored +X.
IDPO Quake skins are snapped so the painted face aims +X (face-UV normals;
no soft-raster 180 flip). WED pan/tilt/roll then orients every entity.

Cameras are different: Acknex `ang_to_vec(pan,tilt)` must be remapped to a
Godot forward vector — do **not** reuse entity euler for Camera3D (−Z look).
"""
from __future__ import annotations

import math


def gs_pos_to_godot(x: float, y: float, z: float) -> list[float]:
    return [float(x), float(z), float(-y)]


def gs_scale_to_godot(sx: float, sy: float, sz: float) -> list[float]:
    return [float(sx), float(sz), float(sy)]


def gs_euler_to_godot_deg(pan: float, tilt: float, roll: float) -> list[float]:
    # Node3D default rotation order is YXZ: (x=pitch, y=yaw, z=roll).
    # Model local +X is Acknex "forward". After Z-up→Y-up, pan=0 keeps +X,
    # pan=90 maps forward to Godot −Z — that is yaw = +pan (not −pan).
    # Cameras must NOT use this; they use gs_view_forward_godot + look_at.
    return [float(tilt), float(pan), float(roll)]


def gs_view_forward_godot(pan_deg: float, tilt_deg: float) -> list[float]:
    """Acknex ang_to_vec(pan,tilt) remapped into Godot Y-up."""
    p = math.radians(pan_deg)
    t = math.radians(tilt_deg)
    x = math.cos(p) * math.cos(t)
    y = math.sin(p) * math.cos(t)
    z = math.sin(t)
    # GS (x,y,z) → Godot (x, z, -y)
    return [float(x), float(z), float(-y)]


def godot_pos_to_gs(x: float, y: float, z: float) -> list[float]:
    return [float(x), float(-z), float(y)]
