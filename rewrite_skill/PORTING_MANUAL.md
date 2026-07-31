# Piposh 3D → Godot 4: Porting Manual

**Audience:** the LLM agent doing the work.
**Repo:** `guillotine-mods/piposh-3d-godot` (audited at commit `0937726`).
**Authorization:** the rights holder has approved this remaster. Assets ship in the clear and may be committed, converted, and redistributed. Do not spend turns on licensing.

---

## 0. How to use this document

Read this file, then `docs/CONTRACT.md`, then `docs/SESSION_LOG.md`, **before your first edit.**

Precedence when documents disagree:

1. This manual (fidelity targets and phase order)
2. `docs/CONTRACT.md` (transform and convert rules)
3. `docs/TRANSLATION.md` (A5 engine semantics)
4. `docs/ENGINE.md`, `docs/LEVELS.md`, `docs/PLAYTEST.md`
5. Code comments
6. `fixes/SKILL.md` — **stale, see §3.6. Do not follow it.**

When this manual and CONTRACT.md conflict, this manual wins and **you must update CONTRACT.md in the same commit** so the conflict does not survive you.

### Three rules that override any instinct to be helpful fast

**R1 — Never claim a fix works because you read the code.** Static reading narrows hypotheses. It does not confirm them. A change is "done" only when a check prints a number, a rendered image is inspected, or the user reports observed behavior. This project has already burned multiple sessions on fixes that looked right and were not.

**R2 — Never verify a change with a metric computed by the code path you changed.** If you modify the orientation pipeline, do not validate it with a script that reads the orientation pipeline's own output as ground truth. Compare against raw source bytes, a rendered PNG, or the user's eyes. `docs/SESSION_LOG.md` 2026-07-27 documents two consecutive failures of exactly this kind.

**R3 — When you cannot determine something from the data, say so and stop.** Do not fill a gap with a plausible constant. The `Bus` model's facing is the canonical example: it is genuinely unrecoverable from the MDL format or any WDL source, and the correct action is to ask the user for one screenshot, not to guess a yaw value. An inert entity is more honest than a wrong one.

---

## 1. Mission and the definition of "correct"

### 1.1 The fidelity target

The game must play the way it played on Acknex A5: same level flow, same camera behavior, same NPC behavior and timing, same lighting mood, same menu structure, same audio cues. A player who knows the original should not be able to name a behavioral difference.

"Same" is judged against **the original executables' observable behavior**, not against the port's current behavior and not against your reading of the WDL. Where the WDL and a screenshot disagree, the screenshot wins.

### 1.2 Sanctioned deviations — do these deliberately

These are approved improvements, not fidelity bugs. Do not "fix" them back toward A5.

| # | Deviation | Rationale |
|---|---|---|
| D1 | **Text is re-rendered with real font glyphs**, not the original bitmap-baked strings | Sharp at any resolution, scales to mobile, makes future localization possible. Already begun in `scripts/ui/game_hud.gd`; §7 finishes it. |
| D2 | **Level select** (F4 / menu entry) | The original chained EXEs; late levels were unreachable without a full playthrough. |
| D3 | **Quick save / quick load** with named slots | A5 build had a minimal `writegamedata` path. |
| D4 | **Mobile support** with on-screen movement, look, and action controls | New platform. |
| D5 | **Settings menu** — resolution, audio buses, sensitivity, language, touch layout | A5 exposed only `video_mode` / `video_depth` globals. |
| D6 | **Widescreen support** at correct horizontal FOV | A5 ran 4:3. See §5.4 — the FOV conversion is a fidelity requirement, not an aesthetic choice. |

Everything not in that table is a fidelity target.

### 1.3 What "done" means for a level

A level is done when **all** of these hold:

- Entity JSON and `_brush.glb` exist and validate.
- Its `.wdl` executes — via `WdlInterpreter` or a reviewed hand-port — with **zero `[wdl] unbridged:` lines** in the console for that level.
- Lighting is lit geometry with real normals, WMB lights at correct range, and baked lightmaps where the WMB has them (§6).
- Camera mode matches the original (first-person, scripted, or free) and FOV comes from `camera.arc`, not a literal.
- A human has played it and its row in `docs/PLAYTEST.md` says so.

A green row in `docs/LEVELS.md` means the pipeline produced files. It does not mean the level works. Do not conflate them.

---

## 2. Current state: verified inventory

I measured all of the following directly. Trust these numbers; re-measure before changing anything that would move them.

### 2.1 What is solid — do not rewrite

| Area | State |
|---|---|
| Level coverage | 49/49 playable levels have both entity JSON and `_brush.glb`. No gaps. |
| MDL conversion | 648 models → GLB. Single det **+1** axis map for both A5 (MDL2–5) and Quake IDPO, winding flip on IDPO, `_assert_proper_rotation()` guard. Correct. |
| Brush/BSP reconstruction | Standard Quake/GoldSrc edge/surfedge walk, verified against all 134 WMBs. |
| glTF validity | 783/784 GLBs parse as strict glTF. (The one failure is §3.4.) |
| WDL parse | 85 ASTs; recursive `include` merge resolves the `IO.wdl` chain correctly — this is genuinely hard and it is right. |
| Path resolution | `_resolve_level_json` / `_resolve_brush_glb` / `_direct_glb` probe direct paths with case variants before `DirAccess`. Correct for case-sensitive filesystems and Android PCKs. |
| Transform contract | `angle_gs` as single source of truth, det +1 discipline, `ang_to_matrix` for entity basis, cameras excluded from entity euler. Correct. |

### 2.2 The blocking defect chain, in priority order

Everything in §3 is a real, reproduced defect with a file and line. Work them in the phase order in §4, not in the order you find them interesting.

---

## 3. Defect catalogue

### 3.1 [P1] Dispatch chain disables most of the game's logic

`scripts/engine/wdl_director.gd:610–636`:

