---
name: piposh3d-godot-port
description: >-
  Rules and workflow for accurately porting Piposh 3D (3D GameStudio / Acknex A5)
  to Godot 4 in the piposh-3d-godot repo — converting WMB levels, MDL models, WDL
  logic, and GFX/SFX assets. Use this skill whenever the task involves Acknex/A5
  or Quake IDPO asset conversion, coordinate/handedness transforms, WMB/MDL/WDL
  parsing, entity orientation ("model faces the wrong way", "level looks wrong"),
  brush/BSP geometry extraction, or getting a converted Piposh 3D level to run in
  Godot. Consult it even when the request sounds like a quick fix ("just rotate
  this model", "why is this level empty"), because the failure modes here are
  silent and the naive fix usually causes another regression.
---

# Piposh 3D → Godot conversion

Porting this game is not line-by-line translation — the original **levels are
code**: each location is `Something.exe` + `Something.wdl` + `Something.WMB`, and
the WDL defines behaviour, not just data. Assets convert generically; level
*semantics* (geometry, WDL actions, per-model orientation) are only partly
general. Expect a long tail of per-level work, and optimise for **not
regressing** what already works.

## Prime directive: deterministic, verified, one convention

The single biggest time sink on this project is **silent, invisible errors**.
Converted meshes render `UNSHADED` + `doubleSided` + `CULL_DISABLED` with no
vertex normals, so a mirrored, back-facing, or 180°-wrong model looks *almost
correct*. You cannot eyeball your way out of that — you will loop forever. So:

1. **Never guess orientation from pixels or vibes.** Derive it from a known
   transform, then confirm with a check that prints a number or one image.
2. **One source of truth per quantity.** Where two fields encode the same thing,
   trust the raw one and delete/ignore the derived one (see angles below).
3. **Make "the check passes" the success criterion**, not "it looks right in my
   head." Every change should end with `verify_transforms.py`,
   `validate_levels.py`, a smoke test, or a single rendered PNG.
4. **Scope tightly.** WDL and Acknex formats are thin ground for language models;
   change one thing, verify, commit. Do not free-run an agent across the engine.

## Coordinate & handedness conventions (authoritative)

Acknex/WED is **Z-up, left-handed** (top view = X/Y). Godot is **Y-up,
right-handed**. Helpers live in `tools/gs_math.py`.

| Acknex quantity        | Godot result            | Notes |
|------------------------|-------------------------|-------|
| position `(x, y, z)`   | `(x, z, -y)`            | proper rotation, det **+1**, distance-preserving |
| scale `(sx, sy, sz)`   | `(sx, sz, sy)`         | |
| euler `pan, tilt, roll`| `rotation_degrees = (tilt, +pan, roll)` | yaw is **+pan** (model local **+X** = Acknex forward) |

- **Cameras are different.** Do **not** copy an entity's euler onto a `Camera3D`.
  Use `gs_view_forward_godot(pan, tilt)` + `look_at` — cameras look down `-Z`.
- Any position map you introduce for meshes **must have determinant +1**. A det
  `-1` map is a reflection: it mirrors geometry so front faces become back faces.
  With culling disabled you won't see it, but the model is genuinely wrong.

## Entity angles: `angle_gs` is truth, `angle_deg` is contaminated

Level JSON stores both `angle_gs` (raw `[pan, tilt, roll]` from the WMB) and
`angle_deg` (a derived Godot euler). **`angle_deg` is unreliable** — the repo
history left two conventions (`[tilt, +pan, roll]` and the older `[tilt, -pan,
roll]`) mixed together, sometimes within one file. Rules:

- Read rotation from `angle_gs` only: `rotation_degrees = (tilt, +pan, roll)`.
- **Never re-negate pan** in a fallback path — that negation is what created the
  contamination in the first place.
- If a level lacks `angle_gs`, regenerate it from the source WMB with
  `tools/migrate_angles.py --only <Level>` rather than trusting `angle_deg`.
- After any angle change, run `python tools/verify_transforms.py` (checks JSON
  vs raw WMB and confirms distances are preserved).

## MDL models (`tools/convert_mdl.py`)

- A5 (`MDL2/3/4/5`) uses `_gs_to_godot` (det +1) and keeps authored **+X**
  forward. Good.
- Quake **IDPO** historically used a det **-1** reflection map, making Quake
  models opposite-handed from A5 models — the real reason facing was unreliable
  and why a skin-pixel "find the face, snap to +X" heuristic got bolted on.
- **Correct approach:** use a det +1 IDPO map matching A5, and flip triangle
  winding once to compensate (a proper rotation preserves winding, so switching
  off the reflection requires one flip). Assert det +1 at runtime so the bug
  can't silently return. Then **delete the skin-pixel heuristic** — WED pan
  orients every entity uniformly, exactly like A5 models.
- Verify on ONE model, not 640: `godot --headless -s res://tools/smoke_orient.gd
  -- Ami`. Correct = the character faces the camera (camera sits on +X). Compare
  a baseline build against a `--fix-idpo --no-face-orient` rebuild.
- Keep materials unshaded/nearest/alpha-scissor to match the A5 look — **but**
  when debugging orientation, temporarily emit normals or enable backface
  culling so wrong-facing geometry becomes visible.

## WMB levels (`tools/extract_wmb_full.py`, `tools/extract_wmb_mesh.py`)

- Entities/lights/paths → JSON via `extract_wmb_full.py`. This is the reliable
  part. Object list is index **15**; entity types are **3** (old) and **7**.
- Brush/BSP geometry (`extract_wmb_mesh.py`) is **best-effort**: it skips faces
  it can't reconstruct from the edge/surfedge lists and returns nothing for a
  whole level if the list layout doesn't match. Only a whitelist of levels is
  attempted. When there's no brush mesh, the loader drops a flat placeholder
  floor — so "the level loaded but it's an empty pad" means geometry extraction
  failed, not that the level is broken.
- After axis remap, **flip winding** for right-handed Godot (fan-triangulate as
  `[base, base+k+1, base+k]`).
- **UV caveat:** the extractor divides s/t by texture width/height assuming
  texel-scale vectors. If textures look tiled/misscaled, that assumption is the
  suspect. **Texture format** detection (RGB565 vs 24/32-bit) is heuristic; a
  reddish `(160,80,80)` fill means format mis-detection, not a missing texture.

## WDL logic — this is why levels need per-level work

`docs/ENGINE.md` is the map. Each level's `main()`, camera binding, and per-entity
`action` behaviours (`Cam`, `RandomBuilding`, `PatrolCity`, `Inn`/`Taxi`/`Travel`
triggers, minigames) are **reimplemented by hand** in
`scripts/engine/wdl_director.gd`. `Run("Next.exe")` maps to
`LevelRouter.goto_level("Next")`. A level using an action nobody has ported yet
still loads, but its entities sit inert. Bringing a new level to *playable* means:
extract its geometry, reimplement its actions, and patch its per-entity quirks —
in that order.

## Per-asset special cases live in the loader

`scripts/engine/wmb_level_loader.gd` holds hardcoded fixes: brush-duplicate
skips (`townl`/`desertl`/…), `StudioL` nudged `+4`, wall cards (`shiknote`/`afg`)
rebuilt as quads, a feet-snap heuristic assuming WED origin = feet. When a model
sits wrong, prefer fixing the **general** cause (axis map, feet-snap rule) over
adding another hardcoded name — every hardcode is future maintenance. If you must
special-case, keep it in one clearly-commented block and note *why* the general
path fails for it.

## Standard verification loop

Run these before declaring anything fixed:

```bash
python tools/extract_wmb_full.py --only <Level>     # entities → JSON
python tools/migrate_angles.py --only <Level>       # clean angle_gs
python tools/verify_transforms.py                   # JSON vs raw WMB, distances
python tools/validate_levels.py --only <Level>      # entity → GLB coverage
godot --path . --headless -s res://tools/smoke_test.gd
# visual: render ONE image, inspect it — don't trust unshaded double-sided
godot --headless -s res://tools/smoke_orient.gd -- <Model>
```

## Gotchas checklist

- [ ] Reading rotation from `angle_gs`, never re-negating pan?
- [ ] Any new position/mesh transform has determinant **+1**?
- [ ] IDPO winding flipped to match its axis map?
- [ ] Camera pose from `ang_to_vec`, not entity euler?
- [ ] Change verified by a printed number or a single rendered PNG?
- [ ] Fixed the general cause instead of adding another hardcoded name?
- [ ] Empty-looking level = brush extraction failed (check `extract_wmb_mesh`)?
