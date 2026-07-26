# Piposh 3D → Godot contract (frozen)

This is the **single source of truth** for Acknex A5→Godot translation.
Levels must work from **uniform convert + spawn + WDL data**, not per-level hacks.

If a fix requires violating this file, **add a failing test first**, then update
this contract in the same change.

See also [`docs/TRANSLATION.md`](TRANSLATION.md) for engine semantics.

## 1. Transforms (`tools/gs_math.py`)

Acknex A5 / WED is **right-handed Z-up** (RHZUP): +X east, +Y north, +Z up.
Godot is right-handed Y-up.

| Quantity | Formula |
|----------|---------|
| Position | `(x,y,z)_gs → (x, z, -y)_godot` |
| Scale | `(sx,sy,sz) → (sx, sz, sy)` |
| **Entity** basis | Conitec `ang_to_matrix` (DX) → `R_g = S R_dx S`, `S=diag(1,1,-1)` |
| **Camera** forward | Acknex `vec_for_angle` / `ang_to_vec(pan,tilt)` → Godot `(x, z, -y)`, then `look_at` |

- Entity local **+X** is Acknex forward. `pan=0` → +X, `pan=90` → +Y (Godot −Z).
- **Forbidden:** spawn or re-orient via Euler `(tilt, ±pan, roll)` alone when tilt/roll
  may be nonzero. Rebuild basis with `ang_to_matrix` / `_acknex_entity_basis`.
- Cameras **must not** copy entity basis onto `Camera3D`.
- Level JSON stores raw `angle_gs = [pan, tilt, roll]`. Spawn reads **`angle_gs` only**.
- JSON `angle_deg` is a legacy dump field; ignore at runtime.

## 2. MDL convert (`tools/convert_mdl.py`)

Same pipeline for every model:

1. **A5 (MDL2–5):** `_gs_to_godot` axis remap; **keep authored facing**
   (WED pans assume MED orientation — do not face-UV re-yaw A5).
2. **IDPO:** `_idpo_to_godot` axis remap; then `orient_mesh_face_plus_x`
   (face-UV normals → +X). **No** soft-raster 180 flip.
3. Faceless / paper-thin props: leave authored facing.
4. **Forbidden:** global `pan+180`, flipping IDPO to A5 Z-sign “to try”,
   or silent per-model yaw tables. Exceptions only via
   `tools/mdl_yaw_allowlist.json` + a test row.

## 3. WMB / levels

1. Extract with `tools/extract_wmb_full.py` (entities, skills, paths, `angle_gs`, flags).
2. OLD ENTITY (`typ==3`): **3 pad bytes** after action before the 8 skills.
3. Brush mesh with `tools/extract_wmb_mesh.py` → `levels/{Name}_brush.glb`.
4. Loader resolves GLB/JSON via **`ResourceLoader` / direct paths first**
   (Android PCK-safe).
5. **Origin vs feet:** WED point = **model origin**. Engine feet = `Z + MIN_Z`.
   Feet-snap is an **opt-in** lift for floor actors (Walk/Stand characters) so
   mesh AABB min Y lands on the WED origin. **Off** for cameras, wall cards,
   and attachment scenery (`Window`, `Glass`, `B747`, `Cockpit`, `TV`, `Island`,
   `HeadPhone`, `Land`, biplanes). Never default-snap everything.
6. **Flags:** apply at spawn — `INVISIBLE` (bit0) hides meshes; `PASSABLE`-class
   bits skip prop collision.
7. **First person:** WMB `player_walk*` / `player_stand` / `player_fly` →
   `move_view_1st` (LevelRunner FP). Eye =
   `MIN_Z + 0.8*(MAX_Z−MIN_Z)`. Wins over generic Cam scripting.
8. Outdoor sky: `AcknexSky` from `wdl_meta.json`. No solid-color fake sky outdoors.

## 4. WDL runtime

Prefer **data-driven** behaviour from WMB actions + `levels.json` + `wdl_meta.json`:

- `Cam` / `MyCamera` → scripted camera
- `player_walk*` → first person
- paths → walk / LookAtMe (nearest / skill-bound, not random)
- click actions / `Run("X.exe")` → `LevelRouter.goto_level`
- `scene_map` → horizon cylinder

Custom director chapters (Start/Studio/Shiks/Plane/Plane2) are **overlays** on
this generic runtime, not a separate transform system.

## 5. Talk / audio

- Mouth / Talk skins only while voice is playing (or an explicit WDL phase).
- SFX live under `assets/converted/sfx/` and **are committed** to git.

## 6. Android export

- `export_presets.cfg` UTF-8 **without BOM**
- `include_filter` must keep non-resource sidecars: `*.json, *.mdlanim, *.skins`
- Never rely on DirAccess-only indexes inside a PCK

## 7. Agent / PR rules

1. Read this file before changing facing, spawn, convert, or sky.
2. Change **one layer** at a time (convert xor spawn xor director).
3. Run `powershell -File tools/check_all.ps1` before claiming fixed.
4. Forbidden without a new failing test: pan sign flip, disable face-UV,
   feet-snap on scenery, solid outdoor skies, one-off model yaw hacks,
   or Euler spawn / re-yaw instead of `ang_to_matrix`.
5. **Check `docs/SESSION_LOG.md` before retrying a fix.** If a prior session
   already tried an approach for this symptom and it failed, don't repeat it
   blindly — that's how this project loops. Read why it failed, then try
   something different or ask the user something more specific.
6. **A runtime bug gets a debug-log iteration before it's "fixed."** If a
   `tools/verify_*.py` script can mechanically decide the question (angles
   match raw WMB, det +1, entity→GLB coverage), that's sufficient. Otherwise
   — facing "looks wrong," something "sinks," a click "doesn't work" — add
   targeted `print()`/`push_warning()` output, ask the user to run the game
   and report the exact output, and log the question + answer in
   `docs/SESSION_LOG.md`. Static code reading can narrow hypotheses; it does
   not confirm them (see the "silent, invisible errors" warning at the top of
   `fixes/SKILL.md`).
7. **Commit after each verified change**, not in one large uncommitted batch.
   Small, reviewable diffs are how loops and regressions get caught early;
   a 2000-file uncommitted changeset is not reviewable by anyone.
8. **Track completion in `docs/PLAYTEST.md`, not just `docs/LEVELS.md`.** The
   goal is a complete, correct game — pipeline coverage (JSON/brush/director
   present) is necessary but not sufficient. Don't call a level done because
   its `LEVELS.md` row is green; call it done when a playtest confirms it.
9. **Before wiring an entity `action` to a behaviour, grep
   `original/piposh3d/WDL/*.wdl` (and the level's own `.wdl`) for that action
   name.** Do not infer behaviour from spatial/visual proximity to another
   entity ("it's on the same wall as X, so it probably does what X does") —
   that produced the `AFG_Card` bug (aliased to `ShikNote`'s Shiks-scene
   click because it sits on the same wall; the real script,
   `WDL/Afgan.wdl`, is an unrelated 32-card collectible system). If no WDL
   source defines the action, say so explicitly instead of guessing — an
   inert/stubbed entity is more honest than a wrong one.