```gdscript
if HAND_PORTS_ENABLED and _is_start_level():           # const is false (line 41)
elif HAND_PORTS_ENABLED and _is_studio_level():        # ...all seven disabled
...
elif fp:                                               # ← interpreter never reached
    scripted_camera = false
    _wire_generic_run_clickables()
elif scripted_camera and _try_begin_interpreted_level():
elif scripted_camera:
    _begin_generic_level()
else:
    status.emit("Free player camera")                  # ← nothing runs
```

Three compounding faults:

1. `HAND_PORTS_ENABLED := false` (line 41) bypasses ~2,000 lines covering Start, Studio, Town, Shiks, Plane, Plane2, Range — the **only human-playtested behavior in the project**. The comment says this was requested deliberately. It is still the single largest live risk, and it violates CONTRACT.md §4.1's own rule ("check it reproduces a level already confirmed correct by a human" before extending).
2. The `elif fp:` branch precedes the interpreter, so **every first-person level runs zero WDL**. Plane2 lost both paths at once: its hand-port is disabled and its interpreter is unreachable.
3. The interpreter is gated on `scripted_camera`, so a level needs a `Cam`-class entity to get any behavior. **13 playable levels have a parsed AST but no camera-action entity** — AsyAct2, AsyAct3, Desert, Final, InShrine, Inn, Map, Mine, Mount, Olympic, Plane2, Race, Shooter — and fall to the `else` branch as inert geometry.

**Root cause:** the chain conflates *who owns the camera* with *whether the level's script runs*. Those are independent questions.

### 3.2 [P3] Interpreter coverage is far thinner than the docs imply

`_register_builtins()` registers **32** builtins. Walking every AST: **531 distinct callees**, **11,410 call sites**, of which **~2,960 resolve to nothing** after excluding user-defined functions.

Highest-traffic unbridged names, with real call counts:

| Calls | Builtin | What is dead without it |
|---:|---|---|
| 104 | `ang` | angle normalization — pervasive |
| 98 | `DoDialog` | all dialogue |
| 58 | `actor_move` | NPC movement |
| 56 | `trace` | line of sight, most click and proximity triggers |
| 47 | `vec_scale` | blocked on VECTOR reference semantics |
| 46 | `vec_rotate` | same |
| 47 / 44 / 37 | `file_close` / `file_str_read` / `writegamedata` | save and load |
| 33 | `actor_explode` | combat feedback |
| 31 / 31 / 30 / 30 | `ent_waypoint` / `actor_turnto` / `scan_path` / `ent_nextpoint` | path following |

`VECTOR`-typed by-reference builtins are no-ops because the interpreter has no reference-semantics variables. That one missing feature blocks the entire `vec_*` / `ang` / `vec_to_angle` family — the largest single cluster in the table.

### 3.3 [P2] Lighting is structurally wrong in three independent ways

This is the largest fidelity gap and it needs the most care. All three faults are confirmed by measurement.

**(a) Zero vertex normals anywhere.** I parsed all 784 GLBs: **not one contains a `NORMAL` attribute.** All 1,603 materials are `doubleSided: true`.

`_force_unshaded_if_needed()` (`wmb_level_loader.gd:571`, now misnamed) was recently switched to `SHADING_MODE_PER_PIXEL` so WMB lights would have something to fall on. But lit shading on meshes with no normals means Godot's importer synthesizes **flat** normals per glTF spec — and with `cull_mode` disabled, back faces are lit using the front-face normal. Result: harsh faceting on low-poly A5 meshes and incorrectly lit back faces. Nothing like A5's smooth per-vertex lighting.

**(b) All 358 lights are effectively switched off.** `_spawn_light()` (line 630):

```gdscript
light.omni_range = clampf(rng * 0.05, 4.0, 120.0)
light.light_energy = 1.1
```

Measured across level JSONs: 358 light objects, `range` from **100 to 500,000 quants, median 500**. Town's floor sits at `floor_y = 311`; props reach 80,000 quants out. A median light becomes a **25-quant** radius and the largest is clamped to 120. In a world of that scale these illuminate nothing. `light_energy` is a fixed literal, discarding whatever intensity A5 stored.

**(c) A5's baked lightmaps are discarded entirely.** A5 lit brush geometry with **precomputed lightmaps stored in the WMB**, not with runtime lights. `tools/extract_wmb_mesh.py` reads lists 2 (textures), 3 (vertices), 6 (texinfo), 7 (faces), 12 (edges), 13 (surfedges) — and **never touches the lightmap list.** Grep for `lightmap` in that file returns nothing.

Worse, the face record is 24 bytes and the extractor reads only three fields:

```python
base = f_off + fi * 24
first = struct.unpack_from("<i",  data, base + 4)[0]   # first surfedge
num   = struct.unpack_from("<h",  data, base + 8)[0]   # edge count
ti    = struct.unpack_from("<h",  data, base + 10)[0]  # texinfo index
```

Bytes **0–3** and **12–23** are never read. Following Quake's `dface_t` layout, which WMB4/5 closely follows, those almost certainly hold the **plane index** and the **light styles plus lightmap offset**. Two things follow:

- The plane index gives every face its **exact authored normal for free**, from the planes list. That is the correct fix for (a) — not smooth-normal generation, not a shader hack.
- The lightmap offset is the entry point for (c).

**Do not attempt to reproduce A5 lighting with runtime OmniLights.** That is the wrong model and it will never converge.

### 3.4 [P4] Stale and duplicated converted assets

- **`assets/converted/wmb/Shiks.glb` still has a NUL-padded JSON chunk** — the exact defect CONTRACT.md §2.5 claims to have fixed. Strict parse fails: `Extra data: line 1 column 21020`. It is a pre-fix artifact that was never regenerated. `levels/Shiks_brush.glb` is the same level re-extracted correctly. Two copies of one level, one broken — and `_find_wmb_glb("Shiks")` reaches the broken one first.
- **279 duplicate-content groups, ~23 MB.** Level textures: **778 files, 366 unique images** (2.1×). Each brush GLB embeds its own copy of shared textures (`metalrust`, `checker1`, `LIFT`, …). Godot imports and holds every copy separately in VRAM — a real cost on the Android target.
- **4,847 `.import` files** → very long first editor open.
- ~140 debug PNGs plus `.import` sidecars committed under `tools/` (`render_*`, `uvcheck_*`, `_prev_*`, `gltf_*`, `_chk_*`, `fixed_*`).

