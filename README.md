# Piposh 3D — Godot Port (alpha)

Godot **4.3+** reimplementation base of **Piposh 3D** (Piposh Revolution), originally built in **3D GameStudio A5** (Acknex).

Source assets were copied from `D:\Games\piposh_stuff_backup\piposh3d.zip` / `D:\Games\Piposh Revolution\Data` into `original/piposh3d/`.

## Open in Godot

1. Install Godot 4.3+
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
| MDL3/4/5 + Quake IDPO → GLB | ~648 models via `tools/convert_mdl.py` |
| WMB entity extract → JSON (+ bounds/spawn) | `tools/convert_wmb.py` |
| Level validation / smoke test | `tools/validate_levels.py`, `tools/smoke_test.gd` |
| Boot + menu + level runner | Loads Menu/Studio/Town/… entity scenes |
| Save flags (IO.wdl Piece/Village/…) | `GameState` JSON slots |

`original/` is `.gdignore`d so Godot does not import the raw 1.9k WAVs.

## Not done yet (next milestones)

- **WMB brush/BSP geometry** (levels use fitted ground + entity props; nested `.wmb` props are markers)
- WDL action runtime (dialogs, inventory, minigames, full `Run` chain)
- AVI intro movies (`MOV/`)
- MDL animation frame playback
- Hebrew UI / voice wiring from `Voice.wdl` + full SFX bank copy (`python tools/convert_sfx_batch.py --all`)

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
