# Piposh 3D — Godot Port (alpha)

Godot **4.7** reimplementation of **Piposh 3D** (Piposh Revolution), originally built in **3D GameStudio A5** (Acknex).

Source assets were copied from `D:\Games\piposh_stuff_backup\piposh3d.zip` / `D:\Games\Piposh Revolution\Data` into `original/piposh3d/`.

**Start here:** `rewrite_skill/PORTING_MANUAL.md` (fidelity targets, phase plan), then `docs/CONTRACT.md` (transform/convert rules), then `docs/SESSION_LOG.md` (what's already been tried). This README is a quick-start pointer, not the source of truth for project status.

## Open in Godot

1. Install Godot 4.7
2. Run the conversion pipeline once (Python 3 + Pillow + numpy):

```bash
pip install pillow numpy
python tools/run_pipeline.py
```

3. Open `project.godot` and press **F5**

Boot → splash → **3D Menu** (entities from `Menu.WMB`). Orange markers = menu doors (New / Load / Exit / Credits).

## What works now

| Piece | Status |
|-------|--------|
| Full original asset dump (WDL/WMB/MDL/GFX/SFX/MOV) | Copied under `original/piposh3d/` |
| GFX PCX/BMP → PNG | `tools/convert_gfx.py` |
| MDL2–5 + Quake IDPO → GLB | 648 models via `tools/convert_mdl.py`, det +1 axis map, no per-model heuristics |
| WMB brush/BSP geometry | `tools/extract_wmb_mesh.py` — verified against all 134 WMBs |
| WMB entity extract → JSON (+ bounds/spawn/`angle_gs`) | `tools/extract_wmb_full.py` |
| Level coverage | 49/49 playable levels have entity JSON + `_brush.glb` |
| WDL parse → AST | `tools/parse_wdl.py`, 85 scripts, recursive `include` merge |
| WDL runtime | `WdlInterpreter` drives every level's script (as of 2026-07-28); ~32 builtins bridged so far against 531 distinct callees in the corpus — unimplemented calls no-op and log `[wdl] unbridged: X` rather than crashing. Seven levels (Start/Studio/Town/Shiks/Plane/Plane2/Range) also have a hand-ported `wdl_director.gd` chapter, currently bypassed in favor of the interpreter. |
| Boot + menu + level runner | Loads Menu/Studio/Town/… entity scenes |
| Save flags (IO.wdl Piece/Village/…) | `GameState` JSON slots |

`original/` is `.gdignore`d so Godot does not import the raw 1.9k WAVs.

## Not done yet (next milestones)

See `rewrite_skill/PORTING_MANUAL.md` §3–4 for the full defect catalogue and phase plan. Highlights:

- **Lighting** — no vertex normals on any converted mesh, WMB light range/intensity is mis-scaled, and A5's baked lightmaps aren't extracted yet. Runtime lights are not the right fix; see manual §5.10.
- **Interpreter coverage** — the highest-traffic gaps are `VECTOR` reference semantics (blocks the whole `vec_*`/`ang` family), `trace`, `DoDialog`, and the `actor_*` path-following builtins.
- AVI intro movies (`MOV/`)
- Hebrew UI text — no font is committed yet, so exported builds show tofu boxes for Hebrew strings; dialogue is hardcoded for 4 indices instead of a translation table.
- Settings menu, real Godot audio buses, mobile action/interact button.

## Controls

| Input | Action |
|-------|--------|
| WASD / arrows | Move |
| Mouse | Look |
| Esc | Free / capture mouse |
| F1 | Return to menu (in levels) |
| F2 | Quicksave slot 1 |
| F3 | Cycle debug levels (Studio→Start→Town…) |

## Verify

```bash
python tools/validate_levels.py --only Menu Studio Town
godot --path . --headless -s res://tools/smoke_test.gd
```

## Layout

```
original/piposh3d/     # pristine A5 game files
assets/converted/      # PNG / GLB / level JSON / SFX subset
tools/                 # Python converters
autoload/              # GameState, LevelRouter, AudioBus
scenes/                # boot, main_menu, level_runner
scripts/engine/        # WMB JSON loader
```

## License / assets

Game assets belong to the original Piposh 3D rights holders. This repo is a technical port/research harness.