### 3.5 [P4] Two frame-rate–dependent timing bugs

`scripts/engine/wdl_director.gd:1167` and `:1173`:

```gdscript
node.global_position.y -= 5.0 * t * delta    # t is ALREADY delta * 16.0
node.global_position.y += 10.0 * t * delta
```

That is **delta-squared**: ~**60× too slow at 60 fps**, and the speed changes with refresh rate. Every other use of `t` in the file is correct (`_range_fire_length -= 3.0 * t`, `target["delay"] -= t`, `pan + 0.2 * t`, `_p2_hammer_t += 10.0 * t`). These two lines are the only outliers. Shooting-range targets barely move.

Same function, line 1177:

```gdscript
if not bool(target["pop"]) and randi() % int(_range_rapidness) == int(_range_rapidness / 2.0):
```

This roll happens **per frame**, while `target["delay"]` decrements **per tick**. At 60 fps targets pop ~**3.75×** too often — the minigame's difficulty depends on the player's monitor. `scripts/engine/mdl_animator.gd` already does this correctly by gating its `randi() % 40` behind a 0.06 s accumulator; copy that pattern.

`project.godot` has no `[physics]` section at all: `physics_ticks_per_second` is unpinned.

### 3.6 [P0] Documentation contradicts itself and the code

- **`fixes/SKILL.md:43` says Acknex/WED is "Z-up, **left-handed**." `docs/CONTRACT.md:13` says "**right-handed** Z-up."** Both present themselves as authoritative. For a project whose central discipline is det ±1, this is the worst possible sentence to have two versions of. CONTRACT.md is correct; `docs/TRANSLATION.md` agrees with it.
- **`fixes/patching_3d_godot.zip` is stale and actively harmful.** Its patch sets `FIX_IDPO=False` / `FACE_ORIENT=True` as opt-in defaults. The current code has already moved past that to `FIX_IDPO=True` / `FACE_ORIENT=False`. Applying the patch regresses the fix.
- **`tools/migrate_angles.py` does not exist in `tools/`** — it lives only inside that zip, while CONTRACT.md's "Standard verification loop" and SKILL.md both tell you to run it. The documented verification loop cannot be executed from a clean clone.
- **README says "Godot 4.3+"; `project.godot` declares `config/features=PackedStringArray("4.7", …)`.** A 4.3 editor will not open this project.
- README's "What works now" / "Not done yet" tables predate the interpreter entirely.

### 3.7 [P0] The repo cannot be rebuilt from a clone

- `original/` is gitignored, so README step 2 (`python tools/run_pipeline.py`) fails immediately in `convert_gfx.py`.
- Even with the originals present, `run_pipeline.py` **never calls `extract_wdl_meta.py`** (produces `wdl_meta.json`, required by `AcknexSky` per CONTRACT §3.8) **or `parse_wdl.py`** (produces `wdl_ast/`, required by the interpreter per §4.1). The documented pipeline cannot reproduce the committed asset set.
- `extract_wmb_mesh.py --only` defaults to **7 stems out of 134**; `convert_mdl.py --limit 80` out of 375+.
- `export_presets.cfg` is gitignored, yet CONTRACT §6 specifies requirements for it (UTF-8 without BOM, `include_filter` keeping `*.json, *.mdlanim, *.skins`). The Android build is not reproducible.
- No `.github/` at all. Every `verify_*.py` script runs only when someone remembers.

### 3.8 [P5] Text rendering is half-finished and will show empty boxes on export

The approach is right — `game_hud.gd:313` sets `TEXT_DIRECTION_RTL`, Godot `Label`s are overlaid on the original `Opt` bar GFX. But:

- **There is no font file anywhere in the repository.** I searched for `*.ttf`, `*.otf`, `*.woff*`, `*.fnt` — zero hits. Every Hebrew string is rendering through Godot's built-in default font, which has **no Hebrew coverage**. In an exported build this is tofu boxes. It may look fine in the editor only because of an OS font fallback that will not ship.
- Hebrew strings are **hardcoded in GDScript** (`_dialog_lines()`, `game_hud.gd:330`), covering only 4 dialog indices × 3 lines. There is no string table, and `.gitignore` excludes `*.translation`.
- Layout is nudged with magic offsets and comments like "Godot Label descent sits low vs A5 TEXT" — a symptom of not having chosen a font with known metrics.

### 3.9 [P6] Menu deviates from A5 framing and has dual input paths

- `scenes/main_menu.gd` hardcodes `_script_cam.fov = 60.0`, ignoring `camera.arc`. Menu framing will not match the original.
- The camera aims with `look_at` after flattening `aim.y = cam.y` — an approximation of `vec_to_angle`, not the real thing.
- `Vector3(cos(p)*cos(t), sin(t), -sin(p)*cos(t))` is a **third** independent implementation of the Acknex-forward remap, alongside `_apply_acknex_view` in the director and `gs_view_forward_godot` in `tools/gs_math.py`.
- The background uses `mainmsg.png` at `alpha 0.15`, and the code's own comment admits this is **the death/retry panel**, not a menu background.
- Both a Godot `MenuPanel` overlay and the 3D entity doors drive the same actions — two input paths, two chances to desync.
- No settings entry point exists.

### 3.10 [P7] Smaller issues, fix opportunistically within their phase

