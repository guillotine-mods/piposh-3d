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

   **Correction (2026-07-31): resolved by direct in-game user confirmation
   after two wrong render-only guesses — a rendered image is necessary but
   NOT sufficient for this kind of fix; a static front/back check has a
   real blind spot a moving in-game viewpoint doesn't.** A real playtest
   report ("Yachdal isn't facing the right way, should be 90° to its
   left") led to an automated direct check using `tools/wmb_web_viewer.py`'s
   `window.__WMB_DEBUG__` hook (Playwright driving headless Chromium,
   camera positioned along a candidate forward vector, screenshot read
   back) — a rule-3-compliant *rendered image*, not a metric from the code
   being changed, so this wasn't a rule-3 violation. That check correctly
   showed `extra_yaw_deg=270` was backwards (his own local +X showed his
   back, -X showed his face dead-on) but is **only a front/back test** —
   it cannot distinguish "correct" from "off by 90° to one side" from "off
   by 90° to the other side," because all it ever compares is a single
   axis and its exact opposite. Two render-based guesses at the remaining
   90°-away candidates (90, then 180) were both reported wrong by the user
   in real gameplay before landing on the actual answer: **0**. The user
   then separately reported the *same* problem on Crowd — contradicting
   this file's own 2026-07-28/30 claims that Crowd/Crowd2 were
   independently confirmed correct at 270 (those checks had exactly the
   same front/back-only blind spot: a full, plausible-looking face **is**
   visible from +X at 270, but a *more* plausible one turned out to exist
   at 0 too, and nothing about a single static render could tell them
   apart). Crowd and Crowd2 are now also 0, confirmed in-game. **Genia is
   intentionally left at 270** — never reported as wrong, but given this
   history her earlier "confirmed correct" status should be treated as
   unverified until someone actually checks her in-game, not relied on.
   **Takeaway for any future orientation fix:** a render can rule out a
   180°-backwards mesh cheaply, but resolving a 90°-magnitude ambiguity
   needs the human's own eyes on the actual running game — don't keep
   guessing candidate values from renders once the front/back question is
   already settled.

   The bearing-consistency method that originally (2026-07-27/28) "confirmed"
   Yachdal — inferring his facing from the fact that Crowd's individually
   scattered placements loosely point at him, like an audience facing a
   screen — sounds like solid indirect evidence but was never actually a
   *rendered* check of Yachdal's own mesh; it validated a *self-consistent
   narrative* (crowd facing some landmark), not that the landmark itself
   was oriented correctly. Keep using it for ruling out "our WMB pan
   extraction is buggy," not for signing off an individual model's facing —
   that needs an actual image, every time, per rule 3.

   **Bus (reported 180° off, unresolved as of 2026-07-28):** checked
   whether the same bearing-consistency method that once seemed to confirm
   Yachdal/Crowd/Crowd2 could resolve it — it can't, and per the correction
   above, don't lean on that method alone even where it does produce an
   answer. Bus has only 3
   placements (`Menu`, `Shiks`, `golf`), each in an unrelated scene, all
   with `angle_gs` pan `== 0`, so there's no varying bearing to cross-check
   against a shared landmark the way Crowd's placements around Yachdal
   worked. `action Bus` (`Shiks.wdl`) only plays a sound and nudges `my.y`
   during one specific cutscene trigger — no directional signal either.
   This is a genuine ceiling, not an unfinished investigation: a parked
   bus's correct facing isn't recoverable from any data this format or the
   WDL source encodes. Needs one human-confirmed measurement (screenshot or
   `tools/wmb_web_viewer.py`) before it can go in the allowlist — do not
   guess a value to fill this row.
5. **GLB container: JSON chunk pads with SPACE (`0x20`), BIN chunk pads
   with NUL (`0x00`) — never the same padding byte for both.** Both
   `convert_mdl.py write_glb()` and `extract_wmb_mesh.py
   write_multi_glb()` NUL-padded the JSON chunk for a long time (a shared
   `align4()` used for both chunks). Godot's glTF importer tolerated it,
   so every model rendered fine in Godot all along — but NUL is not valid
   JSON whitespace, so any strict parser's `JSON.parse`/`json.loads`
   (browsers, `tools/wmb_web_viewer.py`'s three.js `GLTFLoader`, likely
   any non-Godot glTF consumer) throws on it and the model silently fails
   to load. Found 2026-07-27 via the standalone web viewer (see
   `docs/SESSION_LOG.md`) after models rendered as bare arrows with no
   mesh. Fixed with a separate `align4_json()`; if you touch either GLB
   writer again, keep this split — don't reunify "for simplicity."
6. **3D model skins are always fully opaque — never treat a "looks empty"
   color value as a transparency sentinel for a 3D skin (2026-07-31).**
   `_apply_quake_palette` (8-bit indexed) and `_rgb565_to_rgba` (16-bit
   RGB565 — the more common format in this corpus) both used to treat a
   specific color as "this pixel is transparent": palette index 0 (this
   game's real palette has index 0 = plain black, an ordinary grayscale
   ramp entry used for real shading, not a reserved colorkey) and a raw
   RGB565 value of exactly 0 (also plain black) respectively. Real bug,
   found via a real playtest report ("heads are transparent... I think its
   because we make dark black transparent... it should be for the 2d
   images not the 3d ones") — correctly diagnosed by the user, confirmed
   via a direct render (Yachdal's eye sockets showed background scene
   geometry straight through them). Both fixed to unconditional
   alpha=255. Left alone: `_rgba4444_to_rgba` (a real, per-pixel-authored
   alpha channel, not a sentinel-color guess) and `_palette_skin` (the
   degraded no-real-palette-data fallback, where index-0-transparent is a
   reasonable choice since there's no real color to trust at all — check
   `_game_palette()` returns non-null before assuming a model needs this
   fallback's behavior). Regenerating the corpus after either fix requires
   a plain `python tools/convert_mdl.py` (no `--only`) — this is a shared
   decode-function change, not a per-model one.

### 2b. GFX / 2D panels (`tools/convert_gfx.py`)

- **Only bitmaps used by a `panel { ... flags = ...overlay...; }` get the
  black→transparent colorkey — everything else must render opaque.**
  `color_key_black()` is a real Acknex behavior (the `overlay` panel flag),
  not a universal "black means empty" rule; applying it unconditionally to
  every GFX file made `Studio`/`Start`'s own subtitle bar (`panel pSom`/
  `panel pOvr`, no `overlay` flag) lose its solid black background,
  leaving only faint, hard-to-notice green glyphs — reported as "the HUD
  text isn't showing" even though the (colorkeyed-transparent-by-mistake)
  texture was, technically, being drawn (2026-07-31). `NON_OVERLAY_BMAPS`
  in `convert_gfx.py` is a real corpus measurement (every `panel` block
  across every original `.wdl`, checked for `overlay` in its own flags,
  resolved back to a filename) — zero filenames are used both ways, so
  it's an unambiguous split, not a per-file guess. Regenerate the list
  with `tools/gen_overlay_bmap_list.py` if the original `.wdl` corpus ever
  changes (paste its output back into `convert_gfx.py` by hand — kept as
  a reviewed literal, not auto-applied, so a re-scan can't silently change
  conversion output). Regenerating assets after a change here requires a
  plain `python tools/convert_gfx.py` (no filter) — shared conversion
  logic, not a per-file one.

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
   measured-exception stem list — see `_should_feet_snap` in
   `wmb_level_loader.gd`. Never default-snap everything off (the opposite
   regression, already hit once).

   **2026-07-28: every remaining stem re-measured, not carried over.**
   `tools/verify_corpus.py`'s feet-snap audit computes, for every excluded
   stem: the fraction of its GLB's local-Y AABB that hangs below the WED
   origin, and whether any real WDL `action` body used on its placements
   ever assigns `my.x`/`my.y`/`my.z` at runtime (grepped across every
   `original/piposh3d/**/*.wdl`, not guessed from the action's name). Run it
   to get current numbers; results as of this pass:

   | stem | below-origin | moves at runtime | verdict |
   |---|---|---|---|
   | `tv` | 55.4% | no | **removed from exclusion** — same bug shape as Cockpit (68.3%): no WDL action ever touches its position, so it needs the default floor-lift like everything else. |
   | `hanger` | 43.0% | no | **removed** — no `action Hanger` anywhere; placements sit within 0–3 units of the level `floor_y` in 3 of 4 placements. |
   | `towerw` | 32.9% | no | **removed** — no `action TowerW`; placements consistently 6–29 units of `floor_y`. |
   | `glass` | 6.6% | no | kept — mesh already sits almost exactly at its own origin (Dutyfree-shaped, not Cockpit-shaped). |
   | `dutyfree` | 0.0% | no | kept — origin already at the mesh's own bottom. |
   | `b747` | 53.2% | **yes** | kept — `action B747` (`Plane2.wdl`) assigns `my.z` directly during takeoff; a runtime-controlled vehicle, a load-time floor-lift doesn't apply. |
   | `island` | 18.8% | **yes** | kept — `action Land` (`Plane3.wdl`) assigns `my.y`/`my.z` at runtime (descends, then slides); also sits ~387 units below `floor_y` in both Plane3 and Town. |
   | `biplane`, `biplane2` | 48.7% | **yes** | kept — `action Fly` (`Intro4.wdl`) does `my.x += ..; my.z += ..`; same class as `b747`. |
   | `headphon` | 46.3% | no | kept — action-based checks (`headphone`/`A1` on this stem) already cover its placements; unresolved whether the stem-list entry is still needed on its own, low priority. |

   `Cockpit` (found 2026-07-27, GLB local Y -165.66..+76.83, 68.3% below
   origin) and now `tv`/`hanger`/`towerw` are the confirmed instances of
   this exact bug shape — a blank/no-op WDL action is *not* a valid signal
   that a stem should be excluded; only "does it move at runtime" or a
   direct AABB measurement is.
6. **Flags:** apply at spawn — `INVISIBLE` (bit0) hides meshes; `PASSABLE`-class
   bits skip prop collision.
7. **First person:** WMB `player_walk*` / `player_stand` / `player_fly` →
   `move_view_1st` (LevelRunner FP). Eye =
   `MIN_Z + 0.8*(MAX_Z−MIN_Z)`. Wins over generic Cam scripting.
8. Outdoor sky: `AcknexSky` from `wdl_meta.json`. No solid-color fake sky outdoors.
9. **Brush reconstruction verified across the full corpus** (2026-07-28): the
   edge/surfedge face-walk in `extract_wmb_mesh.py` ran against all 134 WMB
   files (WMB4 props + WMB5 levels) — 0 files returned no mesh, only 2 skip
   a single face out of 1000+ (<0.1% each). Every one of the 338 entity
   placements that reference a `.wmb` prop file has a generated `.glb` on
   disk. If a level looks empty, check GLB resolution
   (`_find_wmb_glb`/`_find_glb` in `wmb_level_loader.gd`) or the file's
   magic bytes before assuming extraction failed — it's the less likely
   explanation now.
10. **UV formula** divides the s/t texinfo dot-product by texture
    width/height — the standard Quake/GoldSrc texel-scale convention, not a
    guess. Spot-checked 2026-07-28 across Studio/Start/Shiks: Studio and
    Start land in a normal tiled-texture range; Shiks has a wider outlier
    range that's plausibly a large area with small tiled textures (normal
    for this format) but not yet visually confirmed — check via
    `tools/wmb_web_viewer.py` before assuming a bug, and derive any
    correction from real texinfo vector magnitudes, not a trial constant.
11. **Texture format:** all 984 WMB-corpus textures are `type == 40` and
    decode cleanly (verified 2026-07-28, zero hits on the RGB565/24-bit/
    32-bit fallback branches in `_load_textures`) — those branches are real
    code but dead for this game's actual asset set. A reddish `(160,80,80)`
    fill would still mean decode failure if it ever showed up.
12. **Known hardcoded special-cases live in `wmb_level_loader.gd`:**
    brush-duplicate skips (`townl`/`desertl`/…), `StudioL` nudged `+4`, wall
    cards (`shiknote`/`afg`) rebuilt as quads. Prefer fixing the general
    cause (axis map, feet-snap rule) over adding another hardcoded name —
    every hardcode is future maintenance. If you must special-case, keep it
    in one clearly-commented block noting why the general path fails for it.

## 4. WDL runtime

Prefer **data-driven** behaviour from WMB actions + `levels.json` + `wdl_meta.json`:

- `Cam` / `MyCamera` → scripted camera
- `player_walk*` → first person
- paths → walk / LookAtMe (nearest / skill-bound, not random)
- click actions / `Run("X.exe")` → `LevelRouter.goto_level`
- `scene_map` → horizon cylinder

Until 2026-07-30, hand-ported director chapters (Start/Studio/Shiks/Plane/
Plane2/Town/Range — human hand-translations of each level's real `.wdl`,
written under this project's previous approach) existed as an overlay on
this generic runtime. They were deleted outright, not left disabled: every
chapter had already been running through the generic interpreter since
2026-07-28 (`HAND_PORTED` emptied, see §4.1.1), so the hand-port functions
had been dead code for two days with zero effect on any in-game behavior —
removing ~2000 lines of them changed nothing observable, only made
`wdl_director.gd` maintainable again (3,220 → ~1,000 lines). See §4.1.3.

### 4.1. Generic WDL interpreter (2026-07-28) — for every level without a hand-ported chapter

Hand-porting each level was explicitly rejected as "hardcoded fixes per
stage" that doesn't scale — 15 "Intro" levels (Intro2–Intro16) had zero
ported behavior at all before this. The fix is a real interpreter, not more
hand-porting:

- `tools/parse_wdl.py` — lexer + recursive-descent parser, WDL source text
  → JSON AST (`assets/converted/wdl_ast/{Level}.json`). Grammar coverage is
  measured against the whole corpus (`tools/verify_wdl_parse.py`), not
  assumed — see that file's `KNOWN_SKIPS` for the handful of files with any
  residual gap (all confirmed-unused Conitec SDK template scripts, not
  `include`d by any real level; see docs/SESSION_LOG.md 2026-07-28 for how
  that was checked, not guessed). No real `switch`/`case` control flow
  exists anywhere in the corpus (every "switch" hit is a `bmap` resource
  name or prose) — confirmed before deciding not to implement it, not
  assumed absent.
- `scripts/engine/wdl_interpreter.gd` (`WdlInterpreter`) — tree-walking
  runtime. Each `action`/`main()` becomes an independent fire-and-forget
  GDScript coroutine (`await get_tree().process_frame` on
  `wait()`/`waitt()`, mirroring Acknex's own per-tick cooperative
  scheduling and this codebase's existing `_line()` await pattern).
  Builtins are bridged to already-verified engine code where one exists
  (`ent_frame`/`ent_cycle`/`Talk`/`Blink`/`morph` → `MdlAnimator`;
  `sPlay`/`vPlay`/`play_sound`/`play_entsound`/`snd_playing`/`GetPosition` →
  `AudioChannels` (Voice/SFX/Music split, see §5); `Run`/`load_level` →
  `LevelRouter`), not reimplemented. An unbridged builtin logs once
  (`[wdl] unbridged: X`) and no-ops rather than crashing or guessing —
  check the console for these before assuming a level "doesn't work",
  since it names the exact missing piece.
- Entry point: `wdl_director.gd::_try_begin_interpreted_level()`, tried in
  `setup()` for every level with a parsed AST (unconditionally — there is no
  more hand-port opt-out since 2026-07-30, see §4.1.3), regardless of
  `fp`/`scripted_camera`. Camera ownership (who LevelRunner points the
  active camera at) is decided independently, after this call — see the
  2026-07-29 fix note in §4.1.1.
- **Verification rule for this mechanism specifically**: because an
  interpreter bug can affect every level driven through it at once (unlike
  a single hand-ported level bug), don't trust it on new, never-verified
  content without also checking it reproduces a level that's *already*
  confirmed correct by a human (e.g. replay Shiks's real `.wdl` through the
  interpreter and compare against the existing hand-ported behavior) before
  extending its builtin coverage further — same "external ground truth,
  not a self-referential check" standard as rule 3 in §2.
- **Known gaps, not silently faked**: `VECTOR`/`ANGLE`-typed by-reference
  scratch globals (2026-07-30) now have real support — `WdlInterpreter._vectors`
  (a `String -> Vector3` dict) backs bare scratch identifiers (`temp`,
  `my_angle`, ...), and `_vec_get()`/`_vec_put()` resolve a RAW (unevaluated)
  AST argument node to a by-reference read/write target for `vec_set`/
  `vec_sub`/`vec_to_angle`, which are real implementations now, not no-op
  stubs. `_get_field`/`_set_field` fall back to the same `_vectors` storage
  for ordinary field-assignment syntax on an unresolved bare identifier
  (`temp.x = ...;`), not just inside those three builtins — this fallback
  MUST stay *before* the "target doesn't resolve to a real entity" early
  return in both functions, not after it (an earlier version put the
  generic-custom-field fallback after the early return, making it
  unreachable for exactly this shape — see docs/SESSION_LOG.md 2026-07-30,
  "characters facing wrong"). `scan_path`/`ent_nextpoint` (2026-07-30) bind
  an entity to the nearest point on the nearest path in the level (from
  `_loader.last_level_data`) and write its GS coordinates into
  `_TARGET_X`/`_TARGET_Y`/`_TARGET_Z` for real — not just a truthy stub
  that avoids false-gating unrelated logic (the original 2026-07-30-earlier
  fix), an entity genuinely walks its bound path now. Still open, not
  built: `ent_waypoint` stays a no-op (redundant with what `scan_path`
  already sets up at every real call site checked so far). This port
  still has no verified A5 bit mapping for `my.flag1`..`my.flag8` (only
  bit0=INVISIBLE and bit10=PASSABLE are confirmed, in
  `wmb_level_loader.gd`) — don't guess a general bitfield position without
  a human-confirmed measurement, since a wrong guess would apply
  corpus-wide to every level's own independent use of flag1-8, not just
  one. **`action LookAtMe` specifically is an exception (2026-07-30,
  user-approved after the bit-mapping dead end)**: `WdlInterpreter._seed_look_at_me_flag1()`
  seeds `flag1` for entities whose action is exactly `LookAtMe`, inferred
  from comparing the entity's own authored pan against 270° (the literal
  value `LookAtMe`'s `flag1==on` branch hardcodes into `camera.pan`) — a
  textual coincidence too specific to be accidental, verified live via
  `tools/smoke_start_diag.gd` (Start's two `LookAtMe` placements now
  correctly hand off camera control between Scene 0/2 and Scene 1/3/5).
  Explicitly scoped to this one action name, not a general flags-bit
  reader — do not extend this specific heuristic to other actions' flag1
  usage without the same kind of concrete, per-action textual evidence.
  `ShowDialog` (2026-07-30) IS bridged now — see the `DoDialog`/dialog-
  choice entry a few bullets down — but only the panel/click mechanism is
  generic; the actual choice *text* per level is not extracted anywhere
  (Acknex renders it as pre-baked bitmap graphics, not string data in the
  `.wdl` source) — `GameHud._dialog_lines()` only has real hand-typed text
  for the 4 indices the original hand-port authors transcribed
  (Studio/Plane); every other level's dialogue shows the real, clickable
  panel but with "…" placeholder text. Extracting real text for the rest
  would need OCR/manual transcription from the original bitmap assets, not
  something the parser can derive. Extend `_register_builtins()` in
  `wdl_interpreter.gd` as real playtests surface what's actually needed —
  don't pre-build the long tail blind.
- **`Run("X.exe")` (2026-07-30) is bridged the same way, and it's the
  highest-impact one of the four shared-function-shadowing bugs found
  tonight — see docs/SESSION_LOG.md for the full trace.** `WDL/IO.wdl`
  (included by nearly every level) declares its own real
  `function Run(filename) { file_open_write("Run.txt"); ...; exit; }` —
  the ORIGINAL game's real level-transition mechanism (each "level" was a
  separate .exe; a wrapper launcher process watched `Run.txt` to know what
  to start next; the current .exe's own `exit;` terminated it). None of
  that applies to a single-process Godot port, and `exit;` isn't even a
  statement this interpreter recognizes — so the shadowed real `Run()`
  silently did nothing at all: never transitioned levels, never stopped
  anything. `run` is now in `BRIDGE_OVER_SHARED_FUNCTIONS`; this
  interpreter's own `_do_run()` calls `LevelRouter.goto_level()` **and**
  sets `_running = false` synchronously (matching real Acknex's `Run()`
  halting the current level immediately, not whenever the actual Godot
  scene swap eventually lands a few frames later — without this, other
  still-suspended coroutines on the old level keep running in that gap).
  **Any new symptom that looks like "a script called the right thing but
  nothing happened" is worth checking against this exact pattern first**
  (`grep -rn "^function NAME" original/piposh3d`) before assuming the
  builtin itself is broken.
- **`GetPosition(Voice)`'s "finished" reading is debounced per (caller,
  voice generation), NOT per frame — see `_do_get_voice_position(my)` and
  `AudioChannels._voice_generation`.** Two corpus-wide WDL idioms share
  this one value and need different things from it: a blocking
  `while (GetPosition(Voice) < 1000000) { wait(1); }` wait for one
  specific line, and a one-shot `if (GetPosition(Voice) >= 1000000) {
  Scene = Scene + 1; ...}` poll inside a perpetual loop that must fire at
  most once per real completion (2026-07-30, Start: two `LookAtMe`
  entities both consumed the same completion in the same frame and both
  incremented `Scene`). A first fix (2026-07-30) debounced globally by
  frame — "only the first caller each frame wins" — which quietly broke
  the moment a THIRD caller polls unconditionally every single frame
  (2026-07-31, Studio: `Naknik`'s own always-running poll permanently
  starved `ShikNote`'s click-triggered `ShikKlik` coroutine, since Godot
  always resumed Naknik first, so `ShikKlik`'s own wait loop never once
  saw "finished" — `Talking` stuck, `Run("Shiks.exe")` never fired).
  Current design: each caller (keyed by the `my` that called
  `GetPosition(Voice)`) tracks the last voice generation *it personally*
  has seen as finished — a late-starting caller always gets its own
  guaranteed first look at the current completion regardless of poll
  order, while a caller that keeps polling after already consuming a
  generation still only sees "finished" once per real completion. Verified
  both directions still hold: `tools/smoke_studio_shikklik.gd` (Studio no
  longer starves) and `tools/smoke_start_diag2.gd` (Start still reaches
  `Scene==6.0` and halts). See `docs/SESSION_LOG.md` 2026-07-31 for the
  full trace — don't re-debounce this globally again.
- **A generic unresolved-builtin fallback can silently gate unrelated
  logic, not just the feature it's actually missing (2026-07-30) — check
  what a "harmless" 0.0/no-op fallback is fed into before assuming it's
  safe.** Found via a real playtest report (Start/Studio/Plane/Shiks all
  "stuck"): `scan_path()`'s 0.0 fallback fed into a corpus-wide
  `result = scan_path(...); if (result==0) { my._MOVEMODE = 0; }` idiom
  (22 files), and the SAME `while (my._MOVEMODE > 0) { ... }` loop the
  original scripts gate with that flag also contains completely unrelated
  per-tick logic (dialogue-scene advancement, `GetPosition(Voice)`
  polling) — so an "acceptable, documented" pathing gap silently broke
  dialogue too. Compounding cause: `WdlInterpreter._get_field`/`_set_field`
  only supported a small fixed field allowlist
  (x/y/z/pan/tilt/roll/skin/invisible/passable/event/enable_click/skillN);
  any other custom field name (`_movemode`, `_target_x`, ...) was a silent
  no-op on write and always read 0.0, so even fixing `scan_path`'s return
  value alone wasn't sufficient. Both fixed: `scan_path` returns `1.0`;
  `_get_field`/`_set_field` gained a generic `node.get_meta("wdl_custom_"
  + name, ...)` fallback so any unrecognized field name just works, not
  only the specific ones hit so far. Same lesson applies to
  `actor_move()`/`actor_turnto()` (see §5's `BRIDGE_OVER_SHARED_FUNCTIONS`
  entry) and `WdlInterpreter._last_result`/the `result` global (Acknex's
  implicit last-call-return value, read via `X = result;` — a real,
  general mechanism, not sound-specific, now bridged via `_call()` storing
  every builtin/function return into `_last_result`, read through a
  `"result"` case in `_get_var()`).
- **`my.enable_click = on; my.event = X;` is a real, generic mechanism
  (2026-07-30), not a per-level hand-port.** This is the standard WDL idiom
  for making any entity clickable at runtime (`WdlInterpreter._set_field`
  handles both fields: `event` stores the target action/function name as
  `node.set_meta("wdl_event", ...)`, `enable_click` ensures a pickable
  `Area3D` exists). `_assign()` special-cases a bare identifier on the RHS
  of `.event =` (e.g. `HP` in `my.event = HP;`) as the literal action name,
  not a variable read — reading it as a variable was the actual bug: `HP`
  isn't declared anywhere, so it silently evaluated to `0.0`, and
  `enable_click`/`event` weren't handled by `_set_field` at all, so this
  entire idiom was a complete no-op game-wide. `WdlDirector._handle_click_action()`
  checks the clicked node for `wdl_event` meta *before* any of its
  hardcoded per-level action-string branches and, if present, calls
  `WdlInterpreter.invoke_event()` — which runs the named action/function as
  a fresh fire-and-forget coroutine, the same way `begin_level()` starts
  each entity's own initial action. Applies to every interpreted level with
  no per-level wiring needed.
- **`my.enable_impact/enable_push/enable_entity = on; my.event = X;` — the
  walk-into-it counterpart to `enable_click` — needs TWO mechanisms, not
  one, and got the second one wrong on the first attempt (2026-07-31, then
  corrected 2026-08-01).** 22 files use this idiom (Shiks' `action Bumpin`
  is the confirmed case). Real "walk into it" collisions come from two
  structurally different movers in this port: the real player
  (`player_controller.gd`'s `CharacterBody3D`, a genuine physics body —
  `Area3D.body_entered` correctly detects it) and every OTHER entity
  (`WmbLevelLoader._spawn_entity()` spawns everything as a plain `Node3D`,
  repositioned by `actor_move()` writing `global_position` directly — no
  physics-engine awareness at all, so `body_entered` can NEVER fire for
  an NPC walking into something). The first fix only implemented the
  Area3D half and verified it by calling the event handler directly
  (`tools/smoke_shiks_bumpin.gd`) — proved the *dispatch* worked, never
  that real NPC movement would ever reach it, which it didn't (Shiks'
  own `action Piposh2` walking into `action Bumpin`'s `Snail` is exactly
  this case). Fixed with a second, complementary mechanism:
  `WdlInterpreter._impact_zones` + `_check_impact_proximity()`, a plain
  per-frame distance check (called from the existing `_process()`)
  against every other live entity, edge-triggered via `_impact_touching`
  to match `body_entered`'s once-per-approach semantics, not a per-frame
  poll. **Do not reuse `_clickable_center_offset()` (the AABB-centering
  from the `enable_click`/poster-position fix) for impact zones** — that
  centering is correct for raycasting a *visible* mesh, but this is a
  position-to-position proximity check; Shiks' own `Snail` mesh is
  424x344x89 units, so its AABB center sits ~100 units from the entity's
  actual origin, which silently moved the whole trigger zone into empty
  space when first tried. Impact zones use plain origin. Verified end to
  end (not a shortcut) with `tools/smoke_shiks_bumpin_proximity.gd`:
  physically walks an entity's `global_position` toward the target over
  real frames, same as `actor_move()` does, and confirms the mechanism
  fires on its own.
  **Still not enough for a real walk (2026-08-01, third pass):**
  `_check_impact_proximity()`'s original full-3D-sphere distance check
  can never fire for a mover whose Y never changes if the target sits on
  genuinely different ground — and this port's non-player movers never
  floor-snap (`_do_actor_move()` is a straight-line X/Z translation, no
  raycast against level geometry, unlike the original engine's
  `actor_move()`). Confirmed live: Shiks' `Piposh2` spawns and walks flat
  at Y=8 while `Bumpin` sits at Y=-69 (its neighbor `StandHere`, Y=-73,
  confirms that room really is ~80 units lower, not bad data) — closest
  possible 3D approach along the flat path is ~80 units, outside even a
  28-unit sphere, forever. Fixed by comparing horizontal (XZ) distance
  only in `_check_impact_proximity()` for the NPC-vs-entity path — the
  real player's `Area3D`/`body_entered` path is untouched (a genuine
  `CharacterBody3D` floor-snaps correctly already). This sidesteps the
  missing-floor-snap gap for the one mechanism it broke; it does not fix
  floor-snapping generally (a larger, riskier change touching every
  `actor_move()` call site, not justified by this one report — see
  docs/SESSION_LOG.md 2026-08-01 fourth entry). Verified with the same
  `smoke_shiks_bumpin_proximity.gd` (unchanged, still passes — it places
  entities at matching Y by construction) plus a new
  `tools/smoke_shiks_walk_to_bumpin_real.gd`, which drives the actual
  reported flow (repeated dialogue-choice selection, not manual position
  manipulation) and confirms `Piposh.skill2` really reaches 2.
- **`ShowDialog()`/`DialogChoice` dialogue-choice UI (2026-07-30) is a
  real, generic mechanism, not a per-level hand-port.** Every dialogue
  choice in the game follows the same shape: `DoDialog(num) {
  DialogChoice=0; DialogIndex=num; ShowDialog(); Talking=0; }`, then the
  same coroutine's own already-written per-tick loop
  (`while (DialogIndex==X) { if (DialogChoice==1) {...} ... wait(1); }`)
  polls for the response. `WdlInterpreter`'s `"showdialog"` builtin
  (force-bridged over the real, unbridgeable `WDL/DIalog.wdl` function —
  see §4.1's "known gaps" entry) calls `GameHud.show_dialog(DialogIndex)`;
  `GameHud.dialog_choice` is connected (in `WdlInterpreter.setup()`, which
  now takes an optional `hud: GameHud` param) to set the `DialogChoice`
  global directly. No per-level wiring needed — same "applies to all
  levels at once" shape as `enable_click`/`event` above. GameHud's panel/
  button/click UI itself is fully generic; only the *text* shown per
  `DialogIndex` is level-specific and mostly unextracted (see the known-
  gaps entry above).

### 4.1.1. Camera ownership and script execution are independent (2026-07-29)

`wdl_director.gd::setup()` used to gate `_try_begin_interpreted_level()`
behind `elif fp:` and `scripted_camera`, so a level either had a camera
entity or it ran zero WDL — the two questions "who does LevelRunner point
the camera at" and "does this level's script run" were conflated. Fixed:

- The interpreter is now tried for every level with a parsed AST regardless
  of `fp`/`scripted_camera`. Camera/click wiring for `fp` levels happens
  *after*, unconditionally on top of whatever the interpreter did.
- (2026-07-30: the `HAND_PORTED` opt-out dict and the hand-port chapter
  functions it gated no longer exist at all — see §4.1.3. This bullet's
  history is kept for context; there is nothing left to opt back into.)
- `setup()`'s final `else` branch (`status.emit("Free player camera")`)
  `push_warning()`s by name if a level with a parsed AST still reaches it —
  that combination means dispatch itself is broken again, not that the
  level has no script.
- Verify with `godot --headless --path . -s res://tools/smoke_dispatch.gd`
  (instantiates `WmbLevelLoader`+`WdlDirector` per level, real dispatch
  outcome, not a code read) before trusting a dispatch-chain change here.

### 4.1.2. Action names are not consistently cased in the corpus; `my`/`entity` parameters in the interpreter must stay untyped (2026-07-30)

Two related, corpus-wide correctness bugs found by actually clicking every
`enable_click` entity in every level that has one (`tools/smoke_click_survey.gd`,
16 levels, 307 entities — built because a single hand-picked entity, as
`tools/smoke_click_event.gd` alone checks, can't surface a bug that only
some *other* level's naming happens to trigger):

- **`_actions` needs a case-insensitive fallback, same as `_functions`.**
  The WDL corpus itself is not consistently cased between an action's
  declaration and its use as a bare-identifier reference: Olympic.wdl
  declares `action GiveNut` but every placement's `my.event = givenut;`
  uses lowercase; Dutyfree's `Talktome`/`talktome` is the same shape. Not
  isolated typos — confirmed across multiple files by the survey. Fixed
  with `_actions_lower` (mirroring the existing `_functions_lower`) and a
  single `_resolve_action(name)` helper used everywhere an action name is
  looked up by string: `begin_level()`'s entity dispatch, `invoke_event()`,
  and the `create()` builtin's 3rd-arg spawn action.

- **Every `my`/`entity` parameter in `wdl_interpreter.gd` must stay
  untyped (`Variant`, not `Node3D`) — this is load-bearing, not style.**
  Root cause, reproduced in isolation with `tools/smoke_remove_race.gd`:
  the standard WDL shape `action X { while(1){ if(cond){remove(my);}
  wait(1); } }` plus a *second*, click-triggered coroutine that also
  removes the same entity (e.g. `WDL/Afgan.wdl`'s `AFG_Card` — which
  checks `AFG[my.skill1]` — and `AFG_Take`, its `my.event` target, which
  sets that same flag right before its own `remove(my)`) means `remove()`
  can be called *twice* on one entity within a single synchronous
  signal-dispatch window, once from each coroutine. At that reentrant
  instant `is_instance_valid()` and `is_inside_tree()` on the entity both
  still read `true`, and even `my == null` is unreliable (observed
  returning `true` for a definitely-non-null, definitely-freed reference)
  — yet simply passing that same reference into a `Node3D`-typed parameter
  (as `_eval()` and ~20 other functions here used to require) crashed the
  engine outright: `SCRIPT ERROR: Invalid type in ... previously freed
  instance, not a subclass of the expected argument class`, a hard SIGSEGV
  before the fix, not a recoverable error. Deferring the `queue_free()`
  call, deferring which signal the click-triggered coroutine starts on,
  and switching signals entirely were all tried first and confirmed
  insufficient (see `docs/SESSION_LOG.md` 2026-07-30 for the full
  elimination sequence) — the crash is at the GDScript argument-passing
  boundary itself, not a timing window a script-level check can close.
  The fix has three parts, all required together:
  1. Untype every `my: Node3D` / `entity: Node3D` parameter in
     `wdl_interpreter.gd` to plain `my` / `entity` (and any `-> Node3D`
     return that could hand one back, e.g. `_resolve_entity`,
     `_resolve_arg_entity`) — GDScript's strict argument/return type
     validation is what actually throws, not the object state itself.
  2. `_do_remove()` is idempotent: it no-ops (does not call `queue_free()`
     again) if `wdl_removed` meta is already set on the target, closing
     off the double-removal path directly.
  3. `_entity_alive(my)` — the guard used at the top of `exec_stmt`, both
     `while` loops (async and sync), and `invoke_event()` — checks
     `typeof(my) == TYPE_NIL`, never `my == null`, before checking
     `is_instance_valid(my)` and the `wdl_removed` meta flag.
  Any new function added to this file that takes an entity reference
  (`my`, `entity`, `target`, ...) that might outlive a `remove()` call
  elsewhere must follow the same pattern. `tools/smoke_remove_race.gd`
  is the fast, isolated regression test for this specific shape; run it
  after touching `_eval`, `exec_stmt`, `exec_block`, or `_do_remove`.

### 4.1.3. Runtime/game-logic rewrite (2026-07-30) — hand-port deletion, camera authority, audio channels

Triggered by direct user feedback that individual bug fixes were "patches on
a shaky foundation" — `wdl_director.gd` had grown to 3,220 lines, most of it
the seven dead hand-port chapters (§4.1) plus ~40 instance fields that
existed only to feed them. Scope, confirmed with the user before starting:
runtime/game-logic layer only (the asset conversion pipeline — §1-§3 above —
was not touched and is not where these bugs lived); keep the native
`CharacterBody3D` FP controller as-is; delete the dead hand-port code
entirely rather than leave it disabled (git history preserves it if ever
needed).

- **`wdl_director.gd` rewritten 3,220 → ~1,000 lines.** Deleted: all seven
  `_begin_X()`/`_update_X()`/`_apply_X_cam()`/`_run_X_choice()` hand-port
  chapters, the `HAND_PORTED` dict/`_is_hand_ported()`, and every instance
  field that existed only to feed them. Kept, unchanged in behavior: generic
  dispatch (`_try_begin_interpreted_level`/`_begin_generic_level`), click
  wiring/resolution, camera-class entity discovery (unified into one
  `CAMERA_ACTIONS` match instead of a dozen single-purpose fields), patrol
  movement, random-building variation, `_copy_cam`/`_apply_acknex_view`/
  `_acknex_entity_basis_local` and the rest of the transform-correct camera
  utilities, and the `MdlAnimator` wrapper functions.
- **New `scripts/engine/camera_authority.gd` (`CameraAuthority`)**
  formalizes the 2026-07-30 camera-authority fix (§4.1.1's "most recent
  write wins" model) into one explicit `PLAYER_FP`/`SCRIPT` state object
  instead of loose fields split across `LevelRunner` and `WdlInterpreter`.
  `LevelRunner._process()` now just calls `_camera_authority.update()`.
- **New `autoload/audio_channels.gd` (`AudioChannels`) replaces
  `autoload/audio_bus.gd` (`AudioBus`).** The old bus gave *every* sound —
  dialogue and incidental SFX alike — one shared `AudioStreamPlayer` and one
  shared busy/finished flag pair (the root architectural cause of §5's
  "audio from talks is not being played" bug family). Split into three
  independent channels: **Voice** (dedicated player, only touched by
  `sPlay`/`vPlay`/`GetPosition(Voice)`), **SFX** (small round-robin player
  pool, `play_sound`/`play_entsound`, never touches Voice state), **Music**
  (unchanged). See §5.
- **Found and fixed while wiring the channel split: `sPlay`/`vPlay` were
  being shadowed by Voice.wdl's own real WDL-source functions.** User
  functions take priority over builtins in `_call()` (correct in general —
  a level's own helper functions should be able to override), but Voice.wdl
  (pulled in via nearly every level's include chain) declares its own
  `function sPlay/vPlay(...)` that drives Acknex's real MP3 DLL layer
  (`dll_open`/`InitMp3Adv`/`LoadSongSlot`/`PlaySong`/...) — infrastructure
  this port can never bridge, so calling it is a silent no-op that never
  actually starts anything on the Voice channel. Result: `GetPosition(Voice)`
  reports "already finished" from the very first check, and a whole
  multi-line dialogue action races to completion in one synchronous frame.
  This bug pre-dated tonight — it was invisibly *masked* under the old
  single-channel `AudioBus`, where an unrelated ambiance sound
  (`play_entsound`) happened to keep the *shared* busy-flag pinned "playing"
  for unrelated reasons, accidentally making `GetPosition(Voice)` look
  correct. Splitting the channels correctly removed that cross-contamination,
  which is what surfaced the real bug. Fixed with
  `BRIDGE_OVER_SHARED_FUNCTIONS` in `wdl_interpreter.gd::_call()`: a fixed
  set of names (`splay`, `vplay`, `play_sound`, `play_entsound`,
  `stop_sound`, `snd_playing`, `getposition`, `actor_move`) always resolve
  to this interpreter's own bridge, never to a same-named WDL-source
  function. **Do not add `setvoice`/`voiceinit` to this list** — an
  earlier version of it did, by name-similarity reasoning instead of
  checking the corpus, and that broke 22 levels' real per-level `SetVoice`
  dialogue-boot sequencers; see §4.1's "generic unresolved-builtin
  fallback" entry and docs/SESSION_LOG.md 2026-07-30 for the full story.
  Only add a name here after confirming via corpus grep
  (`^function NAME`) that every real declaration of it is a genuinely
  unbridgeable shared-library primitive (Voice.wdl's MP3 layer,
  actors.wdl's physics), never a per-level override.
- **`Dialog` (the WDL choice-panel PANEL object) is special-cased in
  `_resolve_entity()`/`_get_field()`/`_set_field()`, the same pattern as
  `camera` — not a step toward generic PANEL support (still a known gap,
  see §4.1).** Reading `Dialog.visible` bridges to `_hud.is_dialog_open()`;
  writing `Dialog.visible = off` bridges to `_hud.hide_dialog()` (the only
  write ever seen corpus-wide — `= on` occurs exactly once, inside the
  real `ShowDialog()`, already force-bridged, so it never reaches this
  code path). Before this (2026-07-31), `Dialog` was a genuinely
  unresolved identifier — safe on its own (`_get_field`'s null-entity
  fallback returns 0.0) but corpus-wide `while (Dialog.visible == on) {
  ...; wait(1); }` gates (meant to block re-showing a prompt until the
  current click is processed) never blocked anything, so `ShowDialog()`
  re-ran every frame, resetting `DialogChoice` to 0 before the script's
  own `if (DialogChoice == N)` checks could see a real click. Found via a
  real report on Shiks ("after choosing, the talk isn't starting") that
  turned out to also be the root cause of a second, seemingly unrelated
  symptom ("camera moves through the window... doesn't happen") — both
  are gated by the exact same `while (Dialog.visible == on)` statement in
  `action Piposh2`, just at different `DialogIndex`/`DialogChoice` values
  reached later in the same state machine. Verified with
  `tools/smoke_shiks_dialog_choice.gd` and
  `tools/smoke_shiks_dialog2_choice.gd`, both simulating a real click via
  `GameHud.hide_dialog()` + the `dialog_choice` signal (matching what
  `_emit_choice()` actually does — emitting the signal alone without
  calling `hide_dialog()` first gives a false FAIL).
- **Found and fixed while auditing what was safe to delete: the AFG card
  collectible's HUD feedback and save persistence had gone silently dead.**
  `WdlDirector._handle_click_action()`'s generic `wdl_event` dispatch
  (added earlier the same day, §4.1) checks the clicked entity for
  `wdl_event` meta *before* every hardcoded action-string branch — correct
  for nearly everything, but it meant an AFG card's own `my.event =
  AFG_Take;` (set by its interpreter-run action) routed through
  `WdlInterpreter.invoke_event()` instead of the legacy `_run_afg_take()`
  branch below it, which never ran again. The interpreter's own execution
  of `action AFG_Take` only mutates its ephemeral, per-level `AFG[]` global
  (lost on level change, never saved) and silently no-ops on
  `AFG_Show.skin/tilt/visible/alpha` (an unbridged PANEL reference) — so
  pickup stopped persisting to `GameState.afg`/`GameState.save_slot()` and
  the collected-card HUD popup stopped showing, in every level with an AFG
  card, not just the one originally reported on. Fixed by special-casing
  `node.has_meta("afg_card_index")` at the very top of
  `_handle_click_action()`, ahead of the generic `wdl_event` check —
  confirmed against `original/piposh3d/WDL/Afgan.wdl`'s real `AFG_Take`
  action that `_run_afg_take()`/`_show_afg_card()` are a faithful port of
  its actual side effects (`AFG[skill1]=1; WriteGameData(0);
  AFG_Show.skin/tilt/visible/alpha; remove(my);`), not a guess.
- **Verification**: `tools/smoke_dispatch.gd`, `tools/smoke_click_survey.gd`
  (16 levels / 307 entities, including every level's own AFG cards, not
  just Plane2's), `tools/smoke_click_event.gd`, `tools/smoke_event_unit.gd`,
  `tools/smoke_remove_race.gd`, `tools/smoke_plane2_playtest.gd`, and
  `powershell -File tools/check_all.ps1` all pass against the rewritten
  files.
- **Known gaps this rewrite did not attempt to close** (pre-existing, not
  regressions from deleting hand-port code — see the reasoning above for
  why each was already inert): Range's shooting-gallery minigame has no
  mouse-click→fire bridge into the interpreter (Range.wdl's real input
  model isn't yet known to use the same `enable_click` idiom as everything
  else); GameHud's dialogue-choice/subtitle/range-HUD UI
  (`show_dialog`/`setup_*_subtitles`/`set_range_hud`/...) has no caller left
  at all, since every call site lived in the deleted hand-port chapters —
  it was already effectively dead once `HAND_PORTED` was emptied
  2026-07-28, this rewrite just makes that permanent instead of latent.

## 5. Talk / audio

- Mouth / Talk skins only while voice is playing (or an explicit WDL phase).
- SFX live under `assets/converted/sfx/` and **are committed** to git.
- **`sound NAME = <FILE.WAV>;` declarations must resolve through
  `WdlInterpreter._get_var()` (fixed 2026-07-30) — this is not optional
  plumbing.** They're parsed into `_sounds`/`_sounds_lower`, but nothing
  read them there for a while, so referencing a declared sound name (e.g.
  `play_entsound(my, cockpit, 300)` in an ambiance loop) silently evaluated
  to `0.0` instead of the WAV filename.
- **`autoload/audio_channels.gd` (`AudioChannels`) replaced
  `autoload/audio_bus.gd` (`AudioBus`) on 2026-07-30 — see §4.1.3.** The old
  bus gave *every* sound (dialogue and incidental SFX alike) one shared
  `AudioStreamPlayer` and one shared busy/finished flag pair, not scoped
  per-line: a broken/unrelated ambiance call failing *while a real dialogue
  line was actively playing* force-cleared that shared "finished" flag, so
  `GetPosition(Voice)` reported the *dialogue* line done within one tick
  regardless of its real duration — confirmed via a real playtest report
  ("audio from talks is not being played"), even though the ambiance call
  itself worked correctly every time it ran. Fixed architecturally, not
  patched: `AudioChannels` gives Voice (`sPlay`/`vPlay`/`GetPosition`), SFX
  (`play_sound`/`play_entsound`, round-robin pool), and Music independent
  state, so an unrelated sound can no longer touch Voice's busy/finished
  flags at all. **Any new sound-related builtin must pick the correct
  channel explicitly** (Voice only for dialogue lines that `GetPosition`
  needs to gate on; everything else is SFX) — do not add a fourth shared
  flag pair "for convenience."
- **This port's own `sPlay`/`vPlay`/etc. builtins must win over a
  same-named WDL-source function (fixed 2026-07-30, see §4.1.3).** Voice.wdl
  (in nearly every level's include chain) declares its own real
  `function sPlay/vPlay(...)` backed by Acknex's MP3 DLL layer, which this
  port can never bridge — letting it shadow the working builtin (the normal
  "user functions beat builtins" rule) makes dialogue audio a silent no-op.
  `wdl_interpreter.gd`'s `BRIDGE_OVER_SHARED_FUNCTIONS` list is the fix;
  any other builtin found to have this exact shape (a real Voice.wdl/
  IO.wdl-side implementation that can never actually work in this port,
  confirmed via corpus grep to never be a per-level override) belongs in that
  same list, not a one-off special case.
- `tools/smoke_audio_timing_check.gd` confirms headless Godot genuinely
  advances `AudioStreamPlayer` playback progress over real time (no audio
  device needed for the *timing* to be real) — use it to re-check this
  class of bug rather than assuming headless audio can't be trusted at all.

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
   not confirm them (see `rewrite_skill/PORTING_MANUAL.md`'s R1/R2/R3 rules).
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
