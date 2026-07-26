# Piposh 3D → Godot engine notes

**Frozen translation rules:** see [`docs/CONTRACT.md`](CONTRACT.md).  
**Level status board:** [`docs/LEVELS.md`](LEVELS.md) (regenerate with `tools/build_level_board.py`).  
**Regression gate:** `powershell -File tools/check_all.ps1`

## Original architecture

Piposh 3D is a **multi-EXE Acknex A5** title. **WDL + WMB are the full game description** — not just assets:

| Source | Contains |
|--------|----------|
| `Level.wdl` | `main()` → `load_level`, `action` behaviours, camera, `Run("Next.exe")` |
| `Level.WMB` | Entities with `file` + `action` + `skills`, paths, lights, positions |
| `WDL/*.wdl` | Shared systems (IO, movement, dialog, weapons, …) |

Each location is `Something.exe` + `Something.wdl` that `load_level(<Something.WMB>)` and transitions via `Run("Next.exe")` → `Run.txt`.

Godot port strategy: extract WMB → JSON, map each entity `action` to a GDScript behaviour (see `scripts/engine/wdl_director.gd`), and treat `Run()` as `LevelRouter.goto_level()`.

Town example (`Town.wdl`):
- `action Cam` — bind engine camera to entity; mouse look; `on_v = ToggleView`
- `action RandomBuilding` — morph `House1..10` + random pan
- `action PatrolCity` / `SportCar` — follow `path_001`… from WMB
- `action Inn` / `Taxi` / `MOI` / `Travel` — click → `Run("….exe")`

## Asset formats

| Format | Role | Converter |
|--------|------|-----------|
| `.wdl` | Scripts | Parsed for flow (`levels.json`); logic reimplemented in GDScript |
| `.wmb` | Compiled levels (WMB4/5) | Entities → JSON; brush → `*_brush.glb` |
| `.mdl` | Models (MDL3/4/5 + IDPO) | → `.glb` |
| `.pcx` / `.bmp` | UI / skins | → `.png` |
| `.wav` | Voice / SFX / music | Copied; Godot imports WAV |
| `.avi` | Intros | Not yet |

## Godot runtime

- `LevelRouter.goto_level(name)` replaces `Run("Name.exe")`
- `WmbLevelLoader` spawns entities from JSON + GLB
- `GameState` mirrors `Piece[]`, `Village[]`, … from `IO.wdl`

## Coordinates

Acknex A5 / WED is **right-handed Z-up** (RHZUP; top view = X/Y). Godot is **Y-up**.
Full semantics: [`docs/TRANSLATION.md`](TRANSLATION.md).

| Acknex | Godot |
|--------|-------|
| position `(x, y, z)` | `(x, z, -y)` |
| scale `(sx, sy, sz)` | `(sx, sz, sy)` |
| euler `pan, tilt, roll` | Conitec `ang_to_matrix` → Godot basis (`S R S`) |

Entity local **+X** is Acknex forward. Cameras use `vec_for_angle` →
`gs_view_forward_godot` (do **not** copy entity euler onto `Camera3D`).

MDL convert is uniform for MDL3+ and IDPO: axis remap, then WED pan/tilt/roll.

Shared helpers: `tools/gs_math.py`. Level JSON stores both `origin` (Godot) and `origin_gs` (raw).

`tools/verify_transforms.py` checks JSON vs raw WMB and confirms distances are preserved (orthonormal map).

Town street band is ~`floor_y = 311`; `Island.MDL` stays at authored scale **20**.