| File:line | Issue |
|---|---|
| `wmb_level_loader.gd:690–695` | `_find_glb` prefix fallback matches when either key `begins_with` the other (≥6 chars). Can silently return a **different model**. Make it exact-match, or `push_warning` on every prefix hit. |
| `autoload/level_router.gd:11–40` | `aliases` is 28 identity mappings; dead weight. It also omits Intro2–16, AsyAct*, AfterMin/AfterRac. |
| `autoload/level_router.gd:76` | `has_level_data()` uses the exact path only, unlike the loader's case-tolerant resolution. Two different answers to "does this level exist." |
| `autoload/level_router.gd:44–61` | 500 ms global cooldown papering over an unidentified double-invocation. Find the second caller (likely press+release both reaching the handler, or a signal connected twice). A wall-clock lock will eventually eat a real transition. |
| `scenes/level_runner.gd:_toggle_level_select` | Builds its list via `DirAccess` on `res://`, which CONTRACT §6 explicitly forbids inside a PCK. Use `levels.json`. |
| `scenes/level_runner.gd:_enable_first_person` | Contains `await` but is called from `_ready()` without `await`, so `snap_to_floor()` and the FP status message land out of order with the debug HUD. |
| `autoload/game_state.gd:load_slot` | No null check on `FileAccess.open()` before `f.get_as_text()`. |
| `autoload/game_state.gd` | Stray indented comment between `game_score` and `skip_intro_movies`. |
| `scenes/level_runner.gd:DEBUG_LEVELS` | Title-case, but names arrive lowercase from the F4 picker, so `find()` returns −1 and F3 always restarts at "Studio". |
| repo | 3 commits for 13k LOC + 567 MB of assets, against CONTRACT §7.7's own "commit after each verified change." |

---

## 4. Phase plan

Do the phases in order. Each has an explicit gate. **Do not start phase N+1 until phase N's gate passes.** Commit at every gate.

### Phase 0 — Stop lying to the next contributor (½ day)

1. Set the README to Godot **4.7** to match `project.godot`, or lower `config/features` — pick one and make both agree.
2. Delete `fixes/patching_3d_godot.zip`. Extract `migrate_angles.py` and `smoke_orient.gd` into `tools/` first.
3. Fold `fixes/SKILL.md`'s still-true content into `docs/CONTRACT.md`, **resolve the handedness sentence to "right-handed Z-up"**, then delete `fixes/SKILL.md`.
4. Update the README's status tables to describe the interpreter-era reality.
5. Add `.github/workflows/verify.yml` running:
   - `tools/verify_transforms.py`
   - `tools/validate_levels.py`
   - `tools/verify_corpus.py`
   - `tools/verify_wdl_parse.py`
   - **a strict-glTF check over every `.glb`** — chunk-walk each file and `json.loads` the JSON chunk. This is ~15 lines and would have caught `Shiks.glb` on the commit that introduced it. Make it a gate, not a report.
6. Add `tools/verify_normals.py`: fail if any GLB lacks a `NORMAL` attribute. It will fail on all 784 today; that is the point — it becomes Phase 2's gate.

**Gate:** CI green on a clean clone (asset checks may run against committed assets; the pipeline itself is Phase 8).

### Phase 1 — Restore game logic (highest value per hour)

This is the change that turns a tech demo back into a game.

1. **Separate camera ownership from script execution.** Restructure `wdl_director.gd:610–636` so that:
   - `_try_begin_interpreted_level()` is attempted **first**, whenever an AST exists, regardless of `fp` and `scripted_camera`.
   - Camera mode is decided **after**, from `has_first_person()` / camera entities / the interpreter's own `camera` assignments.
   - The `else` branch never leaves a level with an AST completely inert. If you reach `status.emit("Free player camera")` on a level that has an AST, that is a bug — log it loudly.
2. **Replace `HAND_PORTS_ENABLED` with a per-level set:**
   ```gdscript
   const HAND_PORTED := {"shiks": true}   # add/remove one level at a time
   ```
   This is what CONTRACT §4.1 actually asks for: level-by-level interpreter-vs-hand-port parity. An all-or-nothing const cannot express "Shiks is the parity reference." Keep every hand-port function; none were deleted and none should be.
3. **Run the Shiks parity check** CONTRACT §4.1 requires: Shiks hand-ported vs Shiks interpreted, same seed, compare observable behavior. Log the result in `docs/SESSION_LOG.md`.
4. **Playtest Plane2 first** after the restructure. It is the level that lost both paths, so it is the sharpest signal that the fix landed.

**Gate:** every playable level either runs a hand-port or starts the interpreter. Zero levels reach the inert `else`. Print a per-level table proving it. Shiks parity logged.

### Phase 2 — Lighting and material fidelity

Order matters here; (a) unblocks the rest.

1. **Recover real normals from the plane list.** Read the face record's bytes 0–3 as a plane index, read the planes list, and emit a per-face `NORMAL` attribute. Do **not** generate smooth normals and do **not** let the importer synthesize flat ones. Confirm the sign convention empirically on one level: with normals present, temporarily set `cull_mode = BACK` and render one PNG. Faces that vanish had inverted winding — this is also the first time this project will be *able* to see winding errors, which SKILL.md correctly identified as the source of its silent-error problem.
   - Do the same for MDL meshes in `convert_mdl.py`. A5 models had per-vertex normals; derive them by area-weighted averaging of face normals, with a hard angle threshold so hard edges stay hard.
   - **Once normals exist, stop shipping `doubleSided: true` by default.** Keep it only for genuine wall cards and foliage. Backface culling is a correctness tool.
2. **Fix light range and intensity.** Delete the `* 0.05` scale and the `[4, 120]` clamp in `_spawn_light()`. A5 light range is in quants; the value in the JSON is already correct in Godot units after the axis remap. Read intensity from the WMB light record rather than hardcoding `1.1`. Sanity-check against Town (`floor_y = 311`): a median range-500 light should visibly cover a room.
3. **Extract the WMB lightmaps.** This is the change that makes lighting actually look like A5.
   - Use `tools/probe_wmb_blocks.py` to identify the lightmap list empirically. Print every list's offset, length, and length-vs-face-count ratio across several WMBs. Do not assume an index number from Quake — verify it against this game's files.
   - Parse the lightmap offset out of face bytes 12–23. Following `dface_t`, expect light styles (a few bytes) plus a 32-bit offset into the lightmap block.
   - Emit lightmap UVs as **`TEXCOORD_1`** and pack the lightmap atlas as a second texture.
   - In Godot, apply it via a custom `ShaderMaterial` sampling `UV2` and multiplying into albedo, or via `BaseMaterial3D`'s AO/emission channel on UV2. Prefer the shader — it is one file and it is exact.
   - Keep the runtime `OmniLight3D` spawns for lights the WDL animates at runtime. Static lights that are already baked into the lightmap must **not** also be spawned, or everything doubles up.
