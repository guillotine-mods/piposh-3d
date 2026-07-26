# Acknex A5 → Godot translation map

Engine semantics used by the Piposh port. Sources: Conitec manuals
(`pan`/`tilt`/`roll`, `ang_to_matrix`, `vec_for_angle`, `genius`, `min_z`),
A5 WDL Tutorial (2001), and `original/piposh3d/WDL/{camera,movement}.wdl`.

## Coordinates

| | Acknex A5 | Godot |
|--|-----------|-------|
| Handedness | **Right-handed** Z-up | Right-handed Y-up |
| Axes | +X east, +Y north, +Z up | +X, +Y up, −Z “camera forward” |
| Unit | **quant** (WED/MED unit) | same numeric value after remap |
| Position | `(x,y,z)` | `(x, z, -y)` |
| Scale | `(sx,sy,sz)` | `(sx, sz, sy)` |

## Angles

- **pan:** about upright Z, degrees CCW. `0`=+X, `90`=+Y north, `180`=−X, `270`=−Y.
- **tilt:** about rotated Y (−90…+90 typical; WED may store 345 = −15).
- **roll:** about rotated+tilted X.
- Composition: pan → tilt → roll (Conitec Euler).
- Forward (`vec_for_angle`):
  `(cos pan·cos tilt, sin pan·cos tilt, sin tilt)`.
- Entity matrix: Conitec `ang_to_matrix` (DirectX Y-up) conjugated by
  `S=diag(1,1,-1)` into Godot. Local **+X** = forward.
- Cameras: remap forward vector + `look_at` — never entity euler on `Camera3D`.
- `camera.arc` is **horizontal** FOV. Godot `Camera3D.fov` is vertical — convert
  with `v = 2·atan(tan(h/2) / aspect)`.

## Origin, feet, eyes

- WED entity position = **model origin**, not automatic feet.
- Feet contact ≈ `origin.z + MIN_Z` (GS) → Godot Y + local min after convert.
- `move_view_1st` eye height:
  `Z = player.Z + MIN_Z + (MAX_Z−MIN_Z) * eye_height_up`
  with `eye_height_up = 0.8` (`movement.wdl`).
- `camera.genius = player`: hide player body in first person.

## Time

- A5 `time` / ticks ≈ 16 Hz reference. Godot uses wall-clock `delta`.
- Approximate: multiply WDL `N * time` by ~16 when scrubbing anim percents.

## WMB objects (list 15)

| typ | Kind | Notes |
|-----|------|-------|
| 1 | POSITION | |
| 2 | LIGHT | |
| 3 | OLD ENTITY | name20, file13, action20, **pad3**, skills[8], flags |
| 6 | PATH | points (+ optional edges) |
| 7 | NEW ENTITY | longer names, skills[20], path index, ambient |

Piposh levels are almost entirely OLD ENTITY + WMB4/5.

## Flags (WED / runtime)

Observed / applied in this port:

| Mask | Meaning (working) |
|------|-------------------|
| `0x1` | `INVISIBLE` — hide meshes at spawn |
| `0x400` | Passable / non-solid prop — skip prop collision |
| `0x40000` | Common “shadow/cast” bit — ignored for now |

Actions may still toggle visibility at runtime (e.g. `PiposhHit`, `Vase1`).

## Level modes

| WMB signal | Runtime |
|------------|---------|
| `player_walk*` / `player_stand` / `player_fly` | First person (`move_view_1st`) |
| `Cam` / `MyCamera` without player_* | Scripted camera |
| Cutscene chapters (Start/Studio/Shiks/Plane) | Director overlay |

## Tick checklist before changing facing/spawn

1. Read `docs/CONTRACT.md`.
2. Prefer pipeline fix over per-entity hack.
3. Run `tools/check_all.ps1`.
