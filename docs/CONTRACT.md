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

**One rule, no per-model branching, for every model, A5 or IDPO alike:**
axis-remap with the handedness-correct, det **+1** map, then **keep
authored facing**. No face-detection heuristic runs on anything, ever.
`_gs_to_godot` (A5) and `_idpo_to_godot` (IDPO, `FIX_IDPO` path) are both
proper rotations from their native format into Godot; WED's `pan` then
orients every entity uniformly regardless of source format, exactly as
Acknex itself does. This *is* the original design intent (see history
below) — do not reintroduce per-model classification, allowlists, or a
heuristic without a human-confirmed reason and a byte-diff to prove it, per
rule 3 below.

1. Axis remap only: `_gs_to_godot` for MDL2–5, `_idpo_to_godot` with
   `FIX_IDPO` for IDPO. Both are det +1 — assert it
   (`_assert_proper_rotation`).
2. **Forbidden:** face-UV / skin-pixel heuristics, soft-raster front/back
   guessing, global `pan+180`, per-model yaw tables, or any mechanism that
   decides facing from anything other than the raw authored mesh + WED pan.
   If a specific model is later found to need an exception, it must come
   with (a) a human-confirmed screenshot/description of what's wrong, and
   (b) the fix must be checked by comparing rendered output, not by an
   internal metric grading itself.
3. **The only sound verification for an orientation change is external
   ground truth** — a human's description of what they see, or a rendered
   image — never a metric computed by the same code path being changed.
   `docs/SESSION_LOG.md` 2026-07-27 has the two-strikes history of why this
   rule exists: a "det -1 vs det +1 mirror" mistake, then a "restore to a
   prior commit" mistake where the prior commit itself was never actually
   human-validated for most of the affected models. A model matching an
   earlier commit only proves *determinism*, not *correctness* — Crowd,
   Wwheel, and Bus were all still wrong after being restored to
   byte-identical prior states, because those prior states were never
   confirmed correct either; they just predated this session's changes.
   Don't equate "unchanged from before" with "right."
4. **Why `mdl_yaw_allowlist.json` (4 entries) is not a contradiction of
   rule 1, checked and logged so it isn't re-litigated blind:** the fair
   challenge is "the original engine is deterministic, so a correct parse
   should need zero per-model entries." Checked, not just asserted
   (2026-07-27): (a) compared the raw IDPO header of all 4 allowlisted
   models against 7 confirmed-correct IDPO models (Ami, Sfan, Island,
   ShikFond, Wwheel, Bus, B747) — `version`, `flags`, `synctype`, and the
   sign of `scale` are byte-identical in shape across all 11; nothing in
   the MDL format itself flags "this asset's forward isn't +X". (b)
   Pulled Crowd's 24 individual WMB placements from `Start.json` —
   each has its own small, plausible `angle_gs` (a scattered crowd loosely
   facing one direction, consistent with the movie-screening scene in
   `Start.wdl`'s `DefineYachdel`/`Scene` logic), not a uniform
   miscompensating offset — ruling out "our WMB pan extraction is buggy
   for these entities." Conclusion: the MDL format has **no field that
   declares authored forward** — it's a pure modeling-tool convention, and
   these 4 specific meshes' vertex data just wasn't built to it (most
   likely reused/legacy assets, not an artifact of our parser). That can't
   be recovered by reading more bytes; a fixed, once-measured, per-asset
   correction applied uniformly everywhere that file is used (never
   per-level, per-instance, or re-guessed) is the deterministic ceiling
   here — structurally the same kind of fix as the axis remap itself, just
   scoped to 4 files instead of all 375. Don't try a geometry/UV heuristic
   to replace this table — that was already tried twice and both attempts
   regressed previously-correct models (rule 3's history).

## 3. WMB / levels

1. Extract with `tools/extract_wmb_full.py` (entities, skills, paths, `angle_gs`, flags).
2. OLD ENTITY (`typ==3`): **3 pad bytes** after action before the 8 skills.
3. Brush mesh with `tools/extract_wmb_mesh.py` → `levels/{Name}_brush.glb`.
4. Loader resolves GLB/JSON via **`ResourceLoader` / direct paths first**
   (Android PCK-safe).
5. **Origin vs feet:** WED point = **model origin**. Engine feet = `Z + MIN_Z`.
   Feet-snap is **opt-OUT**: on by default (mesh AABB min Y lifted to the WED
   origin) for everything, since WED origin is a floor/attachment reference
   and MDL geometry commonly hangs below it. **Off** only for cameras, wall
   cards (`AFG`, `ShikNote`), `window`-action glass, and a short
   measured-exception stem list (`glass`, `b747`, `tv`, `island`,
   `headphone`, `biplane`, `biplane2`, `hanger`, `towerw`, `dutyfree`) —
   see `_should_feet_snap` in `wmb_level_loader.gd`. **`Cockpit` is NOT in
   that list** — it was there until 2026-07-27, found wrong by direct
   measurement (GLB local Y spans -165.66..+76.83, hangs mostly *below*
   origin, same shape as every other floor prop) and removed; do not
   re-add it without a fresh measurement. Checked whether the remaining
   stem list could instead be derived from data (2026-07-27): cross-
   referenced every excluded stem's WDL `action` across all levels — no
   action name or pattern reliably predicts "should skip snap" (several,
   like `dutyfree`/`hanger`/`towerw`, have **no action at all**, same as
   `Cockpit` had before it was found to need snapping — a blank action is
   not a valid signal). `B747` does have a real, checkable reason: its own
   `action B747` in `Plane2.wdl` assigns `my.z` directly during flight — a
   runtime-controlled vehicle, not a floor prop, so a load-time floor-lift
   doesn't apply to it at all. Where no such reason is found, treat the
   entry as an unverified carry-over, not a confirmed rule — re-measure
   before trusting it, same as Cockpit needed. Never default-snap
   everything off (the opposite regression, already hit once).
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