4. **Re-check the material style rules.** `_force_unshaded_if_needed()` is now misnamed and does the opposite of its name. Rename it, and split its responsibilities: filtering (nearest, no mipmaps — that comment about mipmaps blurring alpha-scissor skins is correct, keep it), culling, shading mode, and lightmap wiring are four separate decisions.

**Gate:** `tools/verify_normals.py` passes on all 784 GLBs. One rendered PNG per lighting class (indoor lightmapped, outdoor sky-lit, dynamic-lit) reviewed by the user against an original screenshot. Light-range sanity table printed for Town, Studio, Shiks.

### Phase 3 — Interpreter depth

Bridge in this order. It is dependency-ordered, not frequency-ordered.

1. **VECTOR reference semantics.** Variables must be addressable by reference so `vec_set`/`vec_sub`/`vec_scale`/`vec_rotate`/`vec_to_angle` can mutate their first argument. This single change unblocks the largest cluster in §3.2, including all 104 `ang` sites.
2. **`trace`** — line of sight and collision queries. Most click, proximity, and AI-vision triggers route through it. Map to Godot's `PhysicsDirectSpaceState3D.intersect_ray`, honoring A5's trace mode flags.
3. **`DoDialog` / `show_message` / `showdialog`** — wire to the existing `GameHud` dialog UI rather than building a second one. Coordinate with Phase 5: these must read from the string table, not literals.
4. **`actor_move` / `actor_turnto` / `ent_waypoint` / `ent_nextpoint` / `scan_path`** — the path-following library. The WMB path data is already extracted; this is the consumer for it.
5. **`file_str_read` / `file_close` / `writegamedata`** — route to `GameState`, not to raw `FileAccess`. Coordinate with Phase 7's save system.

**Instrumentation to add before you start:** a per-level unbridged-builtin counter dumped on level exit. Prioritize by what the level you are testing actually calls, not by the corpus totals in §3.2 — a builtin with 104 corpus calls may be irrelevant to the level in front of you.

**Gate:** for each level you touch, zero `[wdl] unbridged:` lines in its console output, and a playtest note in `docs/PLAYTEST.md`.

### Phase 4 — Tick and timing fidelity

1. Delete the stray `* delta` on `wdl_director.gd:1167` and `:1173`.
2. **Introduce one shared Acknex tick accumulator** and move every per-tick decision into it:
   ```gdscript
   const ACKNEX_TICK := 1.0 / 16.0
   var _tick_acc := 0.0

   func _process(delta: float) -> void:
       _tick_acc += delta
       while _tick_acc >= ACKNEX_TICK:
           _tick_acc -= ACKNEX_TICK
           _acknex_tick()      # every randi() gate and per-tick decrement lives here
       _interpolate(delta)     # only smooth visual motion stays per-frame
   ```
   Audit every `randi() %` in `wdl_director.gd` and move it inside `_acknex_tick()`. `mdl_animator.gd` is already correct — do not change it.
3. Pin `physics/common/physics_ticks_per_second` in `project.godot`. Consider moving director logic to `_physics_process` so it is frame-rate independent by construction.
4. Sweep for any other `X * t * delta`. Establish `* t` as the one convention and comment it once at the top of the file.

**Gate:** a headless test running the same scripted sequence at forced 30, 60, and 144 fps produces the same state after N simulated seconds, within tolerance. This is mechanically checkable — make it a CI test.

### Phase 5 — Text rendering and localization (deviation D1)

1. **Add a real font.** Pick one with full Hebrew coverage and an open license — Noto Sans Hebrew, Rubik, Heebo, or Alef. Commit the `.ttf`, create a `FontFile` resource, and set it as the **project theme default** in `project.godot`, not per-Label. Without this step nothing in this phase is visible on an exported build.
   - Add a Latin fallback for debug and credits text.
   - Verify glyph coverage explicitly: render a string containing every Hebrew letter plus final forms, niqqud if used, and the punctuation the dialogue needs (`'`, `"`, `…`), and inspect the PNG.
2. **Move every string into a translation table.** Godot CSV translations → `.translation`. Remove `*.translation` from `.gitignore` **or** commit the CSV and generate on import — pick one and document it. Replace `_dialog_lines()`'s hardcoded `match` with `tr()` keys.
   - Extract the remaining dialogue from the original `DIalog.wdl` comments and per-level WDL. Only 4 of the dialog indices are currently populated.
   - Key scheme: `DLG_<LEVEL>_<INDEX>_<LINE>`, so a missing key is obvious in-game rather than silently blank.
3. **Fix layout properly.** With a known font you can stop nudging. Set `vertical_alignment`, use `Control` anchors, and delete the magic offsets and the "descent sits low" comments.
4. **RTL correctness.** `TEXT_DIRECTION_RTL` on the Label is not sufficient for mixed content. Use `TEXT_DIRECTION_AUTO` with `BiDi` on, and test strings that mix Hebrew with Latin names and digits — the failure mode is silently reordered text that still looks plausible.
5. **Language selection** wires to Phase 7's settings menu. Ship Hebrew as default; leave English as an empty column so translators have a target.

**Gate:** every visible string comes from the table (grep for Hebrew literals in `.gd` returns nothing). An exported build screenshot shows correct glyphs and correct RTL for a mixed Hebrew/Latin/digit string.

### Phase 6 — Menus

1. **Fidelity first.** Restore `Menu.WMB`'s original framing: pull the menu camera's `arc` and convert it with the formula in §5.4. Delete the `fov = 60.0` literal.
2. **One shared Acknex-view helper.** Collapse the three implementations (`main_menu.gd`, `_apply_acknex_view` in the director, `gs_math.py`) into a single GDScript function and a single Python function that provably agree. Add a test comparing them on a table of `(pan, tilt)` pairs.
3. **Replace `mainmsg.png`.** The code comment already identifies it as the death/retry panel. Find the correct menu background in `wdl_meta.json`'s `bmaps` map (WDL bmap name → converted PNG) — that table is exactly for this.
4. **Pick one input path.** Either the 3D entity doors drive everything (fidelity) or the Godot overlay does (accessibility, and required for mobile). Recommended: 3D doors are the visual, an invisible `Control` layer over them handles input so touch, keyboard, and gamepad all work. Do not leave two independent paths.
5. **Add the settings entry** to the menu (Phase 7) and a pause menu reachable in-level.
6. **A5 menu semantics to preserve:** New / Load / Exit / Credits as the four doors; `SNG032.WAV` menu music; the `ShowMov` panel behavior.

**Gate:** side-by-side screenshot against the original menu, same aspect ratio, reviewed by the user. All four doors reachable by mouse, key, and touch.

### Phase 7 — QOL features (deviations D2–D5)

**Settings menu.** Build it as a scene reachable from both main menu and pause.

- **Audio.** `AudioBus` currently has no Godot audio buses at all — it sets `volume_db` on players directly, and `project.godot` has no `[audio]` section and no `default_bus_layout.tres`. Create real buses: `Master → {Music, SFX, Voice}`. Route `play_sfx` / `play_music` / voice to their buses. Sliders then map to `AudioServer.set_bus_volume_db`. Without this, per-category volume is not implementable.
- **Video.** Resolution, window mode, MSAA (`project.godot` currently pins `msaa_3d=1`), texture filtering. Expose the render scale for mobile.
- **Controls.** Mouse sensitivity, invert-Y, touch layout side (left/right-handed), on-screen control opacity and size.
- **Language.** Wired to Phase 5.
- Persist to `user://settings.cfg` via `ConfigFile`. Load in an autoload **before** the first scene so the first frame is already correct.

**Save system.** `GameState` already mirrors `IO.wdl`'s flags correctly — build on it, do not replace it.

- Add a `version` field to the save dict now, before saves exist in the wild. `from_dict` is already tolerant of missing keys; make it explicitly version-aware.
- Fix the missing null check in `load_slot` (§3.10).
- Named slots plus one autosave slot. Store `current_level`, a timestamp, and a display name.
- Quicksave/quickload on F5/F9 in addition to the existing F2. Show a HUD confirmation.
- Route `writegamedata` from Phase 3 through this, so the WDL's own save calls and the QOL save are one system.

**Level select.** Replace the `DirAccess` implementation (§3.10) with `levels.json` as the index — it is already loaded and it is PCK-safe. Show human-readable names, group by chapter, and mark which are reachable in normal flow. Keep it behind a debug toggle or a settings opt-in so it does not spoil first-time play.

**Mobile / touch.** `scripts/ui/touch_controls.gd` is a reasonable start (move pad + look drag, mouse-motion synthesis for desktop testing). To finish:

- Add an **action/interact button** — currently `interact` is keyboard `E` or mouse click only, so click-driven levels (which is most of this game) are unplayable on touch.
- Handle **safe areas**. Use `DisplayServer.get_display_safe_area()` so controls clear notches and gesture bars.
- Make the pads **configurable** in size, opacity, and handedness, per the settings spec.
- **Scale hit targets to physical size**, not pixels — use `DisplayServer.screen_get_dpi()`.
- Add haptics on interact via `Input.vibrate_handheld()`.
- Test the **PCK sidecar filter**. CONTRACT §6 is right that `include_filter` must keep `*.json, *.mdlanim, *.skins`; verify on a real device, because a missing sidecar presents as an empty level, which looks like a geometry bug and will send you down the wrong path.

**Gate:** a full level playable start to finish on a physical Android device with touch only. Settings persist across relaunch. Save/load round-trips mid-level.

### Phase 8 — Asset hygiene and reproducibility

1. Regenerate `assets/converted/wmb/Shiks.glb`, or delete it and let `_find_wmb_glb` fall through to `levels/Shiks_brush.glb`. Then confirm the Phase 0 strict-glTF gate passes.
2. **De-duplicate textures.** Write brush GLBs with **external** texture URIs pointing at one shared `assets/converted/textures/`. Recovers ~23 MB, removes thousands of `.import` files, and fixes VRAM duplication in one change.
3. Move `tools/`' ~140 debug PNGs to a gitignored `tools/_scratch/`.
4. Make `_find_glb` exact-match only (§3.10).
5. **Make the pipeline real.** Add `parse_wdl.py` and `extract_wdl_meta.py` to `run_pipeline.py`. Default `extract_wmb_mesh.py` and `convert_mdl.py` to full-corpus in the pipeline path. Have the pipeline fail with a clear message naming the expected `original/` layout when the dump is absent, plus a checksum manifest so a wrong dump is detected immediately rather than producing subtly wrong assets.
6. Commit `export_presets.cfg` — CONTRACT §6 has requirements about it and it holds no secrets.
7. Now that the rights holder has approved redistribution, keep the converted assets committed. Add `.gitattributes` with LFS for `*.glb`, `*.wav`, `*.png` under `assets/converted/` to keep clone times sane.

**Gate:** a fresh clone plus the original dump reproduces the committed `assets/converted/` byte-for-byte, or with a documented and explained diff.

---

## 5. A5 semantics reference

Use these. Do not re-derive them, and do not trust a memory that contradicts them.

### 5.1 Coordinates

| Quantity | Acknex A5 (right-handed Z-up) | Godot (right-handed Y-up) |
|---|---|---|
| Position | `(x, y, z)` | `(x, z, -y)` |
| Scale | `(sx, sy, sz)` | `(sx, sz, sy)` |
| Unit | quant | same numeric value |
| Entity basis | Conitec `ang_to_matrix` (DX) | `R_g = S · R_dx · S`, `S = diag(1,1,-1)` |

Any position or mesh transform you introduce **must have determinant +1**. A det −1 map is a reflection: it mirrors geometry so front faces become back faces. Assert it.

### 5.2 Angles

- **pan** about upright Z, degrees CCW: `0` = +X, `90` = +Y, `180` = −X, `270` = −Y.
- **tilt** about the rotated Y (WED may store `345` meaning `−15`).
- **roll** about the rotated-and-tilted X.
- Composition: pan → tilt → roll.
- Forward (`vec_for_angle`): `(cos pan·cos tilt, sin pan·cos tilt, sin tilt)`.
- Entity local **+X** is forward.
- Read rotation from **`angle_gs` only**. `angle_deg` is a contaminated legacy field — two conventions were mixed in the repo's history, sometimes within one file. **Never re-negate pan**; that negation is what created the contamination.

### 5.3 Cameras

Never copy an entity euler onto a `Camera3D`. Cameras look down −Z; entities forward along +X. Use the remapped forward vector plus `look_at`.

### 5.4 FOV

`camera.arc` is **horizontal** FOV. Godot's `Camera3D.fov` is **vertical**:

```
fov_vertical = 2 · atan( tan(arc / 2) / aspect )
```

This is also how widescreen (D6) stays honest: keeping horizontal FOV fixed and deriving vertical means widescreen shows *more at the sides* rather than cropping the original 4:3 framing.

### 5.5 Time

A5 ticks at a **~16 Hz** reference. `t := delta * 16.0` converts seconds to ticks. A quantity expressed per-tick in WDL is `X * t` in Godot — **never** `X * t * delta`. Per-tick probability rolls must happen inside a tick accumulator, not per frame.

### 5.6 Origin, feet, eyes

- A WED entity position is the **model origin**, not feet.
- Feet contact ≈ `origin.z + MIN_Z`.
- `move_view_1st` eye height: `Z = player.Z + MIN_Z + (MAX_Z − MIN_Z) · 0.8` (from `movement.wdl`).
- `camera.genius = player` hides the player body in first person.
- Feet-snap is **opt-OUT**, on by default. It is off only for cameras, wall cards (`AFG`, `ShikNote`), `window`-action glass, and a measured exception list. The correct signal for exclusion is "does a WDL action assign `my.x/y/z` at runtime" or a direct AABB measurement — **not** whether the action body looks blank. `Cockpit`, `tv`, `hanger`, and `towerw` were all mis-excluded on exactly that bad signal.

### 5.7 WMB object list (list 15)

| typ | Kind | Notes |
|---|---|---|
| 1 | POSITION | |
| 2 | LIGHT | 358 across levels; range 100–500,000 quants |
| 3 | OLD ENTITY | `name20`, `file13`, `action20`, **3 pad bytes**, `skills[8]`, flags |
| 6 | PATH | points, optional edges |
| 7 | NEW ENTITY | longer names, `skills[20]`, path index, ambient |

Piposh levels are almost entirely OLD ENTITY on WMB4/5. The 3 pad bytes are easy to lose and produce plausible-but-wrong skills.

### 5.8 Flags

| Mask | Meaning |
|---|---|
| `0x1` | `INVISIBLE` — hide meshes at spawn |
| `0x400` | Passable / non-solid — skip prop collision |
| `0x40000` | Shadow/cast bit — currently ignored; revisit in Phase 2 |

Actions may toggle visibility at runtime (`PiposhHit`, `Vase1`).

### 5.9 Level mode selection

| WMB signal | Runtime mode |
|---|---|
| `player_walk*` / `player_stand` / `player_fly` | First person (`move_view_1st`) |
| `Cam` / `MyCamera` without `player_*` | Scripted camera |
| Cutscene chapters | Director or interpreter overlay |

After Phase 1, this table decides **camera mode only**. It must no longer decide whether the level's script runs.

### 5.10 A5 lighting model

This is the section to internalize before touching Phase 2.

- **Brush geometry** was lit by **baked lightmaps stored in the WMB**. Runtime lights did not light walls.
- **Entities** were lit per-vertex from `ambient`, the level's light entities, and their own `my.lightrange` / `my.ambient` skills.
- Dynamic lights existed but were the exception, used for effects.
- There was no PBR, no specular workflow, no shadow mapping.

So: lightmaps for static geometry, cheap per-vertex or per-pixel lighting for entities, dynamic `OmniLight3D` **only** where the WDL animates a light. Do not spawn a runtime light for something that is already baked.

---

## 6. Verification protocol

### 6.1 What counts as proof

| Question type | Acceptable proof |
|---|---|
| Do angles match the source? | `tools/verify_transforms.py` — JSON vs raw WMB, distance preservation |
| Is a transform proper? | `_assert_proper_rotation` — printed determinant |
| Entity → GLB coverage? | `tools/validate_levels.py` |
| Does every GLB parse? | strict-glTF CI check (Phase 0) |
| Do normals exist? | `tools/verify_normals.py` (Phase 0) |
| Does the grammar cover the corpus? | `tools/verify_wdl_parse.py` |
| Is timing frame-rate independent? | multi-fps headless state comparison (Phase 4) |
| **Does facing/lighting/framing look right?** | **A rendered PNG you inspected, or the user's description. Nothing else.** |
| Does the level play correctly? | A human playtest logged in `docs/PLAYTEST.md` |

Anything in the bottom three rows cannot be closed by a script that consumes your own pipeline's output.

### 6.2 The loop

```bash
python tools/extract_wmb_full.py --only <Level>
python tools/migrate_angles.py --only <Level>      # after Phase 0 restores this
python tools/verify_transforms.py
python tools/validate_levels.py --only <Level>
python tools/verify_corpus.py
godot --path . --headless -s res://tools/smoke_test.gd
godot --headless -s res://tools/smoke_orient.gd -- <Model>   # ONE model, then look
```

Render **one** image and actually look at it. Do not render 640 and grade them with a script.

### 6.3 Before every commit

- [ ] Reading rotation from `angle_gs`, never re-negating pan?
- [ ] Every new position/mesh transform det **+1**?
- [ ] Normals present and winding verified with culling **on**?
- [ ] Camera pose from the forward vector, not entity euler? FOV from `arc`?
- [ ] Per-tick logic inside the tick accumulator, not per frame?
- [ ] Change verified by a printed number or a rendered PNG?
- [ ] Fixed the general cause, not added another hardcoded name?
- [ ] Every visible string from the translation table?
- [ ] `docs/SESSION_LOG.md` updated with what you tried and what the result was?
- [ ] One layer changed (convert **xor** spawn **xor** director)?

### 6.4 Commit discipline

Commit at **every** gate and after every verified change. The repo currently has 3 commits for 13k LOC and 567 MB of assets, against its own CONTRACT §7.7. A large uncommitted changeset is not reviewable and is how regressions hide.

---

## 7. Do not repeat these

From `docs/SESSION_LOG.md` and my audit. Check this list before trying anything that resembles an item on it.

| Attempted | Why it failed |
|---|---|
| Skin-pixel "find the painted face, snap to +X" heuristic | Regressed previously-correct models twice. The MDL format has **no field declaring authored forward** — it is a modeling-tool convention. Retired permanently. |
| Global `pan + 180` compensation | Mirrored asymmetric models while its own self-check kept passing. |
| "Restore to a prior commit" as a repair | Proves determinism, not correctness. Crowd, Wwheel, and Bus were all still wrong after being restored to byte-identical prior states. |
| Unifying the two GLB chunk padding functions "for simplicity" | JSON chunk pads with **space `0x20`**, BIN with **NUL `0x00`**. NUL is not valid JSON whitespace; Godot tolerates it, strict parsers do not. Keep `align4_json()` separate. |
| Excluding a stem from feet-snap because its WDL action looked blank | A no-op action is not a signal. Only "does it assign `my.x/y/z` at runtime" or a direct AABB measurement is. |
| Inferring an entity's behavior from spatial proximity to another entity | Produced the `AFG_Card` bug — aliased to `ShikNote`'s click because it sits on the same wall. The real script, `WDL/Afgan.wdl`, is an unrelated 32-card collectible system. **Grep the WDL for the action name.** If nothing defines it, say so. |
| A same-frame guard for the double `goto_level()` | Did not catch it; the calls land a few frames apart. The current 500 ms cooldown is a band-aid — find the actual second caller. |
| Reproducing A5 lighting with runtime OmniLights | Wrong model. A5 baked its brush lighting. Extract the lightmaps. |
| Guessing a yaw value for `Bus` | Unrecoverable from the format or any WDL source. Needs one human-confirmed measurement. Leave the row empty. |

---

## 8. Appendix: file map

```
project.godot                      # 4 autoloads; features="4.7"; no [physics] or [audio] yet
autoload/
  game_state.gd                    # IO.wdl flag mirror + JSON slots — build on this
  level_router.gd                  # Run("X.exe") → scene change; identity alias dict; 500ms guard
  audio_bus.gd                     # NO real Godot buses yet — Phase 7 blocker
  piposh_debug.gd
scenes/
  boot.gd/.tscn                    # boot → Start or Menu
  main_menu.gd/.tscn               # 3D Menu.WMB shell; hardcoded fov=60; wrong bg asset
  level_runner.gd/.tscn            # hosts loader + director + HUD; DirAccess level select
scripts/engine/
  wmb_level_loader.gd    (748)     # entity/brush spawn; _spawn_light:630; materials:571
  wdl_director.gd       (3103)     # hand-ports + dispatch (610-636); HAND_PORTS_ENABLED:41
  wdl_interpreter.gd     (951)     # AST runtime; 32 builtins; recursive include merge (correct)
  mdl_animator.gd        (541)     # correct tick gating — reference implementation
  acknex_sky.gd          (163)     # sky_map/cloud_map panorama + scene_map horizon cylinder
scripts/game/player_controller.gd  # move_speed=140, gravity=500 in FP mode
scripts/ui/
  game_hud.gd            (500)     # dialogs/subtitles; RTL set; NO font; hardcoded Hebrew
  touch_controls.gd      (175)     # move pad + look drag; no action button; no safe area
tools/                             # converters + verify_*; ~140 debug PNGs to relocate
  extract_wmb_mesh.py   (481)      # face stride 24, bytes 0-3 and 12-23 UNREAD ← Phase 2
  convert_mdl.py       (1097)      # FIX_IDPO=True, FACE_ORIENT=False — correct, leave alone
  parse_wdl.py          (727)      # WDL → AST; not in run_pipeline.py
  gs_math.py            (102)      # canonical transforms — the one source of truth
assets/converted/
  levels/{Name}.json               # entities, angle_gs, bounds, spawn — 49 playable
  levels/{Name}_brush.glb          # brush mesh — 49
  mdl/*.glb                        # 648 models, zero normals
  wmb/*.glb                        # 136 props; Shiks.glb is stale/broken
  wdl_ast/*.json                   # 85 parsed scripts
  wdl_meta.json                    # bmaps name→PNG map (use for menu assets), sky/scene maps
  levels.json                      # level index + run/load_level flow graph
docs/CONTRACT.md                   # frozen rules — update it when this manual overrides it
docs/SESSION_LOG.md               # read before retrying anything
fixes/                             # DELETE in Phase 0 — stale and contradicts the code
```

---

## 9. If you get stuck

Ask the user a **specific** question with a specific expected answer. Not "does this look right?" but:

> "Run the game, press F4, load `Range`, and tell me whether the targets rise in about half a second or crawl up over half a minute."

Add targeted `print()` / `push_warning()` output first so the answer is a fact and not an impression. Then log the question **and the answer** in `docs/SESSION_LOG.md`, so the next session does not ask again.

If a question cannot be answered from the game's data at all — `Bus`'s facing is the standing example — say so plainly, leave the entity inert, and move on. An honest gap is cheaper than a wrong value that someone later has to discover and unwind.
