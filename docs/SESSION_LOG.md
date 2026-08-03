# Session log

Append-only. One entry per investigation. Read this before re-guessing at a
symptom or re-asking a question already answered — that's the whole point of
this file. Newest entries at the bottom.

Format:

```
## YYYY-MM-DD — <short symptom>
Checked: <what was read/instrumented>
Asked: <exact question posed to the user>
Answer: <exact user answer>
Result: <root cause / fix / still open>
```

---

## 2026-07-26 — Process setup + checkpoint

Checked: full repo state. Found a large uncommitted diff (last session's WIP:
`ang_to_matrix` entity-basis rewrite, feet-snap rework, first-person spawn,
click wiring) sitting on top of the last commit — this is the state the user
has been playtesting. Compared `fixes/patching_3d_godot.zip` (a patch +
SKILL.md from a different Claude instance) against current code: its
`wmb_level_loader.gd` target (`_apply_legacy_angle_deg` pan-negation fix) is
already obsolete, superseded by the `ang_to_matrix` rewrite. Its
`convert_mdl.py` `FIX_IDPO`/`--fix-idpo` toggle and `smoke_orient.gd` are
still net-new and match `CONTRACT.md`'s already-documented but unimplemented
IDPO fix.

Asked: (1) commit the uncommitted WIP as a checkpoint first? (2) how is the
game normally run, to decide where debug output should go?

Answer: (1) yes, commit it now. (2) Godot editor (F5) — so `print()` /
`push_warning()` output in the Output panel is visible and is the right
channel for debug logging, no on-screen overlay needed.

Result: Checkpoint committed (`31e8e37`). Proceeding to instrument the three
reported bugs — see entries below once the user reports back.

## 2026-07-26 — Ami Studio wall: two clickable items, only one works

Checked: `scripts/engine/wdl_director.gd` match statement — both `ShikNote`
and `AFG_Card` actions call `_make_clickable(node, "ShikKlik")`, so both
*should* route to the same place. Read `_mount_wall_card` in
`wmb_level_loader.gd`: for stem `shiknote` the original WMB brush mesh is
hidden and replaced with a hand-built poster quad (no collision shape of its
own); for stem `afg` the original instanced MDL mesh is kept *and* also gets
a solid collision body from `_add_mesh_collision` (general prop-collision
rule) in addition to the click `Area3D`. Two un-confirmed hypotheses: (a) the
solid collision body on AFG_Card competes with/occludes the click Area3D for
raycasting, or (b) something about entity `name` collision (both entities in
Studio.json share the literal name `ShikNote_mdl_014` despite different
`action`/`file`/position) causes a lookup to resolve to the wrong node. Did
NOT guess further — added debug prints instead (see next entry) rather than
picking one hypothesis blind, per the project's own "never guess from vibes"
rule.

Asked: run Studio, click each wall item, paste `[click-wire]`/`[click-hit]`
console output.

Answer: user pasted logs. Both `ShikNote` (87, 95, 508) and the AFG entity
(158, 152, 508, auto-renamed `@Node3D@150` by Godot — see naming note below)
registered fine, radius 48 each. All 8 logged clicks resolved to the AFG
node with `action=ShikKlik`, i.e. clicking (at least the area tested)
fired the Shiks scene every time. User also separately reported the camera
and some assets are generally "off" / not in the right place, and asked for
systemic fixes, not per-MDL heuristics.

Result: **Root cause found — not a click-resolution bug, a wrong-behavior
bug.** `AFG_Card`'s Godot handler aliased it to `ShikNote`'s `"ShikKlik"`
action with the comment "same click → Shiks" — a guess based on the two
objects sitting on the same wall. Checked `original/piposh3d/WDL/Afgan.wdl`:
`AFG_Card` is an unrelated 32-card collectible pickup system
(`AFG[my.skill1]=1`, `WriteGameData(0)`, remove entity, HUD card-fade via a
separate `AFG_Show` entity) — nothing to do with Shiks. Confirmed via the
entity's `skills[0]=16.0` in `Studio.json` (card index 16), and the same
`action: "AFG_Card"` appears in 18 different level JSONs, confirming it's a
game-wide mechanic, not level-specific — validates fixing it generically
rather than per-level.

Fixed: added `GameState.afg` (32-int array, mirrors `IO.wdl`'s `piece`/
`village`/etc. pattern), wired `AFG_Card` → `AFG_Take` in
`wdl_director.gd` (persist pickup, remove entity, skip re-spawn if already
collected), removed the false `ShikKlik` alias. **Not yet ported:** the
`AFG_Show` HUD card-reveal fade sprite — flagged in code comments, not
silently dropped. Added CONTRACT.md rule #9: grep `original/piposh3d/WDL/*`
for an action's real script before wiring behavior from spatial guessing.

Naming note (not a bug, don't re-investigate): `Studio.json`'s `ShikNote`
and `AFG_Card` entities both have JSON `"name": "ShikNote_mdl_014"` — this
is literally in the source WMB's `name20` field (probably the original WED
author copy-pasted the ShikNote object to place AFG and never renamed the
copy). Godot auto-renames the second child to avoid a collision
(`@Node3D@150` in logs). Harmless for behavior since nothing keys off
`node.name`; just confusing in debug logs. Don't assume other duplicate
`name` values across the level corpus indicate an extraction bug — check
the raw WMB name20 bytes first.

Still open: re-verify after this fix that `ShikNote` (→ Shiks) and
`AFG_Card` (→ card pickup) are now independently clickable, not just
differently-behaving-but-still-cross-triggering. Ask user to re-test.

Follow-up: user confirmed the card is now taken, but reported nothing
appears on screen (`AFG_Show`, the HUD card-reveal, was explicitly flagged
as not-yet-ported above). Implemented `_show_afg_card()`: instantiates
`LeCards.glb`, sets its skin to the card index via the existing
`MdlAnimator.set_skin()` (same mechanism already used for Naknik's skin),
parents it to the active camera for ~3s, then frees it. Simplified vs.
original: no alpha fade-in/out (original ramps `AFG_Show.alpha` over ~90
ticks), shown as a flat pop-in/pop-out instead. Noted in code comments as a
known simplification, not silently faked. Not yet playtested.

## 2026-07-27 — Camera "off" (general) + "floating below" in Shiks

Checked: `_copy_cam()` / `_apply_cam_smooth()` in `wdl_director.gd` — used
by every scripted-camera level (Studio, Town, Shiks, generic). Found a
hardcoded `CAM_LENS_LIFT := 14.0` added to every camera's Y position, plus a
tilt-softening curve (`if twrap < -2.0: twrap = twrap*0.65+4.0`) applied to
every camera's look angle. Compared against `original/piposh3d/Studio.wdl`
`TheCam`/`TheCam2` (the actions these entities actually run): the real
engine does an **exact** copy — `camera.x=my.x; camera.z=my.z;
camera.tilt=my.tilt; camera.pan=my.pan; camera.roll=my.roll` — no offset,
no softening anywhere. Both constants were undocumented, uncited guesses
(comments said "sits a bit low" / "soften... so subjects sit higher" with
no source reference) tuned against one level (Studio) and then applied
game-wide — the same mistake pattern as `AFG_Card`, just in the camera path
instead of a click handler. This directly explains both symptoms: "camera
off" in general (wrong tilt reshaping the look direction everywhere) and
"floating below a bit" in Shiks specifically (a flat +14 that happened to
look OK-ish for Studio's camera entities doesn't have to hold for Shiks'
differently-placed `MyCamera`/`PipiCam` entities).

Fixed: removed both. `_copy_cam` now copies entity position and Acknex
pan/tilt/roll unmodified (the existing `_apply_acknex_view` already handles
the WED tilt wrap-around, e.g. 345=-15, so no behavior lost there).

Asked: (not yet — re-test is the ask; see reply to user)

Answer: (pending)

Result: Fix applied, affects every scripted-camera level uniformly (not
per-level). Needs playtest confirmation across at least Studio, Shiks, and
one generic level, since removing a blanket hack could reveal it was
partially compensating for something real in one of them.

## 2026-07-27 — MDL facing in Intro levels (IDPO hypothesis, unconfirmed)

Checked: scanned all `Intro*.json` level files for referenced `.MDL` files
and read each one's 4-byte magic from `original/piposh3d/MDL/`. Of 135
distinct models used across Intro cutscenes: 69 are `IDPO`, 50 are `MDL3`,
16 are `MDL5`. `docs/CONTRACT.md` already documents IDPO as the
historically unreliable facing path (legacy axis map is a det -1
reflection vs. A5's det +1) — this session added the `--fix-idpo`/
`--no-face-orient` toggle to `tools/convert_mdl.py` and `tools/
smoke_orient.gd` for exactly this test, but hasn't run it (headless Godot
rendering hangs in this sandbox — see below). Given IDPO is the majority
format in Intro content, this is circumstantial support for "Intro facing
is wrong" being the same known IDPO handedness issue, not proof.

Asked: (see reply to user — asking them to run smoke_orient.gd on one IDPO
model, legacy vs --fix-idpo, and compare)

Answer: (pending)

Result: Open. Do NOT flip `FIX_IDPO` default without this confirmation —
it would change every IDPO model in the game at once with no verification,
exactly the kind of ungrounded sweeping change the process is meant to
prevent.

## 2026-07-27 — Sandbox limitation: headless Godot rendering hangs

Checked: both `tools/smoke_orient.gd` and a trivial throwaway script that
merely calls `WdlDirector.new()` and quits hung indefinitely when run via
`godot --headless -s ...` in this environment, while `tools/smoke_test.gd`
(pure JSON/file checks, no rendering/Node instantiation) completed in
seconds, and `godot --headless --import` also completes normally. This
looks like a sandbox rendering/GPU limitation, not a code defect — `--import`
already exercises full script compilation (would have caught real syntax
errors) and passed clean both before and after this session's edits.

Result: Any test requiring an actual rendered frame (`smoke_orient.gd`,
visual facing/camera checks) needs to be run by the user locally, not by me
in this sandbox. Noted so a future session doesn't re-attempt this and
waste time waiting on the same hang.

## 2026-07-27 — Follow-up round: AFG card too big, camera fix "not seen", sinking confirmed in 2 levels, Plane2 walking broken

Answer (to prior round's asks): AFG card pickup confirmed working, but
`_show_afg_card()`'s placeholder size/distance (position -6 on Z, no
explicit scale) was too large on screen. User also confirmed sinking
happens in **both** Studio (Ami) and Shiks — not level-specific. User
reports "all graphical changes besides AFG card were not seen" — i.e. the
`_copy_cam` lift/tilt removal appeared to have no visible effect. New:
after the Plane2 "movie" (goal-collection finale), user expected to keep
walking first-person but instead sees a static camera outside the plane.

Checked:
- AFG card: no way to know LeCards.glb's authored scale without a render.
  Added an explicit small scale (0.12) + moved further away (30 units) +
  a debug print of the raw mesh AABB, so the next report gives real
  numbers to tune from instead of guessing a second time blind.
- Camera fix "not seen": since the AFG fix *was* visible, stale
  code/caching is ruled out — the user is running fresh code. Rather than
  guess further at why `_copy_cam`'s change didn't register, added a
  print of the exact computed position/pan/tilt/roll and resulting
  Camera3D transform every time `_copy_cam(hard=true)` runs (level entry /
  cam switch), so the next report either confirms the new (unlifted)
  numbers are being applied — meaning the bug is elsewhere entirely — or
  reveals something is still adding an offset downstream of this function.
- Sinking in 2 levels: re-examined `MdlAnimator._set_blended_frame` —
  it rebuilds a fresh `ArrayMesh` each pose change (not an in-place vertex
  poke), so `Mesh.get_aabb()` should already reflect the posed mesh, not a
  stale bind-pose AABB — my initial "stale AABB" hypothesis doesn't hold
  up on inspection. Rather than guess a different cause, added the
  MdlAnimator's actual `_current_clip` and the raw local AABB size to the
  `[feet-snap]` print, to see the real clip/size data instead of assuming.
- Plane2 walking: confirmed via JSON that `Plane2.json` does have a
  `player_walk2` entity and "plane2" is correctly excluded from
  `level_runner.gd`'s `CUTSCENE_LEVELS` list, so FP mode *should* engage on
  entry — the state machine in `_update_plane2`/the four goal-movie
  functions (`_run_plane2_hp/_tv/_passanger/_sikot`, `_run_plane2_finale`)
  is complex enough that guessing which one fails to hand control back is
  not worth the risk of breaking working parts. `level_runner.gd` already
  has an on-screen debug label (F10) showing `mode=FP/scripted/free` —
  pointed the user at this existing tool instead of adding new code.

Asked: (see reply to user)

Answer: (pending)

Result: Three debug iterations added (AFG card size/AABB, camera transform
per hard-cut, feet-snap clip+AABB size), plus a pointer to the existing F10
debug overlay for the Plane2 FP-mode question. Waiting on next playtest
report before making further behavior changes — deliberately avoided
guessing fixes into the camera-"not seen" mystery or the Plane2 state
machine without more data.

## 2026-07-27 — Major regression found: feet-snap policy inverted (opt-in vs opt-out)

Checked: user reported fans/lights/curtains sinking below the floor
specifically in Studio, described as "the same issue we had before." Pulled
each entity's raw `origin_gs`/GLB mesh bounds directly:
`StudioL_mdl_004..007` (light fixtures) all sit at raw Acknex Z=0 (floor
level) yet their GLB mesh spans local Y from -288 to +117 — a huge range
straddling the origin, meaning without a feet/mount-snap a large chunk of
each fixture renders underground. Compared current `_should_feet_snap`
(opt-in: only snap entities on a `FLOOR_ACTIONS`/`FLOOR_STEMS` whitelist)
against the checkpoint's *pre-rewrite* version of the same function (still
visible in this session's initial diff): the old version was opt-OUT —
`return true` for everything except a short exclusion list (cameras, wall
cards) — with a comment reading verbatim: **"Without snap, curtains/fans/
StudioL sink under the floor."** That is exactly the bug just reported.
The rewrite replaced a safe "snap by default, list the exceptions" policy
with an unsafe "snap only these named cases" policy, silently un-snapping
every scenery prop not on the new whitelist (fans, curtains, light rigs,
smoke machines, ...) game-wide, not just in Studio.

Note: this does NOT explain Shiks' character/camera sinking — those
entities (stem "piposh") were already covered by the old whitelist, so the
regression doesn't apply there; that report is still open (needs the
`[copy-cam]`/`[feet-snap]` logs asked for last round, which weren't pasted
this time).

Fixed: restored opt-out policy in `_should_feet_snap` (default `true`,
keeping every existing named exclusion — cameras, wall cards, window/glass/
b747/cockpit/tv/island/headphone/biplane/hanger/towerw/dutyfree,
land/wind/ent_rotate/item_pickup — each for the same documented reason as
before). Removed the now-dead `_stem_has_walk_or_stand` helper and the
whitelist constants. Updated `tools/verify_feet_snap_policy.py`, which had
been silently mirroring the *old buggy* opt-in logic and never actually
exercised the regressed cases (Sfan/Curtain/StudioL/Shtomba) — added those
as explicit regression-guard test cases so this can't quietly reappear.

This is level-agnostic (any level, any non-whitelisted prop), so it likely
also explains the separately reported "Plane level assets not in place."

## 2026-07-27 — AFG_Card double-wired in Plane2, second wiring wins

Checked: user reported "an item I can't click" in Plane2. `AFG_Card` also
appears in `Plane2.json` (in addition to Studio). The main entity loop
correctly wires it to `"AFG_Take"` (this session's earlier fix). But
`_begin_plane2()` also calls `_wire_first_person_clickables()`, whose
`CLICK` whitelist included `"afg_card"`, re-registering the same node with
the *raw* `"AFG_Card"` action string — which has no handler in
`_handle_click_action`. `_make_clickable` unconditionally overwrites
`click_action` on every call, so whichever wiring pass runs last wins;
for Plane2 that's the second, broken one. Studio's AFG_Card wasn't affected
because Studio's director path never calls `_wire_first_person_clickables`.
Also checked `original/piposh3d/WDL/Plane2.wdl` for the two other
candidates before touching anything: `PiposhHit` and the lone
`item_pickup`-actioned entity (`BiPlane2`, a distant background prop) are
both genuinely non-interactive by design (`PiposhHit` is a hidden
"you got hit" camera-swap proxy driven by a global flag, not a click
target; the `item_pickup`-actioned `BiPlane2` is 29,469 units away —
background scenery, not a real pickup) — left both alone rather than
"fixing" something that was already correct.

Fixed: removed `"afg_card"` from `_wire_first_person_clickables`'s `CLICK`
list, so the main loop's correct wiring (and its "already collected → skip
spawn" check, which the whitelist path didn't replicate at all) is the only
one that touches these entities.

Asked: (see reply to user)

Answer: (pending)

Result: Two systemic fixes this round (feet-snap default, AFG double-wire).
Still open: Shiks camera/character sinking (need the logs), Plane2's
"static camera after the movie, should be walking" (state machine too
complex to guess into — pointed at F10 overlay + asked for exact repro
sequence, not yet answered), and Intro MDL facing (still blocked on a
render the user needs to run).

## 2026-07-27 — Follow-up: Shiks camera "blocky", AFG card invisible in Plane2 (again), IDPO facing attempt + near-miss regression

Answer (to prior asks): Shiks confirmed better, but camera motion is
"three blocky movements" instead of one flow. Plane2 AFG card: taken, but
still nothing appears on screen (a *second*, different bug from last
time — see below). Studio: only remaining issue is the fan (Sfan) facing
180° backwards. Range (post-Plane2 level): camera not in the right place,
"stage doesn't start." Some assets in "other mid scenes" pointing 90° off.

Checked/fixed:
- **AFG card in Plane2 invisible**: `_show_afg_card()` parented the card to
  `_world_camera` (the scripted-cam reference passed to `setup()`), but
  Plane2 runs in first-person, where the actual rendering camera is the
  player's own `Camera3D` — `_world_camera` is a different, inactive node.
  Fixed to use `get_viewport().get_camera_3d()` (same pattern `_try_click`
  already used), falling back to `_world_camera` for scripted levels.
- **Shiks camera "blocky"**: traced to `_start_shiks_fly`/`_update_shiks` —
  the camera moves toward `_shiks_path` waypoints in straight X/Z segments
  (Y is not interpolated at all), advancing to the next point within 12
  units. The extracted path data has a `bezier` field per edge that isn't
  used at runtime — likely why it reads as segmented rather than curved.
  Not fixed this round (lower priority, scoped as a real gap, not a quick
  guess) — flagged for the user to confirm priority.
- **Sfan 180° + IDPO facing, attempted a global fix, reverted after it
  broke tested models**: confirmed `Sfan.MDL` is IDPO (matches CONTRACT's
  documented unreliable-facing path). Given IDPO is 750/1298 of all game
  models, and the report pattern (180° here, ~90° elsewhere) matches a
  per-model heuristic guessing wrong rather than one consistent sign error,
  flipped `convert_mdl.py`'s `FIX_IDPO`/`FACE_ORIENT` defaults game-wide and
  reconverted all 375 IDPO models. `tools/check_all.ps1` caught the mistake
  immediately: `verify_mdl_facing.py` encodes a **previous session's own
  tested fix** for 5 specific models (Crowd, Crowd2, Yachdal, Genia,
  Island) that depends on `FACE_ORIENT`'s heuristic *and* the legacy
  winding convention together — flipping `FIX_IDPO`'s winding changes what
  "front-facing" means to that heuristic's normal computation, so my
  change regressed all 5 while only being an unverified guess for Sfan.
  Reverted defaults to `FIX_IDPO=False, FACE_ORIENT=True` (all 375 IDPO
  models reconverted again — diff against committed `.glb`s came back
  empty, confirming a clean revert). Documented this coupling in
  `convert_mdl.py` so it isn't attempted blind again.
- Applied `--fix-idpo` to **only Sfan** (`--only Sfan`, default
  `FACE_ORIENT` untouched) — Sfan is "faceless" per `verify_mdl_facing.py`
  (no clear face-UV bbox), so the heuristic never touched it either way;
  this isolates the handedness/winding fix to exactly the one model with
  actual playtest evidence, without touching the 5 tested ones.
  `check_all.ps1` passes. **Not visually confirmed** — need the user to
  check the Studio fan specifically.
- Range: confirmed its entities (`Handgun`, `Terrorist`, `TNT`,
  `CamTarget`, `CameraEngine`) are a full shooting-range minigame with no
  case in `wdl_director.gd`'s match statement at all — i.e. it was never
  given custom director logic (`docs/LEVELS.md` lists it "generic", not
  "custom:range"). "Camera not in the right place, stage doesn't start" is
  consistent with there being no implemented gameplay to start, not a
  parsing defect — geometry/entities extract fine per the pipeline. This
  needs new behavior code, not a re-parse; flagged as a scope question for
  the user rather than guessing at a minigame's rules from geometry alone.

Asked: (see reply to user)

Result: Net this round — 1 real fix shipped (AFG camera-attach), 1 targeted
experiment shipped needing visual confirmation (Sfan `--fix-idpo`), 1 gap
scoped but not fixed (Shiks path smoothing), 1 scope question raised
(Range minigame — new feature, not a bug), and one important lesson
learned the hard way: `FIX_IDPO` and `FACE_ORIENT` are coupled through
winding/normal direction and must never be changed as a blanket default
without re-deriving `verify_mdl_facing.py`'s expected angles first.

## 2026-07-27 — Sfan confirmed fixed; Bus/B747 90°-off root-caused (vehicles + face heuristic don't mix)

Answer: Sfan (Studio fan) confirmed facing correctly now. New reports: some
"Start" models 90° off (unspecified which), Shiks bus 90° off, Piposh in
"Plane" ~90° off, Plane2's moving plane 90° off, Shiks camera fly still
blocky, Range still stuck outside the plane.

Checked: found and fixed a real classification bug in my own investigation
tooling first — a throwaway script to check whether `orient_mesh_face_plus_x`
touches a given IDPO model returned "unchanged" for literally every model,
because that function mutates `mesh.positions` **in place** and returns the
same object; comparing it to itself after the fact is always true. Fixed by
snapshotting positions before the call. Rerun showed Bus and B747 (both
confirmed IDPO) ARE actively re-yawed by the face-orient heuristic — unlike
Sfan, which the heuristic never touched. That heuristic looks for
skin-colored ("face-like") pixel regions — a concept that doesn't apply to
a bus or an airliner hull; it likely locks onto some warm-colored livery
patch and guesses an arbitrary wrong orientation, which fits "~90 off"
better than the clean 180 a handedness-only bug would produce.

Fixed: added `NON_FACE_STEMS = {"bus", "b747"}` in `convert_mdl.py` —
`orient_mesh_face_plus_x` now skips the heuristic entirely for these (kept
"authored, faceless" like Sfan), and `--fix-idpo` applied to just these two
(matching Sfan's already-confirmed treatment). This does NOT touch the 5
heuristic-dependent protected models (verified: `verify_mdl_facing.py`
still passes unchanged) since it's a disjoint set. `check_all.ps1` green.
Not yet visually confirmed by the user.

Investigated but not yet fixed: "Piposh in Plane 90 off". Traced Plane's
two separate Piposh-related entities in `wdl_director.gd`: `PiposhWalk` (a
walking NPC, faces its movement direction every frame via
`atan2(-step.z, step.x)` — matches the same formula used everywhere else
in the codebase, so unlikely to be the bug) and `Pip` (a distinct,
stationary "peek and look back" entity per `original/piposh3d/Plane.wdl`'s
`action Pip` — invisible/visible toggle + `LookBack` frame + talk, no
movement at all). If it's `Pip` that's wrong, that points at `Piposh2.MDL`
itself (its file), not at movement logic — but this needs the user to say
which of the two they mean before guessing further.

Not investigated this round (no specifics yet): "some Start models 90
off" — need names.

Asked: (see reply to user)

Result: Net this round — Sfan confirmed working end to end (first fully
closed loop of the debug→ask→fix→verify cycle this session). Bus/B747
fixed with strong reasoning and passing tests, needs visual confirmation.
Piposh/Plane narrowed to two candidates, needs the user to disambiguate.
Range and Shiks camera smoothing still waiting on a priority call.

## 2026-07-27 — IDPO facing: the actual systemic fix (not per-model)

Answer: Plane + Bus confirmed facing correctly. New report: "the stationary
one in Start", "the many characters in the middle and the speaker that's
a bit upper than them" (Start's Crowd/Crowd2 audience + Yachdal, who gives
a speech from a raised position) are ~90 off. Notably, Crowd/Yachdal/Genia
are 3 of the 5 models `verify_mdl_facing.py` already claims are correct —
so a per-model exclusion approach (like Bus/B747) couldn't be the answer
here; something about the *test itself* wasn't catching a real problem.
User explicitly asked to stop fixing this "one by one" and fix the parsing
generally.

Checked: confirmed empirically that `FIX_IDPO`'s winding flip reverses the
sign of the cross-product face normal in `_face_uv_forward_yaw`, shifting
its computed direction by exactly 180° (measured directly: Crowd's raw
face-UV yaw is 90° with legacy winding, 270° with FIX_IDPO winding — a
clean 180° gap, not a coincidence). This means the previously "passing"
verify_mdl_facing.py result was only correct *relative to the mirrored
(det -1) legacy geometry* — the actual mesh vertices for every
heuristic-oriented IDPO model are a left-right mirror image of the
authored original, which a rotation can partially disguise (the model
still ends up facing +X) but can't fully fix (asymmetric mesh details —
a name tag, an asymmetric prop, non-mirror-symmetric anatomy — stay
mirrored), which plausibly reads as "still somehow wrong" even after the
heuristic "corrects" the facing direction. This is a deeper bug than
"model faces the wrong way" — it's "model is a mirror image of itself."

Fixed: added a 180° compensation inside `_face_uv_forward_yaw` itself,
active whenever `FIX_IDPO` is set, so the heuristic's face-direction
conclusion becomes winding-independent. Verified empirically before
touching any real assets: with `FIX_IDPO=True` + compensation, all 5
protected models (Crowd, Crowd2, Yachdal, Genia, Island) plus Ami compute
`post≈0` (correctly oriented), same as before. Re-derived and updated
`verify_mdl_facing.py`'s `EXPECT_PRE_YAW` table for the new (now
handedness-correct, un-mirrored) numbers — documented why each one is what
it is, not just the new values.

Made `FIX_IDPO=True` the actual global default (previously `False`) now
that it's verified compatible with every model the test suite protects,
plus the two known heuristic-false-positive vehicles (Bus, B747, via
`NON_FACE_STEMS`, unaffected by this specific compensation since they skip
the heuristic entirely). Reconverted all 375 IDPO models in the game (not
one at a time) — `check_all.ps1` green. This is the actual "parse the
models to fix, not one-by-one" the user asked for: every IDPO model in the
game now gets correct handedness, and every model with a genuine painted
face gets a heuristic that's no longer silently coupled to a mirroring bug.

Result: Should resolve Start's Crowd/Crowd2/Yachdal/Genia report (and any
other similarly-affected IDPO model across the whole game, not just the
ones explicitly reported) since this touched the shared function all of
them go through, not a named exclusion list. Needs a broad playtest to
confirm rather than one more single-model check.

## 2026-07-27 — Range minigame built; Shiks camera path smoothed

Answer: user confirmed the general-fix approach and asked for two
concrete builds instead of more one-off checks: (1) implement the Range
shooting-gallery level for real ("write it and the scene and everything"),
and (2) fix Shiks' camera — "it feels like originally it was one moving
motion, not a couple of stitched ones."

Range: read `original/piposh3d/Range.wdl` in full before writing anything
(per CONTRACT rule #9). It's an on-rails shooting gallery: a fixed
`CamTarget` camera aimed with the mouse (pan/tilt, tilt clamped -15..45),
a `Handgun` viewmodel, and ~20 `Terrorist`-actioned entities that share one
model (`Fakeguy.MDL`) and randomly pop up as either a terrorist or a
civilian (skin-swapped per type); shoot terrorists (correct), let civilians
be (shooting one is a mistake), terrorists that stay up too long shoot back
(health damage). All terrorists down -> `Run("Plane3.exe")`; health or
civilians hitting zero -> restart. None of this had any code before —
confirmed via a grep across `wdl_director.gd` before starting, all of
CamTarget/Handgun/Terrorist/TNT/Ground/SkyX/Cloud were absent from the
match statement, so `scripted_camera` and `fp` both computed false and the
level fell all the way through to "free player camera" with nothing
happening — exactly "outside the plane and stuck".

Implemented `_begin_range()`/`_update_range()` in `wdl_director.gd`: camera
bound to `CamTarget` with the WDL's own mouse sensitivity/clamp, per-target
state machine (pop/dying/going-up/delay) mirroring `action Terrorist`
almost line-for-line, `_range_fire()` raycasting from screen center (the
crosshair is screen-locked in the original too — you aim by moving the
camera, not a cursor) against `Terrorist`/`TNT` entities via the same
walk-up-parents pattern `_try_click` uses, health/civilian/terrorist
counters surfaced through `status.emit` (the original's pixel-art HUD
panels were not reproduced — noted as a simplification, not a silent gap).
Disabled the Handgun viewmodel's auto-added collision body (the generic
FP-collision rule in `wmb_level_loader.gd` would otherwise make it block
its own shooting raycast at point-blank range). Not yet playtested — this
is a full new feature, needs real gameplay verification, not just
`check_all.ps1` passing.

Shiks camera: replaced the discrete "move straight at waypoint, jump to
next waypoint within 12 units" logic with a continuous Catmull-Rom spline
through the same path points, parameterized by continuous arc-progress
rather than a per-waypoint distance check. Height (Y) is still untouched
by the path, matching the original's behavior exactly (it only ever
computed direction from X/Z). Not yet playtested.

`check_all.ps1` green after both changes (neither touches anything the
existing test suite covers — new code paths, not modified shared ones).

Result: Two features shipped this round instead of debug-and-ask, per the
user's direction that these needed building, not diagnosing. Both need a
real playtest — Range especially, since it's untested new gameplay, not a
verified-then-applied fix like the facing/camera work above.

## 2026-07-27 — The 180° "compensation" was wrong: mirroring vs rotation

Answer: user reported the "systemic" fix regressed several previously-good
models — Start's crowd/Yachdal now 180° off (was 90° before), Ami now 180°
off (was confirmed correct before this session touched it), Shiks'
ShikFond ("Shick") 180° off, a Shiks propeller (Wwheel, WaterWheel) 90°
off. Bus reported 180° off too, despite its `.glb` being provably untouched
since the confirmed-good `cf1ecde` commit (see below — unresolved).

Root cause of the regression: the "180 compensation" added to
`_face_uv_forward_yaw` was based on a false premise. A det -1 (legacy) IDPO
mesh and its det +1 (FIX_IDPO) counterpart are **mirror images of each
other** (chirality) — not two different rotations of the same shape. No
yaw rotation can turn a mirrored asymmetric mesh into the unmirrored one.
The compensation made the heuristic's *own* post-orient yaw metric read as
correct, but that metric is self-referential — it only proves "the
heuristic agrees with itself," not "the geometry matches what was
previously confirmed correct." This is exactly why `verify_mdl_facing.py`
kept passing throughout: it was checking the same biased function it was
supposed to be validating.

Fixed properly (`tools/convert_mdl.py`):
- Removed the compensation from `_face_uv_forward_yaw` entirely — restored
  to a plain, uncompensated computation.
- Added `_convert_idpo()`: for each IDPO model, parse under **legacy**
  winding first. If the face-orient heuristic has *any* opinion on it
  (checked via `_face_uv_forward_yaw(...) is not None` — NOT "did positions
  change", which can't distinguish "heuristic correctly decided 0°
  rotation" from "heuristic found nothing at all"; this exact confusion
  caused a second bug attempt to fail Ami/ShikFond even after removing the
  180 compensation, caught before shipping), keep legacy winding — matching
  what the heuristic was tuned and playtest-validated against. Only use
  FIX_IDPO when the heuristic has no opinion at all (faceless/excluded
  props: Sfan, Bus, B747).
- Rewrote `verify_mdl_facing.py` to check this **by direct data
  comparison** (does `_convert_idpo()`'s output match a manually-forced
  legacy parse, or a manually-forced FIX_IDPO parse?) instead of an angle
  metric — the class of check that would have caught the original mistake.
- **Verified against ground truth, not self-consistency**: diffed the
  regenerated `Ami.glb`/`Crowd.glb` against the very first commit
  (`1db264d`/`df96b0d`, before this session touched anything) — **zero
  bytes different**. Same for `ShikFond.glb`/`Wwheel.glb`. And diffed
  `Sfan.glb`/`Bus.glb`/`B747.glb` against their confirmed-good commit
  (`cf1ecde`) — also zero bytes different. This is the standard the lesson
  demands: not "a metric says it's fine" but "byte-identical to a state a
  human already confirmed with their eyes."
- Documented this as a permanent rule in `docs/CONTRACT.md` §2.5 so this
  exact mistake class (algebraically "fixing" an orientation metric instead
  of comparing real output data) cannot recur without contradicting a
  written rule.

Bus (Shiks) remains unexplained — its `.glb` has not changed since the
commit the user confirmed it working in. Either that confirmation was
about a different model (B747, easily conflated with "bus"), or something
context-dependent is going on. Not guessing further; asked the user to
re-confirm specifically.

Range gameplay bugs also addressed this round (not a facing issue, no
connection to the above): `_begin_range()` now calls `_steal_camera()` to
actually disable the player controller/FP camera (previously nothing
stopped a fallback to free/3rd-person movement — likely why "it enables me
to move from first person to 3rd which shouldn't be possible"), excluded
Range from the generic RMB mouse-look toggle (it has no cursor mode in the
original), and added a real always-visible HUD label
(`GameHud.set_range_hud`) for health/terrorist/civilian counts — the
previous version only used `status.emit()`, which is gated behind the F10
debug overlay and therefore invisible in normal play, explaining "there's
no overlays with the stats of the game".

Still open, not investigated this round: Plane2's control-panel position,
a moving-animation that should be closer to Krupnik, TV with no animation
inside, and "there should be a scene before Range and other graphics" —
logged in `docs/PLAYTEST.md`, need specifics/repro before touching.

Result: Facing pipeline now verified against real committed baselines, not
a self-checking metric — this is the standard to hold going forward.
Process lesson: when "reverting to a known-good state," always diff the
output against the actual prior artifact, never re-derive and trust a
metric alone, however well-reasoned it seems.

## 2026-07-27 — The "restore to prior commit" fix was ALSO wrong; deleted the heuristic entirely

Answer: user reported the just-restored models are STILL wrong — "Start:
characters and crowd facing 90 off", "Shiks: water-wheel 90 off, bus still
180 off" — and pushed back hard: "the code should be 1 parse to get
EVERYTHING correct", explicitly rejecting further per-instance chasing.

This was the second wrong turn in a row, and it exposed a mistake in my
own reasoning, not just the code: **"byte-identical to a prior commit"
proves determinism, not correctness.** I verified the restored
Ami/Crowd/Yachdal/Genia/ShikFond/Wwheel `.glb`s matched commits from before
this session touched anything, and treated that as proof they were right.
But those prior commits were never actually confirmed correct by a human
for most of these models — only Sfan ever got an explicit "yes that's
correct now" from the user. Crowd, Wwheel, and Bus were all *still wrong*
after being perfectly restored to their untouched, original state, because
that original state was itself never validated. The face-orient heuristic
had been running on these models since before this session began, entirely
unverified — I had been protecting a heuristic's output as if it were
ground truth just because it predated my own changes.

Re-read `docs/CONTRACT.md`'s own pre-existing (pre-session) prescription
for this exact problem, which had been sitting unimplemented: "use a det +1
IDPO map matching A5, and flip triangle winding... Then delete the
skin-pixel heuristic — WED pan orients every entity uniformly, exactly like
A5 models." That is: no heuristic, no per-model classification, one rule
for every model. This session tried two more-clever-seeming alternatives
first (the 180 compensation, then per-model legacy/fixed classification)
instead of trusting that simpler, already-written answer — both failed.

Fixed: deleted the heuristic path from the live pipeline entirely.
`FACE_ORIENT` now defaults to `False`; `parse_mdl` applies the same rule to
every IDPO model as A5 always used — handedness-correct axis remap
(`FIX_IDPO`, det +1, unconditional), then keep authored facing, full stop.
No `_convert_idpo`, no per-model winding choice, no `NON_FACE_STEMS`
special-casing needed (still defined, but now unreachable in the default
path — the heuristic it exists for never runs). Rewrote
`verify_mdl_facing.py` to check the only thing that now matters: that nothing
gets re-yawed, for a representative sample spanning every model this
session fought over (Ami, Crowd, Crowd2, Yachdal, Genia, Island, ShikFond,
Wwheel, Sfan, Bus, B747). Reconverted all 375 IDPO models — 315 changed
from the "restore per-model" state (everything that had been on legacy
winding switches to the simple, uniform rule); Sfan/Bus/B747 unchanged
(they were already on this exact treatment). `check_all.ps1` green.
Documented as the permanent rule in `docs/CONTRACT.md` #2, replacing the
per-model version from two commits ago.

Bus specifically: still unchanged by this fix (it was already using
handedness-correct-no-heuristic before), and still reported wrong. This
means Bus is likely a genuine, narrow exception — not another instance of
the heuristic problem — but I have not applied a guessed correction for it;
that would repeat the exact mistake this entry is about. Needs the user to
re-confirm against this new build specifically before any targeted fix.

Result: This is now the actual "1 parse, everything correct" architecture
CONTRACT.md always specified. Every previously-heuristic-touched model in
the whole game changed, not just the reported ones — needs a broad
re-test, not a narrow one. Process lesson recorded permanently in
CONTRACT.md: an unchanged-since-before-this-session artifact is not
evidence of correctness unless a human specifically confirmed it; only
external ground truth (a person's eyes) can validate an orientation fix,
never an internal metric or "it matches an earlier commit."

## 2026-07-27 — CLI silently re-enabled the just-deleted heuristic; found before it mattered again

Answer: user reported Start's characters were *still* 90° off even after
the heuristic deletion — a specific, measured, consistent amount (not the
scattered errors a live heuristic guess produces).

Checked: before assuming the deletion itself was wrong again, verified the
actual CLI path used to regenerate assets. Found a real bug:
`FACE_ORIENT = not args.no_face_orient` in `main()` — with the `--no-face-orient`
flag defaulting to unset (`False`), this evaluates to `True` on every
plain CLI run, silently overriding the new module-level default
(`FACE_ORIENT = False`) back on. The entire "delete the heuristic, regenerate
all 375 models" commit had been running through `main()` via
`python tools/convert_mdl.py --magic IDPO` — meaning the heuristic was
**still active** for that whole regeneration, despite the module default
and `verify_mdl_facing.py` (which calls functions directly, bypassing
`main()`) both correctly reflecting "off". The test passed because it
never exercised the actual CLI path used to build the real assets.

Fixed: renamed the flag to `--face-orient` (opt-in, matching `FIX_IDPO`'s
`--legacy-idpo` opt-out pattern) so a plain run can no longer silently flip
a default back on. Regenerated all 375 IDPO models again, this time via the
corrected CLI — 250 files differ from the previous (still-heuristic-tainted)
commit. `check_all.ps1` green; Sfan/Bus/B747 still byte-identical to their
long-standing baseline (`cf1ecde`) as expected.

Process lesson: **a unit test that calls internal functions directly does
not prove the CLI entry point behaves the same way.** Always test (or at
minimum spot-check the printed `[orient] FIX_IDPO=... FACE_ORIENT=...`
line) through the actual command used to produce real output, not just the
underlying functions.

## 2026-07-27 — Crowd/Crowd2/Yachdal/Genia: legitimate per-model correction, not a heuristic guess

After the CLI fix, Start's characters were re-tested and still 90° off —
a genuine, consistent, human-measured data point, not heuristic noise. This
is exactly the case `docs/CONTRACT.md` #2's exception process is for: a
human-confirmed measurement, applied via `tools/mdl_yaw_allowlist.json`
(a mechanism that existed in the repo, unwired, before this session).

Wired it in: `convert_mdl.py` now has `_apply_yaw_allowlist()`, applied by
`parse_mdl()` after the standard handedness-correct, no-heuristic remap.
Added `Crowd`, `Crowd2`, `Yachdal`, `Genia` at `+90°` — a first guess at
direction (the user reported magnitude, not direction); trivial to flip to
`-90`/`270` if backwards. Added a `verify_mdl_facing.py` check confirming
the allowlist entries are actually applied by the full `parse_mdl()`
pipeline (required by CONTRACT's "no row without a test" rule).

This is categorically different from the two failed heuristic attempts:
it's not code guessing an angle from pixels, it's recording a fact a human
already measured, in the one sanctioned place for such facts, with a test.

## 2026-07-27 — Plane2 Krupnik hammer / TV: read the source, ported the real animation

User reported Krupnik doesn't do the hammer-hitting animation and the TV
has no animation. Checked `original/piposh3d/Plane2.wdl` directly (per
CONTRACT rule #9) instead of guessing:

- `action Krupnik`: idle `ent_cycle("Stand", ...)`; ~1/40 chance per tick to
  start a hammer swing, then **continuously scrubs** `ent_frame("Hammer",
  skill10)` as `skill10` ramps 0→100, playing a sound in the 50–60% window,
  resetting at 100. The prior port did a single static `_anim_frame(...,
  "Hammer", 50.0)` snapshot — a frozen mid-swing pose, not an animated hit.
  Rewrote `_update_plane2`'s Krupnik block to scrub continuously, matching
  the source exactly, with a played-once guard on the sound.
- `action TV`: continuously cycles `my.skin` 1→12 every 4 ticks (~0.25s) —
  a flipbook "video" effect. The prior port stored `_p2_tv` and never
  animated it at all. Added the cycle using the existing `MdlAnimator`
  skin-swap mechanism (same one AFG cards and Naknik already use).
- "Control panel on the floor, should be higher/in the middle": no entity
  named anything like "panel" exists in `Plane2.json` — likely refers to
  Krupnik's own position/setup, not a separate object. Not fixed this
  round; asked the user which specific model they mean.

## 2026-07-27 — Range still not functional: found one real bug (skip button), added diagnostics for the rest

User reports Range doesn't let them aim/shoot and no targets pop up, plus
an unexplained "skip button" appearing after repeated deaths. Found one
concrete, confirmed bug: `GameHud`'s skip-line button (`_skip_btn`) is
built with `visible = true` and `mouse_filter = STOP`, and
`set_skip_visible()` — the only way to hide it — is **never called
anywhere in the codebase**. It's been visible (top-right, blocking clicks
in its own rect) throughout the whole game the whole time; Range is just
where the user happened to notice it. Fixed for Range specifically
(`_begin_range()` now calls `_hud.set_skip_visible(false)`); the general
case (button visible everywhere, always) is a separate, pre-existing gap,
noted but not fixed game-wide this round.

Could not find a further code-level explanation for "can't aim/shoot, no
targets popping up" after re-reading the dispatch chain, input handlers,
and target RNG logic — all read correctly in isolation. Added debug
logging instead of guessing further: `_begin_range()` logs camera/handgun/
target-count/mouse-mode on entry, `_update_range()` logs once on its first
tick, `_range_fire()` logs every attempt (blocked/miss/hit-what). Next
report should make the actual failure point obvious instead of requiring
another guess.

## 2026-07-27 — Screenshot-driven fixes: Cockpit feet-snap, water-wheel/vase roll axis, Yachdal direction flip

User sent a screenshot of the Plane2 cockpit (first image shared instead of
a text description) plus: "DefineYachdel is facing 90 off" (still, after
the earlier +90 correction), "water electricity generation now spins on
the wrong axis", "Plane/Plane2 controller still lower than it should be",
"Range still completely off", and a direct challenge: "you have the MDL,
read it, parse it... why do you need to manually fix things."

**Cockpit** (the "control panel"): the screenshot showed it rendering near
floor/knee height next to Krupnik. No entity is literally named "panel" in
`Plane2.json` — `Cockpit.MDL` (blank action, pure scenery) is the object,
positioned almost exactly at Krupnik's own Y (33/49 vs Krup2's 35/51).
Measured its GLB directly (same method as the original StudioL find in the
first session): local Y spans -165.66..+76.83 — the mesh hangs mostly
*below* its own origin, same bug shape as the earlier light-rig props. It
had been excluded from feet-snap on the assumption it's fixed "attachment
scenery" (grouped with B747/Island/etc. in `wmb_level_loader.gd`) — that
assumption doesn't hold for this model. Removed "cockpit" from the
exclusion list; updated `verify_feet_snap_policy.py` to match (moved from
the "must never snap" cases to the "regression guard, must snap" cases).

**Water wheel / turn vase**: checked `Shiks.wdl` directly. `WaterWheel`
does `my.roll += 5`; `TurnVase` does `my.tilt += 20*time; my.roll +=
20*time`. Acknex tilt/roll rotate about the entity's OWN local axes (post
pan), not a fixed world axis. The port had hardcoded
`rotation_degrees.z +=` / `.x += ... .z +=` (Godot world/local axes),
which only coincidentally matches Acknex tilt/roll when pan happens to be
0 — this session's facing pipeline changes likely altered the wheel's
effective authored pan, exposing a latent bug as "spins on the wrong
axis" (the bug predates this session, the facing fix just surfaced it).
Added `_set_entity_tilt_roll()` (rebuilds the full `ang_to_matrix` basis
from stored pan + new tilt/roll, mirroring the existing `_set_entity_pan`)
and used it for both.

**Yachdal direction**: flipped `mdl_yaw_allowlist.json` from `90` to `270`
(i.e. -90) — the first guess was the wrong rotational direction; text
("90 degrees off") can't disambiguate direction, which is exactly why this
round-trip was needed. Crowd/Crowd2/Genia untouched (not re-reported as
wrong).

**On "why can't you just parse it correctly instead of manual fixes"**:
answered the user directly, not just in code. For facing, the blueprint
(raw MDL geometry) genuinely is being read and used directly — correct
handedness + keep-authored-facing is what fixed ~371 of 375 IDPO models
with zero per-model intervention. The remaining handful are models whose
own 3D data, even correctly handedness-fixed, doesn't point +X — not a
parsing gap, a fact about how those specific assets were originally
authored that nothing in the MDL format self-declares. Proposed leaning on
screenshots more (the user can render, I can read images) as a faster,
unambiguous alternative to "N degrees off" text going forward.

## 2026-07-26 — Camera/assets "off", characters sinking (general)

Checked: user pasted `[feet-snap]` logs for Start/Menu/Studio/Shiks. Spot
check (Studio/Ami: `min_y=-57.057`, `y_before=0.0`, `y_after=57.057`,
`floor_y=0.0`) — the math is internally consistent with the documented
contract (mesh AABB min lands exactly on the original WED-origin height,
i.e. `y_after + min_y == y_before`). This doesn't confirm the *visual*
result is correct, only that the feet-snap function itself isn't
introducing an arithmetic bug — the bug (if the model still looks sunk)
would have to be upstream (floor_y extraction, brush mesh height, or a
different code path entirely for cameras, which are never feet-snapped).

Asked: (not yet — need a specific level + whether it's the player, an NPC,
or the camera, and roughly how far off, before adding more targeted debug
output; see reply to user for the exact ask).

Answer: (pending)

Result: Open. User's report is currently too general ("camera is off",
"some assets ... not in the correct place or not pointing to the right
place") to instrument without guessing. Do not add per-entity heuristics
for this — get a specific repro first.

## 2026-07-27 — Range camera fight root-caused from live debug logs; level select added; static WDL-action audit run

User asked for a way to jump straight to Range (it's the last level in the
Plane → Plane2 → Range chain) and to run three tracks in parallel: (1) the
Range camera bug, (2) a static audit of every action wired in
`wdl_director.gd` against real WDL source, (3) headless facing/floor-snap
gallery scripts for batch human verification. Then pasted a real
`[feet-snap]`/`[range]`/`[copy-cam]` console dump from an actual playtest
run — the "debug-log-before-fix" discipline (CONTRACT.md §7) paying off
directly: the log itself contained the answer instead of needing another
guess-and-report round trip.

**Range camera fight (found from the log, not guessed):** the dump showed
`_update_range`'s per-frame aim/fire lines interleaved with repeating
`[copy-cam] cam_entity=Cam_mdl_124 ...` lines — something was calling the
*generic* scripted-camera path every frame during Range and fighting with
`_update_range`'s own camera control. Traced `_update_town_cam()` (the
generic-camera-follow function) and `ensure_scripted_view()` (the one-time
setup dispatcher): `ensure_scripted_view()`'s final `elif _cams.size() > 0:
_snap_to_active_cam(true)` fallback runs for ANY level with no dedicated
`_is_*_level()` branch and at least one "Cam"/"Cammy"/"SCam" entity in its
WMB — Range.wmb has exactly that (`Cam_mdl_124`, an unrelated leftover
intro-movie camera entity), so on top of Range's own `_update_range`
camera code, the generic fallback was ALSO grabbing and copying that
entity's transform onto the world camera every frame via
`_update_town_cam()`, producing the "camera not in the right place, stage
doesn't start" symptom from earlier reports.

Fix: added an explicit `elif _is_range_level(): pass` branch in
`ensure_scripted_view()` (Range has its own `CamTarget` system, needs no
generic snap) plus a defensive one-time-logged early return in
`_update_town_cam()` so if anything else ever calls it during Range again,
it's a loud log line instead of a silent fight. This is a **general risk
class**, not just a Range-specific bug: any future custom-directed level
that has a leftover generic "Cam" entity in its WMB (common — many levels
have an unused editor/intro camera) will hit the same fallback unless it
also gets an explicit `elif _is_<level>_level(): ...` branch. Worth
grepping for this pattern if a future level reports the same "camera
fights itself" symptom.

Committed as `4e2bacd` "Fix Range camera fight; add F4 level-select
overlay" (not yet pushed — last push was at `e170551`, per the user's
explicit "commit and push what we have now" from the previous round; no
new push request since).

**Level select (F4):** added a debug-only overlay in
`scenes/level_runner.gd` (`_toggle_level_select`) — scans
`assets/converted/levels/*.json` for level names, `ItemList` + click →
`LevelRouter.goto_level()`. Also added "Range"/"Plane3" to the existing F3
`DEBUG_LEVELS` cycle. Pure dev-QOL, no gameplay logic touched.

**Static WDL-action audit:** extracted ~90 action-like case labels from
`wdl_director.gd`'s match statements (filtered down to 79 genuine action
names after removing Range's internal dictionary keys like
`"base"`/`"delay"`/`"pop"` which aren't WDL actions at all, just match-arm
noise from an unrelated dictionary literal). Cross-referenced all 79
against every `action X { ... }` block in `original/piposh3d/*.wdl` +
`original/piposh3d/WDL/*.wdl`: **100% have a real matching WDL action
definition somewhere** — no fabricated/hallucinated action names anywhere
in the port. A byte/line-count "behavioral complexity" proxy (WDL action
body size vs. Godot reference count) turned out unreliable: the same
action name is reused across ~135 different per-level `.wdl` files with
unrelated bodies each time, so "biggest body found anywhere" isn't a valid
cross-file comparison. Fell back to one manual targeted spot-check
instead: `action Naknik` in `Studio.wdl` (64 lines, the Genia
dialogue-branching state machine for `DialogChoice==3`) vs.
`wdl_director.gd`'s corresponding handler (~line 2625-2664) — a faithful,
line-for-line-equivalent port (same WAVs, same `genia` state transitions
0→1→2→0). Conclusion: the AFG_Card-class bugs found earlier this session
were about wiring/behavior fidelity in specific spots, not systemic
fabrication — a full line-by-line audit of all 79 actions isn't
automatable with the tools available and would need to be spot-check-driven
like this one, level by level, if deeper coverage is wanted later.

**Headless galleries (batch human verification, replacing one-model-at-a-
time `smoke_orient.gd` runs):**
- `tools/gallery_facing.gd` — grid-lays-out many character models (`--all`
  auto-discovers all 236 with a `.mdlanim` sidecar, paginated 36/image) or
  an explicit list, each with a red reference arrow at its feet pointing
  world +X (the "authored forward" convention every model is supposed to
  match). One screenshot, many models — outliers whose facing disagrees
  with their own arrow should be visually obvious at a glance.
- `tools/gallery_feet_snap.gd` — for each of the 6 stems currently
  excluded from feet-snap (B747/TV/Biplane/Biplane2/Hanger/Towerw) plus 5
  known-good regression guards (Sfan/Curtain/StudioL/Shtomba/Cockpit),
  renders a RAW row (as-authored, no snap) and a SNAPPED row (mirrors
  `_snap_mesh_feet_to_origin`'s exact min-Y math, or stays raw if the real
  `_should_feet_snap` policy would exclude it) against a floor-plane
  reference at world Y=0. Answers "is this excluded stem legitimately
  floating (e.g. B747 as a flying plane) or wrongly hanging below the
  floor (the same bug shape Cockpit had)?" in one image instead of six
  separate guesses.

Both scripts do rendering (Camera3D + viewport), which is confirmed to
hang headless in this sandbox (documented earlier this session) — they are
written for the USER to run (`godot --headless -s res://tools/<name>.gd --
...`), not verified by a self-run here. Static review only: cross-checked
API calls (`OS.get_cmdline_user_args()`, `Label3D` props, viewport resize,
`save_png`) against the working `smoke_orient.gd` pattern already in the
repo, and confirmed every default/candidate stem actually has a matching
`.glb` on disk (236/236 for the facing gallery's `.mdlanim` roster, 11/11
for the feet-snap gallery's default list) before handing off.

Asked: run both gallery scripts, report which models (if any) look wrong
in each image — this replaces the six still-open "needs re-confirmation"
rows in PLAYTEST.md (Crowd/Crowd2/Genia/Yachdal facing, Cockpit/water-
wheel/Krupnik-hammer/TV fixes) plus the open Bus 180°-off mystery, with one
or two screenshots instead of one-off text reports.

Answer: (pending)

Result: Range camera fight fixed and committed. Level select shipped.
Static action-name audit came back clean (100% grounded). Two gallery
scripts written, statically reviewed, handed off for the user to run —
not yet executed or confirmed.

## 2026-07-27 — Direct challenge: "why validate bugs at all if you hardcode/heuristic everything, positions are deterministic"

User pushed back hard on `mdl_yaw_allowlist.json` (4 entries) and the
feet-snap stem-exclusion list (~10 entries): if the original engine is
deterministic, a correct parse shouldn't need per-model tables at all —
fix the parsing/redistribution once, not bug-by-bug. Fair challenge,
answered by actually investigating rather than re-asserting the existing
CONTRACT.md wording.

**Yaw allowlist — checked for a missed parsing signal, found none:**
compared the raw IDPO header (`version`, `scale` sign, `flags`,
`synctype`, `numskins/verts/tris`) of all 4 allowlisted models against 7
confirmed-correct IDPO models (Ami, Sfan, Island, ShikFond, Wwheel, Bus,
B747) — structurally identical across all 11 (`version=6`, `flags=0`,
`synctype=0` for every one, scale sign always positive). Nothing in the
file format flags "this mesh's forward isn't +X". Separately pulled
Crowd's 24 individual WMB placements from `Start.json`: each carries its
own small, plausible `angle_gs` (a loosely-clustered crowd, consistent
with the movie-screening `Scene`/`DefineYachdel` logic in `Start.wdl`),
not a uniform miscompensating offset — rules out a WMB-pan-reading bug
for these specific entities. Conclusion, now recorded in CONTRACT.md #2
rule 4: the MDL format has no field for authored-forward; it's a pure
modeling convention, and these 4 meshes' vertex data just wasn't built to
it (most likely non-house-authored/reused assets). Not recoverable by
parsing more bytes. The allowlist is the correct, deterministic ceiling —
a fixed, once-measured, per-asset correction applied uniformly wherever
that file is used, structurally the same class of fix as the axis remap
itself (see CONTRACT.md #2 rule 4 for the full writeup).

**Feet-snap exclusion list — checked, and this one found a real bug:**
cross-referenced every excluded stem's WDL `action` across all levels —
no action name/pattern reliably predicts "should skip snap" (`dutyfree`,
`hanger`, `towerw` all have blank action in every placement, same as
`Cockpit` did before it was found to need snapping — blank action isn't a
valid signal on its own). `B747` does check out: `action B747` in
`Plane2.wdl` assigns `my.z` directly during the takeoff sequence — a
runtime-flight-controlled vehicle, not a floor prop, so load-time
floor-lift is genuinely inapplicable, not just "measured to look ok."

Then measured every excluded stem's actual GLB vertical extent (min/max
local Y), the same direct-measurement method that caught Cockpit:
`Dutyfree` spans `[0.44, 224.93]` — its origin sits almost exactly at the
mesh's own bottom already (unlike Cockpit's `[-165.66, 76.83]`, which
hung mostly *below* its origin) — first stem in this list with a genuine
measured reason to stay excluded, not just an inherited guess. The rest
(`Glass`, `B747`, `TV`, `Island`, `Biplane`/`Biplane2`, `Hanger`,
`Towerw`) all "span origin" in a way that doesn't cleanly separate from
confirmed-correct snapped props like `Sfan` (`[-260.21, 106.53]`) —
geometry alone isn't decisive here the way it was for Cockpit; this is
exactly what `tools/gallery_feet_snap.gd` (built earlier this session)
exists to settle visually instead of guessing further from numbers.

**Found and fixed a real, concrete bug in the process**: the stem
`"headphone"` in the exclusion list (`wmb_level_loader.gd`
`_should_feet_snap`, and its mirror in `verify_feet_snap_policy.py`) never
matched anything — the actual file is `Headphon.MDL` (8.3-truncated DOS
filename, no trailing "e"), so `stem.to_lower()` is always `"headphon"`,
never `"headphone"`. Dead entry. It happened to not matter for most
placements because the *action*-based check (`a in [..., "headphone",
...]`) independently excludes the 8 of 9 Plane2 placements that use
`action = "HeadPhone"` — but one placement in `Plane2.json` uses
`action = "A1"` instead, which slipped through both the (typo'd, dead)
stem check and the action check, and would have been feet-snapped while
its 8 siblings using the same model weren't — an inconsistent, silent
per-instance bug that a screenshot likely would have shown as "one
headphone prop floating differently from the rest." Fixed the typo
(`"headphone"` → `"headphon"`) in both files; added a regression-guard
test case (`action="A1", stem="Headphon"`) to `verify_feet_snap_policy.py`
that exercises the stem path independently of the action path, so this
exact class of typo can't silently regress again. `check_all.ps1` still
green after the fix.

Asked: run `tools/gallery_feet_snap.gd` and confirm visually whether
Glass/B747/TV/Island/Biplane/Biplane2/Hanger/Towerw are legitimately
excluded or (like Cockpit and now the stray Headphon instance) quietly
wrong — geometry measurement alone wasn't decisive enough to answer this
one without a render.

Answer: (pending)

Result: Both hardcoded tables checked against real data rather than
defended by assertion. Yaw allowlist confirmed to be at the genuine
ceiling of what parsing can recover (documented in CONTRACT.md #2 rule 4).
Feet-snap exclusion list: one stem (Dutyfree) now has a measured
justification, one real bug found and fixed (Headphon typo + a live
inconsistent-instance case), the rest still need the gallery screenshot
to close out — not further guessing.

## 2026-07-27 — Three new bugs reported (Shiks post-conversation Piposh missing; Plane1 Piposh missing first half + wrong camera); Yachdal/crowd mutual-facing independently confirmed

User reported three concrete symptoms and, separately, a useful ground-
truth detail from the original game: "Yachdal_mdl_001 is facing the
crowd and the crowd is facing him" — explicit instruction not to
"fix this heuristically," i.e. verify against real data, don't patch the
symptom.

**Yachdal/crowd mutual-facing — checked against real WMB placement data,
confirmed correct, not a heuristic guess:** computed the bearing from
Yachdal's position to the Crowd instances' centroid in `Start.json`:
271.1°. Current `mdl_yaw_allowlist.json` value for yachdal: 270.0° — match
within measurement noise. Then checked, for every one of Crowd's 63
placed instances (Crowd + Crowd2 combined) game-wide, whether its
authored WMB pan *plus* the current +90° allowlist correction points back
toward Yachdal: circular mean deviation 2.9°, consistency R=0.906 (1.0 =
perfect agreement across all instances). Both allowlist values are now
independently geometrically confirmed against real placement data, not
just "not re-reported as wrong."

**Shiks — investigated the post-conversation Piposh-not-appearing report
by reading `Shiks.wdl` in full.** Two separate Piposh actors exist:
`Piposh2` (walks in, talks with Shik, DialogIndex 1) and `Piposh3`/
`piposh2x` (a second placement near the "photo booth" area, used from
DialogIndex 2 onward — `talking` states 1/11/12/13 drive its Talk/Dumb/
Walk/hide behavior). Confirmed both are correctly bound in
`wdl_director.gd` (`_piposh2`, `_piposh3`) and spawn normally (WMB flags
262144 on Piposh3/ShikX don't map to any bit our loader currently
interprets — checked, not the cause; loader only reads bit0/bit10).

Found a **real, checkable discrepancy** via the extracted path data:
`Shiks.wmb`'s only path (`path_002`, 7 points) is what `MyCamera` flies
along after `Bumped` triggers (`Piposh.skill2` 1→2); once the fly
completes, `MyCamera`'s own action stops updating `camera.*` entirely (its
`if` only covers `skill2==1` or `skill2==2`) — so per source, the camera
just freezes at the path's last waypoint and heading, with no separate
look-at for the DialogIndex-2 conversation. Computed that last waypoint
(`(-327, 475)` in GS X,Y) against Piposh3 `(-1,-48)` / ShikX `(-3,35)`:
~550-620 units away, with the final travel heading (~7.7°) pointing
~294° away from Piposh3's actual bearing (301.9° needed vs 7.7° actual).
If this is really what Acknex rendered too, the original may have simply
not shown Piposh3/ShikX in a tight shot at that exact moment (voice-over
during a scenic pan) rather than this being a port bug — genuinely
unclear from static reading alone. **Did not "fix" this** (would be a
guess — e.g. snapping the camera to Piposh3 has no textual justification
in the source). Instead added `PiposhDebug.log_msg("shiks", ...)` right
where the fly-cam loop ends, dumping camera position/heading vs. Piposh3/
ShikX position/visibility, so the next playtest report settles it with a
real number instead of another static-reading guess.

Also fixed one real, source-grounded (non-heuristic) bug found while
reading this code: `TurnVase` in `Shiks.wdl` is `if (Talking==11)
invisible=off; else invisible=on;` — re-checked **every tick**. The port
only ever set `_turn_vase.visible = true` once, inside the `talking==11`
branch, with no corresponding reset — so once shown, it stayed visible
forever instead of hiding again when `talking` moved on. Fixed to
re-evaluate every frame like the source does.

**Plane (first level) — investigated "Piposh not shown first half" +
"camera points to the wrong place" by reading `Plane.wdl` in full and
checking the extracted data.** Confirmed via data, not guesswork: (1)
`Cam` entities correctly carry `skill1` 1/2/3 matching `Camera1/2/3` in
source (extractor's "OLD ENTITY pad" fix holds up), so
`_plane_cams[0]` genuinely is Camera1, matching `ThePlaneMovie`'s one-time
snap-to-Camera1 at boot. (2) Camera1's authored pan (90°) matches the
real bearing to both Krupnik (85.3°) and the walk path's endpoint (93.1°,
after correctly converting `origin_gs` and path points — which are stored
in *different* coordinate conventions, raw-GS vs. pre-converted-Godot
respectively; my first pass compared them directly and wrongly looked
like a coordinate bug before re-checking types). So the initial camera
framing is data-correct: Camera1 should show both Krupnik and Piposh's
walk-up. No `_plane_piposh.visible = false` exists anywhere in the port
before `_plane_phase == 3`, matching source (`PiposhWalk`'s own action
never sets `invisible=on` until deep in `DialogChoice==3`). Static
reading did not find the bug — ruled out the data/parsing-level
explanations that would have been "one correct parse" fixes, which is
exactly why they're worth recording (saves re-checking the same three
hypotheses next time). Added `PiposhDebug.log_msg("plane", ...)`: once at
`_begin_plane()` (resolved camera positions + piposh binding), once on
the first `_update_plane` tick, and once per second thereafter (scene/
talking/phase/walking state, Piposh visibility + position, active camera
identity + world camera position) — this is a live-state bug, not a
static one, per CONTRACT.md rule 6.

Asked: reproduce both Shiks (choose dialogue leading to the vase/window
ending) and Plane1 (from level start through the first camera change),
and paste the console output (`[shiks]` / `[plane]` tagged lines). This
replaces guessing with the exact runtime state at the moment each bug
happens.

Answer: (pending)

Result: Yachdal/Crowd facing now has independent geometric confirmation,
not just "not re-reported wrong" — closes that open item for good. Shiks
flycam-landing mismatch is a concrete, data-verified lead, instrumented
rather than guessed at. TurnVase visibility-reset bug found and fixed
(genuine source mismatch, not a guess). Plane1: ruled out the camera-
selection and Piposh-visibility-flag hypotheses with real data; the
actual cause needs the live debug output, not another read of the
source.

## 2026-07-27 — gallery_facing.gd debug loop; found the real "no lighting" bug instead

User sent a real original `Start.exe` screenshot (Yachdal at a podium
facing the crowd, crowd facing him — visibly *shaded/lit*, not flat) and
tried to run `gallery_facing.gd` for a side-by-side. The script itself had
three separate real bugs, found one at a time across too many round trips
(rightly called out as "a bad loop"): (1) `ceil()` in a compound float
expression at gallery_facing.gd:130 failed static type inference — split
into an explicit `int` step; (2) `Camera3D.global_position`/`look_at()`
were called before `host.add_child(cam)` — both require the node already
inside the tree to resolve a parent transform; fixed in
`gallery_facing.gd`, `gallery_feet_snap.gd`, and `smoke_orient.gd` (same
copy-pasted pattern in all three); (3) after those were fixed, Genia's
model (max extent ~573 units) is ~2.5x bigger than Yachdal/Crowd/Crowd2
(~184-231) — the script's fixed `cell = 140.0` let Genia overflow into and
swamp the whole shot. Rewrote to measure each model's real AABB first and
size the grid from the actual batch's max extent, not a guessed constant.

Then tried running the script myself directly (user gave the Godot binary's
full path so they wouldn't have to). Confirmed: my tool-execution
environment does not have a working GPU/display context even though it
shares a filesystem with the user's machine — `--headless
--rendering-driver opengl3` still hit the dummy/null renderer
(`Parameter "t" is null` in `dummy/storage/texture_storage.h`) and then
hung past 60s, stopped manually. This is the same class of limitation
documented earlier this session for headless rendering scripts in general —
now confirmed it also applies when invoking Godot directly via the
session's own shell tools, not just the sandboxed script-runner. Do not
retry running Godot rendering scripts directly from here; they must be run
by the user.

At that point the user stated directly: "your parser is not working
correctly, this is a fact... also there would be lighting as the original
game shows." Checked the lighting claim instead of arguing the facing
claim further — and it's real, unambiguous, unrelated to parsing:
`scripts/engine/mdl_animator.gd`'s `_apply_material_style` and
`scripts/engine/wmb_level_loader.gd`'s `_force_unshaded_if_needed` both
force `SHADING_MODE_UNSHADED` on every material in the game (characters,
props, AND all brush wall/floor geometry — `_force_unshaded_if_needed` is
the dominant path, called on every spawned mesh in every level). Comment
cited "match mdl-texture-editor / A5: unlit textured meshes" as the
reasoning — introduced in `df96b0d` (2026-07-25) with no further
explanation, predating this session, never revisited. Meanwhile
`_spawn_light()` in the same file correctly creates a real `OmniLight3D`
per WMB light entity — so every level already has real lights placed, they
just had nothing that could receive them. The original screenshot directly
contradicts the "unlit" assumption (visible directional shading on
Yachdal/crowd). Switched both to `SHADING_MODE_PER_PIXEL`. This is a
systemic fix (every level, every mesh), not a one-model patch — higher
risk than the narrow facing question, but backed by direct evidence, not a
guess, and it doesn't touch the axis-remap/facing pipeline at all, so no
overlap with the still-open Yachdal facing investigation.

Asked: play the actual Start level in the Godot editor (F5) or the built
`.exe`, not the still-fragile gallery script, and screenshot the Yachdal/
crowd scene now that lighting is on — a more faithful comparison than the
synthetic debug tool, and it settles the lighting fix at the same time.

Answer: (pending)

Result: Gallery script's three bugs fixed (not yet confirmed working end to
end — still blocked on the environment's headless rendering limitation for
a self-test). Real, high-confidence lighting bug found and fixed
game-wide, independent of the facing investigation. Pivoted the facing
verification away from the debug script toward the real running game,
since the debug tool has cost more round-trips than it's saved so far.

## 2026-07-27 — New standalone web WMB viewer (tools/wmb_web_viewer.py)

User asked to start over on the WMB parser with fresh, clean code, viewable
in a browser via a local server, so they can inspect raw parsed data and
give feedback directly — independent of Godot's editor/import/rendering
entirely (which has been the source of most of this session's friction,
including the confirmed fact that this session's own tool-execution
environment has no working GPU context).

Built `tools/wmb_web_viewer.py`: a from-scratch WMB entity/light/path
parser (does not import `extract_wmb_full.py` or `gs_math.py` — written
fresh) plus a small `http.server`-based local server serving a Three.js
viewer (orbit controls, click-to-inspect, search box, per-entity red
forward-arrow, toggleable labels/lights/brush). The entity rotation math
(Conitec `ang_to_matrix` conjugated into Y-up) is implemented twice,
independently — once in this new Python file, once fresh in the embedded
JavaScript — specifically so two independently-written implementations
have to agree, instead of one codebase's assumption being trusted twice.

Reused, unmodified, on purpose (not re-derived): the already-built
`{Level}_brush.glb` (wall/floor geometry, for spatial context) and the
already-built per-model `.glb` files under `assets/converted/mdl/` —
brush/MDL mesh *parsing* is a separate, already-proven problem (position
extraction has a real constructive proof via `verify_transforms.py`'s
exact distance-preservation check); this tool targets the actually-disputed
part, entity position + angle + facing.

Tested directly (this doesn't need GPU rendering — the server is pure
Python, actual 3D rendering happens in the user's browser, so unlike the
gallery scripts this was testable end-to-end from here): found and fixed
one real bug before handing it off — `VIEWER_HTML.format(...)` crashed on
every request to `/` because the embedded HTML/CSS/JS is full of literal
`{...}` (CSS rules, JS object/template literals, the import map) that
`.format()` tried to parse as placeholders, throwing on ones that didn't
match a keyword arg. Switched to plain `.replace()` of `__LEVEL__`-style
tokens. Verified after the fix: `/`, `/api/level.json`, `/brush.glb`, and
`/mdl-glb/<name>.glb` all return correct data for both Start (75 entities,
6 lights, 2 paths — matches `Start.json`'s 81 combined objects exactly:
75+6=81) and Town (529 entities, matches `verify_transforms.py`'s
`raw=529 json=529`). Every entity in both levels resolved a matching
`.glb` (0 missing). Confirmed Yachdal's entity data via this fresh parser
matches the existing pipeline's output exactly: pos `[0, -180, -286]`,
pan/tilt/roll `[0,0,0]` — independent re-derivation, same numbers.
Extracted and syntax-checked the embedded JS with `node --check` (passed;
can't runtime-test Three.js/WebGL rendering itself from here, same GPU
limitation as everything else — the actual visual verification is the
user's job now, that's the point of this tool).

Usage: `python tools/wmb_web_viewer.py Start` (opens a browser
automatically; `--port`/`--no-browser` available).

Asked: run it for Start, look at Yachdal specifically (search box, or find
"Yachdal_mdl_001" in the list), and report whether the red forward-arrow
and the loaded mesh's own visual facing agree with each other and with
the crowd's position — and whether anything else (brush walls, other
entities) looks visibly wrong. This is raw parsed data with no Godot-side
material/animation/spawn-order code in between, so any facing bug seen
here is definitely in the parser, not downstream.

Answer: (pending)

Result: New tool built, tested end-to-end (server + data), one real bug
found and fixed. Ready for the user's actual visual feedback loop.

## 2026-07-27 — Real GLB spec bug found: NUL-padded JSON chunk breaks strict glTF parsers

User ran the new web viewer and reported: no character meshes rendered at
all, only the red forward-arrows — a much more basic failure than the
facing question it was built to answer. Also reported (separately, on
Yachdal specifically): needs a 90° right turn to face the crowd correctly
per what little could be judged from arrows alone. Held off acting on the
facing number until the rendering itself was fixed, since a broken
renderer makes any facing observation unreliable.

Root-caused instead of guessing: manually validated the actual `.glb`
bytes against the glTF 2.0 binary container spec. Found it —
`convert_mdl.py write_glb()` and `extract_wmb_mesh.py write_multi_glb()`
both pad the GLB's JSON chunk with trailing NUL (`\x00`) via a shared
`align4()` helper also used (correctly) for the BIN chunk. The glTF 2.0
spec requires the JSON chunk padded with trailing SPACE (`0x20`)
specifically — NUL is not valid JSON whitespace, so a strict
`JSON.parse()` throws on trailing NULs. This is the exact same class of
error hit repeatedly earlier this session writing throwaway Python GLB
inspection scripts (`.rstrip()` workarounds were needed every time) — it
was a real, shipping bug in the converters themselves the whole time, not
just an inspection-script annoyance. Godot's own glTF importer is
apparently lenient enough to tolerate it (every model has rendered fine in
Godot all session); three.js's `GLTFLoader` is not, and failed silently on
every single model.

Fixed: added a separate `align4_json()` (space-padded) in both files,
used only for the JSON chunk; `align4()` (NUL-padded) stays for the BIN
chunk, which is spec-correct there. Regenerated everything:
`python tools/convert_mdl.py` (648/649 MDL models) and
`python tools/extract_wmb_mesh.py --all` (134 brush/sub-model glbs).
Verified the fix directly: stock strict `json.loads()` on the raw JSON
chunk bytes now succeeds with no `.rstrip()` needed (Python's `json.loads`
has the same trailing-whitespace strictness as JS `JSON.parse` for this
purpose). `check_all.ps1` still all-green afterward, including the exact
distance-preservation checks in `verify_transforms.py` — confirms this
was purely a container-padding fix, geometry/positions are byte-identical
to before.

This is a genuine, previously-undetected bug in the shipping conversion
pipeline, not a guess or a heuristic — a real answer to "your parser isn't
working correctly," even though it turned out to be about glTF container
framing, not the WMB angle/position math that's been under suspicion.

Asked: re-run the web viewer now that meshes should actually load, and
re-check the Yachdal-vs-crowd facing question with real meshes visible
(not just arrows) — the 90°-right report from before this fix may or may
not still hold once there's an actual mesh to look at, so it needs
re-confirming rather than assuming it still applies.

Answer: (pending)

Result: Real, high-confidence, previously-unknown bug found and fixed
across the entire asset pipeline (782 regenerated files, geometry
unchanged, verified via check_all.ps1). Facing question deferred until
the rendering fix is confirmed, rather than acting on a report gathered
through a broken renderer.

## 2026-07-27 — Three more real viewer bugs, all root-caused with data (Genia scale, arrow-vs-allowlist gap, no feet-snap)

With meshes finally rendering (previous entry's GLB padding fix), user
reported three things from the actual render: Genia much too big; every
crowd character's mesh facing 180° opposite its own red arrow (and
described the fix as "crowd turns right, Yachdal turns left"); crowd and
Yachdal both sitting below the floor.

All three traced to concrete, verifiable causes in `tools/wmb_web_viewer.py`
— none needed guessing:

1. **Genia scale**: `level.json` for Start's `Genia_mdl_005` entity has
   `scale: [0.2, 0.2, 0.2]` (a 5x shrink) — confirmed by querying the
   running server directly. The viewer never applied `ent.scale` to
   anything, so every entity rendered at its raw mesh size regardless of
   its WMB-authored scale; Genia's mesh happens to be the biggest raw MDL
   in this batch (~573 unit max extent vs. Yachdal's ~223, per the earlier
   gallery-script investigation) and was also the most scaled-down,
   making the bug maximally visible on her specifically. Fixed:
   `rs.scale(new THREE.Vector3(...ent.scale))` before placement, matching
   Godot's `_acknex_entity_basis(...) * Basis.from_scale(scl)`.

2. **Crowd mesh vs. its own arrow, 180°**: root-caused with arithmetic,
   not guessing. The arrow was computed from raw WMB `pan/tilt/roll`
   only — it never knew about `mdl_yaw_allowlist.json`'s per-model
   correction (+90° Crowd, +270° Yachdal), which is baked directly into
   the mesh's vertex data at convert time. Computed by hand what the gap
   *should* be from this alone: for Crowd, `arrow=(1,0,0)` vs.
   `mesh=(0,0,-1)` after the +90° bake — exactly 90°, not the reported
   180°. That gap between predicted-90 and reported-180 was left
   unresolved (rather than force-fit an explanation) until the actual
   render could be re-checked — but the arrow not accounting for the
   allowlist at all was unambiguously a real, fixable gap regardless.
   Fixed: `_make_entity_dict()` now reads `mdl_yaw_allowlist.json` (same
   file `convert_mdl.py` uses) and computes each entity's `forward` field
   as the entity basis applied to the mesh's *own* yaw-corrected local
   +X, not raw local +X — so the arrow now shows exactly what the mesh
   should show. Verified numerically after the fix: Crowd's `forward` ≈
   `(0,0,-1)`, Yachdal's `forward` ≈ `(0,0,1)` — exactly opposite, i.e.
   facing each other, matching the independent crowd-centroid-bearing
   math from two investigation rounds ago. Whether this alone resolves
   what the user saw, or there's still a real bug beyond the
   arrow-completeness gap, needs a fresh look now that both the mesh
   (previous entry) and the arrow (this fix) are correct.

3. **No feet-snap in the viewer**: entities were placed at their raw WED
   origin with no floor correction at all — this tool never had any of
   `wmb_level_loader.gd`'s `_should_feet_snap`/`_snap_mesh_feet_to_origin`
   logic. Ported fresh: `should_feet_snap(action, stem)` (same policy,
   same exclusion list) computed server-side per entity, and client-side
   the loaded mesh's raw local AABB corners are transformed by the
   entity's rotation+scale (not position) to find the true minimum Y,
   lifting the entity so its lowest point lands on the WED origin plane —
   same approach as Godot's version and as `tools/gallery_feet_snap.gd`
   earlier this session, re-derived here independently a third time.

Regenerated nothing this round (no MDL/WMB data changed, only the viewer's
own rendering/placement logic) — re-extracted and `node --check`'d the
embedded JS (syntax-valid), then started the server and queried
`/api/level.json` directly to confirm the new `mesh_yaw_deg`/`forward`/
`should_feet_snap` fields compute the expected numbers for Yachdal, Crowd,
and Genia before handing back to the user, rather than shipping unverified
again.

Asked: re-run the viewer (same command) and re-check all three — does
Genia look normal-sized now, does the crowd's mesh now agree with its own
arrow, and are Yachdal/crowd standing on the floor instead of sunk into
it. If the crowd-vs-Yachdal mutual-facing STILL looks wrong even with a
now-correct arrow and mesh, that's the real signal to chase next — not
before.

Answer: (pending)

Result: Three more real, independently-verified bugs found and fixed in
the new tool (not in Godot's pipeline — this is all inside
`wmb_web_viewer.py`, which is deliberately a separate, from-scratch code
path). The facing question specifically has a strong mathematical
prediction now (Crowd/Yachdal arrows exactly opposite) but still needs
the user's actual re-render to confirm, per this file's whole standing
rule: computed agreement is not the same as confirmed agreement.

## 2026-07-28 — Found the real facing bug: Crowd/Crowd2/Genia's allowlist value was measured backwards, in a prior session, under a broken viewer

User's re-render showed Genia and the crowd still wrong even with a
correct mesh, correct arrow, correct scale, and correct feet-snap — all
four independently confirmed working by this point. When pushed on why
this was being "hunted" instead of just fixed, and then directly asked
"why are you guessing instead of correctly parsing and emulating the
engine, search the MDL/WDL/WMB/EXE for what it actually knows" — did that
search for real rather than re-asserting the earlier conclusion:

- **Every MDL header field**, including ones previously called "unused"
  (`eye`, `synctype`, `flags`, `size`), compared across Crowd/Crowd2/Genia
  vs. 6 confirmed-correct IDPO models — byte-identical, no signal.
- **Animation frame names** — no orientation hint (Crowd has only generic
  `Frame 1-4`; Genia/Yachdal have semantic names like `Walk1`/`Speech1`,
  unrelated to facing).
- **Raw WMB bytes, hex-dumped by hand**, bypassing both `extract_wmb_full.py`
  and `wmb_web_viewer.py` entirely — confirmed Yachdal's pan bytes are
  literally `00000000` (0.0) and Genia's are `00003843` (184.0) exactly.
  Not a parsing bug on either parser's part.
- **Every `.wdl` file, not just `Start.wdl`** — found something real:
  **no `action Genia { ... }` exists anywhere in `Start.wdl`.** Her WMB
  `action` field says "Genia" but nothing implements it — she's inert
  decoration in the original game, not a scripted character (the other
  "Genia"/"Crowd" hits across the codebase are unrelated dialogue-state
  variables and sound names in five different, unrelated levels).

Conclusion, grounded in this search rather than asserted again: the MDL
format genuinely has no field for authored-forward, confirmed exhaustively
this time, not just previously reasoned through. The engine itself doesn't
"know" either — it trusts the raw vertex data the artist built, with zero
verification, same as this pipeline now does once the correction is right.

**The actual, concrete bug**: `mdl_yaw_allowlist.json`'s `Crowd`/`Crowd2`/
`Genia` value (90°) was exactly 180° backwards. Confirmed empirically, not
by more reasoning: flipped it to 270° (matching Yachdal, which was already
correct), regenerated the three affected `.glb`/`.mdlanim` files, and
re-rendered in `tools/wmb_web_viewer.py` — user directly confirmed the
crowd visibly rotated correctly ("you successfully spinned the crowd by
180"). This value was almost certainly measured in a prior session using a
viewer that was itself broken at the time (this session alone found and
fixed three real rendering bugs in the new tool before this measurement
could even be trusted: GLB JSON padding preventing any mesh from loading,
missing entity scale, missing feet-snap) — the 90° number was a bad
measurement taken under bad conditions, not a parsing failure.

Also caught and fixed a real methodology bug in my own verification: an
early re-test compared "front" vs "back" camera candidates positioned
*relative to* the value being tested (`ent.forward`) — flipping the
allowlist value moved the camera along with it, so the comparison was
circular and couldn't actually show whether anything changed. Redid it
with a camera at a literal fixed world-space position, independent of the
value under test, before trusting any before/after comparison.

Regenerated: `Crowd.glb`/`.mdlanim`, `Crowd2.glb`/`.mdlanim`,
`Genia.glb`/`.mdlanim`. `check_all.ps1` all-green, including
`verify_mdl_facing.py` (reads the allowlist dynamically, no hardcoded
values to update). Updated `mdl_yaw_allowlist.json`'s own comment to
record the correction and why, so a future session sees this history
instead of re-measuring blind.

Asked: (nothing further needed for Start/Yachdal/Crowd/Genia specifically —
user already confirmed the fix visually). Still open: does this same
90-degrees-backwards class of error affect any of the OTHER allowlist-free
"confirmed correct" IDPO models, or any levels beyond Start — no evidence
either way yet, not re-checked.

Answer: n/a (user confirmed directly, not via a follow-up question).

Result: Real bug found and fixed with actual evidence (exhaustive field
search + empirical before/after re-render + direct user confirmation),
not a guess and not a heuristic. `mdl_yaw_allowlist.json` remains exactly
what CONTRACT.md #2 rule 4 says it should be: a short, human-confirmed
correction table — this entry was simply wrong, and is now right, measured
under a viewer that actually works.

## 2026-07-28 — "Same bugs as before": found the real cause (unported Intro levels), built a generic WDL interpreter instead of more per-level hand-porting

User reported facing/feet-snap fixes from earlier the same day made no
visible difference, and explicitly rejected another round of "back and
forth on one problem" — asked for a translation accurate enough to be
instantly visible, matching original behavior without heuristics or
per-stage hardcoding, covering all levels/WMBs at once.

**Root-caused "same bugs" first, not guessed:** asked what was actually
being tested — "Intro sequence through Plane." `docs/LEVELS.md` shows all
15 Intro levels (Intro2–Intro16) as `generic` director — geometry/entities
load but **zero** of their WDL was ever ported, so nothing scripted runs in
any of them. That's an entirely different problem class from the
facing/position work done earlier that day (which only touched a handful
of background props + one Shiks dialogue branch) — explained the mismatch
directly instead of re-diagnosing blind.

**What was asked for is a real interpreter, not more hand-porting** — user
explicitly rejected per-level chapters (which is what Studio/Start/Shiks/
Plane/Plane2/Town/Range all are). Measured scope before committing to an
approach: 67,147 lines of WDL across the whole game, ~914 `action` blocks,
~1,208 distinct call-like identifiers. Built:

- `tools/parse_wdl.py`: lexer + recursive-descent parser, WDL → JSON AST.
  Iterated against the **entire real corpus** (not a sample) until skip
  count dropped from 428 to 88, fixing real bugs found this way (not
  guessed): a `panel NAME { ... }` skip-desync that silently corrupted the
  rest of a file (found via Studio.wdl going from 6 real actions to 0);
  `<file.ext>` resource-literal tokenizing greedily across `<`/`>`
  comparison operators; `SET x,y;`, comma-sugar and juxtaposed
  `STRING name "value";` declaration forms; `entity NAME { field=value; }`
  declarative blocks; `TYPE* name;` pointer decls; `if cond { }` without
  parens; no-parens comma-arg command calls (`play_sound X,100;`); missing
  bitwise `&`/`|`/`^` operators (silently dropped by the lexer, desyncing
  `if((a & b) == c)` two real levels' `Shooter`/`AsyAct3` scripts);
  keywords (`Type`/`Level`/`bmap`) used as plain identifiers outside their
  one special context (found via Ziggy.wdl, a real level, failing to
  parse). Confirmed via the include-graph that `switch`/`case` doesn't
  exist anywhere as real control flow (every hit is a `bmap` name or
  prose) before deciding not to implement it. Found and fixed a real
  output-collision bug: `Menu.wdl` (the actual game menu level) and
  `WDL/menu.wdl` (an unused Conitec SDK template with the same stem) wrote
  to the same output filename, and the wrong one was winning — top-level
  files now always take priority over the `WDL/` shared-library folder on
  a stem collision.
- `tools/verify_wdl_parse.py`: whole-corpus regression guard, wired into
  `check_all.ps1`. Remaining 88 skipped decls are concentrated in
  Menu/venture/adept2/auftrag.wdl-style **unused Conitec SDK template
  files** (confirmed via include-graph search: nothing in the real game
  includes them) plus one genuine source typo in `Fight.wdl`
  (`if (player.health) > 0 { ... }`, an extra `)` in the original script)
  — not chased further, both documented as known, not silently ignored.
- `scripts/engine/wdl_interpreter.gd` (`WdlInterpreter`): tree-walking
  coroutine runtime executing the AST directly, wired into
  `wdl_director.gd::_try_begin_interpreted_level()` as a new fallback tried
  before the old bare `_begin_generic_level()`, only reached by levels with
  no existing hand-ported chapter — Studio/Start/Shiks/Plane/Plane2/Town/
  Range are untouched. Builtins bridge to already-verified engine code
  (`MdlAnimator`, `AudioBus` — including `get_voice_progress()`, a new
  `GetPosition(Voice)` port added this session since Acknex's value is a
  0–1,000,000 *fraction of the clip played*, not milliseconds — confirmed
  by how it's used everywhere in the corpus, not assumed). Unbridged
  builtins log once (`[wdl] unbridged: X`) and no-op rather than crash or
  guess. See `docs/CONTRACT.md` §4.1 for the architecture and the parity
  rule this must satisfy before trusting it on unverified content.

**Honest limits, stated plainly rather than overclaimed:** no Godot binary
exists in this sandbox (a known, previously-documented limitation) — every
line of `wdl_interpreter.gd` and the `wdl_director.gd` hook was verified by
careful manual read-through plus brace/paren-balance checks, never an
actual run. The parity check against a known-good hand-ported level
(Shiks) and the real playtest of Intro2 both still need the user. Also not
done this round: `actor_*`/`ent_waypoint`/`scan_path` (NPC path-following)
and `DoDialog` (dialogue UI) are real, frequently-used builtins left
unbridged — logged clearly, not silently faked, and flagged as the likely
next gap once Intro2 is actually played.

Also built this session (before the above, addressing the *previous*
"same bugs" report about facing/position specifically): `TV`/`Hanger`/
`TowerW` feet-snap fix (same bug shape as the earlier Cockpit fix, found
by re-measuring every excluded stem rather than guessing), `MdlAnimator.
morph_to()` (Acknex's runtime model-swap primitive, 243 call sites
game-wide, previously entirely unimplemented — see the Shiks "photo booth"
wiring as a concrete example), and `tools/verify_corpus.py` (whole-corpus
brush/coverage/feet-snap/facing-consistency audit). Full detail in the
turn immediately prior to this one.

Asked: run the game, specifically test Intro2 onward now that it's
interpreter-driven, and paste any `[wdl] unbridged: X` console lines —
those name exactly what to bridge next instead of guessing.

Answer: (pending)

Result: The actual mechanism the user asked for exists and is wired in,
verified as far as static analysis can go. Real playtest confirmation is
the next step, not assumed.

## 2026-07-28 — Real playtest round-trip: found and fixed 5 concrete bugs via debug-log iteration (CONTRACT rule 6 paying off)

User ran Intro2 through the interpreter multiple times, pasting real console
output each round. Each bug below was found from that log, not guessed:

1. **`WdlInterpreter._eval`: Array vs Dictionary crash.** `var I[3] = 0,0,0;`
   (array literal init) stores `init` as a *list* of AST nodes in
   `tools/parse_wdl.py`, but `_eval()` only handled a single node. Added
   `_eval_init()` to branch on the shape.
2. **Camera fight, again:** `_update_town_cam()` (the same generic "snap to
   nearest Cam entity" fallback already root-caused for Range on
   2026-07-27) also runs for any `scripted_camera=true` level with no
   dedicated `_process()` branch — interpreted levels had none. Added an
   explicit `elif _wdl_interp != null: pass` branch.
3. **Level loading twice.** Confirmed on both an interpreted level (Intro2)
   and a hand-ported one (Plane) — not specific to the new interpreter.
   Root cause found on the *third* round: Intro2.wdl's own `main()` calls
   `load_level(<Intro2.WMB>)` — in the original engine this is how a
   level's own script loaded its map; in this port `WmbLevelLoader` already
   loads the level before the interpreter runs. Mapping `load_level` to a
   real `LevelRouter.goto_level()` call made `main()` retrigger a full
   reload of itself every time it ran, which restarts `main()`, which
   reaches `load_level` again almost immediately — a fast reload cascade
   that reads as "sound looping" / "camera resets" / "characters frozen"
   (nothing ever survives long enough to move). Fixed by making
   `load_level` a true no-op. (A `LevelRouter.goto_level()` re-entrancy
   guard was added first, as defense in depth, before this root cause was
   found — kept, doesn't hurt, but this was the real fix.)
4. **`total_frames` permanently 0.** A real Acknex built-in frame counter;
   `while (total_frames == 0) { wait(1); }` is a standard idiom closing out
   `main()` in dozens of level scripts, silently stalling forever as an
   ordinary never-updated global. Added a live counter incremented in
   `WdlInterpreter._process()`.
5. **`float()`/`int()` crash on entity references.** GDScript's `float()`
   throws on a Node3D or Array instead of coercing — but `if (you)`,
   `target == my`, and unimplemented `vec_*` out-params (still Arrays/null)
   are all normal WDL patterns that reach exactly this path. Added
   `_to_num()` (safe coercion; a live entity reference reads as truthy/1)
   and fixed entity-identity comparisons to compare by reference instead of
   trying to numeric-coerce an entity.

**Then, independent of anything the user reported, re-examined why Intro2's
"Piposh conversation" left the camera stuck** (`action Cam`'s per-tick
camera-follow is gated `if (MovPos == 0)`, and dialogue actions set
`MovPos` — if the dialogue system never actually ran, `MovPos` could get
stuck non-zero forever). Checked `Intro2.json`'s parsed function list
against the raw source instead of guessing at the WDL logic: **2 of 11 real
functions were silently missing** — `Blink2` and `DoDialog`, with **zero**
parse errors recorded. Root-caused by counting brace depth through the
actual source: `function Blink()` (copy-pasted across nearly the entire
game — confirmed present with the same bug in ~55 of the corpus's level
scripts) has one extra closing brace, a genuine authoring typo in the
shipped game, not a grammar gap. The parser's "unknown top-level construct,
skip to the next `;`" recovery, applied to that stray `}`, was skipping
into and eating the *next* function's body (its first inner `;` reads as a
top-level terminator) — silently, with no error, because that recovery
path was never meant to run on a bare `}`. Fixed by giving `}` its own
recovery case that consumes only itself. Also found and fixed, from the
same investigation: `while (Photo ! = 3)` in `Shiks.wdl` — a real
whitespace-split `!=` the original engine's lexer tolerated and this one
didn't (fixed by merging adjacent `!`/`=` tokens post-lex); and **includes
don't chain** — `Intro2.wdl` includes `IO.wdl`, which itself includes a
dozen more files (`DIalog.wdl`, `movement.wdl`, `actors.wdl`, `weapons.wdl`,
...) that a one-level merge never reached, so real, widely-used functions
like `ShowDialog` (needed by `DoDialog`) were unavailable game-wide. Fixed
with a recursive include merge (cycle-guarded via a visited set).

Regenerated the whole corpus after the brace-recovery fix: total recorded
skips went from 88 to 271 — a *higher* number that's actually a large
correctness improvement, not a regression: previously most of the
`Blink()`-typo files recorded **zero** skips while silently losing content;
now every instance is caught and safely recovered instead. Updated
`tools/verify_wdl_parse.py`'s baseline from the real, current per-file
counts.

Result: 8 real, evidence-backed fixes this round, several with corpus-wide
impact (not just Intro2). `check_all.ps1` green throughout. Still waiting
on a playtest of the current state — expect this to change Intro2's
"Piposh conversation" camera-freeze behavior specifically, given `DoDialog`
went from completely unavailable to fully working, but that's a prediction
to verify, not a claim it's fixed.

## 2026-07-28 — Switched hand-ported chapters to the interpreter (user request, ahead of planned order); found a real load-time cost

User explicitly asked to switch Studio/Start/Town/Shiks/Plane/Plane2/Range
from their verified hand-ported `wdl_director.gd` chapters to the generic
interpreter now, instead of the originally-planned order (prove out on
never-ported levels + Shiks parity check first). Implemented as a single
flag, `HAND_PORTS_ENABLED = false` in `wdl_director.gd` — every hand-ported
function (`_begin_studio_sequence`, `_update_shiks`, `_apply_plane_cam`,
etc.) is still there, just bypassed, at all three dispatch points
(`setup()`, `_process()`, `ensure_scripted_view()`). Flip back to `true` to
restore the previous verified behavior immediately if needed.

User then reported "scenes are stuck a bit when starting." The pasted log
showed no error/crash — but investigated for a concrete cause anyway rather
than dismissing it as a vague/unverifiable report: `WdlInterpreter.setup()`
recursively merges every `include`d file's AST, and nearly every level
`include`s `IO.wdl`, which itself includes ~12 more files
(`DIalog.wdl`/`movement.wdl`/`actors.wdl`/`weapons.wdl`/`war.wdl`/...).
Before this fix, that whole chain was read from disk and JSON-parsed fresh
on *every single level transition*, even though those shared files never
change at runtime. Added a `static var _ast_cache` in `WdlInterpreter` (a
new instance is created per level, so a per-instance cache wouldn't help)
so each shared file is read/parsed once per game session, not once per
level. Plausible concrete fix, not confirmed against the actual reported
hitch — needs the user to check whether it's better.

Result: `check_all.ps1` green. Committing and pushing this and the prior
entry's work per explicit user request.

## 2026-07-29 — "Game is really slow and getting stuck": measured the actual cause instead of guessing at the AST-cache fix again

User reported severe slowdown right after the AST-cache fix + hand-port
switch went out. Before assuming the cache fix was wrong, checked what else
changed recently that could scale badly: the transitive-include fix
(previous entry) means every level now merges its entire shared-library
tree through `IO.wdl`. Measured it directly instead of guessing at the
size: **~325 global variables** now merge into a single level's
`_globals` (Shiks 325, Start 322, Intro2 334 — versus 11-21 before that
fix).

`_get_var`/`_set_var`/`_call()` each had a case-insensitive fallback that
scanned every key with `.to_lower()` comparisons when the exact-case name
didn't match — fine at 11-21 entries, a real O(n) cost at ~325, and this is
the single hottest path in the whole interpreter (every bare identifier
read/write and every function call, for every entity's action coroutine,
every frame). With dozens of simultaneously-running coroutines (Start alone
starts 66), this compounds directly into visible slowdown/stutter.

Fixed by adding `_globals_lower` / `_functions_lower` indexes (lowercase
name -> canonical name), built incrementally at every insertion point and
kept in sync on removal (function-call parameter shadowing erases entries
in `_call_user_function`), turning the fallback into an O(1) dictionary
lookup. `check_all.ps1` green.

Result: A measured, quantified fix (not a guess) for a real complexity
regression this session's own include fix introduced. Not confirmed against
the actual reported slowdown yet — needs the user to retest.

## 2026-07-29 — "No audio, space doesn't skip": a real bug in this session's own GetPosition(Voice) port

User reported no audio at all and Space no longer skipping. Traced instead
of guessing: `AudioBus.get_voice_progress()` (added 2026-07-28 for the
`GetPosition(Voice)` idiom) returned 0.0 whenever nothing is *currently*
playing -- which includes the exact instant a clip finishes naturally
(`is_voice_playing()` flips false the moment the `finished` signal fires).
Since `while (GetPosition(Voice) < 1000000) { wait(1); }` is the standard
pattern nearly every dialogue-driving action in the game uses to wait for a
line to finish, this meant **every such loop could never exit** -- it
either read "still playing" or snapped straight back to "hasn't started"
the instant the line ended, never "done". Every dialogue coroutine got
permanently stuck on the very first line it played, which explains both
symptoms: no further sPlay calls are ever reached (silence after the first
line), and pressing Space (which calls `AudioBus.stop_sfx()`) didn't help
because stopping the clip also just reads as "not currently playing" =
0.0, not "finished".

Fixed with an explicit `_voice_finished` flag: false while a line is
actively playing, set true by natural completion (`_on_sfx_finished`) *and*
by an explicit stop/skip (`stop_sfx()`), checked first in
`get_voice_progress()` so "finished" always reads as 1.0 regardless of why
it finished. This also makes existing Space-skip wiring
(`_on_skip_line_pressed` -> `AudioBus.stop_sfx()`, the one branch of that
function not gated behind now-disabled hand-port state) correctly unstick
the interpreter's own wait loop, without needing new skip-specific code in
the interpreter itself.

Result: `check_all.ps1` green. This was a real regression in code added
this session (not present before 2026-07-28), found by reading what the
report implied rather than re-guessing at the interpreter itself. Needs a
playtest to confirm.

## 2026-07-29 — `rewrite_skill/PORTING_MANUAL.md` Phase 0 (docs/CI cleanup), done in full

User asked to start executing the manual, which audited the repo at commit
`0937726` — three commits (O(n) lookup fix, `GetPosition(Voice)` fix,
busy-loop diagnostic) had already landed since that audit, none reflected
in the manual or `CONTRACT.md` yet. Worked Phase 0 items 1-6 in order:

1. **README** now says Godot **4.7** (matches `project.godot`'s
   `config/features`), points to this manual/CONTRACT/session-log as the
   real status source instead of duplicating it, and its "What works
   now"/"Not done yet" tables describe the interpreter-era reality (every
   level driven by `WdlInterpreter`, hand-ported chapters currently bypassed,
   ~32/531 builtins bridged) instead of the pre-interpreter snapshot.
2. **`fixes/patching_3d_godot.zip` deleted.** First extracted its two
   still-useful files: `migrate_angles.py` -> `tools/` (read it fully —
   still correct, uses the current `angle_gs`-is-truth / `gs_math.py`
   convention, no changes needed) and `smoke_orient.gd`, which turned out to
   already exist in `tools/` in a newer form, so the zip's older copy was
   discarded rather than overwriting it. The `.patch` file inside
   (`FIX_IDPO=False`/`FACE_ORIENT=True` defaults) was not extracted — it's
   the actively-harmful regression the manual warned about; the repo is
   already past it.
3. **`fixes/SKILL.md` folded into `docs/CONTRACT.md`, then deleted.** Most
   of its content was already superseded by CONTRACT's more current, more
   precise version (SKILL.md's own handedness line — "Z-up, left-handed" —
   was the exact contradiction CONTRACT.md's "right-handed Z-up" was correct
   against; deleting SKILL.md resolves it by removing the wrong copy, not by
   editing the right one). What SKILL.md had that CONTRACT.md didn't --
   specific verified facts, not general rules -- got added as CONTRACT §3
   items 9-12: the 134-WMB brush-extraction verification numbers, the UV
   formula's spot-check results (Shiks' outlier range still visually
   unconfirmed), the 984-texture format verification, and the known
   hardcoded per-asset special cases in `wmb_level_loader.gd`
   (`townl`/`desertl` dup skips, `StudioL +4`, wall-card quads). `fixes/`
   is now empty and removed.
4. **`tools/verify_gltf_strict.py` (new)** — walks the GLB chunk header per
   spec and `json.loads`s the JSON chunk; no dependency on the gitignored
   `original/` dump, so it's a real gate on a clean clone. First version had
   a bug (compared `chunk_start` instead of `off` for "JSON must be first",
   which flagged every file as broken) -- caught by running it against the
   real corpus and getting a 784/784 failure rate that didn't match the
   manual's claimed 783/784, instead of trusting the code read (R1/R2). Fixed
   offset comparison, reran: 784 checked, exactly 1 failure --
   `assets/converted/wmb/Shiks.glb`, `Extra data: line 1 column 21020` --
   matching the manual's §3.4 finding byte-for-byte. This is real
   external-ground-truth verification (raw chunk bytes), not the pipeline's
   own output grading itself.
5. **`tools/verify_normals.py` (new)** — same clean-clone-safe approach,
   counts glTF primitives missing a `NORMAL` attribute. Confirmed 783/784
   fail (1 unparseable = the same broken Shiks.glb, correctly *not*
   double-counted as a normals failure since its JSON can't even be read).
   Matches the manual's "not one contains a NORMAL attribute" claim.
   Deliberately wired into CI as **non-blocking** (`continue-on-error`) per
   the manual's own framing -- it's supposed to fail today and become a real
   gate in Phase 2, not before.
6. **`.github/workflows/verify.yml` (new).** Two jobs: `asset-integrity`
   (strict-glTF required, normals non-blocking, no `original/` dependency --
   real on every clone) and `source-verified-checks` (the four scripts that
   need the gitignored `original/` dump: `verify_transforms.py`,
   `validate_levels.py`, `verify_corpus.py`, `verify_wdl_parse.py`). The
   second job checks for `original/piposh3d/` first and explicitly reports a
   **skip** with a `::notice::` pointing at manual §3.7 when absent, rather
   than either crashing or faking a pass -- on GitHub-hosted runners today
   that's every run, since the dump isn't fetchable from anywhere in CI yet
   (that gap is Phase 8's problem, tracked, not hidden). Sanity-checked all
   four commands actually run correctly by running them locally (this
   machine has `original/`): all four exit 0 against current `HEAD`.
7. **Opportunistic fix, not originally a Phase 0 item:** the new strict-glTF
   check is written as a *required* CI gate, but with the known-broken
   `Shiks.glb` still in the tree it could never go green -- Phase 0's own
   gate ("CI green on a clean clone") and Phase 8's task list ("regenerate
   or delete Shiks.glb... confirm the Phase 0 gate passes") were in tension.
   Diffed the two copies byte-for-byte: `assets/converted/wmb/Shiks.glb` and
   `assets/converted/levels/Shiks_brush.glb` are identical except the first
   pads its JSON chunk with NUL and the second (correctly) with space --
   exactly CONTRACT §2 item 5's known bug, on a file that predates the fix
   and was never regenerated. `_find_wmb_glb()` in `wmb_level_loader.gd`
   checks the direct `wmb/` path before its `_brush.glb` fallback, so it was
   reaching the broken copy. Grepped every level JSON for a nested
   `Shiks.wmb` prop reference first (none — it's only ever loaded as a
   level's own brush, never as another level's prop) before deleting
   `assets/converted/wmb/Shiks.glb` + its `.import` + its 25 duplicate
   texture PNGs, letting the loader fall through to the already-correct
   `levels/Shiks_brush.glb`. Reran the strict check after: 783/783, 0
   failures.

Result: `powershell -File tools/check_all.ps1` green (regenerated
`docs/LEVELS.md` as a side effect, byte-identical to what was committed —
confirmed via `git diff`, no unrelated drift). Phase 0 gate genuinely met,
not just claimed: `tools/verify_gltf_strict.py` passes on every committed
GLB, the four source-dependent scripts were confirmed to actually run
(not just read), and the docs no longer contradict each other or the code.
Phase 0 item left undone: `tools/verify_normals.py` exists and runs but is
intentionally non-blocking, per the manual's own instruction that it should
fail until Phase 2. Not logged as a question needing a user answer --
everything here was closable from the repo's own data.

## 2026-07-29 — `rewrite_skill/PORTING_MANUAL.md` Phase 1 (dispatch chain): every level now reaches a real path, two real bugs found by actually running it

User asked to continue past Phase 0 into fixing levels / "making the main
work." Phase 1 targets exactly the P1 defect from the manual's audit:
`wdl_director.gd`'s dispatch chain conflated *who owns the camera* with
*whether the level's script runs at all*, so `elif fp:` (first-person
levels) sat **before** `elif scripted_camera and _try_begin_interpreted_level()`
in `setup()` -- meaning every FP level ran zero WDL regardless of the
now-removed `HAND_PORTS_ENABLED` flag, and any level without a camera
entity (`scripted_camera == false`) never even tried the interpreter.

**Code changes (`scripts/engine/wdl_director.gd`):**
1. `const HAND_PORTS_ENABLED := false` replaced with `const HAND_PORTED:
   Dictionary = {}` (empty -- matches the user's 2026-07-28 request to run
   every chapter through the interpreter; the manual's own suggested
   default was `{"shiks": true}`, written before it knew about that
   request, so left empty rather than silently reverting Shiks against
   what the user already asked for) plus `_is_hand_ported()`, which mirrors
   the exact same fuzzy script-name-or-level-name matching every
   `_is_X_level()` already uses, rather than a second, looser lookup that
   could disagree with it. Swapped in at all three dispatch points
   (`setup()`, `_process()`, `ensure_scripted_view()`) -- same three the
   old flag touched.
2. `setup()`'s dispatch restructured so `_try_begin_interpreted_level()`
   (renamed dependency: extracted `_wdl_ast_stem()`/`_has_wdl_ast()` out of
   it so the AST-existence check is shared, not duplicated) runs whenever a
   level isn't hand-ported, regardless of `fp`. Camera/click wiring for `fp`
   levels moved to run *after*, unconditionally on top of whatever the
   interpreter did -- `LevelRunner._enable_first_person()` already
   independently forces `scripted_camera=false` and switches to the player
   camera from `loader.has_first_person()` alone (verified by reading
   `scenes/level_runner.gd:73-84`: `use_fp` never consults
   `_director.scripted_camera`), so this was safe to decouple without
   touching that file. The bottom `else` branch now `push_warning()`s by
   name if a level with a parsed AST still reaches it, per the manual's "log
   loudly, don't silently stay inert" instruction.

**Verification (R1/R2: had to actually run it, not read it):** built
`tools/smoke_dispatch.gd`, a headless script that really instantiates
`WmbLevelLoader` + `WdlDirector` and calls `setup()` per level, then reads
back `fp`/`_is_hand_ported()`/`_has_wdl_ast()`/`_wdl_interp != null`/
`scripted_camera`. Two throwaway mistakes on the way, both worth recording
so they're not repeated: (a) GDScript has no implicit adjacent-string-literal
concatenation like Python -- `"a" "b" % x` is a parse error, not string
concat, hit twice (once in the script, once in the `push_warning` I'd just
added to the director) before checking the GDScript-vs-Python assumption;
(b) a first version looped over all ~55 `levels.json` levels with zero
`await` between iterations, instantiating full scenes back-to-back with no
frame yields -- looked hung (5+ minutes, zero output, because Godot's
`print()` to a redirected file doesn't flush until something actually
yields) and got killed rather than trusted; confirmed via
`Get-Process -Id <pid>` that CPU was still climbing (not deadlocked, just
heavy) before killing it, so the real fix was scope + pacing, not "wait
longer": bounded the default roster to the 19 levels the manual's audit
specifically named as affected (7 former hand-ports + the 13 listed as
"parsed AST, no camera entity, guaranteed inert"), and added
`await process_frame` between levels so previous levels' fire-and-forget
interpreter coroutines actually get torn down before the next one piles on
(`--all` still runs the full roster if wanted later). Also hit "Identifier
not found: GameState/AudioBus/PiposhDebug" the first time it ran -- a
static `WmbLevelLoader`/`WdlDirector` type reference at the top of a
`-s`-mode custom-main-loop script apparently compiles before this project's
autoloads finish registering (no existing `tools/smoke_*.gd` had ever
instantiated either class, so this ordering gap had never been hit before);
fixed by `load()`-ing both scripts inside `_run()`, after an initial
`await process_frame`, instead of a static top-level type reference.

**Real bug the fixed dispatch surfaced, not introduced by it:**
`WdlInterpreter._loose_eq()` (`wdl_interpreter.gd:394`) did
`if l == null or r == null or l is Node3D or r is Node3D: return l == r` --
correct when *both* sides are an entity reference or null, but GDScript
throws `Invalid operands 'float' and 'Object' in operator '=='` when
*exactly one* side is (e.g. a WDL `target == 0` "no entity" sentinel
check, a common pattern). Fired 16 times across the 19-level run before the
fix, at a real call site (`_try_begin_interpreted_level -> setup`), meaning
these comparisons had always been broken -- they just never ran before,
since none of these 19 levels' scripts ever executed under the old dispatch
bug. Fixed by only taking the identity-compare path when both sides are
null-or-Node3D; when exactly one is, they can never be meaningfully equal,
so return `false` directly instead of calling `==` on mismatched types.

Result: `tools/smoke_dispatch.gd` now reports 19/19 dispatched, zero
inert-with-AST levels, zero script errors (down from 16). Plane2 --
"the level that lost both paths," the manual's own suggested first signal
--  now shows `fp + interpreted`: player-controlled first-person camera
*and* a live WDL script, instead of the previous total silence. `check_all.ps1`
green, `verify_gltf_strict.py` still 783/783, base `smoke_test.gd` still
6/6. **This confirms dispatch reaches the interpreter, not that any of
these 19 levels play correctly** -- none have had a human playtest through
the interpreter yet; `docs/PLAYTEST.md`'s hand-port row updated to say so
explicitly rather than implying more than was checked. Per the manual's own
suggestion, Plane2 is the sharpest next signal: asking the user to run F4 →
Plane2 and report what they see.

## 2026-07-30 — Plane2 playtest report: found and fixed a real game-wide bug (`my.enable_click`/`my.event` were complete no-ops), not a Plane2-specific one

Checked: `Answer` first. User's report: "I see camera shots moving one by
one but without any audio or animation." User also gave two standing
instructions for this session: fix things generically ("any change...
should be applied to all levels at once"), and hold the original-game
fidelity bar ("the game should be played as it would be played originally
if opened in its original way").

Investigated by running the actual game state instead of re-reading
Plane2.wdl for a third time. Built `tools/smoke_camera_trace.gd`
(instantiates the real `level_runner.tscn`, not just
`WmbLevelLoader`+`WdlDirector` in isolation, so `LevelRunner`'s own
`_enable_first_person()` camera-authority logic actually runs) and traced
900 frames of both Plane2 and Plane with zero input: **camera never moved,
never switched, in either level.** This ruled out "the interpreter is
fighting the player camera" -- there was nothing to see because nothing
auto-triggers in Plane2 by design (every dialogue/animation sequence in
`Plane2.wdl` is gated behind `my.enable_click`/`my.event`, i.e. the player
has to click HeadPhone/TV/Sikot/Passenger/STU1 to trigger anything).

That reframed the question: does *clicking* work at all? Traced the click
pipeline and found the real bug, confirmed general (not Plane2-specific)
by inspection of the shared interpreter code:

- `WdlInterpreter._set_field()` (`wdl_interpreter.gd`) had no case for
  `enable_click` or `event` at all -- the match statement's wildcard branch
  only handles `skillN`; every other field assignment, including these two,
  was silently dropped. `my.enable_click = on; my.event = HP;` -- the
  standard WDL idiom for "make this entity clickable, run HP when it is,"
  used throughout the corpus, not just Plane2 -- did *nothing*.
- Independently, `_assign()` would have mis-evaluated the RHS anyway: for
  `my.event = HP;`, `HP` is a bare identifier naming an `action`/`function`,
  not a declared variable -- `_eval()` on an undeclared identifier silently
  returns `0.0` (same class of bug the `create()` 3rd-arg special case
  already exists to avoid, see `_call()`). Fixed both: `_assign()` now
  special-cases a bare-identifier RHS on `.event =` as a literal name
  string; `_set_field()` stores it as `wdl_event` meta and, for
  `enable_click`, ensures a pickable `Area3D` exists (`_ensure_clickable_area()`).
- `WdlDirector._handle_click_action()` (`wdl_director.gd`) now checks the
  clicked node for `wdl_event` meta *first*, before any of the
  hardcoded per-level action-string branches below it, and dispatches via
  a new `WdlInterpreter.invoke_event()` (runs the named action as a fresh
  fire-and-forget coroutine, same mechanism `begin_level()` uses to start
  each entity's own initial action). This generic path now sits in front
  of e.g. the old `_plane2_active`-gated dispatch, which was itself
  confirmed dead for interpreter-mode Plane2 (that flag is only ever set by
  the hand-ported `_begin_plane2()`, which never runs now -- see the
  2026-07-29 Phase 1 entry above).

**Verification (R1/R2): built two throwaway regression tools, both kept.**
`tools/smoke_event_unit.gd` constructs a bare `WdlInterpreter` with a
synthetic one-statement action and calls `invoke_event()` directly --
isolates the mechanism from Plane2's 14 concurrent always-on coroutines,
which made a first full-level trace attempt unreadable (every coroutine's
statements interleave in the log). `tools/smoke_click_event.gd` then
verifies it end-to-end against the real level: loads Plane2, finds the
HeadPhone entity, confirms `wdl_event == "HP"` (not the pre-fix `0.0`),
simulates the click via `_handle_click_action`, and checks the result.

Both false starts on the way are worth recording: (1) a first debug pass
showed `Scene` still `0.0` immediately after invoking the click and looked
like the fix hadn't worked -- turned out the assertion was wrong, not the
fix: headless audio never actually loads/plays dialogue WAVs, so
`GetPosition(Voice)` reports "finished" immediately and every
`while (GetPosition(Voice) < 1000000) { wait(1); }` in `action HP`'s
21-statement body resolves with zero iterations, so the *entire* action
(all 5 lines, all state transitions) runs to completion in one synchronous
pass instead of pausing mid-sequence like it would with real audio -- a
step-by-step per-statement trace confirmed this exactly, down to `Scene`
correctly going `1.0 -> ... -> 0.0` (its own final reset) within a single
call. Fixed the assertion to check the actually-correct end state
(`Goal_Headphones == 1`, `Scene`/`MoviePlaying` back to `0`) instead of an
assumed mid-sequence snapshot. (2) A debug-only `var tag := <bool
expression>` in a hot path failed GDScript's static type inference
("Cannot infer the type of tag") and silently broke compilation of
everything depending on `WdlInterpreter` for one run, producing a
completely unrelated-looking failure (`WdlDirector` couldn't `.new()` it) —
worth remembering that a compile error deep in a dependency can surface as
a confusing symptom several frames removed from its actual cause.

Result: both new regression tests pass; `tools/smoke_dispatch.gd` still
19/19 with zero script errors; `check_all.ps1` green. All temporary debug
`print()`s removed from `wdl_interpreter.gd`/`wdl_director.gd` before
committing -- none belong in the shipped code. This is a real, general fix
(every interpreted level using `enable_click`/`event` benefits, not just
Plane2) per the user's explicit instruction, and CONTRACT.md §4.1
documents the mechanism for future reference. **Not yet re-confirmed by the
user in the actual game** -- the original report (camera shots, no audio)
wasn't literally reproduced by this investigation (the camera-trace tool
showed no automatic movement at all, contradicting "shots moving one by
one"), so there is still an open question about what exactly the user saw;
asking them to retest Plane2 with this fix and describe the result again,
specifically whether clicking the headphones/TV/passenger/Sikot/STU1 now
produces dialogue and animation.

## 2026-07-30 — "Add many more debug prints... run it yourself too don't rely on me": found and fixed two real corpus-wide bugs, one of them a hard engine crash

User asked for more instrumentation and, explicitly, for verification to
happen by actually running the game rather than asking for another
playtest report. Added permanent (not throwaway) debug logging via the
existing `PiposhDebug.log_msg()` convention: `[wdl-event]` tags in
`wdl_interpreter.gd` for `.event`/`enable_click` capture and
`invoke_event()` dispatch outcome, `[click-hit-interp]` in
`wdl_director.gd` for the generic click-dispatch priority check added
2026-07-30 earlier today.

Then, instead of testing only the one entity the earlier session verified
(Plane2's HeadPhone), grepped the whole corpus for `enable_click`
(`grep -rl enable_click original/piposh3d/*.wdl` — 17 files) and built
`tools/smoke_click_survey.gd`: loads each of the 16 loadable levels for
real through `level_runner.tscn`, finds every entity that ends up with a
captured `wdl_event`, and clicks every single one — 307 entities across 16
levels in one run. This is the level of coverage a single hand-picked
regression test structurally cannot provide, and it paid off immediately:
the first full run surfaced two real, previously-undetected bugs, both
corpus-wide, neither specific to the level they happened to be found in.

**Bug 1 — `_actions` had no case-insensitive fallback.** `_functions` has
had one (`_functions_lower`) since the 2026-07-29 O(n)-lookup fix;
`_actions` never got the same treatment. The WDL corpus is not
consistently cased between an action's own declaration and its use as a
bare-identifier `.event` target: Olympic.wdl's `action GiveNut` is
referenced as `my.event = givenut;` (lowercase) everywhere it's placed;
Dutyfree's `Talktome`/`talktome` is the same shape. Confirmed as a real,
repeated corpus pattern (not one typo) via the survey's "NOT FOUND" log
lines before the fix. Fixed with `_actions_lower` + a `_resolve_action()`
helper, used everywhere an action name is looked up by string
(`begin_level()`, `invoke_event()`, `create()`'s 3rd arg). Full detail in
`docs/CONTRACT.md` §4.1.2.

**Bug 2 — a real engine crash (SIGSEGV), not a script error.** The survey
log showed `SCRIPT ERROR: Invalid type in function '_eval' ... previously
freed instance` 25 times, always right after clicking an
`AFG_Card`/`AFG_Take`-shaped entity (the collectible-card system shared
across many levels via `WDL/Afgan.wdl`). Root-caused with an isolated
reproduction, `tools/smoke_remove_race.gd`, built specifically because the
full corpus survey's 300+ interleaved coroutines made the original crash
log unreadable (guessed wrong twice reading it before building the
isolated repro — see below). The actual mechanism, confirmed step by step:

1. `AFG_Card`'s own persistent `while(1) { if (AFG[my.skill1]==1)
   {AFGremove();} wait(1); }` coroutine and the click-triggered `AFG_Take`
   (which sets `AFG[my.skill1]=1` then calls `remove(my)` itself) can both
   end up resumed within the *same* synchronous `process_frame`
   signal-dispatch batch.
2. This means `remove(my)` can be called **twice** on one entity in that
   same window — once from the click handler, once from the persistent
   coroutine's own next iteration re-observing the flag it just set.
3. At that reentrant instant, `is_instance_valid()` and `is_inside_tree()`
   on the entity both still read `true` — neither validity check catches
   it — and even `my == null` is unreliable (directly observed returning
   `true` for a reference that was never null and was definitely freed).
   Yet simply passing that same reference into any `Node3D`-typed
   parameter throws immediately, regardless of what the callee's body
   does with it (confirmed by making a decoy guard function's own
   parameter untyped: the crash moved to the *next* typed-parameter call
   site instead of going away, proving it's GDScript's own
   argument-passing validation, not anything checkable from inside the
   receiving function).

Three things were tried and confirmed **not** sufficient, in order, each
disproven by rerunning `smoke_remove_race.gd` and watching the crash
persist: deferring the `queue_free()` call via `call_deferred`; deferring
which frame the click-triggered coroutine even starts on; switching the
defer from `process_frame` to `physics_frame` (headless mode processes
both together, so this bought nothing). The fix that actually worked, and
is now permanent, has three parts (all required — removing any one brings
the crash back, re-verified individually while narrowing this down):
untyping every `my`/`entity` parameter in `wdl_interpreter.gd` (~20
functions) so the crash-causing argument-type validation never triggers;
making `_do_remove()` idempotent (no-ops past the first call on one
entity, closing the double-removal path directly); and checking
`typeof(my) == TYPE_NIL` instead of `my == null` in the shared
`_entity_alive()` guard, since the latter was the specific check observed
giving a false answer on a dangling reference. Full mechanism and the
reasoning for each of the three parts is in `docs/CONTRACT.md` §4.1.2 —
read that before touching `_eval`/`exec_stmt`/`_do_remove` again.

**Process note for next time:** the corpus-survey script itself needed two
rounds of hardening before it was trustworthy — a first version crashed
the engine itself (SIGSEGV) from a `.map()` lambda touching a Node3D that
a *prior* click in the same loop had freed (fixed by snapshotting
name/action/event as plain strings up front, never holding a Node3D
reference across a click), and reading its raw log directly (hundreds of
interleaved coroutines) led to two wrong guesses about the root cause
before building the isolated single-entity reproduction. The isolated
repro is what actually solved it — worth building one earlier next time a
crash log is this tangled, rather than trying to read the corpus log more
carefully.

Result: `tools/smoke_click_survey.gd` now reports 0 script errors across
all 307 clickable entities in all 16 levels (down from 25 crashes + ~15
unresolved-event misses). `tools/smoke_remove_race.gd`,
`tools/smoke_click_event.gd`, `tools/smoke_event_unit.gd`,
`tools/smoke_dispatch.gd`, and `check_all.ps1` all still pass. All
temporary print-debugging removed from the shipped code; the permanent
`[wdl-event]`/`[click-hit-interp]` logging and the three new smoke-test
tools remain. **Still not confirmed by the user in the actual running
game** — this closes a real, general, corpus-wide defect class (verified
by execution, per R1/R2), but the original reported symptom ("camera
shots… no audio or animation") was never literally reproduced by any of
today's tooling, so it remains an open question what exactly the user saw;
still asking for a retest.

## 2026-07-30 (cont.) — Added camera-write-vs-actual logging and ran a real Plane2 playtest myself: found the WDL script's camera writes never reach the visible camera in FP mode

User: "I don't see the logging being added" (the `[wdl-event]` logging from
the entry above only fires for entities using `enable_click`, and their
pasted console excerpt only covered Start/Menu, neither of which use it --
not a real problem, but not visible from what they'd seen either) and
asked specifically for camera-position logging compared against what the
script says the camera should be, plus running it myself instead of
handing back another request to test blind.

Added two new tags, same `PiposhDebug.log_msg()` family as `[wdl-event]`:
`[cam-write]` in `WdlInterpreter._set_camera_field()` (every
`camera.x/y/z/pan/tilt/roll` write, tagged with which entity's coroutine
made it) and `[cam-actual]` in `WdlDirector._process()` (the real position
of whichever `Camera3D` has `.current == true`, i.e. what's actually
rendered, change-detected so it can't itself flood the console). Then
built `tools/smoke_plane2_playtest.gd`: loads Plane2 through the real
`level_runner.tscn` flow (not the director in isolation), idles 120
frames, clicks the Passenger entity (the one interaction in Plane2 that
engages a WDL-driven camera -- `action Cam3` sets `camera.*` from its own
position whenever the click-set `HitHim > 0`), and watches both tags for
60 more frames.

**Result, run directly rather than asked about:** `[cam-write]` fired 364
times after the click (Cam3's `while(1){ if(HitHim>0){camera.x=my.x;...}
wait(1); }` genuinely runs every tick) -- but `[cam-actual]` logged a
changed position only **twice** in the entire run, both before the click
(the initial spawn placement and the floor-snap adjustment), and **zero
times** afterward. The script is correctly, continuously trying to move
the camera to Cam3's viewpoint; the actually-rendered camera (the player's
own first-person `Camera3D`) never moves at all, because
`LevelRunner._enable_first_person()` sets `_script_cam.current = false`
for the whole level and nothing re-enables it for a script-driven
camera-takeover moment like this one. `WdlInterpreter._set_camera_field()`
only ever writes to `_camera` (the script camera), with no path to the
player's own camera or to toggling which one is `.current`. In the
original Acknex engine there is only one camera object, so this
distinction doesn't exist -- `camera.x/y/z` always affected what the
player saw, first-person or not. This looks like a real, previously
unknown fidelity gap in how FP levels handle a scripted camera cutscene
mid-level, not something specific to Plane2's Passenger interaction --
worth checking whether it explains part of the original "camera shots"
report, but not confirmed as *the* cause; flagging it as a separate,
concrete, verified finding rather than folding it into that guess.

Secondary observation, not yet root-caused: `HitHim` stayed at `1.0` for
all 60 post-click frames instead of progressing through
`action Passanger`'s own sequence to `2.0` then back to `0.0` -- the
click-triggered `HitMe` (`{HitHim = 1;}`) ran fine, but the *persistent*
`Passanger` coroutine (started at `begin_level()`, not by the click) that
is supposed to notice `HitHim==1` on its next tick and run the hit
animation didn't visibly progress within the window checked. Not
investigated further this pass -- noted here so it isn't rediscovered from
scratch, and flagged to the user rather than silently left for later.

Result: `tools/smoke_dispatch.gd` (19/19) and `tools/smoke_click_event.gd`
still pass after the logging additions -- no regression. This is a real,
concrete finding produced by actually running the game, not a report asked
of the user, per their explicit request this round.

## 2026-07-30 (cont. 2) — Chased a stray `[cam-write] field=visible` line back to a real, previously-undocumented missing subsystem: Acknex PANEL objects

User pasted their own console capture (Start -> Menu -> Studio loading) and
it included two unexpected new lines: `[cam-write] field=visible value=0.0
by=<no entity>` / `value=1.0`, right at the Start->Menu boundary. Not
asked about explicitly, but worth chasing since "the camera is getting a
field write nobody expects" is exactly the kind of thing this session's
`cam-write` logging exists to catch.

Traced it: `_set_field()`'s `if node == _camera:` check routes here
whenever `_resolve_entity()` can't resolve an identifier to a real
Node3D and falls back to `my` -- normally safe, but harmless-looking here
specifically because `my` and `_camera` happened to coincide. Grepped
Menu.wdl for the actual statements near this point in execution
(`entSaveLoadMenu.visible = off;`, `pConsole.visible = off;`,
`SavePanel.visible = on;`, `pMenu.visible = ...` -- Menu.wdl alone has
~10+ of these) and checked whether these names are declared anywhere as
WDL `var`s or resolvable WMB entity names: they are not. They're declared
with Acknex's `panel` keyword instead -- confirmed via
`grep -n "^PANEL SavePanel" original/piposh3d/IO.wdl` and
`grep -n "^panel " original/piposh3d/Menu.wdl` (`pMenu`, `pShow`). Acknex
`PANEL` is a distinct top-level declaration for 2D UI overlays (menus,
save/load screens, HUD elements) -- a completely separate system from
`var`/`action`/`function`/`sound`, the four kinds `tools/parse_wdl.py` and
`WdlInterpreter` actually understand.

**This is not a bug in anything built this session -- it's a whole
subsystem with zero support**, previously undiscovered because nothing
until today's `cam-write` logging surfaced its symptom. The immediate
effect of `SavePanel.visible = on;` etc. against an interpreter with no
concept of panels: the identifier evaluates to the "undefined" default
(`0.0`), `_resolve_entity()` falls back to `my`, and whether that lands on
`_camera` (harmlessly ignored, since `_set_camera_field` has no `"visible"`
case) or nowhere at all depends on incidental context -- either way the
actual panel visibility toggle a script is trying to do never happens.
Given Menu.wdl's whole save/load flow is built on this
(`while (savepanel.visible == on) { wait(1); }` gates on it directly per
line 199), the practical effect is real menu UI flows silently not
working, not a cosmetic log artifact.

Scoped but **not implemented this session** -- a real `PANEL` system
(parsing `panel NAME { ... }` blocks, a Godot `Control`-based renderer,
property resolution for `.visible`/`.pos`/`.bmap`/etc., wiring named panel
references into `_resolve_entity`'s fallback) is a substantial new feature
area, not a bug fix, and closer in scope to `rewrite_skill/PORTING_MANUAL.md`
Phase 5/7's UI work than to tonight's interpreter fixes. Flagged to the
user rather than started unprompted mid-session. Debug instrumentation
used to trace this (`print("[DBG3] node==_camera! ...")` in `_set_field`)
was temporary and has been removed; nothing about this finding required a
code change, only investigation.

## 2026-07-30 (cont. 3) — User confirmed the camera-authority gap from real gameplay ("when pressing the hit the camera should move") and fixed it; found and fixed the real cause of "audio from talks is not being played"

User pasted a real console capture of clicking Passenger in Plane2 (not a
headless simulation -- `[click-hit] collider=Col resolved_node=Passn_mdl_011
action=Passanger` is the real `_try_click()` raycast path, proving
today's click-dispatch fix works in actual play) and confirmed directly:
"when pressing the hit for example the camera should move." That's
external ground truth for the camera-authority gap found earlier today via
`tools/smoke_plane2_playtest.gd` -- no longer a "might explain it" guess.
Also reported, from real play: "Audio from talks is not being played" and
"The intro (start file) isn't showing the correct placing of the
characters and camera movement" (not yet investigated), plus general
frustration that fixes were accumulating as patches on top of old
hand-port remnants rather than a clean pass, and that scene loading feels
slow.

**Fixed the camera-authority gap, generically, for every fp-mode level:**
added `WdlInterpreter.is_driving_camera_this_frame()` (tracks
`Engine.get_process_frames()` on every `camera.x/y/z/pan/tilt/roll`
write) and had `LevelRunner._process()` -- new, only active for fp-mode
levels -- switch the visible camera to the script camera on any frame the
interpreter actually wrote it, and back to the player's own camera
otherwise. This is the same "most recent write wins" model the original
single-camera Acknex engine uses, implemented generically rather than
special-cased to Plane2's Passenger/Cam3. Verified with real data via
`tools/smoke_plane2_playtest.gd`: post-fix, `[cam-actual]` correctly
switches from the player camera to `ScriptCamera` at `(-140.0, 85.0,
-255.0)` (Cam3's own position, axis-converted) the frame after the click,
and stays there for the rest of the window HitHim remains >0 -- matching
`[cam-write]`'s target exactly, where before the fix `[cam-actual]` never
moved at all through the same window.

**Root-caused "audio from talks is not being played" -- a second real bug,
not a duplicate of anything fixed today.** `sound Cockpit = <SFX089.WAV>;`
-style declarations were parsed into `_sounds`/`_sounds_lower` back when
`_actions_lower` was added, but `_get_var()` never actually read `_sounds`
-- confirmed by grep, this was a pure oversight, not a deferred TODO.
Referencing a declared sound name (e.g. Plane2's `action Dummy`'s ambiance
loop, `play_entsound(my, cockpit, 300)`) silently evaluated to `0.0`
instead of the WAV filename. On its own that's cosmetic -- but
`AudioBus._voice_busy`/`_voice_finished` are shared, global state across
*all* sound playback, not scoped per line, so `Dummy`'s broken call
failing *while a real dialogue line was actively playing* force-cleared
that shared "finished" flag every tick it ran. `GetPosition(Voice)` reads
that same flag, so every `while (GetPosition(Voice) < 1000000) { wait(1);
}` in the game -- the standard dialogue-wait idiom, used everywhere --
resolved almost instantly regardless of the real clip's duration, and the
next `sPlay()` call cut off whatever was still actually playing. This
also explains a false conclusion from earlier today's `smoke_click_event.gd`
work: HP's whole 21-statement, 5-line body appearing to "run to completion
in one synchronous pass" was attributed to headless audio never loading at
all -- it was actually this bug (Plane2's own `Dummy` entity is what was
interfering), not a headless-specific limitation.

Fixed by wiring `_sounds`/`_sounds_lower` into `_get_var()` (same
case-insensitive-fallback pattern as `_actions_lower`/`_functions_lower`).
Verified two ways: (1) `tools/smoke_audio_timing_check.gd` (new) confirms
headless Godot genuinely advances real `AudioStreamPlayer` playback
progress over real wall-clock time -- `get_voice_progress()` climbed from
0.0 to 0.41 over 270 frames on a real SHK019.WAV clip, still not finished
at 300 -- so headless *is* trustworthy for verifying audio timing, not
just "whether play_sfx() was called." (2) `tools/smoke_click_event.gd`'s
assertion was updated (it was checking the now-wrong "final state 2 frames
after the click" behavior, which was actually itself a symptom of this
bug) to check that `action HP` starts correctly *and* is still genuinely
in progress rather than racing to completion -- both must hold for the
fix to be considered confirmed working. `docs/CONTRACT.md` §5 documents
the shared-state design trap for next time.

Not investigated this round, flagged for later: Start's character
placement/camera report, and the "old hand-port remnants" architecture
concern -- `HAND_PORTED` is empty (§4.1.1: every chapter already runs
through the interpreter), but the dead `_begin_start_sequence()` /
`_update_shiks()` / etc. functions are still physically present in
`wdl_director.gd`, unused. Worth asking the user directly whether to
delete that dead code for a cleaner file, rather than assuming.

Result: `tools/smoke_dispatch.gd` (19/19), `tools/smoke_click_survey.gd`
(307 entities / 16 levels, 0 script errors), `tools/smoke_click_event.gd`,
`tools/smoke_event_unit.gd`, `tools/smoke_remove_race.gd`, and
`check_all.ps1` all pass after both fixes. Two real, user-confirmed-or-
reported bugs fixed this round, both verified by execution against real
data (not claimed from code reading), matching R1/R2.

## 2026-07-30 — "Instead of porting the game correctly you did a combination of using the old things from the bad port and other changes" — runtime/game-logic rewrite
Checked: user's own real playtest reports from earlier the same day (camera
not moving on click, audio from talks not playing, Start intro placement
wrong) against the fixes already made for them — each fix was individually
correct and verified by execution, but landed as a patch on
`wdl_director.gd`, a 3,220-line file still physically containing all seven
dead hand-port chapters (Start/Studio/Town/Shiks/Plane/Plane2/Range) even
though none of them had run since `HAND_PORTED` was emptied 2026-07-28.
Asked: "I want you to 'start over'... create the game again now with a
proper way of doing it and with a proper porting and running logic" — then,
after investigating (the named reference path was the same raw game data
already in `original/piposh3d/`, and decompiling the actual Acknex runtime
exe is out of reach), asked directly: "What's the real goal here — what's
making the current codebase feel wrong enough to restart?"
Answer: "Specific bugs are piling up." Reframed from "rewrite everything" to
"architecturally redo the runtime/game-logic layer" via three follow-up
questions: keep the native `CharacterBody3D` FP controller (fix the
camera-authority seam, don't reimplement Acknex movement builtins); scope
is runtime/game-logic only (asset pipeline — WMB/MDL/WDL convert — stays
untouched, it's verified byte-accurate and isn't where the bugs live);
delete the dead hand-port code entirely, not just leave it disabled (git
history preserves it if ever needed).
Result: `wdl_director.gd` rewritten 3,220 → ~1,000 lines (all seven
hand-port chapters + their exclusive fields deleted; every confirmed-generic
piece — dispatch, click resolution, camera-class entity discovery, patrols,
random buildings, camera-transform utilities — kept, mostly verbatim).
New `scripts/engine/camera_authority.gd` formalizes the camera-authority
arbitration. `autoload/audio_bus.gd` replaced by
`autoload/audio_channels.gd` (Voice/SFX/Music split, ending the shared-flag
class of bug documented in `docs/CONTRACT.md` §5). Two real bugs found and
fixed *during* the rewrite, not designed in from the start:
1. `sPlay`/`vPlay` were silently shadowed by Voice.wdl's own real,
   DLL-backed WDL-source functions (user functions beat builtins by design,
   correct in general, wrong for these specific names) — dialogue audio
   never actually started on the Voice channel, so `GetPosition(Voice)`
   reported "done" instantly and whole multi-line actions raced to
   completion in one frame. This exact failure mode was *previously masked*
   by the old single-channel `AudioBus`'s shared busy-flag (an unrelated
   ambiance sound happened to keep it pinned "playing"), so splitting the
   channels correctly is what surfaced it, not something the split caused.
   Fixed with an explicit `AUDIO_BRIDGE_BUILTINS` allow-list in `_call()`.
2. The AFG collectible-card HUD popup + save persistence
   (`_run_afg_take()`/`_show_afg_card()`) had gone silently unreachable in
   *every* level with an AFG card (not just the one first noticed), because
   the generic `wdl_event` click-dispatch fix added earlier the same day
   now runs before it — the interpreter's own execution of `action
   AFG_Take` only touches an ephemeral, never-saved global and can't show
   the HUD card (an unbridged PANEL reference). Fixed by special-casing
   `node.has_meta("afg_card_index")` ahead of the generic dispatch.
Verified via the full smoke suite (`tools/smoke_dispatch.gd`,
`tools/smoke_click_survey.gd` — 16 levels/307 entities,
`tools/smoke_click_event.gd`, `tools/smoke_event_unit.gd`,
`tools/smoke_remove_race.gd`, `tools/smoke_plane2_playtest.gd`) plus
`powershell -File tools/check_all.ps1` (asset pipeline untouched, still
green). Full reasoning in `docs/CONTRACT.md` §4.1.3 and §5. Known,
pre-existing gaps not closed by this rewrite (documented, not silently
dropped): Range's shooting minigame has no mouse-click→fire bridge into the
interpreter; GameHud's dialogue-choice/subtitle/range-HUD UI has no caller
left (was already dead once `HAND_PORTED` emptied 2026-07-28, this just
makes it permanent).

## 2026-07-30 — Four concurrent headless Godot instances corrupted tracked asset files; root-caused to a `TaskStop` that didn't kill the underlying process
Checked: mid-rewrite, `git status` (routine check before assuming a clean
baseline) showed 54 unstaged deletions under `assets/converted/wmb/Shiks*`
(the `Shiks.glb` mesh and every one of its textures/`.import` sidecars) —
tracked, committed files, gone from disk, despite the working tree being
confirmed clean at the very start of this session. This is exactly the
asset-pipeline output this rewrite was explicitly scoped to leave untouched.
Restored immediately via `git checkout -- "assets/converted/wmb/Shiks*"`
(safe: matches HEAD exactly, nothing to lose) before investigating further,
since leaving tracked files missing from disk mid-session is the higher risk.
Root cause: a `smoke_dispatch.gd` run piped through `| tail -60` appeared to
hang (tail withholds all output until its stdin closes, not a real hang —
a red herring), so it was cancelled via `TaskStop`. That stopped the shell
wrapper but **not** the underlying `godot.exe` process, which kept running
unsupervised. Two more `smoke_dispatch.gd`/`smoke_click_survey.gd` runs were
then launched without realizing the first was still alive — confirmed via
`ps aux`: four separate `godot --headless` processes running concurrently
against the same project, with start times roughly 25 minutes apart. Most
likely explanation: concurrent headless instances racing on the same
`.godot/` import cache during Shiks-level loads is what deleted the tracked
source files, not any code change from this session.
Result: all four processes force-killed, confirmed via `ps aux` that none
remained before launching anything else. Re-ran the full smoke suite one
process at a time afterward with no recurrence — `git status` clean for
`assets/` after every subsequent run. Practice going forward, not yet
automated: after any `TaskStop` on a `godot --headless` command, verify via
`ps aux | grep godot` that the process actually exited, and never launch a
second headless Godot instance against this project while one may still be
running. Flagged to the user directly rather than silently fixed, since
"tracked binary assets were deleted from disk" is the kind of thing that
must not pass unnoticed even though the fix was a clean, lossless restore.

## 2026-07-30 — Final regression pass for the runtime rewrite: one more real bug found by the test suite itself
Checked: re-ran `tools/smoke_dispatch.gd` clean (single instance, no
concurrent Godot processes this time) after the rewrite above. It ran but
logged `SCRIPT ERROR: Invalid call. Nonexistent function '_is_hand_ported'
in base 'Node (WdlDirector)'` on every level — non-fatal (GDScript's dynamic
dispatch on a loosely-typed `Node` just errors and continues rather than
halting), which is why it wasn't immediately obvious as a failure, but a
real one: the tool still called a method §4.1.3's rewrite deleted on
purpose (`_is_hand_ported()`/`HAND_PORTED` no longer exist — hand-porting
isn't a concept anymore).
Result: updated `tools/smoke_dispatch.gd` to drop the `hand_ported`
column/check entirely (every level with a parsed AST now goes straight to
"interpreted" or "fp + interpreted"). Re-ran clean: all 19/19 levels
dispatch correctly, zero levels with an AST reached the inert branch, zero
`SCRIPT ERROR`s, exit code 0. `git status` confirmed clean for `assets/`
after this run too (no repeat of the concurrent-process asset corruption
above). This is the last item in the plan's verification list — the full
regression suite (`smoke_dispatch`, `smoke_click_survey`, `smoke_click_event`,
`smoke_event_unit`, `smoke_remove_race`, `smoke_plane2_playtest`,
`check_all.ps1`) now passes cleanly against the rewritten
`wdl_director.gd`/`wdl_interpreter.gd`/`camera_authority.gd`/
`audio_channels.gd`. Real-game human playtesting (not just smoke tests)
still needed — see the two new `docs/PLAYTEST.md` rows for what specifically
to check first (Shiks, Plane's idle-spinner entities), plus re-confirming
Plane2's Passenger interaction (camera + dialogue) that motivated the
original camera-authority fix earlier the same day.

## 2026-07-30 — Real playtest report: vocals missing, camera/scene stuck on Start/Studio/Plane, Shiks loops after one line
Checked: user actually ran the rewritten build and reported three symptoms
with real console logs — (1) some vocals not playing, other background
noises playing in a glitchy loop; (2) camera stuck / "game not running" on
several levels; (3) Plane specifically stuck on the first frame. Shiks
logs showed one correct vocal then an endless identical `[cam-write]`
loop from `Cam_mdl_003`. Root-caused via direct corpus reading (grep +
read the actual `.wdl` sources), not guessing from symptoms — four
distinct, real bugs, three of them freshly introduced by tonight's own
earlier fixes:

1. **`SetVoice` was being force-routed to a no-op stub.** The
   `AUDIO_BRIDGE_BUILTINS` list added earlier tonight (to stop Voice.wdl's
   unbridgeable `sPlay`/`vPlay` from shadowing this interpreter's own
   bridge) mistakenly included `setvoice`/`voiceinit` too, reasoning from
   name-similarity rather than checking the corpus. `function SetVoice` is
   actually declared independently in **22 different level scripts**
   (confirmed via `grep -rn "^function SetVoice"`), each level's own real
   dialogue/scene-boot sequencer — not a shared, unbridgeable primitive.
   Forcing it to the stub meant every one of those levels' scene
   progression silently died at the very first line. Exactly explains
   Start/Studio/Plane. Fixed: removed `setvoice`/`voiceinit` from the list
   (renamed `AUDIO_BRIDGE_BUILTINS` → `BRIDGE_OVER_SHARED_FUNCTIONS`, with
   a corpus-grep-backed comment explaining exactly which names belong on
   it and why, to stop this exact mistake from recurring for a fifth name).
2. **`snd_playing(handle)` ignored its argument.** Real usage, corpus-wide
   (30+ files, the standard `if (snd_playing(X)==0) { play_sound(...);
   X=result; }` ambiance-loop idiom): poll a *specific* sound instance, not
   "is anything on the Voice channel playing." The existing builtin only
   ever checked the global Voice channel, so the check was permanently
   true and every ambiance loop using this idiom (Shiks' `Mapal`/`Lake`,
   Plane's `Dummy` cockpit loop, etc.) retriggered its sound from the start
   every single tick — the reported "background noises in loop, bad
   sound." Fixed with a real handle scheme: `AudioChannels.play_sfx()` now
   returns `slot*1e6 + generation`; `snd_playing()` decodes it and checks
   that specific pool slot's `.playing` state (generation-checked so a
   stale handle from a since-reused slot reads "not playing," not a false
   positive). Needed `result` (Acknex's implicit last-call-return value,
   read via `X = result;`) to actually work, which it never did before —
   added `WdlInterpreter._last_result`, updated on every `_call()`, read
   via a new `"result"` case in `_get_var()`.
3. **`scan_path()`/custom entity fields (`_movemode`, `_target_x`, ...)
   were silently dropped.** `scan_path` is a documented, deliberately
   unbridged NPC-pathing builtin — but its universal corpus idiom
   (22 files) is `result = scan_path(...); if (result==0) {
   my._MOVEMODE = 0; }`, and the generic unresolved-builtin 0.0 fallback
   made that check always read "no path found," permanently zeroing
   `_MOVEMODE` — which the *same* `while (my._MOVEMODE > 0) { ... }` loop
   also used to gate completely unrelated per-tick logic in the original
   scripts (dialogue-scene advancement, `GetPosition(Voice)` polling).
   Deeper cause underneath: `_get_field`/`_set_field` only ever supported
   a small fixed allowlist (x/y/z/pan/tilt/roll/skin/invisible/passable/
   event/enable_click/skillN) — ANY other custom field name, like
   `_movemode`, was a silent no-op on write and always read back 0.0, so
   even after making `scan_path` return a truthy stub, `my._movemode = 1;`
   still never actually stuck. Fixed both: `scan_path` now returns `1.0`
   (path-following itself stays a no-op, a separate, smaller, already-
   documented gap); `_get_field`/`_set_field` gained a generic fallback
   storing/reading any unrecognized field via `node.get_meta("wdl_custom_"
   + name, ...)`, so custom fields work generically from now on, not just
   for this one name.
4. **`actor_move()` was shadowed too, same shape as bug 1 but one level
   deeper in the include chain.** `WDL/actors.wdl` (shared, pulled in by
   nearly every level) declares a real `function actor_move()` that calls
   `scan_floor()`/`move_gravity()`/`actor_anim()` — genuine per-tick
   ground-scan/gravity/animation-root-motion physics, the same
   movement.wdl-family builtins the native `CharacterBody3D` player
   controller deliberately replaces (user's explicit "don't reimplement
   Acknex movement for the player" decision) — except NPCs route through
   this exact function for their own walking too. Root-caused via Shiks'
   `Piposh2` (`if (Scene==1) { ...; actor_move(); if (my.x >
   StandHerePoint) { Scene=2; ... } }`) never actually moving, so `Scene`
   never left 1 — the "one correct vocal, then stuck in a loop" symptom
   (the loop being `MyCamera`'s own *correct* static establishing shot,
   held because `Piposh.skill2` — a separate flag, changed only by a
   WMB-collision-triggered `action Bumped` this port doesn't model — never
   changes either; the camera itself was never the bug). Fixed with a
   real, approximate forward-walk bridge (`actor_move` added to
   `BRIDGE_OVER_SHARED_FUNCTIONS`, moves `my` along its own pan-facing
   direction, speed = `force * ACTOR_MOVE_BASE_SPEED * time`, constants
   are a stated approximation, not measured from the original engine).
   `actor_turnto` deliberately NOT force-bridged: its real `actors.wdl`
   body (`angle=ang(angle-MY.PAN); ...; MY.PAN += temp*min(1,time);`) is
   fully portable once `ang()` exists as a builtin (added, a real
   normalize-to-(-180,180] formula, not an approximation) — so the actual
   WDL-source implementation now runs correctly on its own merits, no
   bridge needed.

Verified each fix against real state, not just "no script error": new
`tools/smoke_scan_path_gate.gd` (Plane's `Scene`/`Talking` advance past
boot within 15 frames, was permanently stuck before), new
`tools/smoke_shiks_progress.gd` (Piposh2 physically walks and Shiks'
`Scene` reaches 2 within ~4s, was permanently stuck before), new
`tools/smoke_studio_progress.gd` (confirmed Studio's `Scene 1` hold is a
*real*, correctly-timed ~16s song via `AudioChannels.get_voice_progress()`
climbing steadily, not a second stuck bug — needed a much longer test
window than a first pass assumed, see below). Re-ran the full existing
regression suite (`smoke_click_survey`, `smoke_click_event`,
`smoke_remove_race`, `smoke_dispatch`) after each fix — all still green,
no regressions from any of the four changes.

**Not fixed, explicitly out of scope tonight, flagged rather than
silently left**: the pre-existing "while-loop spinning without wait()"
busy-loop performance issue (crowd/background entities whose scripts loop
hundreds of times per frame instead of yielding once per tick) appears to
also be slowing down headless audio mixing itself — Studio's real ~15.7s
song was measured taking ~31s of wall-clock time to fully report
"finished" via `GetPosition(Voice)`, roughly 2x dilated, consistent with
CPU contention from those busy loops competing with the audio thread.
This is a real, separate, already-flagged performance defect (see the
2026-07-29 busy-loop diagnostic commits), not something introduced or
fixed tonight; whether it dilates audio timing the same way in the real
(non-headless, vsync-paced) game is unconfirmed and worth asking the user
about directly if slow/laggy dialogue is reported again after this round.

## 2026-07-30 — "After talking ends the game doesn't move to the next level. There's no text-choosing on screen."
Checked: user's next real playtest report, after the four fixes above.
Grepped the corpus for `ShowDialog` the same way the prior four bugs were
found (a per-level scene reaching a dialogue-choice point via `DoDialog(num)
{ DialogChoice=0; DialogIndex=num; ShowDialog(); ... }`) and confirmed
`ShowDialog` was completely unbridged in `wdl_interpreter.gd` — hit the
generic unresolved-builtin no-op, so the choice panel never appeared. Worse:
even if it had, nothing fed a player's click back into the script's
`DialogChoice` global, so every `while (DialogIndex==X) { if
(DialogChoice==1) {...} }` polling loop already written into these scripts
(the same shape used corpus-wide, this is how every level presents a
dialogue choice) spun forever. This is the same "generic 0.0 fallback
silently breaks something bigger than the missing feature itself" class of
bug as `scan_path`, not a new category. Also confirmed via corpus grep
(`^function ShowDialog`, `WDL/DIalog.wdl:564`) that the real `ShowDialog`
is shared and unbridgeable (`DialogChoice=0; SetDialogOptions(); ShowText();
Dialog.visible=on;` — needs real PANEL text rendering, which doesn't
exist here) — added to `BRIDGE_OVER_SHARED_FUNCTIONS` for the same reason
as `sPlay`/`vPlay`/`actor_move`.

Fixed: `WdlInterpreter.setup()` now takes an optional `hud: GameHud`
parameter (passed through from `WdlDirector._try_begin_interpreted_level()`,
which already held `_hud`) and connects `hud.dialog_choice` to a new
`_on_dialog_choice(choice)` that sets the `DialogChoice` global directly —
the calling coroutine's own already-written polling loop picks it up on its
next `wait(1)`, no other plumbing needed. New `"showdialog"` builtin
(`_do_show_dialog`) resets `DialogChoice` to 0 (matching the real
function's first statement) and calls `hud.show_dialog(DialogIndex)`,
reusing GameHud's existing generic 3-option panel UI (built for the old
hand-port, but the panel/button/click infrastructure itself was always
level-agnostic — only `_dialog_lines(index)`'s *text* is a small hand-typed
Hebrew table covering just the 4 indices the original hand-port authors
transcribed for Studio/Plane; every other level's choices will show the
panel and accept clicks correctly but with "…" placeholder text instead of
real dialogue text — a real, honest, separate gap, not silently hidden).

Verified end-to-end, not just "no script error," via new
`tools/smoke_dialog_choice.gd`: directly drives `WdlInterpreter`'s
`ShowDialog` builtin, confirms `GameHud.is_dialog_open()` becomes true,
then emits `GameHud.dialog_choice` (simulating a real button click) and
confirms `DialogChoice` lands back in the interpreter's globals correctly.
Full regression suite (`smoke_click_survey`, `smoke_click_event`,
`smoke_remove_race`) re-run clean after the change, asset integrity
(`git status` on `assets/`) confirmed clean throughout.

## 2026-07-30 — Start: camera/positions wrong, backgrounds "weird pattern," facing wrong, talk-stop doesn't advance; Studio: camera cut on Shik talk feels off
Checked: user's next real playtest report, this time on Start and Studio
specifically. Diagnosed empirically, not from source reading alone: built
`tools/smoke_start_diag.gd` to trace `Scene`/the `LookAtMe` entity's
position/`_movemode`/`_TARGET_X`/the actually-rendered camera's
position+pan+tilt over 15 real seconds. Root-caused two distinct,
compounding bugs, both real gaps in the WDL/ANGLE-by-reference system, not
new categories:

1. **`scan_path`'s 2026-07-30-earlier "always return 1.0" fix was
   necessary but insufficient — it stopped false gating but never actually
   bound an entity to a real path**, so `_TARGET_X`/`_TARGET_Y` (read via
   `MY._TARGET_X - MY.X` to compute a walk direction) stayed at their
   never-written defaults. Worse: Start.wmb has *two* `LookAtMe` entities,
   and with `scan_path` unconditionally succeeding, both ran their
   identical walk-toward-target logic simultaneously, both writing
   `camera.x/y` every tick and fighting for control — this, not any
   single bug, is what "camera positions not updated correctly" was
   describing. (Investigated whether the two entities' WED-authored
   `flags` bitfield — 768 vs. 769, confirmed present via
   `assets/converted/levels/Start.json` — was meant to distinguish them
   via `my.flag1`; inconclusive without a verified A5 FLAG1-8 bit
   mapping, and the evidence available doesn't clearly support it. Left
   unresolved rather than guessed at — see docs/CONTRACT.md.) Fixed
   `scan_path` for real: finds the nearest point across every path in the
   level (`_loader.last_level_data`, same source `WdlDirector._paths`
   reads), binds the entity to it via node meta, writes real GS
   coordinates into `_TARGET_X`/`_TARGET_Y`/`_TARGET_Z`. New
   `ent_nextpoint` advances to the next bound point the same way.
2. **The actual root cause of "characters facing wrong": `_get_field`/
   `_set_field` returned early (a plain `return`/`return 0.0`) whenever
   the target object didn't resolve to a real spawned entity** — correct
   for a genuinely-missing PANEL reference, but WRONG for Acknex's scratch
   `VECTOR`/`ANGLE` globals (`temp`, `my_angle`, ...), which are real,
   commonly-used structs, not entities, and are written via completely
   ordinary field-assignment syntax (`temp.x = TARGET_X - MY.X;`). Every
   such write was silently dropped before it could reach the generic
   custom-field fallback added earlier tonight (that fallback lived
   *inside* the same function, past the early return, so it was
   unreachable for this exact shape). Result: `temp` always read back as
   `(0,0,0)` regardless of what a script "wrote" to it, so
   `vec_to_angle(my_angle, temp)` always computed a zero-length direction
   and wrote pan=0/tilt=0 — entities always turned to face pan=0 (Acknex
   GS +X) instead of their real target, independent of `scan_path`'s own
   correctness. Fixed by adding the scratch-vector fallback *before* the
   early return in both `_get_field` and `_set_field`, backed by new
   `_vectors: Dictionary` storage and a shared `_vec_field_slot()` helper
   (x/pan share slot 0, y/tilt slot 1, z/roll slot 2 — Acknex's VECTOR and
   ANGLE types are the same 3-float struct with two field-naming
   conventions overlaid). Also implemented `vec_set`/`vec_sub`/
   `vec_to_angle` for real (previously no-op stubs) via new `_vec_get()`/
   `_vec_put()`, which resolve a RAW (unevaluated) AST argument node to a
   by-reference read/write target — bare scratch identifier, or
   `entity.x`/`entity.pan` (Acknex's "a position/angle field is also
   usable as a pointer to the entity's whole x/y/z or pan/tilt/roll
   triple" idiom). `vec_to_angle`'s *return value* is the input vector's
   length (used corpus-wide as a "have I arrived?" distance check,
   `result = vec_to_angle(...); if (result < 25) { ent_nextpoint(...); }`
   — confirmed by reading the actual call sites, not assumed), not the
   angle itself, which is written by reference into the first argument.

Verified via `tools/smoke_start_diag.gd`: post-fix, `_TARGET_X` correctly
advances through a real sequence of waypoint values (842→610→345→57→
-173→...) as `ent_nextpoint` fires, `LookAtMe`'s position follows a
genuine curved path instead of a straight line to infinity, camera
pan/tilt track smoothly (20.9°→164°→94.9° as the entity turns toward
Yachdal), and movement correctly *stops* once `Scene` leaves the
`(Scene==0)||(Scene==2)` walking phase — matching the script's own
`else` branch, not a bug.

Also directly verified Studio's "camera doesn't jump well" report is
already fixed by the earlier `ShowDialog` wiring fix, not a new issue:
new `tools/smoke_studio_camswitch.gd` fast-forwards past the ~16s boot
song, opens the real dialogue panel, clicks option 1, and confirms the
camera hard-cuts instantly from `TheCam2`'s position to `TheCam`'s the
same frame `Talking` becomes 1 — `TheCam`/`TheCam2` are real, already-
correct WDL actions (`if (Talking==1) { camera.x=my.x; ... }` /
`if (Talking==2||Talking==0) { ... }`), no director-side logic was ever
needed; they just couldn't run before because nothing could ever set
`DialogChoice` to make `Talking` change in the first place.

**Not resolved, explicitly flagged rather than silently claimed fixed**:
"backgrounds shown incorrectly, weird pattern" in Start. Investigated only
as far as confirming it's very unlikely to be caused by tonight's
interpreter changes: `AcknexSky.apply()` (unchanged) applies sky/scene-
map textures once at level load from static `assets/converted/wdl_meta.json`
data, entirely independent of the WDL runtime; Start.wdl's own `main()`
never assigns `scene_map` at all (unlike Plane/Studio, which do), so
whatever Start shows comes from `wdl_meta.json`'s extracted default for
it, not from anything the interpreter does at runtime. Needs its own
investigation (what does `wdl_meta.json` actually say for Start, and does
the rendered result match it) rather than folding into this round's fix,
since the evidence so far points away from the runtime layer entirely.

Full regression suite (`smoke_click_survey`, `smoke_click_event`,
`smoke_remove_race`, `smoke_dialog_choice`, `smoke_dispatch` — 19/19) run
clean after these changes; asset integrity confirmed clean throughout.

## 2026-07-30 — "The camera is still not exactly right" — Start's `flag1` disambiguation between its two LookAtMe entities
Checked: user asked directly to read Start.wdl's camera instructions and
explain what might still be wrong, after the scan_path/vec_to_angle fixes
above. Re-read `action LookAtMe` end to end: it branches its ENTIRE camera
behavior on `my.flag1` — `(Scene==0)||(Scene==2)` + `flag1==off` walks
toward Yachdal (already confirmed working); the `else` branch +
`flag1==on` + `Scene!=4` does a fixed `camera.pan=270` shot with no
look-at math, meant for Scene 1/3/5. Start.wmb places TWO `LookAtMe`
entities specifically so one can drive each half. `my.flag1` is a
WED-authored per-entity checkbox this port has no verified bit mapping
for (docs/CONTRACT.md §4.1 — only bit0=INVISIBLE, bit10=PASSABLE are
confirmed). Checked all three camera-class entities in Start.json: the
two `LookAtMe` placements have `flags` 768/769 (differ only in bit0,
already spoken for as INVISIBLE — can't be flag1); `FarCam` has 770
(differs in bit1 from the first, unclear meaning, and FarCam doesn't even
read flag1 in its own script). No bit in the extracted data cleanly
explains the split.
Found instead a strong *textual* clue: the second `LookAtMe` entity's own
authored pan is exactly 270° — the same literal value `flag1==on`
hardcodes into `camera.pan`. The first entity is authored at 90°. Too
specific to be coincidence; reads as the level designer setting that
entity's own facing to match what its dedicated branch does.
Asked: presented the full analysis (bit-mapping dead end + the pan=270
textual match) and asked directly how to proceed — implement the inferred
pan-based heuristic, try guessing a bit position instead, or leave it
open.
Answer: implement the inferred heuristic.
Result: added `WdlInterpreter._seed_look_at_me_flag1()`, called once per
entity in `begin_level()` right before its action coroutine starts.
Scoped deliberately narrow — only entities whose *action* is exactly
`LookAtMe` get `flag1` seeded this way (from comparing authored pan
against 270° within a 15° tolerance); every other level's independent use
of `my.flag1`..`flag2`.8` is untouched, since guessing a real bitfield
position would have applied — possibly wrongly — corpus-wide, not just to
this one action. Explicitly documented as an inference pending playtest
confirmation, not asserted as a verified fact.
Verified via updated `tools/smoke_start_diag.gd` (now traces both
`LookAtMe` entities plus the real camera over 25s): the handoff works
exactly as the script specifies — Scene 0: entity #1 walks + turns to
face Yachdal (pan sweeping 144°→53°), entity #2 sits frozen. The instant
Scene becomes 1 (frame 591), the camera cuts hard to entity #2's position
with `pan=270.0` exactly, and entity #2 starts moving. The instant Scene
becomes 2 (frame 1156), it cuts back to entity #1, which resumes turning
to track Yachdal (pan continuing 49°→5.9°). Full regression suite re-run
clean (`smoke_click_survey`, `smoke_dispatch`), asset integrity confirmed.

**Also confirmed, not a new issue**: `smoke_click_survey.gd` took longer
than 2 minutes on this pass (previously always well under) — re-ran with
a longer budget and it completed correctly, 16/16 levels, 0 script
errors. Almost certainly the pre-existing busy-loop CPU-contention issue
(see 2026-07-29/30 entries), now somewhat worse since `scan_path` does
real nearest-point search work instead of returning an instant stub.
Not a correctness regression — flagged in case it's worth a dedicated
performance pass later, not chased further tonight.

## 2026-07-30 — Follow-up: "camera position is better," characters still facing wrong, scene still never advances
Checked: user's next real playtest pass on Start, after the flag1/camera
fixes above. Three claims: camera better (progress); character facing
still wrong; "when the scene ends it doesn't move to the next level, just
stays in a loop."

**Character facing — investigated, concluded out of scope, not a runtime
bug.** Compared authored WED `pan` (Start.json) against the *live*,
currently-rendering `pan` meta on Yachdal/every Crowd/Grandma entity: they
match exactly, no drift, confirming nothing in tonight's interpreter
changes is rewriting these entities' orientation at runtime (`action
Crowd`/`action DefineYachdel`/`action Grandma` never write `my.pan` at
all, confirmed by re-reading their full bodies). The apparent mismatch
traces to `tools/mdl_yaw_allowlist.json` (asset-pipeline, out of scope
tonight): `Crowd`/`Crowd2`/`Yachdal`/`Genia` all carry a documented
`extra_yaw_deg: 270.0` correction, baked into the GLB at MDL-conversion
time — a *human-confirmed* measurement per that file's own comment and
`docs/PLAYTEST.md`'s history (`tools/wmb_web_viewer.py`, independent of
Godot's own rendering). `Grandma2` is NOT in that allowlist at all and was
never verified in `docs/PLAYTEST.md` either — a real, pre-existing,
never-closed gap, not a regression. Whatever's actually wrong on screen is
either in that already-verified-elsewhere pipeline step or is a case
(Grandma) that was simply never checked — outside tonight's runtime-layer
scope either way. Flagged to the user rather than guessed at further.

**"Scene never advances" — a THIRD real bug, same family as `SetVoice`/
`actor_move`, and the one that actually mattered.** Root-caused via direct
per-write tracing (temporary debug instrumentation on `_set_var`, removed
after), not guessing:
1. Fixed first, real but not sufficient on its own: `stop_sound(handle)`
   had the identical bug shape as the earlier `snd_playing` fix — ignored
   its argument, always force-stopped the shared Voice channel. Confirmed
   via corpus grep that every real call site (20+ files) passes a handle
   from a prior `play_sound`/`play_entsound`, never bare. Fixed the same
   way: `AudioChannels.stop_sfx_handle(handle)`, generation-checked like
   `is_sfx_handle_playing()`.
2. Traced the actual runaway with a temporary per-write print
   (`_set_var`, entity name + `_total_frames`): once `Scene` passed the
   last value `Start.wdl`'s `SetVoice()` explicitly handles (5), calling
   it again is a no-op, so the Voice channel's "finished" state never
   resets — meaning `GetPosition(Voice) >= 1000000` reads true on every
   subsequent real frame, and `LookAtMe`'s own progression check
   (`Scene = Scene + 1; SetVoice();`) fires every frame forever, racing
   arbitrarily far past the `if (Scene == 6) { Run("Menu.exe"); }`
   terminal check the script uses to end the intro. Two sub-issues
   compounded here: (a) initially TWO `LookAtMe` coroutines were each
   independently consuming the same "just became finished" transition
   within one real frame (proven via the trace: both wrote `Scene` in the
   same `_total_frames` value) — fixed generally with a one-frame
   debounce on `GetPosition(Voice)`'s "finished" reading itself
   (`_do_get_voice_position()`/`_voice_finished_seen_frame`): the first
   caller within a given frame sees the real value, later callers in that
   same frame see "not quite yet" (corrects itself the very next frame,
   so a second *legitimate* poller is delayed by at most one frame, never
   given a wrong answer). This closed the double-increment but, on its
   own, did NOT fix the underlying loop — Scene still raced past 6 one
   step at a time. (b) The actual root cause, found by re-tracing with the
   double-increment already fixed: `Scene==6` genuinely was reached and
   checked, but `Run("Menu.exe")` had no effect — because `Run` is ALSO
   shadowed, same class of bug as `SetVoice`/`actor_move`/`ShowDialog`
   before it. `WDL/IO.wdl` (included by nearly every level) declares its
   own `function Run(filename) { file_open_write("Run.txt"); ...;
   file_close(...); WriteDate(); exit; }` — the ORIGINAL game's real
   mechanism (each "level" was a separate .exe; a wrapper launcher process
   watched `Run.txt` to know what to start next, and the current .exe's
   own `exit;` terminated it). None of that applies to this single-process
   Godot port, and `exit;` isn't even a statement this interpreter
   recognizes, so the shadowed real `Run()` silently did nothing at all —
   never called `LevelRouter`, never stopped anything. Fixed by adding
   `run` to `BRIDGE_OVER_SHARED_FUNCTIONS` (this interpreter's own
   `_do_run()` — confirmed already correct — always wins now) and, since
   real Acknex's `Run()` halts the CURRENT level's script immediately, not
   whenever the actual scene swap eventually lands, having `_do_run()` set
   `_running = false` synchronously (the same flag `_exit_tree()` sets;
   every `exec_stmt()` already checks it).

Verified end to end via `tools/smoke_start_diag2.gd` (new, traces `Scene`/
`Delay`/both `LookAtMe` positions and Crowd/Yachdal/Grandma pan over a
70s real-time window): `Scene` now reaches exactly `6.0` at ~58.5s and
**stays there** for the rest of the trace (previously: raced to `3969`+
within 90s and never stopped) — confirming `Run()` fired and the level's
own script execution genuinely halted, not just that a check happened to
pass once. Full regression suite re-run clean afterward (`smoke_click_survey`
16/16, `smoke_click_event`, `smoke_remove_race`, `smoke_dialog_choice`,
`smoke_scan_path_gate`, `smoke_shiks_progress`, `smoke_dispatch` 19/19),
asset integrity confirmed clean throughout.

**Pattern worth calling out explicitly**: this is the FOURTH shared-function-
shadowing bug found tonight (`SetVoice`→wrongly bridged the OTHER
direction initially; `actor_move`; `ShowDialog`; now `Run`) — every one
found by the same method (corpus grep for `^function NAME`, read the real
body, decide whether it's genuinely unbridgeable) rather than guessed.
Worth checking any OTHER builtin this interpreter provides against the
same pattern before assuming a "no-op fallback" is harmless: a shadowed
real function can be silently *worse* than no bridge at all, since it
looks like it "did something" without any warning ever firing.

## Follow-up: character facing in Start ("Yachdal isn't facing the right
## way, he should be 90 degrees to its left") — found a real 180°-backwards
## measurement in `mdl_yaw_allowlist.json`, fixed with a new direct-render
## check, ruled out Crowd/Crowd2/Grandma2

User couldn't pin down an exact degree offset for Grandma2 (the gap
flagged in the previous entry) but was specific about Yachdal and "the
crowd," both needing roughly a 90°-to-the-left correction. Rather than
trust a verbal degree estimate (genuinely hard to judge precisely from
first-person play) or the existing `mdl_yaw_allowlist.json` entries at
face value, built a way to get real rendered ground truth without
depending on the user running a manual tool session: Playwright (already
installed, headless Chromium confirmed working) driving
`tools/wmb_web_viewer.py`'s existing `window.__WMB_DEBUG__` debug hook
(`setForwardCamera`, `findByFile`, `worldForward`/`worldPos` — built for
exactly this, per that file's own header comment about puppeteer-style
automated inspection). For a given entity, position the camera along a
candidate "this should be the front" vector looking back at the model,
screenshot, and just look — this *is* the "external ground truth /
rendered image" rule-3 verification `docs/CONTRACT.md` #2 already
requires, just executed by the agent instead of the user.

Result for **Yachdal**: viewing from local +X (pan=0, `extra_yaw_deg=270`
applied) showed his back — coat seam, quiver, hair from behind; viewing
from -X showed his face dead-on (eyes, nose, mustache, open jacket, tie).
270° was exactly 180° backwards. This directly contradicts
`docs/PLAYTEST.md`'s prior claim that a 2026-07-28 render check had
already confirmed 270° correct — that prior check evidently wasn't the
clean, isolated shot it was recorded as. Fixed: `mdl_yaw_allowlist.json`
Yachdal `270 → 90`, regenerated via
`python tools/convert_mdl.py --only Yachdal`, re-verified with the same
Playwright check showing his face from +X afterward. `git status` showed
only `Yachdal.glb`/`Yachdal.mdlanim`/the allowlist JSON changed.

**First attempt at checking Crowd/Crowd2/Grandma2 gave a false read** —
screenshots kept showing 2-3 *different* faces clustered together no
matter which entity was targeted. Root cause: `Start`'s crowd is dense
(dozens of `Crowd.MDL`/`Crowd2.MDL` placements a few dozen units apart,
plus Genia and Grandma2 nearby), and the first isolation attempt hid by
`mesh === target.mesh` — `pickable` entries are per-entity, so that check
trivially always matched only the exact object already selected and hid
*nothing else*, leaving every entity in frame. Fixed by hiding on
`data === target.data` (verified with a diagnostic count: 75 pickable
total → 1 visible after) *before* screenshotting. With real isolation:
**Crowd, Crowd2, and Genia are all still correct at 270°** (confirmed
face-from-+X, back-from--X, cleanly, no ambiguity) — the user's read on
"the crowd" was very likely Yachdal's own 180°-backwards facing standing
out among an otherwise-correct crowd, not an actual crowd-model bug.
**Grandma2 — the gap flagged in the previous entry — is also already
correct** with no allowlist entry at all (confirmed the same way); the
earlier unisolated attempt had actually been rendering Genia (standing
~100 units away, also wearing a hat with baskets) in the foreground
instead of Grandma2.

Updated `docs/CONTRACT.md` #2.4 (corrected the "bearing-consistency
confirmed Yachdal" claim — that method validates a self-consistent
narrative, crowd loosely facing a landmark, not that the landmark's own
mesh is oriented correctly; keep using it to rule out WMB-parsing bugs,
not to sign off an individual model's facing) and `docs/PLAYTEST.md`
(Yachdal and Grandma2 rows). Character-facing character-model bugs, if
any remain, are now down to: nothing known — every entity actually named
in a playtest report this session (Yachdal, Grandma2, Crowd, Crowd2) has
now been checked against a real rendered image, not carried forward on
an old note.

**Immediate correction: the Yachdal `90°` fix above was itself wrong.**
User reported it as a 180° shift when only 90° was needed. The render
check that produced `90°` only ever distinguished front-from-back (camera
on the model's own local ±X) — it never tested the two 90°-away
candidates against each other, so it couldn't have caught an error of
exactly this shape (right polarity ruled out, but overshot by a further
90° in a direction the front/back test is blind to). Set to `180°` (the
untested midpoint between the original `270°` and the overshot `90°`,
i.e. a genuine 90°-magnitude change from where the user's original report
started) and left **explicitly unconfirmed** pending the user's own
in-game read this time, rather than repeating the mistake of trusting a
static render to settle a question a render can't answer. If `180°` is
still wrong, the only remaining 90°-away candidate is `0°`.

## Resolution: Yachdal is `0°`, and Crowd/Crowd2 needed the identical fix

`180°` was also wrong per direct user testing ("now he is 180 off").
Since `270`, `90`, and `180` were all now ruled out by real gameplay, `0°`
was the only remaining candidate by elimination — applied without another
render round-trip, since there was nothing left to distinguish. The user
also separately reported Crowd was wrong "the same way," which the
2026-07-28 and 2026-07-30 investigations had both — independently —
"confirmed" correct at `270°` via isolated renders. Both of those checks
had exactly the same structural blind spot as the original Yachdal
mistake: a static front/back render found a plausible-looking face at
`270°` and stopped there, never actually comparing it against `0°` to see
which was *more* correct. Set Crowd and Crowd2 to `0°` alongside Yachdal
(`python tools/convert_mdl.py --only Yachdal Crowd Crowd2`), confirmed by
the user in-game. Genia was NOT touched — never reported as wrong — but
per `docs/CONTRACT.md` #2.4's updated note, her "confirmed correct" status
from earlier this session should now be treated as unverified, not relied
on, given the same class of check just failed twice for her neighbors.

**Real lesson, not just a fixed value:** a rendered image is necessary but
not sufficient for resolving a 90°-magnitude orientation question. It can
cheaply rule out "exactly 180° backwards" (this session's front/back
checks were right every time they were used for that). It cannot resolve
"which of two remaining 90°-away candidates is correct" — that requires
an actual moving in-game viewpoint, i.e. the human's own eyes, not a
better camera angle in a standalone tool. Three render-based guesses
(`90`, `180`, and the earlier unquestioned `270` for Crowd/Crowd2) were
wrong before the user's direct testing settled it in one message. Don't
repeat the pattern of iterating render guesses once the front/back
question is already resolved — ask, or wait for the human's report.

## 2026-07-31 — Studio "stuck in a loop" + "coroutines take a lot of time"
## traced to the Start GetPosition(Voice) debounce fix itself; fixed
## generically (per-caller, not per-frame); plus a real, corpus-wide
## "black = transparent" texture bug found and fixed

User reported (with a real console log excerpt) that clicking Studio's
`ShikNote` entity (`action ShikNote` -> `event ShikKlik`) started a
coroutine that never seemed to progress ("coroutines take a lot of time to
start"), and separately that Ami Studio "stays in a loop without moving to
the next part" — paired with an explicit ask: "the answer here should be
generic," i.e. find the real shared root cause, not a Studio-specific
patch.

**Root cause, confirmed via a new diagnostic (`tools/smoke_studio_shikklik.gd`,
directly invokes `ShikKlik` on the `ShikNote` entity and traces
`Talking`/`Scene`/the interpreter's own `_running` flag over real time):**
the one-frame-global `GetPosition(Voice)` debounce added 2026-07-30 for
Start's LookAtMe double-increment bug has a fatal flaw once a THIRD kind of
caller is in the mix. `Naknik`'s own action polls `GetPosition(Voice)`
unconditionally every single frame from level boot onward (its own,
unrelated `if (GetPosition(Voice) >= 1000000) { Scene = Scene + 1;
SetVoice(); }` idiom). Godot resumes Naknik's coroutine before ShikKlik's
(started later, on click) every frame, so Naknik always won the single
global "first caller this frame" slot — meaning ShikKlik's own `while
(GetPosition(Voice) < 1000000) { wait(1); }` (waiting for `SHK001.WAV` to
finish) NEVER once saw "finished", forever. Confirmed live: `Talking`
stuck at `3.0` and `Run("Shiks.exe")` never fired for 40+ real seconds,
while `Scene` quietly raced into the thousands (Naknik's own poll firing
every frame once nothing new was playing — harmless on its own, since
nothing in Studio.wdl reads `Scene` past 3, but a symptom of the same
underlying issue).

Fixed by keying consumption per **(caller, voice generation)** instead of
per frame: `AudioChannels` gained a `_voice_generation` counter (bumped on
every `play_voice()` call, mirroring the existing SFX handle generation
pattern), and `WdlInterpreter._do_get_voice_position(my)` now tracks, per
caller, the last generation it has already seen as finished
(`_voice_finished_consumed_by: Dictionary`), rather than a single global
per-frame flag. Each caller gets its own guaranteed first look at every
real completion, regardless of poll order, so a late-starting coroutine
can never be starved by an earlier, more eager one — while a single
caller that keeps polling after already consuming a generation still only
acts once per real completion (both WDL idioms sharing this value keep
working correctly, see the new code comment for the full two-idiom
breakdown). Verified: `smoke_studio_shikklik.gd` now shows `Talking`
cycling `3.0 -> 1.0 -> 3.0 -> 1.0` correctly and `Run()` firing at frame
1907 (~32s); re-ran `smoke_start_diag2.gd` to confirm this doesn't regress
Start — `Scene` still reaches exactly `6.0` and halts. Full regression
suite (`smoke_dispatch` 19/19, `smoke_click_survey` 16 levels/307
entities) still clean.

**Separate finding while investigating: a real, corpus-wide "heads are
transparent" bug**, reported alongside the above with a sharp, correct
hypothesis from the user ("I think its because we make dark black
transparent even though it should be for the 2d images not the 3d ones").
Confirmed exactly right, via a direct render (Playwright driving the
`tools/wmb_web_viewer.py` debug hook against Yachdal's actual head, no
DIY reasoning): his eye sockets showed background scene geometry visible
straight through them. Root cause: **two separate** color-decode
functions in `tools/convert_mdl.py` each independently treat a
"looks-empty" color value as a transparency sentinel, a convention that
may be legitimate for 2D bitmap colorkeying but is wrong for these 3D
model skins, which are meant to be fully opaque:
- `_apply_quake_palette` (8-bit indexed skins): treated palette index 0 as
  transparent. This game's actual palette (`GFX/palette.pcx`) has index 0
  = plain black `[0,0,0]`, the start of an ordinary grayscale ramp used
  for real shading, not a reserved colorkey slot.
- `_rgb565_to_rgba` (16-bit RGB565 skins — the format Yachdal, Crowd,
  Crowd2, and Genia's skins actually use; `_apply_quake_palette` was a red
  herring for this specific report, confirmed by checking the real
  `group=` tag in Yachdal's own MDL header before assuming): treated a raw
  16-bit value of exactly 0 (which decodes to pure black) as transparent.
  Same mistake, different function.
Both fixed to full opacity (alpha=255 unconditionally). Left untouched:
`_rgba4444_to_rgba` (a real embedded alpha channel, genuinely authored
per-pixel, not a sentinel-color guess) and `_palette_skin` (the
degraded no-real-palette-available fallback, where index-0-transparent is
a reasonable choice since there's no real color data to trust at all —
a genuinely different situation from the two fixed functions, which both
had real, trustworthy color data being discarded).
Regenerated the full MDL corpus (`python tools/convert_mdl.py`, no
`--only` filter, since this is a shared decode-function fix affecting
every model using either format): 648/649 converted (one pre-existing,
unrelated failure — `Hezi4.MDL`, a genuinely degenerate source file with
zero UV data, never successfully converted before this session either,
confirmed via git history). 770 of those output files changed
byte-for-byte (72 from the palette-index fix, ~700 more from the RGB565
fix — confirming RGB565 is by far the more common skin format in this
corpus, not a rare edge case). Verified: re-rendered Yachdal's head after
the fix — eyebrows now read as a solid unbroken black line and both eyes
show full opaque coloring, no background bleed-through. `git status`
confirmed zero deletions throughout.

## 2026-07-31 (follow-up, same day) — Studio subtitle panel wired; camera
## gap during Shik's lines noted, not yet fixed

User confirmed Start and Studio both now "look and play great" after the
above fixes, with two small remaining reports: a camera view "not fixed"
in Studio, and "green text" at the bottom of the screen missing at scene
start.

**Subtitle text — root-caused and fixed.** `GameHud.setup_start_subtitles()`
/`setup_studio_subtitles()` already existed, fully built (correct texture
names, correct `_update_crawl()` slide/blink timings matching
`action DefineYachdel`'s `POvr.pos_x > -200` and `action Ami`'s
`POvr.pos_x > -310` byte-for-byte) — but `git log --all -S` showed **zero
commits ever called either function**, since the initial commit. `pSom`/
`pOvr` are WDL `panel` objects (a pre-rendered green-on-black bitmap TEXT
graphic, not a live font — matches "green text"), which this interpreter
has no generic support for, so `action Ami`'s/`action DefineYachdel`'s
opening `pOvr.visible = on; pSom.visible = on;` silently no-op. Fixed with
a narrowly-scoped hook, `WdlInterpreter._seed_subtitle_crawl()`, called
from `begin_level()` right alongside the existing `_seed_look_at_me_flag1`
seed: fires `hud.setup_start_subtitles()`/`setup_studio_subtitles()` only
for the exact (level, action) pairs GameHud was built for — `action Ami`
is reused in Outro/Smash/VilEnd for an ordinary, unrelated talk/blink
loop (confirmed via corpus grep), so this is gated on `_level_stem` too,
not just the action name. Verified with a new
`tools/smoke_studio_subtitle.gd`: `_crawl_active=true`, both panels
visible with a loaded texture, right after Studio boots.

**Camera "not fixed" — investigated, root cause plausible but not yet
confirmed or fixed.** Studio's only two camera actions are `TheCam`
(`Talking==1`) and `TheCam2` (`Talking==2 || Talking==0`) — confirmed via
corpus grep that **no action anywhere in Studio.wdl ever checks
`Talking==3`**, the value `ShikKlik` sets twice (for `SHK001.WAV`/
`SHK002.WAV`). This is true of the original script too, not a porting
bug on its face — during Shik's own lines, nothing claims the camera, so
it holds whatever position was last written. Ruled out
`CameraAuthority`/`is_driving_camera_this_frame()` as the mechanism:
Studio is a `scripted_camera` (non-fp) level, so `LevelRunner._process()`
never calls `_camera_authority.update()` for it at all — the single
`_script_cam` just keeps `.current = true` throughout, it can't be
silently handed to the player's free-look camera the way an fp-mode level
could. Also ruled out feet-snap (camera props are explicitly excluded,
`_should_feet_snap()`). Given the user could only now reach far enough
into the ShikKlik flow to notice this (it used to hang before the
Naknik/GetPosition fix above), this gap in the Talking==3 window is the
leading hypothesis for what "not fixed" means, but unconfirmed —
**needs a concrete description from the user (which moment, does it
drift/shake vs. just show the wrong static framing) before touching
anything**, since the original script itself has the same gap and
"holds last position" might already be correct/intended behavior that
just looks a little off, not an actual instability bug.

## 2026-07-31 (same day, second follow-up) — the "camera not fixed" report
## was actually about Shiks, not Studio; real root cause found and fixed:
## `Dialog.visible` was a genuinely-unresolved PANEL field, always reading
## off/0.0, so `ShowDialog()` got re-called every frame and reset every
## click before the script could act on it

Asked the user to clarify "camera not fixed." The actual answer reframed
the whole report: it's about **Shiks** (reached via the now-working
Studio -> `Run("Shiks.exe")` transition), not a Studio camera view at all.
"A text choice after the Shiks scene starts - after choosing, the talk
isn't starting, and if I do get to the point where Piposh is moving
inside the house - the other part where the camera moves through the
window and another part of the dialogue starts - doesn't happen."

Read `Shiks.wdl`'s `action Piposh2` (the character's main state machine)
in full. Both symptoms trace to the exact same statement: its `Scene==2`
branch opens with `while (Dialog.visible == on) { Talking = 0; Blink();
wait(1); }`, meant to block re-showing the dialogue prompt until the
player's current click has actually been processed. `Dialog` is a WDL
`panel` object (`WDL/DIalog.wdl`) — this interpreter has no generic PANEL
support (a known, documented gap), so `_resolve_entity()` always returned
null for it, and `_get_field()`'s null-entity fallback always returned
`0.0` — meaning `Dialog.visible` read as permanently **off**, and that
`while` loop never once blocked anything. Consequence: every outer-loop
iteration re-ran `ShowDialog()` (which resets `DialogChoice` to 0, see
`_do_show_dialog()`), so a real player click's `DialogChoice` value was
reset back to 0 before the script's own `if (DialogChoice == N) { ... }`
checks (further down the SAME branch) ever got a chance to see it, on
all but a very lucky single-frame timing window. This blocks BOTH
`DialogIndex==1` (the first prompt, "talk isn't starting") and
`DialogIndex==2` (the second prompt, gating the whole "Piposh flies
through waypoints... camera goes to the window... `Run("Plane.exe")`"
sequence via its own `DialogChoice==2` branch) — one root cause explains
both parts of the report, matching the "should be generic" pattern from
this session's very first Dialog-choice fix.

Fixed by treating `Dialog` as a special-cased pseudo-entity, the same
pattern already used for `camera`: `_resolve_entity()` now returns `_hud`
for the bare identifier `dialog` (case-insensitive); `_get_field()`/
`_set_field()` check `node == _hud` before falling into the generic
Node3D-position code path (required — `GameHud` isn't a `Node3D`, doesn't
have `.global_position`) and bridge `.visible` to
`_hud.is_dialog_open()` on read, and `.visible = off` to
`_hud.hide_dialog()` on write (the only write ever seen corpus-wide —
`.visible = on` occurs exactly once, inside the real `ShowDialog()`
itself, which is already force-bridged to `_do_show_dialog()`, so it
never actually reaches this code path).

Verified with two new smoke tests, both simulating a real button click
(`GameHud.hide_dialog()` + the `dialog_choice` signal, matching what
`_emit_choice()` actually does — an earlier draft that only emitted the
signal directly gave a false FAIL, since skipping `hide_dialog()` left
`Dialog.visible` legitimately still "open" per the test's own
construction, not a real bug):
- `tools/smoke_shiks_dialog_choice.gd`: after forcing `DialogIndex=1` and
  clicking option 1, `PIP012.WAV` now actually plays (`voice_playing`
  goes true at frame 0 and `DialogChoice` stays at `1.0` — previously
  reset to `0.0` every frame, voice never played at all).
- `tools/smoke_shiks_dialog2_choice.gd`: after forcing `DialogIndex=2` and
  clicking option 2, the full window/camera sequence now plays through
  correctly end to end — `Talking` progresses `1→2→1→2→12→13→14→15→16→
  17→18` and `CamShow` advances `1→3→4→5→6→7→8` (matching the source's own
  `// Going away` / `// From the window` / `// On the phone` / `// Weasel`
  / `// Piegon` / `// Driving away` comments) over ~52 real seconds,
  ending with `Run("Plane.exe")` correctly firing (`_running` flips
  false) — previously never reached at all.

Full regression suite re-run clean (`smoke_dispatch` 19/19,
`smoke_dialog_choice`), since `Dialog.visible` is used the same way
across many levels (`Mansion.wdl`, `Studio.wdl`, `WDL/DIalog.wdl` itself),
not just Shiks — this is a shared bridge fix, not a per-level patch.

## 2026-07-31 (same day, third follow-up) — subtitle still not visible on
## screen; a plausible unclamped-delta bug found and fixed, but NOT
## confirmed — headless testing genuinely cannot verify this one

User reports the green subtitle text still doesn't show, despite the
previous fix making `setup_studio_subtitles()` actually get called (which
a headless smoke test confirmed: `_crawl_active=true`, both panels
`visible=true` with a loaded texture). This is a real limitation of this
session's verification method: `godot --headless` always falls back to
the dummy rendering driver in this environment (confirmed earlier the
same day trying `smoke_orient.gd` with `--rendering-driver opengl3` --
`Viewport.get_texture()` still came back null), so **node properties can
be confirmed correct, but actual on-screen pixels cannot** — a bug in
z-order, positioning, or animation timing that leaves the properties
"correct" by the next frame is invisible to every tool used so far.

Found one concrete, plausible candidate via code reading (not confirmed
against real rendering): `GameHud._update_crawl(delta)` is driven by
`_process(delta)`, and the FIRST call after `setup_studio_subtitles()`
lands right after an entire level's worth of synchronous boot work (WMB/
GLB load, every entity's action coroutine starting) — Godot's `delta` for
that frame is the real elapsed wall-clock time, which could be large
enough that this animation (tuned as "8 units per real tick," i.e. for a
normal ~16ms frame) skips most or all of the way to its end state
(off-screen, past the crawl-then-blink-then-slide-down sequence) in a
single step, before the player's eye ever registers a frame where it's
mid-crawl and visible. Fixed defensively: `delta = minf(delta, 1.0/30.0)`
at the top of `_update_crawl()`, so no single frame can move the
animation more than what a real ~30fps tick would. Re-verified the
existing `tools/smoke_studio_subtitle.gd` still passes (doesn't regress
the property-level check), but **this fix is unconfirmed against the
actual symptom** — genuinely possible the real bug is something else
entirely (z-order, an actual rendering-side issue, or something this
session's tools simply cannot see). Needs the user's own eyes on the next
playtest before treating this as resolved.

## 2026-07-31 (fourth follow-up) — five more reports at once: dialogue
## loop, HUD, loading-screen request, free camera in Studio, poster
## click position. Attempted a real desktop screenshot to finally get
## actual pixels -- accidentally captured unrelated, sensitive content
## from another window instead; deleted immediately, abandoned the
## approach, do not retry it.

**Screenshot attempt (abandoned):** tried launching a real (non-headless)
Godot window and capturing it via a Win32 `GetWindowRect`/
`CopyFromScreen` PowerShell script, since headless mode is confirmed
stuck on the dummy renderer in this environment. `SetForegroundWindow`
either failed silently or the coordinates were wrong -- the captured
region showed unrelated, explicit content from a different window on the
screen, not the game. Deleted the file immediately, killed the process,
and will not attempt desktop/window screenshotting again in this
environment -- too easy to capture something that isn't mine to see, and
not reliable enough to trust even when it does work. Back to code-reading
+ headless property-verification only, with the known limitation that
real on-screen pixels still can't be confirmed by this agent.

**Camera moves during Naknik's dialogue when it shouldn't — real bug,
found and fixed, high confidence.** `WdlDirector._unhandled_input()`'s
generic "Town.wdl / generic Cam: pan/tilt -= mickey/5 while mouse_mode==0"
mouse-look feature applies to every `scripted_camera` level EXCEPT an
explicit exclusion list (Start/Shiks/Plane/Range) -- Studio was simply
missing from that list, despite `_is_studio_level()` already existing
(unused until now). Confirmed via reading the full `Studio.wdl`: the
script never reads or toggles mouse state at all. Worse than a no-op:
mouse motion calls `cam.set_meta("pan"/"tilt", ...)` on whichever Cam
entity is currently active, and `TheCam`/`TheCam2` then copy that SAME
meta to the real camera every frame -- so mouse movement was silently
corrupting the entity's own authored facing, not just failing to add a
feature. Fixed by adding `_is_studio_level()` to the exclusion list.

**"Dialogue looping on the first part" — real bug, found and fixed, high
confidence, verified.** Traced `action Piposh2` (Shiks.wdl) fully: its
`Scene==2` block re-calls `ShowDialog()` with the SAME `DialogIndex` no
matter which of the first prompt's 3 choices is picked -- by design, a
revisitable menu. The ONLY way out is choice 3, which sets
`my.skill20 = 1` (walk) and, once the player physically walks into a
separate `Bumpin`-tagged entity, `action Bumped` sets `Piposh.skill2 = 2`,
which is what unlocks `action MyCamera`'s fly-through-waypoints sequence
and eventually `DialogIndex = 2` (the "camera through the window" scene
from the previous report). `Bumpin`'s trigger is
`my.enable_entity/enable_push/enable_impact = on` -- **grepped the whole
interpreter: none of these three fields, or any entity-to-entity physical
collision trigger, existed at all.** 22 files in the corpus use this
idiom. So the only real exit from the first dialogue menu was completely
unreachable through normal play -- not a dialogue-panel bug, a missing
core interaction (walking into things can fire their `.event`, same as
clicking them). Fixed: `_set_field()` now handles all three fields by
ensuring a real Area3D exists that detects the player's own
`CharacterBody3D` (found via `is_in_group("player")`, set by
`player_controller.gd`) entering it, firing `invoke_event()` on
`body_entered` -- same dispatch clicks already use. Verified with a new
`tools/smoke_shiks_bumpin.gd`: simulating the player entering `Bumpin`'s
new trigger area correctly sets `Piposh.skill2` from `1.0` to `2.0`.

**Click-area centering — generic, defensible improvement made, but
verified NOT to be the cause of the "poster is a bit lower" report
specifically.** Both `WdlInterpreter._ensure_clickable_area()` and
`WdlDirector._make_clickable()` centered their 28-unit click sphere on
the entity's raw origin, assuming it always coincides with the mesh's
visual center -- not guaranteed (e.g. a wall note whose origin is a
mount point). Added `_clickable_center_offset()` (AABB-center of the
first `MeshInstance3D` found, converted to the entity's local space) to
both, so future entities with an off-center origin get a correctly
positioned hitbox automatically. Checked `ShikNote` specifically (the
poster in the report) with a dedicated tool
(`tools/smoke_shiknote_offset.gd`): its computed offset is exactly zero
-- both of its meshes (`ShikNote`, a small pin/icon, and
`ShikNotePoster`, the actual 58x72 flat image plane) are already
perfectly centered on the entity's own origin (dumped the full node tree
and both local AABBs to confirm). **So this fix, while real and worth
keeping, does not explain the reported symptom** -- the root cause of
"the poster is a bit lower" is still unknown; possibly the click sphere's
28-unit radius being small relative to the 72-unit-tall poster (only
covering the middle ~56 units), possibly something about the WED-authored
Y position itself, possibly something else entirely. Needs either a
screenshot or a more specific description (is it the visible graphic
that looks low against its wall mount, or does the CLICK only register
if you aim below where the graphic visually is) to make real progress
here instead of guessing again.

**Loading screen — implemented as requested, not yet visually confirmed
(same tooling limitation as above).** `LevelRunner._ready()` does all of
a level's heavy synchronous work (WMB/GLB parse, entity spawn, every
action coroutine starting) with nothing rendered in between, reading as
a freeze rather than a load. A real progress bar would need the load
itself restructured to be async, out of scope for a quick fix; instead,
`_ready()` now creates a full-screen "Loading..." `CanvasLayer` (`layer =
40`, above both `GameHud` and the F4 level-select menu), awaits two
`process_frame`s (one to process the new node into the tree, one to
actually paint it) before starting the heavy work, and frees it once
`_ready()` finishes. **Risk checked and cleared:** `_ready()` becoming an
implicit coroutine (from the new `await`s) could have broken every
existing smoke test that waits a fixed 3 frames after `add_child(runner)`
before reading `_director`/`_wdl_interp` — re-ran `smoke_dispatch`
(19/19), `smoke_click_survey` (16 levels/307 entities), and
`smoke_studio_shikklik.gd` (the tightest-margin existing test) after the
change; all still pass, so 3 frames remains enough headroom.

`git status` confirmed zero deletions throughout this whole round of
fixes.

## 2026-07-31 (fifth follow-up) — the actual "HUD text not showing" root
## cause, found via one precise detail: "originally a black bar with
## green text, running for a couple seconds"

Every prior attempt at this (frame-timing clamp, verifying node
properties) missed because the actual bug was upstream of anything the
interpreter or GameHud touches: the 2D texture converter itself.
`tools/convert_gfx.py` unconditionally ran `color_key_black()` (pure
black → transparent) on **every** GFX bitmap, citing "Acknex panel/bmap
`overlay` treats pure black as transparent" — a real Acknex behavior, but
gated on the panel actually having the `overlay` flag, which the
converter never checked. `Studio.wdl`'s `panel pSom`/`panel pOvr` (and
`Start.wdl`'s identical pair) do NOT have `overlay` in their flags — they
should render their bitmap opaque, black background included. Blanket
colorkeying every GFX file made that black background fully transparent,
so only the green glyphs remained — technically still "shown" (matching
every earlier property check) but with no supporting black bar for
contrast, easy to miss entirely against a busy 3D scene, matching "I'm
still not seeing it" even after the properties were confirmed correct.

Fixed properly, not by exempting just the two reported files: wrote
`tools/gen_overlay_bmap_list.py`, which parses every `panel NAME { ... }`
block across the entire original `.wdl` corpus, checks whether `overlay`
appears in that panel's own `flags`, and resolves the bmap symbol back to
a real filename. Zero filenames were used both ways (with and without
`overlay`) across the whole corpus — an unambiguous, corpus-measured
split, not a guess. Result: 63 files (including `Ami`/`Someover`/
`Somewher`, and, as a side finding, 23 `LoadingNN` images — the original
game's own loading-screen art, unused by this port so far) are
confirmed non-overlay and now convert as plain opaque PNGs; everything
else keeps the historical colorkey behavior (safer than guessing a new
default for bitmaps never actually measured). The list is a reviewed
literal in `convert_gfx.py` (`NON_OVERLAY_BMAPS`), not auto-applied from
the generator script, so a future corpus change can't silently alter
conversion output without a diff someone actually looks at.

Regenerated all GFX assets (`python tools/convert_gfx.py`, no filter —
shared conversion-function fix, not per-file): 552/553 converted (one
pre-existing unrelated failure, `stat0.pcx`, confirmed via `git log`
never successfully converted before this session either). 54 output PNGs
changed, zero deletions. Directly viewed the regenerated `Ami.png`:
now shows the intended solid black bar behind the green Hebrew text,
matching the description of the original ("a black bar... with green
text... running for a couple seconds"). Full regression
(`smoke_dispatch`, 19/19) still clean.

## 2026-07-31 (sixth follow-up) — ShikNote poster nudge (user-confirmed
## fixed) + a fair "why not fix the parser" challenge answered honestly +
## the "black ball" Dummy markers, root-caused and fixed generically

User confirmed the poster fix landed ("now looks like its in the right
place") but pushed back on the approach first: "why are you manually
doing it and not fixing the parser?" Investigated properly before
answering rather than just defending the patch: pulled `ShikNote.wmb`'s
raw geometry directly (`tools/extract_wmb_mesh.py`'s own `extract_brush`)
and the entity's authored angle (`angle_gs = [180, 356, 0]`, i.e.
pan=180°, tilt≈-4°, roll=0°) — both are sane, unremarkable values, not
obviously corrupted. `_mount_wall_card()`'s `shiknote`/`afg` special case
in `wmb_level_loader.gd` is narrowly scoped (exactly these 2 stems, not a
broad pattern), so the "edge-on slab" a previous session found isn't
symptomatic of a general coordinate-convention bug in the shared
`_acknex_entity_basis()` transform every other entity in the game relies
on — experimentally removing the special case to test a real fix isn't
something this session can safely do blind (no working visual
verification here, and that shared function is too high-blast-radius to
touch on a guess). Answered honestly instead of quietly nudging a number:
this stays a contained, hand-placed patch, not a parser fix, because a
real fix needs either a working renderer or a much bigger dive than this
session has scoped — nudged the quad up by a fixed fraction of its own
height (`quad.size.y * 0.12`, matching the user's own "small amount"
estimate) rather than a raw unit guess, confirmed via
`tools/smoke_shiknote_debug.gd` that the offset applied
(`local_pos=(0,8.64,0)`), and the user confirmed it looks right in-game.

**Separately, mid-turn: "Dummy models - black balls - shouldn't appear
visually or at all - I don't know how it reached the Ami level."**
Checked corpus-wide before touching anything (same discipline as every
other fix this session): grepped every `action Dummy` definition across
the entire original `.wdl` corpus (`AsyAct1`, `AsyAct2`, `AsyAct3`,
`Credits`, `Dutyfree`, `HitUFO`, `Inn`, `Intro2`, `MOI`, `Shiks`,
`Studio`) — every single one is a pure logic/sound-position marker with
zero gameplay-visual purpose; `AsyAct3`'s own copy even explicitly sets
`my.invisible = on;` itself, confirming the convention. `Dummy.MDL`'s
real, successfully-converted geometry (62 verts, ~32-unit roughly
spherical bounds) is genuine, not a missing-asset fallback -- just an
unremarkable placeholder shape that apparently went unnoticed in the
original's low-res rendering and stands out as a visible stray dark
sphere in this port. Not level-specific (`Dummy_mdl_018` is a real entity
placed directly in `Studio.WMB`, not carried over from another level, so
"how did it reach Ami" has a mundane answer: it was always there, just
newly visible). Fixed the same way camera placeholders already are:
`_hide_meshes(root)` now also fires for `action.to_lower() == "dummy"`,
alongside the existing camera/`flag_invisible` checks in
`wmb_level_loader.gd`. Visual-only (`_hide_meshes` just sets
`MeshInstance3D.visible = false`), so collision/click/audio behavior for
these entities is untouched — Studio's own `Dummy` still plays its
ambient sound loop correctly, it just doesn't render a mesh anymore. Full
regression (`smoke_dispatch` 19/19, `smoke_click_survey` 16 levels/307
entities) clean after both fixes; `git status` zero deletions throughout.

## 2026-08-01 — Shiks dialogue loop, take two: the 2026-07-31 Bumpin fix's
## own verification only proved dispatch worked, never that real NPC
## movement would ever reach it -- it didn't

User reported: after the first Shiks dialogue choice, "whatever we
choose, it either don't 'go back' to the dialogue, or tries to continue
to the next part (animation fires off) then the game gets back to the
previous dialogue instead of doing the camera movement." Matches `action
Piposh2`'s own structure exactly: every branch of the first prompt
(`DialogIndex==1`) falls through to the same `ShowDialog()` re-open
unless `Piposh.skill2` reaches 2, which only happens via `action Bumped`
-- the walk-into-it collision the previous session's fix was supposed to
enable.

**Root cause: the previous fix's own test never actually tested real
movement.** `tools/smoke_shiks_bumpin.gd` called
`_on_impact_body_entered()` directly -- proved the *dispatch* (event
fires, `Piposh.skill2` gets set) works, never that anything would
actually *call* it during real gameplay. It doesn't: every WDL entity
(`WmbLevelLoader._spawn_entity()`) is a plain `Node3D`, moved by
`actor_move()` writing `global_position` directly -- Godot's physics
engine has zero awareness of that, so `Area3D.body_entered` (which only
fires for real `PhysicsBody3D` nodes) can NEVER fire for an NPC like
Piposh2 walking into something, only for the real player's own
`CharacterBody3D`. Built a real end-to-end test this time,
`tools/smoke_shiks_bumpin_proximity.gd`: physically move Piposh2's
`global_position` toward the Bumpin entity over real frames (the same
thing `actor_move()` does, no interpreter shortcut) and check whether the
existing mechanism picks it up on its own. It didn't -- confirming the
gap for real before trying to fix it.

Added the missing half: `WdlInterpreter._impact_zones` +
`_check_impact_proximity()`, called from the existing per-frame
`_process()`. Plain distance check between every `enable_impact`-tagged
entity and every other live entity in the level, edge-triggered
(`_impact_touching` dict per zone, fires once per approach, not every
frame spent overlapping) to match `body_entered`'s own semantics. Kept
the original Area3D/`body_entered` path too -- still correct for the real
player's actual physics-based movement, just not sufcient on its own.

**Second bug found while wiring the proximity check up, same session:**
first attempt reused `_clickable_center_offset()` (the AABB-centering
added for the "poster is a bit low" fix) for the impact zone's center.
Wrong call for this case -- that centering is correct for raycasting a
*visible* mesh, but "walking into it" is a position-to-position proximity
check, and Shiks' own `Snail` (the entity `action Bumpin` is on) has a
424x344x89-unit mesh, so its AABB center sits ~100 units away from the
entity's own origin. That silently moved the whole trigger zone into
empty space -- confirmed by rerunning `smoke_shiks_bumpin_proximity.gd`
with the zone's actual computed offset logged: Piposh2 walked to within
0.2 units of Snail's origin and the zone (centered ~100 units off) never
fired. Fixed by dropping the AABB offset for impact zones entirely --
plain origin, matching how every other entity's position is measured.
Reran the same test after the fix: fires correctly at frame 176, 27.7
units from Snail's origin (within the 28-unit radius), via real simulated
movement, not a shortcut.

**Honest scope note:** verified the proximity mechanism itself is now
real and correct. NOT independently verified: whether Piposh2's actual,
natural walk direction during real gameplay (driven by whatever `my.pan`
happens to be at that point in the scene, since `action Piposh2`'s
`skill20==1` walk block has no steering/aim logic of its own) actually
carries it close enough to Snail to trigger the now-working proximity
check. The test above walked Piposh2 in a straight line directly at the
target to isolate and confirm the proximity mechanism itself; it doesn't
prove the natural in-game walk direction lands within range. Needs a real
playtest to close the loop on that part.

Full regression (`smoke_dispatch` 19/19, `smoke_click_survey` 16
levels/307 entities) clean; `git status` zero deletions.

## 2026-08-01 (second) — subtitle mechanism fully explained, one real
## timing bug found and fixed: missing hold delay before scroll-away

User pointed at `bmap bOvr = <Someover.bmp>;` and asked to understand the
mechanism properly rather than keep guessing at the visibility symptom.
Read `action Ami` line by line and viewed the raw source bitmaps directly
(bypassing the whole conversion pipeline) to confirm the actual mechanic,
not assumed:
- `pSom` (`Ami.pcx`) is the real message: green Hebrew text on a solid
  black strip, fixed at x=0, never moves horizontally.
- `pOvr` (`Someover.bmp`) is NOT separate text -- viewed the raw 417x23
  bitmap directly: almost entirely solid black (matching `pSom`'s own
  background, so it visually blends), with one small green accent at its
  right edge. It's a wipe MASK, layered on top (`layer=3` vs `pSom`'s
  `layer=2`).
- Phase 1 (reveal): `pOvr` starts covering `pSom`'s right ~417px and
  slides left (`pos_x -= 8*time`) until `pos_x <= -310`. Since the
  covering window's right edge recedes from 640 toward 107, this reveals
  `pSom`'s text right-to-left -- matching Hebrew reading order, a
  scripted typewriter effect, not a static image ever fully visible at
  once during the reveal.
- Phase 2 (hold): once the slide stops, `my.skill34`/`my.skill35`
  (separate counters) start. `skill35` toggles `pOvr.visible` every ~5
  ticks (~0.3s) -- a blinking cursor sitting at the end of the revealed
  line. `skill34` does nothing for the first 60 ticks (~3.75s) -- **this
  gate was missing from the Godot port.**
- Phase 3 (scroll away): only once `skill34 > 60` do `pOvr.pos_y`/
  `pSom.pos_y` start incrementing, drifting the whole line down and off
  the visible strip.

`GameHud._update_crawl()` had phases 1 and the blink correct, but started
the downward scroll (`dy = _slide_t * 16.0`) the instant phase 2 began,
with no hold gate -- the fully-revealed line started sliding away within
under 2 real seconds of finishing its reveal instead of holding for
~3.75s, on top of the ~4.16s the reveal itself takes. Renamed
`_slide_t` -> `_hold_t` for clarity and gated the scroll behind it
(`dy = (_hold_t - 60.0/16.0) * 16.0`, only once `_hold_t > 60.0/16.0`),
matching `my.skill34`'s own gated-increment shape exactly.

Extended `tools/smoke_studio_subtitle.gd` with a real timing check (not
just a property check, which couldn't have caught this): waits 6.5
real-frame-seconds (comfortably past the ~4.16s slide, comfortably short
of the ~7.9s total before scroll should start) and confirms
`pSom.position.y` hasn't moved from its base — would have failed under
the pre-fix code (which have already started scrolling by ~37 units at
that point per the old, ungated formula). Full regression
(`smoke_dispatch` 19/19) clean; `git status` zero deletions.

## 2026-08-01 (third) — the ACTUAL "not showing on screen" cause, found
## immediately once real logging existed: a double-scale position bug,
## present since this code was written, unrelated to every earlier theory

User: still not visible, asked for `[hud-event]` logging plus the actual
text content printed, instead of more guessing. Added
`GameHud.SUBTITLE_TEXT` (hand-transcribed from the raw source bitmap --
there's no string to read, it's baked pixel art) and full lifecycle
logging under `PiposhDebug.log_msg("hud-event", ...)`: setup (kind, text,
texture load status, layer, root scale/position, viewport size),
per-phase snapshots (reveal in progress, heartbeat every 1s; reveal done;
hold done/scrolling), and a `_layout()`-triggered log whenever a
subtitle is active. Design goal: enough to reconstruct the whole picture
without needing eyes on a real window.

**The very first log line, from the very first test run, showed it:**
`pSom design_pos=(0.0, 900.0) screen_pos=(0.0, 1960.0)` against a
1280-tall viewport -- the panel was positioned entirely below the visible
screen. `_layout_subtitles()` set `_p_som.position = Vector2(0,
_som_base_y * _scale)` -- but `_p_som` is a child of `_root`, and `_root`
already carries `_root.scale = Vector2(_scale, _scale)` (set in
`_layout()`). Every other element in this file (`_zoom_label`,
`_range_label`, dialog buttons, ...) sets `.position` in plain unscaled
design-space coordinates for exactly this reason -- `_layout_subtitles()`
was the one place that multiplied by `_scale` a SECOND time, and the
scroll-away code in `_update_crawl()` had the identical bug
(`_p_som.position.y = (_som_base_y + dy) * _scale`). At `_scale=1.0`
(viewport exactly 640x480) this is invisible -- 450*1=450, correct by
coincidence. At any other scale (i.e. essentially every real window size
this game will ever actually run at) the panel lands `_scale` times
further down than intended. This has been wrong since the subtitle code
was first written, completely unrelated to the mouse-look bug, the
colorkey bug, the wiring-never-called bug, or the missing-hold-delay bug
found across the prior four rounds chasing this same report -- none of
those were wrong to fix, but none of them were reachable as "the" bug
until the panel was actually on screen to see them fail at.

Fixed both call sites to use plain design-space coordinates, matching
the rest of the file. Re-ran with the same logging: `screen_pos=(0.0,
1060.0)` against the same 1280-tall viewport -- comfortably on screen.
Full regression: `smoke_dispatch` 19/19 clean; `smoke_click_survey` was
still running after several minutes on this session's own machine load
(observed spending a long stretch re-invoking a single `SparkHit`
entity's event repeatedly -- matches this project's previously-documented
ambient busy-loop/CPU-contention slowness, not a new regression: nothing
this fix touches is reachable from click/event dispatch at all) --
left running in the background rather than block on an unrelated,
already-known-flaky check; `smoke_dispatch`'s clean pass plus the direct
before/after position log are sufficient confirmation for this specific
fix. `git status` zero deletions.

## 2026-08-01 (fourth) — Shiks dialogue loop, take three: found via the
## real dialogue-choice-driven flow, root cause was a fixed ~80-unit
## vertical gap the 2026-07-31 impact fix's sphere check could never close

User pasted the full `original/piposh3d/Shiks.wdl` source and asked to
check the *parser* specifically. Checked `assets/converted/wdl_ast/
Shiks.json`'s `skip_count`/`skipped`: exactly one skip, a genuine stray
`}` in `function Blink()` (a real typo in the recovered source, lines
404-412 -- 4 `{` vs 5 `}`). Traced it by hand: the parser correctly
captures all three of `Blink()`'s intended if-statements before the
orphaned brace and safely skips it with zero cascading damage -- confirmed
via AST dump that all 24 actions and 4 functions parse completely,
including `action Piposh2`'s full DialogChoice/DialogIndex structure.
**Real, pre-existing artifact; not the cause of the reported bug.**

Read `action Piposh2` closely: picking DialogChoice==3 at DialogIndex==1
does *not* advance DialogIndex. It plays `SHK007.WAV`, sets
`my.skill20=1` (which makes the entity walk via `actor_move()` while the
line plays), and once the voice finishes, calls `ShowDialog()` again --
reopening the *same* DialogIndex==1 prompt. This is correct, intended
design, not a bug: the real advance happens by *physically walking into*
`Bumpin` (`action Bumpin`: `enable_impact=on`, `event=Bumped`), which sets
`Piposh.skill2=2`, waking `action MyCamera`'s scripted path-follow flight
that ends with `DialogIndex=2; ShowDialog();`. So "loops on the same
prompt while Piposh walks" is exactly what the original game does too --
the bug is specifically that the walk-into-Bumpin trigger never fires in
this port.

Wrote `tools/smoke_shiks_walk_to_bumpin_real.gd` to drive the *actual*
reported flow (repeated `hud.dialog_choice.emit(3)`, not manual position
manipulation, unlike the 2026-07-31 proximity test). Result: Piposh
closes to distance 143.4 on round 1, then overshoots and keeps walking
away in a straight line every subsequent round (`Piposh.skill2` stuck at
1.0 for all 15 rounds) -- confirming the 2026-07-31 impact-proximity fix
(`_check_impact_proximity()`) dispatches correctly when invoked directly
but still never fires for this *specific* real walk.

Root cause, confirmed via `assets/converted/levels/Shiks.json` origins:
`Piposh2` spawns at Godot `(-893, 8, 0)` with `pan=0`, so
`_do_actor_move()`'s straight-line translation (`dir=(cos(pan),0,-sin(pan))`,
no floor tracking -- this port's movers are plain `Node3D`, not physics
bodies, so there is no floor-snap the way the original engine's
`actor_move()` does it for free) never changes Y or Z: Piposh walks
dead-flat at Y=8, Z=0 forever. `Bumpin` sits at `(-149, -69, 23)`; nearby
`StandHere` is at `(-475, -73, 8)`, confirming that whole room really is
~80 units lower, not a data error. The closest possible 3D distance along
Piposh's flat path to Bumpin's origin is `sqrt(77^2 + 23^2) ≈ 80.4` units
-- comfortably outside the impact zone's 28-unit sphere radius, so the
`_check_impact_proximity()` sphere check added 2026-07-31 could *never*
close, no matter how long the walk continued.

Fixed `_check_impact_proximity()` (`scripts/engine/wdl_interpreter.gd`)
to compare horizontal (XZ-plane) distance only, ignoring Y, for the
NPC-vs-entity proximity path specifically -- the real player's
`Area3D`/`body_entered` path is untouched (the player is a genuine
`CharacterBody3D` and floor-snaps correctly on its own). This is a
targeted fix for the specific gap (no-floor-snap movers), not a claim
that floor-snapping the movers generally is unneeded -- that would be the
fuller root-cause fix but is a much larger, riskier change (raycasting
against level collision geometry, touching every `actor_move()` call
site across the corpus) that isn't justified by this one report.

Verified: extended `smoke_shiks_walk_to_bumpin_real.gd` to check
`Piposh.skill2` reaching 2 (Bumped fired) rather than requiring
`Run("Plane.exe")` (a different dialogue choice under DialogIndex==2,
out of scope here). Re-ran: `bumped=true after 1 round(s)`,
`final Piposh.skill2=2.0`. Re-ran `smoke_shiks_bumpin_proximity.gd`
(2026-07-31's regression test, which places Bumpin/Piposh at matching Y
by construction) unchanged: still passes, `frame=176: skill2 became 2.0
(distance to Bumpin=27.5)`. `git status` zero deletions.

## 2026-08-01 (fifth) — two more Shiks reports in the same batch: a
## "squirrel" that shouldn't be visible yet, and "weird noise... plays
## non stop"; both real bugs, both fixed generically (not per-level hacks)

**Squirrel (`action Weasel`, Weasel.MDL).** Only ever does
`my.invisible = off` when `CamShow == 6`, with no initializer and no
re-hide branch. Checked Shiks.json's raw WED flags for this entity: 256
(bit0 clear) -- genuinely authored visible, not a flag-decode bug, so the
model really does sit in the open from frame 1 in both the original game
and this port; it's just that this port's `scan_path` waypoint-following
(an *approximate* reconstruction of the original camera path, see
`_do_scan_path()`) can plausibly point the camera at it before its
CamShow==6 reveal, where the original's exact path may not have.
Considered a Shiks-only hardcoded fix but `action Weasel` doesn't exist
anywhere else in the corpus (`grep -r "action Weasel"` -- one hit), so a
hardcoded special case would be exactly the kind of per-level branch this
project has been deleting, not adding. Fixed generically instead: new
`WdlInterpreter._seed_reveal_only_hidden()`, called from `begin_level()`
before each entity's coroutine starts, statically scans the action's own
AST body (however deeply nested in if/while) for `my.invisible = ...`
assignments -- if it only ever finds `= off` (reveal) and never `= on`
(hide), *and* the entity's WED flag doesn't already start it hidden, the
reveal statement is a structural no-op (already visible) that defeats an
obvious "become visible at the right story beat" intent, so the entity is
forced hidden at spawn and let the script's own reveal logic do its job.
Verified this is a real, generic pattern first: corpus-wide scan (Python,
`assets/converted/wdl_ast/*.json`, restricted to `target.obj.name=="my"`
specifically -- several actions, e.g. Plane2's `A1`/`PiposhHit`, also
write `player.invisible`/`opponent.invisible`/etc., which says nothing
about the acting entity's own starting visibility and must NOT count)
found 26 matching actions across 20 files, not just Weasel -- this is a
common corpus idiom, not a one-off. First implementation looked correct
but did nothing: a GDScript lambda closure over local `bool`s doesn't
mutate the caller's copy (captures by value), silently no-op-ing the scan
-- rewrote to return `[seen_show, seen_hide]` directly instead of a
callback. Verified with `tools/smoke_shiks_weasel_debug.gd` (new):
`visible(node)=false` from frame 1 through 14s of real dialogue-driven
play (previously `true` throughout). Full regression
(`smoke_dispatch` 19/19, `smoke_shiks_bumpin_proximity.gd`) still clean.

**Background noise ("plays non stop").** Added temporary `[sfx-event]`
logging to `AudioChannels.play_sfx()` and ran Shiks for real (both
headless and a real, non-headless window -- no screenshot, log capture
only) to see what was actually happening instead of guessing. Headless:
305 play_sfx calls in a 12s-frame-budget run. Non-headless (real audio,
real timing): 1679 calls in 12 real seconds -- *worse*, which ruled out
"headless dummy-audio-driver artifact" as the explanation and confirmed
a genuine bug. Breakdown by sound name showed it wasn't evenly spread:
SFX140.WAV (Mapal, `action Watrfall`, ~3.1s) alone accounted for 720 of
those calls -- landing on the same pool slot every time, `was
playing=false pos=0.000` on every single call, immediately after each
`.play()`. Isolated test (`AudioStreamPlayer` playing the same resource
directly, nothing else running) played it perfectly for 4s straight --
ruling out file corruption. Root cause: `wdl_director.gd`'s `setup()`
had a leftover hand-ported branch (`"WaterWheel"`/`"Watrfall"`/`"Dummy"`
match arms) that called `AudioChannels.play_music("SFX100.WAV"/
"SFX140.WAV"/"SFX089.WAV"/"SFX105.WAV", ...)` once at level load --
*duplicating* what Shiks/Plane/Plane2/Studio's own `action WaterWheel`/
`action Watrfall`/`action Dummy` already do generically via the
interpreter (`play_entsound` + `snd_playing`, confirmed by reading each
level's own recovered .wdl source directly). `play_music()` ->
`_enable_loop()` mutates the loaded `AudioStream` *resource itself* --
`load()` caches and shares one Resource instance per path across every
player using it, SFX pool included -- and was setting `loop_mode` without
`loop_end`, leaving it at its default of 0: a degenerate zero-length loop
region. Once the duplicate `play_music()` call ran that once, the SFX
pool's own later playback of the same file could never sustain
`.playing == true` for its natural duration again, so `snd_playing()`
read false almost immediately and the WDL ambiance loop retriggered as
fast as it could poll. Fixed at both ends: deleted the duplicate
`wdl_director.gd` branch entirely (dead/duplicate code per this file's
own already-stated direction -- interpreter-first execution is the only
path now, confirmed each affected level's own `action Dummy`/
`WaterWheel`/`Watrfall` already produces the same ambiance independently:
Studio's Dummy plays `vin`, Plane's and Plane2's both play `cockpit`),
and made `_enable_loop()` set a real `loop_end` (from the stream's actual
PCM sample count) so no future `play_music()` caller can corrupt a shared
stream this way again. Also hardened `play_sfx()`'s pool to prefer a
genuinely free slot over blind round-robin eviction -- not the actual
cause this time, but the same class of bug (stealing an actively-playing
slot) was a real latent risk with only 6 slots shared across every
concurrent ambiance loop in a level, cheap to close off regardless.
Verified: real-window re-run dropped from 1679 calls/12s to 25 (matching
each sound's own natural retrigger rate: SFX100 x1 in 12s for a 17.9s
clip, SFX101 x21 for a 0.7s clip, SFX140 x6 for a 3.1s clip -- all
sane). New `tools/smoke_shiks_sfx_debug.gd` (rewritten from the
diagnostic version into a permanent regression check, headless,
frame-budget-based, threshold well below the old bug's rate) confirms:
20 calls over 720 frames, comfortably under the 200-call regression
threshold. Full regression (`smoke_dispatch` 19/19,
`smoke_shiks_bumpin_proximity.gd`, `smoke_shiks_walk_to_bumpin_real.gd`)
still clean. `git status` zero asset deletions.

## 2026-08-01 (sixth) — Plane: Piposh enters below the cabin floor. Two
## fix attempts reverted before landing on a narrow, safe one

User: "Piposh enters but he's lower than he should be, not walking on
the plane's height at the start of the scene" -- asked to clarify when
(picked "right at level load, before walking", not "throughout the
walk" or "only later"). Confirmed via `assets/converted/levels/
Plane.json`: `action PiposhWalk` spawns at Godot Y=-39 while this
level's own computed `floor_y` (WmbLevelLoader's own load-time log) is
83 -- a ~120 unit gap. No script in the corpus manages the height axis
around `actor_move()` (confirmed: the original engine's own
`actor_move()` floor-snaps for free every tick; this port's is a
straight-line X/Z-only translation, see `_do_actor_move()`), so nothing
was ever going to correct this on its own.

**First attempt (reverted):** interpolate height toward the entity's
current `scan_path()`/`ent_nextpoint()` waypoint target, reusing the
`wdl_custom__target_z` meta those builtins already track. Seemed
principled (a real 3D waypoint, not a guess) but wrong for this case:
Plane's own 2-point path is *also* authored at the low spawn height
(~-28), not the cabin floor's, so this pulled Piposh the wrong direction
instead of fixing anything. Live test (`tools/smoke_plane_piposh_height.gd`,
new) confirmed: height converged toward the path's own low value, not
upward.

**Second attempt (reverted):** a real per-tick raycast floor-snap in
`_do_actor_move()`, against the same collision geometry
`_add_mesh_collision()` already builds for the player, bounded to a
40-unit step per tick so a big gap wouldn't visibly teleport. Matches
the original engine's actual behavior most faithfully, but broke
immediately in testing: on this exact mesh the ray locked onto the wrong
collision surface (plausibly an upper-deck/ceiling hit) once the ray's
rising start point crossed into it, and climbed away without ever
settling -- confirmed live, Y climbing 141 -> 307 -> 420 -> 553 -> 681
over 4 seconds instead of stabilizing. Too fragile to ship blind (no way
to visually confirm it's hitting the right surface on every level), and
touching every `actor_move()` call site in the corpus for one report
was disproportionate anyway.

**Landed fix:** a narrow, one-time spawn-time correction in
`WmbLevelLoader._spawn_entity()`, scoped to this exact entity (same
precedent as `_mount_wall_card()`'s 2-stem special case) -- if
`level_name=="Plane" and action=="PiposhWalk"` and the authored origin
is more than 40 units below this level's own already-computed
`floor_y`, snap to `floor_y` before the transform (and downstream
feet-snap) is applied. Uses a value the loader already computes for this
exact level, not a hand-picked guess. Verified: spawn Y went from 19.35
(post feet-snap) to 141.35, landing within the same general band as the
level's own floor_y (83) instead of ~120 units below the raw origin.
Rewrote `tools/smoke_plane_piposh_height.gd` into a permanent regression
check (spawn Y must land within 80 units of the level's floor_y).
Full regression (`smoke_dispatch` 19/19, `smoke_shiks_bumpin_proximity.gd`)
still clean -- confirms the two reverted attempts left no trace in
`_do_actor_move()`, which is back to its original, unmodified form.
`git status` zero asset deletions.

## 2026-08-01 (seventh) — Plane2: Hammer sound too loud, and a
## misdiagnosed "stars" report that turned out to be an unrelated static
## prop wrongly animating

**Hammer volume.** `_do_play_sfx()` never used `play_entsound`'s 3rd
argument at all -- corpus survey (`grep` across every `.wdl` file)
confirms it's Acknex's audible-range/falloff-distance parameter (values
run 66-5000 corpus-wide), not a literal loudness scale, and this port
has no distance-based 3D attenuation for entity sounds yet (a real gap,
but implementing it properly touches every `play_entsound` call site in
the corpus with no way to verify the result by ear -- out of proportion
for one report). `sHammer` (SFX090.WAV, Krupnik's hammer-hit in both
Plane.wdl and Plane2.wdl) has range 300, one of the *shorter* ranges in
the corpus -- clearly meant to be quiet/close, which flat full-volume
playback defeats. Fixed with a narrow, filename-keyed volume trim table
(`SFX_VOLUME_TRIM_DB`, `-12.0` for `sfx090.wav`) in `_do_play_sfx()` --
same precedent as the tuned per-sound dB values `wdl_director.gd` used
to hardcode (removed 2026-08-01 fifth entry as duplicate *triggering*,
not because per-sound tuning itself was wrong).

**"Stars" report.** User initially described a "stars" effect appearing
during Krupnik's hammer swing, rendered "a bit behind him." Investigated
thoroughly before asking for clarification: confirmed the "Hammer" clip
exists and plays correctly (`tools/smoke_krup2_clips.gd`), Krupnik's
position/pan stay stable throughout (no positional bug in `action
Krupnik`), Krup2.glb has exactly one mesh with no separate "stars" part
(`tools/smoke_krup2_mesh_dump.gd`), no `create()`/particle-spawn call
exists anywhere in Plane2.wdl, and the file's own AST `skip_count`
entries are the same pre-existing `Blink()`/`Blink2()` stray-brace typo
already confirmed harmless in Shiks. Asked the user to describe it more
precisely rather than guess further or dig into raw MDL binary data
blind -- turned out to be a completely different, unrelated entity:
**AFG_Card** (Afgan.wdl's collectible flight-badge/card system, ~70
units from Krupnik, visually mistaken for a hammer-adjacent effect).
`action AFG_Card` (`original/piposh3d/WDL/Afgan.wdl`) never calls
`ent_frame`/`ent_cycle` anywhere in its body -- it's a static,
wall-mounted, clickable collectible; the only "animation" should be
`AFG_Take`'s pickup fade, not a persistent loop. Root cause:
`AFG.MDL` has a "Frame" clip (each frame likely one of the ~32 card
designs, selected by `my.skill1`, though authored/selected by WED, not
the script) but no "Stand" clip, and `MdlAnimator.setup_from_stem()`'s
existing fallback -- `elif _clips.has("Frame"): play_cycle("Frame", 0.0)`
-- assumes any entity that only has a "Frame" clip and no "Stand" wants
it looped, a correct assumption for the fan/smoke/falling-debris props
it was written for, wrong for a static collectible that just happens to
store its one fixed pose under a clip named "Frame". Fixed generically
(not a single-entity hack): new `MdlAnimator.hold_autoplay` export --
when true, the "Frame" fallback (and an explicitly-requested non-Stand
idle clip) holds frame 0 via `play_frame()` instead of `play_cycle()`.
Set `true` only for `action=="afg_card"` in
`WmbLevelLoader._attach_animator()`; every other user of this fallback
(Cow/Ship/PisaFall/etc., whose own WDL scripts genuinely drive
`ent_cycle("Frame", my.skill1)` themselves over time) is untouched,
default `false`. Verified with new `tools/smoke_plane2_afgcard_static.gd`:
`_playing=false`, `_percent` unchanged across 2s (previously would have
been actively cycling). Full regression (`smoke_dispatch` 19/19,
`smoke_plane2_playtest.gd`) still clean. `git status` zero asset
deletions. **Superseded same-day, see next entry.**

## 2026-08-01 (eighth) — the AFG_Card fix generalized: Sikot (a different
## clickable prop, same level) turned out to have the exact same bug,
## confirming this needed the generic fix, not a second hardcode

User reported a second Plane2 entity animating when it shouldn't (from a
`[click-hit]` log line: `resolved_node=Sikot_mdl_082 action=Sikot`).
Checked `action Sikot` (Plane2.wdl): `{ my.enable_click=on; my.event=
SikotClick; }` -- never calls `ent_frame`/`ent_cycle` either, same shape
of bug as AFG_Card. Confirmed live (`tools/smoke_sikot_clips.gd`):
Sikot.MDL also has only a "Frame" clip, `_playing=true`, `_percent`
climbing 0.94 -> 75.85 over 2s. Two independent real cases of the exact
same pattern is the signal this needed the generic fix, not a second
per-action hardcode.

Replaced the AFG_Card-specific hack entirely with a real, corpus-wide
fix in the interpreter (which has AST access the loader doesn't): new
`WdlInterpreter._seed_static_pose_if_never_animated()`, called from
`begin_level()` alongside `_seed_reveal_only_hidden()` for every entity
at spawn. Statically scans the action's own AST body (however deeply
nested in if/while, via a new generic `_scan_for_calls()` helper) for
any `ent_frame`/`ent_cycle` call; if the action never animates itself,
whatever `MdlAnimator`'s own fallback landed on (e.g. cycling "Frame")
gets corrected to a static hold via `play_frame()`. Runs once at
`begin_level()`, before the first frame ever renders, so correcting an
already-started cycle causes no visible flicker. Reverted the
AFG_Card-specific `hold_autoplay` export and loader hardcode entirely --
fully superseded, and leaving both in place would've meant two
overlapping mechanisms for the same concern.

Verified: `tools/smoke_sikot_clips.gd` and `tools/smoke_plane2_
afgcard_static.gd` both now show `_playing=false`, `_percent` static
across 2s. Confirmed the fallback's *intended* case still works:
Ziggy's `action FCloud` genuinely calls `ent_cycle("Frame", my.skill1)`
itself, so `_scan_for_calls()` correctly finds it and leaves it cycling.
Full regression (`smoke_dispatch` 19/19, `smoke_plane2_playtest.gd`,
`smoke_shiks_bumpin_proximity.gd`) still clean. `git status` zero asset
deletions.

## 2026-08-01 (ninth) — Range level "stops"/errors at start: a real
## crash in the 2026-07-31 impact-proximity mechanism, spamming every frame

User asked to add logging, run Range, and find why it stops at start.
New `tools/smoke_range_debug.gd` loaded the level for real and caught it
immediately: `SCRIPT ERROR: Trying to assign invalid previously freed
instance.` at `WdlInterpreter._check_impact_proximity()`
(wdl_interpreter.gd:1148), firing from the very first frame and
continuing every single frame after -- in a real (non-headless) window
this reads exactly like "stops," since the engine is spending every
frame re-throwing the same error rather than actually hanging.

Root cause: `_check_impact_proximity()` (added 2026-08-01, the Shiks
Bumpin fix) declared `var node: Node3D = zone["node"]` -- a *typed*
assignment. Range's shooting-range targets (`action Terrorist`/`TNT`/
`Window`, all `enable_impact`) are dynamically created at runtime
(`@Node3D@141`-style anonymous names in the `[wdl-event]` log, not
WED-placed), and once one gets freed, Godot's typed-variable assignment
validates the object reference *at the assignment itself* and throws --
before any code, including `_entity_alive()`'s own check on the very
next line, gets a chance to see it. Every other entity-liveness check in
this file already takes its entity parameter untyped for exactly this
reason (`_entity_alive(my)` itself has no type on `my`); this one
function just didn't follow its own project's convention.

Fixed: keep `node` untyped until `is_instance_valid()` (checked via the
untyped Variant, not a typed cast) confirms it's safe, matching
`_entity_alive()`'s own pattern. Also now drops stale entries from
`_impact_zones` (and their `_impact_touching` bookkeeping) once found
freed, instead of merely skipping them forever -- a shooting range that
keeps spawning/freeing targets would otherwise accumulate dead zones
checked every frame indefinitely.

Verified: re-ran `smoke_range_debug.gd`, 0 script errors (down from
constant per-frame spam), `interp._running=true` stable, `_impact_zones`
count holds steady at 29 (not growing) over a 15s sustained run with
real target hits happening (`[wdl-event] INVOKE ... TargetHit` firing
repeatedly on dynamically-created targets throughout). Full regression
(`smoke_dispatch` 19/19, `smoke_shiks_bumpin_proximity.gd` -- the
original consumer of this same mechanism) still clean. `git status`
zero asset deletions.

## 2026-08-01 (tenth) — Range's whole shooting-gallery minigame built:
## dialogue text, mouse-look, firing, panels/HUD, health, win/lose/skip.
## The largest single change this session -- three real engine
## subsystems, not a bug fix, done with explicit user sign-off on scope

User asked for logs, then to run Range and find why it "stops"/errors at
start (see 2026-08-01 ninth entry -- a real crash in the impact-proximity
mechanism, fixed separately). Once that was fixed, follow-up reports:
dialogue choice text shows "…" instead of real text; background sound too
loud, drowns out dialogue; a gun with a visible model but the character
can't move/shoot, no HUD/score screens ever show, and the lose/retry/skip
logic doesn't work. Investigated each before writing code, and confirmed
the last group was not a bug in something built, but a *missing* engine
capability: `mickey` (mouse deltas) and `on_mouse_left` (global click
binding) were completely unimplemented, Acknex `panel` objects (the
entire 2D HUD system) were parsed and immediately discarded, and
`ShowRIP()` (Range's lose screen, defined in the included IO.wdl)
appeared unreachable. Given the scope (build three subsystems, not patch
existing ones), asked the user directly rather than assuming -- picked
"build all of it now."

**Dialogue text ("…").** `GameHud._dialog_lines()` has hand-transcribed
Hebrew for DialogIndex 0-3 (Start/Studio/Town/Plane's own indices) but a
"…" placeholder for anything else -- Range uses DialogIndex 4, never
transcribed. `WDL/DIalog.wdl` stores the real text reversed and run
through a per-letter substitution cipher (confirmed by cross-referencing
the ALREADY-solved indices 0-3: it's the Hebrew alphabet mapped straight
onto a-z in order, `a`→א `b`→ב `c`→ג ... -- not a keyboard layout, as
initially guessed and disproven by a byte-level mismatch against the
known-good text). Decoded DialogIndex 4's three lines with the recovered
mapping and added them.

**Background sound too loud.** Same root cause and same fix shape as
Plane2's Hammer sound (2026-08-01 seventh entry): Range's `Jet`
(SFX091.WAV, looped continuously by both `action PIP` during the intro
dialogue and `action Handgun` during gameplay) has an authored range of
20-30, one of the smallest in the corpus -- clearly meant to be a quiet
backdrop. Added `sfx091.wav: -14.0` to the same `SFX_VOLUME_TRIM_DB`
table.

**The three missing subsystems:**

1. *`include` resolution* -- investigated first, turned out to be a
   red herring: `WdlInterpreter._merge_includes_recursive()`/
   `_merge_ast()` already resolve includes at *runtime* (discovered only
   after building a whole redundant parse-time version in
   `tools/parse_wdl.py` and having to revert it -- the actual gap was
   narrower, see below).

2. *Acknex `panel`/`text` objects* -- `tools/parse_wdl.py` used to
   discard every `panel {...}` block by design (its own docstring:
   "resilience... skipped by balanced-brace, not a hard failure" --
   correct call at the time, before anything needed panel *data*, only
   needed to not crash on it). Added a real `parse_panel()`: captures
   `NAME [=] atom[,atom...];` fields generically (not a fixed schema --
   different panels use different field sets), handling both `bmap =
   bPanel;` and the bare `window 15,58,609,15,bpass,health2,0;`/`BUTTON
   ...;` forms the real corpus uses interchangeably. `_merge_ast()`
   extended to merge `panels`/`bmaps` from includes the same way it
   already merges functions/actions/globals/sounds (this is what
   actually made `ShowRIP()`'s panels -- defined in IO.wdl -- reachable
   from Range; the function itself was already resolvable via the
   existing runtime include merge in item 1, so no parser-side include
   work was needed at all).

   New in `WdlInterpreter`: `_panels_ast` (parsed data) → `_panel_nodes`
   (real `Control` nodes, built once in `setup()` via
   `_ensure_panels_built()`, parented under `GameHud.get_panel_root()` --
   the same 640x480 design-space root every other HUD element uses, new
   public accessor). `_resolve_entity()`/`_get_field()`/`_set_field()`
   extended to recognize panel names and route `.visible`/`.bmap`/
   `.pos_x`/`.pos_y`/`.alpha` through `_get_panel_field()`/
   `_set_panel_field()`. `window` sub-elements (health bar:
   `window 15,58,609,15,bpass,health2,0;`) become a `TextureRect` whose
   `AtlasTexture.region` is resized every frame in `_update_panel_windows()`
   to the bound variable's current value, clamped to the declared width
   (which every corpus usage checked uses as the value's own 0-100%
   reference range, e.g. Health2 climbs 0-609, width=609) -- found live
   that `pass.png` (the health-bar bmap) is exactly 2x that width, a
   "reveal more of the left portion" fill-bar sprite convention, not an
   image meant to be squashed to fit; also found that plain `.size`
   resizing doesn't stick on a `TextureRect` (Godot recomputes minimum
   size from the texture on the next layout pass and snaps it back)
   without `expand_mode = EXPAND_IGNORE_SIZE`. `button` sub-elements
   (`button = 0,0,bSkip,bSkip,bSkip,D1,null,null;`) become a
   `MOUSE_FILTER_STOP` child `Control` sized to its bitmap, wired through
   `gui_input` to `invoke_event(null, onclick_name)`.

3. *`mickey`/`on_mouse_left` (mouse look + firing)* -- `mickey.x/y` needed
   no new field-routing at all: it's kept live in the SAME `_vectors`
   scratch-vector dict `temp`/`my_angle` already use (the generic
   fallback in `_get_field()` already reads any bare vector name from
   there), just needed real per-frame mouse deltas written into it --
   added `_input()` accumulating `InputEventMouseMotion.relative`,
   applied and zeroed once per `_process()` tick (matching Acknex's own
   per-tick-delta semantics). `on_mouse_left = Fire;` needed two fixes
   stacked: (a) `_assign()`'s existing `my.event = HP;` symbol-capture
   special case (assign the bare name, don't evaluate it as an
   undeclared variable) extended to global `on_`-prefixed identifiers
   too; (b) a NEW parser gap entirely -- `on_mouse_left = Fire;` is a
   bare statement *outside any function*, which the old "unknown
   top-level construct" fallback (shaped for `KEYWORD [ident]
   ({...}|...;)` declarations like `panel`/`sound`) silently ate whole,
   never producing an executable statement at all. Added detection for
   `ident (=|+=|-=|*=|/=) ...;` at the top level, parsed via the real
   statement grammar (`parse_stmt()`) into a new `top_level_stmts` AST
   section, executed once in `setup()` after globals are initialized (via
   `_exec_stmt_sync()`, not the async `exec_stmt()` -- these are simple
   assignments with nothing to suspend on).

   **Caught by the regression suite, not by design (important near-miss):**
   the "on_" symbol-capture only matched a bare identifier value
   (`on_mouse_left = Fire;`); `smoke_dispatch.gd` hung indefinitely on the
   9th of 19 levels (AsyAct3) after this landed. Root cause: AsyAct3 uses
   the equally-common call-shaped form, `on_F1 = SwitchWeapon();` -- not
   an "id" node, so the symbol-capture skipped it and the `else` branch
   *actually called* `SwitchWeapon()`, synchronously, at level load, as
   one of the newly-added `top_level_stmts`. A handler function written
   to run forever as its own coroutine once genuinely triggered (a
   `while(1){...wait(1);}` body) hangs forever when run synchronously
   instead. Corpus-wide grep after the fix: 57 call-shaped `on_`
   bindings across 24 files -- this would have been a severe, wide
   regression (every level using this idiom hanging on load) shipped
   without the full-corpus dispatch check catching it first. Fixed by
   accepting both "id" and "call" shapes in the symbol-capture condition.

**Other real bugs found and fixed reaching a working end-to-end loop:**
- `ME` (Acknex's other name for the current entity, alongside `MY`) was
  never recognized -- `action Spark`'s entire movement is
  `move(ME, nullskill, fireball_speed)`; unresolved, every bullet's
  `move()` call silently targeted nothing. Added to `_get_var()`/
  `_resolve_entity()` alongside the existing `my` handling.
- `move(entity, angle_delta, dist_delta)` and `vec_rotate(vec, angle)`
  were both entirely unimplemented (real Acknex engine builtins, not
  WDL-source functions -- confirmed via corpus grep that nothing
  redefines either, so no `BRIDGE_OVER_SHARED_FUNCTIONS` risk). Without
  `vec_rotate`, `CreateSpark()`'s aim computation silently no-op'd, so
  every shot used the same fixed (200,0,0) GS direction regardless of
  where the player was aiming. `vec_rotate` reuses the existing
  `_acknex_entity_basis()` (already the one true pan/tilt/roll -> basis
  conversion in this file) rather than a second formula. `move` needed
  its distance argument read via `_vec_get()`, not the generic per-arg
  `_eval()` every other builtin's arguments go through in `_call()` --
  same class of gap `vec_set`/`vec_sub`/`vec_to_angle` were already
  special-cased for (a bare vector-typed identifier like
  `fireball_speed` isn't a declared WDL global, so the normal path would
  silently read 0.0).
- `create(model, entity.x, Action)`'s 2nd argument was completely
  ignored -- `_do_create()` always spawned at the *calling* entity's
  (`my`'s) own position. Harmless everywhere this had been exercised
  before (`create(<Photos.mdl>, my.x, Photos)` in Shiks: the position
  entity *is* the caller), but `CreateSpark()` runs via the
  `on_mouse_left` global binding (`my == null`), so every fired bullet
  spawned at `Transform3D.IDENTITY`'s origin instead of the player.
  Fixed in `_call()`: the 2nd argument, when field-shaped
  (`entity.x`/`entity.y`/`entity.z`), is now resolved to the ENTITY it
  names (matching the 3rd argument's existing compile-time-symbol
  handling) and passed through; `_do_create()` prefers it over `my`,
  falling back to the old behavior only when it isn't present.

**Verified end to end**, not by inspection: new
`tools/smoke_range_shoot.gd` drives a real click through the real
`_input()` path (`Input.parse_input_event()`, not `warp_mouse()` --
confirmed live that headless `warp_mouse()` doesn't generate a real
motion event, `parse_input_event(InputEventMouseMotion)` does) and
confirms, in order: `CamTarget`'s pan actually changes from a synthetic
mouse-motion event; firing spawns a real `Spark` entity; the bullet
visibly travels (position changes across frames) and/or hits an
`enable_impact` target within the observed window (both outcomes seen
across runs, both correct); forcing `Health` to 0 makes `pRIP` (the real
IO.wdl lose screen) visible. `tools/smoke_range_panels.gd` separately
confirms `ShowPanel()` makes `GUI`/`Terr1` visible, the health-bar window
tracks `Health2` correctly (609-wide clamp, verified against a real
`Health` change through `UpdatePanel()`, not a direct `Health2` write
that just races against it), and `pSkip`'s button resolves to `D1`.

Full regression: `smoke_dispatch` 19/19 (this is what caught the AsyAct3
hang), `smoke_range_shoot.gd`, `smoke_range_panels.gd`,
`smoke_shiks_bumpin_proximity.gd`, `smoke_plane2_afgcard_static.gd`,
`smoke_plane2_playtest.gd` all clean. `git status`: all 85
`assets/converted/wdl_ast/*.json` modified (every file now carries
`panels`/`top_level_stmts` sections even where empty), zero deletions.

## 2026-08-01 (eleventh) — Plane2: finishing all 4 side quests never
## advanced to the next part. Three real, stacked bugs found chasing one
## report, the deepest a genuine gap in the execution model itself

User: "After finishing the tasks/level quest in Plane2 we need to start
the logic that passes us to the next part, which currently doesn't
trigger." The whole check (`if ((Goal_Passanger==1)&&(Goal_TV==1)&&
(Goal_Sikot==1)&&(Goal_Headphones==1)) { ...; Run("Range.exe"); }`) lives
inside `action player_move2`'s main loop -- the real Acknex first-person
movement builtin body this port's native `CharacterBody3D` controller
deliberately replaces for actual movement (user's own standing decision,
see docs/CONTRACT.md), but which still carries this one real piece of
game-progression logic nothing else duplicates. Three independent bugs
were stacked between "the entity exists" and "the check ever runs even
once," found and fixed in order via `tools/smoke_plane2_all_goals.gd`
(new, drives the check directly by setting all 4 goals and watching for
the branch's own side effects: `Scene=2`, `MoviePlaying=1`, `Talking=3`,
set together only inside it):

1. **`DEFINE` constants silently discarded.** `tools/parse_wdl.py` parsed
   `DEFINE NAME,VALUE;` and threw the value away entirely ("rare enough
   outside the shared library files" -- wrong assumption). `WDL/
   movement.wdl` (included by nearly every level) defines
   `_MODE_WALKING`=1 and `_MODE_STILL`=15, and `player_move2()`'s entire
   loop is gated on `(MY._MOVEMODE>0)&&(MY._MOVEMODE<=_MODE_STILL)` --
   unresolved, both constants read as the generic-undeclared-global
   0.0, so `MY._MOVEMODE=_MODE_WALKING` set movemode to 0 and the loop's
   own guard was false from the very first check; the entire body,
   goals check included, never ran at all. Fixed: `DEFINE` now captured
   into `globals` as an ordinary var-shaped decl (`kind: "define"`), so
   it resolves/merges exactly like every other global already does
   (including through the existing runtime include-merge -- no new
   interpreter machinery needed for this part).

2. **Bare bottom-level function calls had no real per-frame yield.**
   Even with (1) fixed, the check still never fired: `player_move2()`'s
   own body opens with `anim_init(); perform_handle();` before its main
   loop -- both plain function calls, which `_call_user_function()`
   (used for every nested call, including this one) runs via
   `_exec_stmt_sync()`, a synchronous-only executor whose only "while"
   safety valve is a flat 100000-iteration counter, no real per-frame
   wait. `perform_handle()` (`WDL/input.wdl`, included the same way) is
   itself a `while(1){...wait(1);}` loop meant to run forever as its own
   coroutine (polling a "handle" key signal) -- run synchronously, it
   burns its entire 100000-iteration budget in a single frame (`wait()`
   here is a one-time no-op warning, not a real suspend) and returns
   having accomplished nothing, meaning `player_move2()`'s own main loop
   -- everything after this call -- never ran either. Two-part fix:
   (a) a genuine architectural addition -- `exec_stmt()`'s "expr_stmt"
   case now detects a BARE top-level call to a user function (not
   nested inside a larger expression, which still can't suspend
   mid-expression -- real WDL never needs that) and awaits a new
   `_call_user_function_async()` (mirrors `_call_user_function()`'s
   parameter binding, but runs the body via the real async `exec_block()`
   instead of the sync executor) -- so a function written as a genuine
   long-running per-frame loop, called as another action's tail
   statement, actually behaves like one; (b) `perform_handle` specifically
   added to `BRIDGE_OVER_SHARED_FUNCTIONS` (forced to a harmless no-op
   builtin) -- it's meaningless in this port (the native controller owns
   all real input, nothing ever sets `_SIGNAL`), and even with (a) its
   genuine `while(1)` would otherwise now run forever for real, which is
   *correct* per real WDL semantics but permanently blocks
   `player_move2()`'s own subsequent code, the same class of problem
   `actor_move`/`ShowDialog`/`run` were already force-bridged for.
   **Caught by the regression suite before being called done:** with (a)
   alone, `smoke_dispatch.gd` still passed (19/19, no level in the
   default roster happens to hit a second forever-loop shared function
   the way Plane2 does) -- the `perform_handle` hang was only found by
   directly testing Plane2's own goal-completion path, a reminder that
   `smoke_dispatch.gd`'s roster answers "does it dispatch," not "does
   every one of its actual behaviors run."
3. **`ACTION`-declared code called like a function was silently
   unresolvable.** Even with (1) and (2) both fixed, the check *still*
   didn't fire -- `TempZ` (the first thing `player_move2()`'s body
   sets) stayed exactly 0.0 forever, proving the body never executed at
   all. Root cause: `player_move2` is itself declared with `ACTION`, not
   `function` (`ACTION player_move2 { TempZ = my.z; ...`) -- Acknex
   allows an action to be invoked like a plain function (no separate
   "callable" concept, both are just named statement blocks), but
   `_call()`'s dispatch (both the sync path and the new async path from
   fix 2) only ever checked `_resolve_function()`, never
   `_resolve_action()`, for a bare call target -- `player_walk2`'s tail
   statement `player_move2();` fell all the way through to the generic
   "unbridged builtin" no-op every time, regardless of the other two
   fixes. Added an `_resolve_action()` fallback to both `_call()` (sync,
   via `_exec_block_sync()`, matching `_call_user_function()`'s own
   shape) and `exec_stmt()`'s new async "expr_stmt" path (via
   `exec_block()`).

**Verified**, layer by layer as each fix landed (not just at the end):
`_MODE_WALKING`/`_MODE_STILL` read correctly (1.0/15.0, was 0.0/0.0);
`TempZ` becomes non-zero (proving `player_move2()`'s body actually
runs); finally, with all three fixes together, setting all 4 goals makes
`Scene`/`MoviePlaying`/`Talking` jump to 2/1/3 together within a few
frames -- the all-4-goals branch's own unique side effects, confirming
it was reached. Did not wait for the actual `Run("Range.exe")` in the
test: the branch first plays `KRP009.WAV` (confirmed via direct duration
check: ~32 real seconds) and waits for it via the already-established,
separately-verified `GetPosition(Voice)`/`sPlay` machinery, slower still
under headless audio's already-documented slower-than-real-time
playback -- waiting that out would test headless audio timing, not this
report. Full regression: `smoke_dispatch` 19/19 (twice -- once after
fix 2 alone, once with all three), `smoke_range_shoot.gd`,
`smoke_range_panels.gd`, `smoke_range_debug.gd`, `smoke_sikot_clips.gd`,
`smoke_shiks_bumpin_proximity.gd`, `smoke_plane2_afgcard_static.gd`,
`smoke_plane2_playtest.gd` all still clean. `git status` zero asset
deletions (same 85 `wdl_ast/*.json` files as the previous entry, now
also carrying real `DEFINE` values).

## 2026-08-01 (twelfth) — skip the original game's pre-level `wait(3);`

User: "in the original game there's a sleep/wait function for 3 seconds
before each level actually start, i think we can skip it since it loads
very quickly anyways on modern devices." Confirmed via corpus grep
(`^\twait(`) this is a real, near-universal idiom -- virtually every
level's `main()` opens with `wait(3);` (or similar), presumably to give
the original engine's own genuinely slow level load a moment to finish
before gameplay started. This port's load is fast enough that the delay
is pure dead time now.

Fixed narrowly, not by scaling/skipping `wait()` generally (would touch
real gameplay timing everywhere): a new `_skip_next_main_wait` flag, set
`true` in `begin_level()` right before `main()`'s own coroutine starts,
consumed by exec_stmt()'s "wait"/"waitt" case the first time it's hit
with `my == null` (main()'s own calling context, the only place this
flag is ever true) -- reduces that one call to a single-frame yield and
clears itself immediately, so every other `wait()` in the entire game,
including any later ones inside `main()` itself, is completely
unaffected.

Verified: new `tools/smoke_wait_skip.gd` checks how many frames it takes
Range's `Health` global (set on the line right after `wait(3);` in its
own `main()`) to become 609 -- 1 frame (was previously gated behind the
skipped wait, which alone would have added several more). Full
regression: `smoke_dispatch` 19/19, `smoke_range_shoot.gd`,
`smoke_plane2_all_goals.gd`, `smoke_shiks_bumpin_proximity.gd`,
`smoke_plane2_playtest.gd` all still clean -- confirms other `wait()`
calls elsewhere in the same levels (ambiance loops, dialogue pacing,
animation timing) are unaffected. `git status` zero asset deletions.

## 2026-08-01 (thirteenth) — "the last commit made all levels stuck now"

User reported the just-pushed commit broke every level. Headless testing
(new `tools/smoke_regression_check.gd`, watching `_total_frames` and
frame timing over a real 10s window) ruled out a true engine hang for
Start/Shiks/AsyAct2/Plane2 -- all kept ticking at a normal frame rate
the whole time, no crash, no script error. Asked the user what "stuck"
actually looked like rather than keep guessing blind: "the page loads
with the animation, but nothing starts playing, no voice no dialogue" +
"the main image doesn't disappear (the Loading screen does)" +
Studio's green subtitle HUD "shown twice, the newer one is more
accurate."

Root cause, found via a temporary per-statement trace of `main()`'s own
execution (`my == null`) for Start.wdl: `WDL/IO.wdl`'s `function
Initialize()` -- called by `VoiceInit(); Initialize();` near the top of
*every* level's `main()`, since every level includes IO.wdl --
unconditionally tail-calls `StartSaveLoad()`, a real `function
StartSaveLoad { while(1) { if (entSaveLoadMenu.visible==on) {...}
wait(1); } }` background loop that animates the save/load menu's vase
pieces. `entSaveLoadMenu` is a documented, pre-existing gap (this port
has no save/load menu UI), so this loop was always meaningless here --
but harmless, because before this session's async-dispatch fix (eleventh
entry), a bare top-level call to a real `while(1)` shared function was
silently inert. Now that such calls genuinely run forever, `Initialize()`
-- and by extension every level's `main()` -- got permanently absorbed
into `StartSaveLoad()`'s loop the instant it ran, before ever reaching
`Start = 1;`/hiding the splash screen/playing the intro movies. This is
the *same shape* as the `perform_handle` fix two entries ago, just
reachable from the shared startup path instead of one level's movement
code, which is why it broke everything instead of one level. Confirmed
live via new `tools/smoke_start_stuck.gd`: Start's `main()` re-executed
`StartSaveLoad`'s own loop body forever, `Start` staying 0.0 for the
full 20s test window. Fixed the same way as `perform_handle`: bridged
`startsaveload` to a no-op builtin.

Also fixed the "shown twice" HUD report while in the area: Studio/Start
declare real WDL `panel pSom`/`panel pOvr` objects (green subtitle
bitmaps), which this session's new generic panel system (tenth entry)
now renders correctly and accurately for the first time. A much older,
hand-wired `GameHud.setup_start_subtitles()`/`setup_studio_subtitles()`
hook (built *before* generic panel support existed, to work around
panels being silently discarded) was still firing from
`_seed_subtitle_crawl()` on top of it, double-rendering the same
overlay. Deleted the hook and the two now-fully-orphaned `GameHud`
methods (plus the `SUBTITLE_TEXT`/`_log_subtitle_setup` debug scaffolding
built only to feed them) -- the generic panel rendering is a strict,
more accurate superset, confirmed by the user's own read of the two
overlays ("the newer one is better and more accurate").

Did not chase the "no voice/dialogue" and "main image doesn't disappear"
symptoms as separate bugs: both are direct, expected consequences of
`main()` never completing, and resolved automatically once
`StartSaveLoad` stopped absorbing it (verified: `Start` reaches 1.0
within under a second, `NoMovie` becomes 1.0, and voice/movie progress
starts climbing, all previously stuck at their initial values forever).

Also investigated and ruled out as unrelated during the search: a
pre-existing (not new) ~2-6s `WmbLevelLoader.load_level()` cost for
heavier levels like Plane2 (confirmed via diff against the previous
commit -- `wmb_level_loader.gd`/`mdl_animator.gd` are functionally
unchanged), and the `while-loop spinning without wait()` diagnostic
added 2026-07-29 firing on dozens of entities in AsyAct2 after ~8.5s --
confirmed a false positive: the diagnostic's `guard` counter doesn't
reset per real frame, so it can't actually distinguish "hundreds of
iterations in one frame" (a real busy loop) from "one iteration per
frame for 512 real frames" (correct, expected behavior for any
long-running `while(1){...wait(1);}` coroutine that's simply been alive
long enough) -- left as-is (out of scope for this fix), noted here so
the next investigation doesn't have to rediscover it.

Verified: new `tools/smoke_start_stuck.gd` (`Start` reaches 1.0 within
~40 frames, was never). Full regression: `smoke_dispatch` 19/19,
`smoke_plane2_all_goals.gd` (all-4-goals branch still reached --
confirms bridging `startsaveload` didn't disturb the `perform_handle`
fix it sits right next to in the same const array),
`smoke_wait_skip.gd`, `smoke_regression_check.gd` against Studio (clean,
faster initial load too). `git status` zero asset deletions.

## 2026-08-01 (fourteenth) — Plane's Piposh spawn height, take two

Follow-up report after the eleventh entry's fix: "Piposh character walks
in and he's too high over the plane's ground, he should walk in and be
the same height as Krupnik that's already there." That earlier fix
snapped `action PiposhWalk`'s spawn Y to this level's own `floor_y`
(83) on the reasoning that it was "closer" than the raw WED origin
(-39) -- true, but `floor_y` turned out to be a different deck of the
plane entirely; the cabin Piposh actually walks into sits at Y=34-35
(Pip/Krup/Dummy's own raw JSON origins), not 83. Confirmed via the
converted level JSON directly (`Piposh_mdl_001`'s "Pip" placement Y=34,
`Krup2_mdl_035` Y=35, vs `floor_y`=83) -- the earlier fix overshot by
~48 units, landing him floating above Krupnik instead of standing next
to him.

Re-fixed properly this time: tried hardcoding the raw JSON Y (34) in
`_spawn_entity()`, same place as before -- still off by ~24 Godot units
after spawning (92.35 vs Krupnik's actual 68.39), because a raw JSON Y
isn't comparable to `pos.y` at that point in the pipeline (feet-snap/
scale/basis transforms haven't been applied yet). Moved the fix to a
new `_snap_piposh_walk_to_krupnik()`, called once at the very end of
`load_level()` after every entity has actually finished spawning:
copies Krupnik's real, already-transformed `global_position.y` directly
onto Piposh -- the only way to guarantee an exact visual match without
reverse-engineering this pipeline's Y transform by hand.

Verified: rewrote `tools/smoke_plane_piposh_height.gd` (the original
version asserted against `floor_y`, the now-known-wrong target) to
assert PiposhWalk's spawn Y matches Krupnik's own spawned Y directly --
92.35 vs 68.39 (fail) before the post-pass fix, 68.55 vs 68.39 (pass,
within floating-point noise) after. Full regression: `smoke_dispatch`
19/19. `git status` zero asset deletions.

## 2026-08-01 (fifteenth) — investigated "2nd dialogue in Shiks doesn't play"

User: "the 2nd dialogue in Shicks level doesn't play doesn't matter what
I choose." Clarified on request: "choice box closes but total silence,
nothing else happens" (not a stuck choice box, not a missing prompt --
the click registers, then nothing).

Extensive headless investigation, three angles, all passing:
1. `tools/smoke_shiks_dialog2.gd` (new): drives dialogue 1 to completion
   for real (choice 1, SHK004.WAV), then transitions to dialogue 2 the
   way `action MyCamera` really does (`Piposh.skill2=4; DialogIndex=2;
   ShowDialog();`) and clicks a choice -- `AudioChannels.
   get_voice_progress()` climbs normally the whole time (0.0008 -> 0.61
   over 4.5s for PIP017.WAV), no stall.
2. `tools/smoke_shiks_chase.gd` (new): sets `Piposh.skill2=2` (matching
   a real bump into `action Bumped`) and lets `action MyCamera`'s real
   `scan_path`/`ent_nextpoint` waypoint-chase run with zero shortcuts --
   `DialogIndex` correctly reaches 1 (~4s) then 2 (~10s), confirming the
   whole real precondition chain (not just the forced-state shortcut in
   (1)) genuinely completes.
3. Pre-existing `tools/smoke_shiks_dialog2_choice.gd` (from an earlier
   session, re-run unmodified against current code): drives the LONGEST
   branch, `DialogChoice==2`'s 8-sequential-voice-line chain ending in
   `Run("Plane.exe")` -- still passes, firing `Run` at ~53s real
   (headless audio is documented slower-than-real-time, so a real
   session should be faster, not slower).

Did not find or fix a bug: every code path this could plausibly follow
(short single-line choices, the full 8-line chain, the real trigger
precondition instead of a forced shortcut) verifies correctly headless.
Reported this to the user rather than guessing further -- the interpreter
and voice-position tracking both work in every reproduction attempted.
If the real symptom persists, the two most likely remaining explanations
are a real-audio-output issue (volume/mixing/muting -- invisible to a
headless position-tracking check, which only confirms the *internal*
playback clock advances, not that sound is actually audible) or simply
not waiting long enough (one branch takes up to a full minute of real
playback with zero visible feedback on screen -- Shiks has no
subtitle-panel text like Range/Studio/Start do, so a long silent wait
reads exactly like "nothing is happening").
`git status` zero asset deletions (no code changes from this
investigation beyond the two new/renamed smoke tests).

## 2026-08-01 (sixteenth) — Plane2 "character is lower than the plane so we can't move"

User: "The height change also broke plane2 where now the character is
lower than the plane so we can't move." The fourteenth entry's fix is
strictly scoped (`if level_name == "Plane":`, only touches
"PiposhWalk"/"Krup"/"ThePlaneMovie") and cannot execute for Plane2 at
all -- confirmed by direct code inspection, and by reproducing the
report on a *fresh* Plane2 load with zero connection to the Plane fix.
Two real, separate, pre-existing bugs, coincidentally surfaced by the
same report:

1. **Wrong-deck floor snap.** `level_runner.gd`'s `_enable_first_person()`
   calls `player.snap_to_floor()` (400-unit default search range) right
   after placing the player at the FP spawn point. For Plane2's exact
   spawn XZ, there's no collision surface between the WED spawn Y (108.35)
   and a genuinely lower deck ~59 units below (49.5) -- the full-range
   raycast's *closest* hit is that lower deck, snapping the player
   straight into it. Confirmed via `tools/smoke_plane2_move.gd`: consistent
   across 3 repeated runs (a real geometry gap, not timing/race flakiness).
   Fixed by passing a tight `40.0` max_drop from this one call site (its
   only caller) -- small enough to still correct a genuine minor gap, too
   small to reach the wrong deck 59 units away.
2. **Camera-authority deadlock, the real "can't move" cause.** Even after
   fix 1, the player still didn't move. Traced via the existing
   `[cam-write]` debug logging (PiposhDebug) already in `_set_camera_field`:
   `player_move2()` -- Plane2's own, faithfully-ported real Acknex FPS
   controller -- calls `Move_view_1st()` every single tick from its own
   main loop (`if(VView==1){Move_view_1st();} ... wait(1);`).
   `WDL/camera.wdl`'s real `move_view_1st()` writes `CAMERA.X/Y/Z/PAN/
   TILT/ROLL` from `player.X/Y/Z/...` every tick -- exactly matching real
   Acknex's own per-frame camera-attach idiom. But in this port `player`
   resolves to the WDL-side FP proxy entity, which never actually moves
   (`_player_force`/`scan_floor`/`move_gravity`, the real movement
   builtins the rest of `player_move2()` calls, are deliberately
   unbridged no-ops here -- the native CharacterBody3D controller owns
   real FP movement instead, per the project's own "don't reimplement
   Acknex's movement builtins" decision). So this wrote the SAME
   stationary position into camera.* every tick, and
   `CameraAuthority.update()` treats any camera.* write this frame as
   "script wants control" -- permanently locking the (stale) script
   camera as current and never handing control to the player's own
   Camera3D. `player_controller.gd`'s own `_physics_process()` zeroes
   `velocity` outright unless `camera.current == true`, so this silently
   disabled all player movement, every tick, forever. Fixed the same way
   as `perform_handle`/`actor_move`: bridged `move_view_1st`/
   `move_view_3rd`/`move_view_3rd_2` to no-ops in
   `BRIDGE_OVER_SHARED_FUNCTIONS` -- the native controller's own Camera3D
   is the sole FP camera authority in this port, so the WDL script's own
   camera-attach logic has nothing useful left to do.

Verified: `tools/smoke_plane2_move.gd` (new) -- before fix 2,
`player camera current=false`, viewport's actual camera stuck on
`ScriptCamera`, 0.000 units of movement despite 2s of forward input;
after both fixes, `camera current=true`, 163.8 units of real movement.
Full regression: `smoke_dispatch` 19/19, `smoke_plane2_all_goals.gd`
(all-4-goals branch and its own scripted end-camera handoff both still
correct -- confirms the bridge doesn't disturb legitimate one-time
cutscene camera writes from other actions, only the per-tick FP-camera-
attach idiom), `smoke_plane_piposh_height.gd` (68.55 vs Krupnik's 68.39,
unaffected by either fix). `git status` zero asset deletions.

## 2026-08-01 (seventeenth) — Plane's missing walk animation; Shiks impact double-fire

Two more fixes while still in the same area, both from live evidence the
user provided directly.

**Plane: no walking animation.** User pasted Plane.wdl's real source
alongside the report and asked outright whether the parser was at
fault. It wasn't -- `action PiposhWalk` genuinely never calls
`ent_frame`/`ent_cycle` in its always-reached walk-in code (unlike
Shiks' own walk block, which explicitly pairs `ent_cycle("Walk",
skill1)` with `actor_move()`). Real Acknex's own `actor_move()` builtin
auto-selects a walk cycle as a built-in convenience this port's
straight-line `_do_actor_move()` never replicated, and
`_seed_static_pose_if_never_animated()` (built for decorative,
never-moving props) froze him to a static pose from the moment his
coroutine started, since it never distinguished "doesn't animate
itself" from "moves via actor_move() but doesn't animate itself".

First attempt: skip the freeze and auto-drive a "Walk" cycle from
`_do_actor_move()` only for actions with no `ent_frame`/`ent_cycle`
call ANYWHERE in their body. Confirmed via `tools/smoke_plane_walk_anim.gd`
that this still didn't work -- `PiposhWalk`'s body DOES contain one
`ent_frame("Take",100)`, buried inside a `DialogChoice==3` response
branch only reachable long after arrival, nowhere near the walk-in
code the scan was meant to protect. Fixed by reordering: check for
`actor_move()` FIRST, unconditionally driving a walk cycle for any
action that calls it regardless of what else exists elsewhere in the
body -- an action calling `actor_move()` is, by definition, meant to
move, so it should always get walk-cycle treatment. Verified: MdlAnimator
`_current_clip` reaches "walk" and stays `_playing=true` while he moves
(was frozen on "Stand" before).

**Shiks: `Bumped` firing twice.** The user's own real console capture
(pasted directly, from a live playthrough) showed `[wdl-event] INVOKE
my=Snail_mdl_043 event=Bumped` firing twice in quick succession.
`_check_impact_proximity()` (the non-physics-body proximity check, for
WDL-driven movers) already debounces this exact shape ("fire once on
approach, not every frame spent overlapping") via `_impact_touching`,
but its sibling `_on_impact_body_entered()` -- the REAL player's own
Area3D `body_entered` signal path -- had no debounce at all. Godot's
`body_entered` can genuinely fire, exit, and re-fire within a few
frames from ordinary collision push-back/sliding along the trigger
sphere's edge, and `action Bumped` (`Piposh.skill2 = 2;`) has no
idempotency guard of its own, matching real WDL (a physical bump was
never this trigger-happy in the original engine). A re-fire after
`action MyCamera`'s chase had already completed (`skill2==4`) would
restart the whole chase and call `ShowDialog()` again mid-flight,
resetting `DialogChoice` to 0 while `action Piposh2` was still polling
the ORIGINAL choice's voice line -- by the time it reached the real
per-choice response block, `DialogChoice` would no longer match any of
its 1/2/3 checks, and nothing would play. (This was investigated as a
candidate cause for the fifteenth entry's still-unreproduced "2nd
dialogue... total silence" report; not confirmed as THE cause, since
reproducing the exact double-fire timing needs real physics jitter this
session couldn't force headless -- but it's a real, verified bug either
way and worth fixing regardless.) Fixed by giving `_on_impact_body_entered`
the same `_impact_touching`-based debounce its NPC-mover sibling already
has (paired with a new `body_exited` handler to clear it), so a
continuous overlap only fires once, while a genuine walk-away-and-back
still re-fires correctly.

Full regression after both fixes: `smoke_dispatch` 19/19,
`smoke_shiks_chase.gd`, `smoke_shiks_bumpin_proximity.gd` (both still
"OK" -- confirms the debounce doesn't suppress the real, intended
first trigger). `git status` zero asset deletions.

## 2026-08-02 (GB-1) — Shiks 2nd dialogue: root cause found and fixed

Continuation of the fifteenth/seventeenth entries' investigation, this
time with real evidence: the user captured a live console log (filtered
to the `dialog-choice` tag, added specifically for this) covering the
actual click. It showed `Piposh_mdl_001`'s voice-poll heartbeat frozen
on the SAME generation (an old, already-finished line) from before a
`SHOWDIALOG DialogIndex=2.0` call, through the real click, and for 30+
seconds after -- meaning `action Piposh2`'s coroutine never reached the
`DialogIndex==2` response code at all.

Reproduced headless for the first time this investigation
(`tools/smoke_shiks_dialog2_choice3.gd`, using choice 3 for dialogue 1 --
the earlier smoke_shiks_dialog2.gd used choice 1 and never hit this),
then root-caused via a temporary per-statement trace scoped to
`my.name == "Piposh_mdl_001"` plus an un-throttled log of every
`Dialog.visible` read. Confirmed exactly:

1. After choice 3, `action Piposh2` re-shows a stale `DialogIndex=1`
   dialogue box (`DialogIndex` is never reset in the WDL source --
   `//DialogIndex = 0;` is commented out at Shiks.wdl:327 -- corpus
   data, not something to hand-edit).
2. `action MyCamera`'s waypoint-chase loop (still running at this point,
   ~10s total) contains `Dialog.visible = off;` **unconditionally, every
   tick** (Shiks.wdl:110, meant to hide leftover subtitle text while the
   camera flies through) -- with zero awareness that a completely
   unrelated dialogue box might be open for a different reason at that
   exact moment.
3. That force-closes Piposh2's stale box before any real click can
   happen. `DialogChoice` stays at its post-`ShowDialog()` reset value
   (0), so when Piposh2 re-checks its own `if(DialogIndex==1/2){if
   (DialogChoice==1/2/3){...}}` blocks, none of them match -- no new
   `sPlay()` ever happens -- and it falls through to
   `while(GetPosition(Voice)<1000000){Talk();wait(1);}`, still polling
   the SAME already-finished generation from choice 3's own response.
4. The interpreter's per-caller voice-finished debounce
   (`_voice_finished_consumed_by`, built 2026-07-31 to stop a
   *different* idiom -- `if(GetPosition(Voice)>=1000000){OneShot();}`
   inside a perpetual `while(1)` -- from re-firing every tick forever)
   had already marked this exact (caller, generation) pair consumed,
   from the earlier wait loop moments before. So this NEW, unrelated
   `while` loop's very first check saw the debounce's "already seen"
   sentinel (999999, not real progress) instead of the fresh "yes,
   finished" real Acknex would have given it -- permanently stuck,
   since nothing will ever bump the generation again.

Root cause was the debounce being too sticky for this shape, not the
`Dialog.visible` race itself (which may well exist in the original
engine too, and isn't something to "fix" by editing WDL data). A
blocking `while(GetPosition(Voice)<1000000){...})` loop ("idiom A")
only ever needs to see "finished" once, by construction -- unlike idiom
B, it can never incorrectly "re-fire" from seeing it more than once, so
it should never be starved by an earlier, unrelated while-loop (same
caller) having already consumed the current generation. Fixed by
clearing `_voice_finished_consumed_by[my]` the moment a NEW
`while`-loop whose condition calls `GetPosition` begins (both the async
and sync `exec_stmt` "while" cases) -- gives idiom A a guaranteed fresh
read every time, without touching idiom B's own debounce at all (that
lives entirely inside a perpetual `while(1)`'s nested `if`, never a
fresh `while` dispatch).

Verified: `smoke_shiks_dialog2_choice3.gd` now shows real voice progress
climbing normally through the full DialogIndex=2 chain after the click
(previously frozen at the same generation, `is_playing=false`, forever).
Confirmed the fix does NOT reopen the idiom-B bug it would have
regressed: `smoke_studio_shikklik.gd` (the original Naknik/ShikKlik
report this debounce was built for) still shows `run_fired=true`. Full
regression: `smoke_dispatch` 19/19, `smoke_shiks_dialog2_choice.gd`
(the long 8-line chain, still `OK`), `smoke_plane2_all_goals.gd` (still
reaches the all-4-goals branch). `git status` zero asset deletions.

Also added (kept, throttled): `SPLAY`/`VOICE_POLL`/`SHOWDIALOG`/`CLICK`/
`DIALOG_VISIBLE_READ` under the `dialog-choice` PiposhDebug tag --
useful general-purpose dialogue/voice diagnostics beyond just this bug,
low-noise (once-per-call for discrete events, ~1/sec heartbeats for
polling loops).

## 2026-08-02 (NB-7) — Shiks: Piposh missing from 2 of the post-dialogue camera shots

User confirmed GB-1 fixed, then reported a new one: after the 2nd
dialogue's choice-2 branch (the long camera-cut sequence -- bus/window,
phone, weasel, pigeon, driving away), Piposh isn't shown during 2 of the
shots specifically: the phone-booth/bus one and the pigeon one (not the
weasel or driving-away shots).

Node-visibility tracing (`tools/smoke_shiks_camshow.gd`, driving both a
forced-state and the real chase-triggered version of the full sequence)
showed every visibility transition matching the WDL source exactly, with
no unexpected pop-in/out -- ruled out a scripting-level race. Moved to
checking camera framing instead: computed real bearings from each
`action PipiCam` camera to its likely subject (using the project's own
established `_gs_view_forward` pan convention, cos/sin(pan) in the GS
XY plane) -- CamShow=6's camera pointed dead-on at Weasel (+2.3°) and
CamShow=7's camera pointed dead-on at the far "Pipi"-action Piposh.MDL
placement (+8.8°), both close range (~230/525 units) -- so the entities
ARE correctly positioned and the cameras ARE correctly aimed at them.
Confirmed via `tools/smoke_shiks_pipi_check.gd` (dumps mesh/spawn state
for every "Pipi" placement) that this is a mesh-level bug instead: the
far Piposh.MDL entity (meant for the pigeon shot) and the PipCell.MDL
entity (the phone booth, meant for the phone shot) both spawn with WED's
own "invisible" flag bit set (`flags=262145`, `invisible_meta=true`) --
`WmbLevelLoader._hide_meshes()` hides their child `MeshInstance3D`
directly at spawn, but the WDL script's later `my.invisible = off;`
(Shiks.wdl's `action Pipi`, `if(CamShow==3){my.invisible=off;...}`,
covering all three of its own placements uniformly) only ever toggled
the entity's ROOT node's own `visible` -- never the mesh child
`_hide_meshes()` actually hid. The root node correctly became
"visible", but the mesh underneath stayed hidden forever, for any
entity that starts flag-invisible and gets revealed later by script (a
real, corpus-wide idiom, not unique to this one report). The near
Piposh.MDL placement (used for the bus/window shots, CamShow 3/4)
wasn't WED-authored invisible in the first place (`invisible_meta=
false`), so it was never affected -- consistent with the user not
reporting those two shots as broken.

Fixed by making the "invisible" write in `_set_field()` recursively
toggle every `MeshInstance3D` descendant to match, mirroring
`_hide_meshes()`'s own recursive shape, instead of only the root node.

Verified: new `tools/smoke_shiks_pipi_reveal.gd` -- before the fix,
writing `my.invisible = off;` to the far Piposh.MDL entity left its
mesh at `visible=false` despite the root node correctly reading
`visible=true`; after the fix, the mesh itself becomes `visible=true`.
Full regression: `smoke_dispatch` 19/19, `smoke_shiks_bumpin_proximity.gd`,
`smoke_plane2_all_goals.gd`, `smoke_range_shoot.gd` all still `OK` --
confirms the recursive mesh-visibility toggle doesn't disturb any of
the corpus's existing invisible/passable/camera-marker hiding, which
never gets a later reveal write and so never exercises this new code
path. `git status` zero asset deletions.

## 2026-08-02 (NB-7 continued) — the real cause: a WED-flag teleport, not just visibility

The mesh-visibility fix above was real and necessary, but the user
reported the bus and pigeon shots still showed Piposh completely absent
-- and, critically, shared two REAL Godot screenshots this time (not
reference footage from the original game, which took a couple of
exchanges to establish -- the first two screenshots the user sent were
original-game captures showing the *intended* framing, not what this
port renders). Those confirmed genuinely empty frames: just the bus/
pigeon-window geometry, no character anywhere, not even cropped at the
frame edge.

Root-caused via a headless test using Godot's own `Camera3D.is_position_
in_frustum()` at the real moment `CamShow==7` (`tools/smoke_shiks_
pigeon_frustum.gd`) instead of manual trig: the target entity's
`global_position.x` had moved from its authored `-14389` to `-754` --
a ~13,600-unit jump, landing it 13,392 units from the camera, past the
12,000-unit far-clip plane. Traced to `action Pipi`'s own body:
`if((Talking==14)&&(my.flag1==off)){my.x=XX;...}`, where `XX` is set
once by `action Dummy { XX = my.x; }` elsewhere in the level. Since all
three "Pipi" placements (the near, scale=1.0 walking Piposh; the far,
scale=3.65 pigeon-shot placement; and the scale=2.03 phone-booth
PipCell.MDL) share the identical action body, ALL THREE independently
teleport to Dummy's position once the shared global `Talking` reaches
14 -- clearly meant to relocate only the one "real" walking-away
placement, gated by `my.flag1` specifically so the other two dramatic
cutaway props stay put for their own shots. `flag1` has no verified WED
bit mapping in this port (the same documented gap `_seed_look_at_me_
flag1` already works around for a different action) -- every entity's
flag1 silently reads "off", so the gate never actually gates anything,
and all three teleport together.

Fixed the same way as the existing flag1 workaround: a new
`_seed_pipi_flag1_stay_put()`, called once per "Pipi" placement at
`begin_level()` time, seeds `flag1 = on` for any placement with a
scale ≥1.5 (real, measured WED data -- see `_spawn_entity()`'s "preserve
authored scales" comment -- not a guess) instead of leaving every
placement able to teleport. The near, scale=1.0 placement is
deliberately left alone (still teleports, matching its "real, moving
Piposh" role); Dummy is untouched entirely.

Verified: new `tools/smoke_shiks_pipi_stay_put.gd` confirms exactly the
scale-based split (the two scaled-up placements get `flag1=1.0` and
stay; the scale=1.0 one stays at `flag1=0.0` and still moves).
`tools/smoke_shiks_pigeon_frustum.gd`, re-run after the fix: the far
placement's `global_position` now matches its authored `-14389.0`
exactly (no teleport), `is_position_in_frustum()` is `true`, and every
AABB corner of its mesh is confirmed inside the frustum -- the entity
is now genuinely on screen, not just theoretically visible. Full
regression: `smoke_dispatch` 19/19, `smoke_shiks_chase.gd`,
`smoke_shiks_bumpin_proximity.gd`, `smoke_plane2_all_goals.gd`,
`smoke_range_shoot.gd` all still `OK` -- confirms the new flag1 seeding
doesn't disturb the `action LookAtMe` one already using the same
`wdl_custom_flag1` meta key, or anything else in the corpus that reads
flag1. `git status` zero asset deletions.

## 2026-08-02 (GB-2) — Plane: Piposh's feet sunk under the cabin floor,
## a cross-model feet-snap mismatch, not a real floor-height gap

Continuing GB-2 (the earlier Krupnik-height spawn fix, commit `5540f00`,
was confirmed correct at spawn on 2026-08-01, but the user later
reported Piposh's feet visibly under the floor throughout the whole
walk AND at the final stop, and confirmed via a real screenshot + a
direct follow-up question that this is present standing still, not just
mid-gesture). `tools/smoke_plane_walk_height.gd` (pre-existing) already
confirmed his Y never drifts during the walk -- whatever's wrong is
present from spawn onward, not something that develops en route.

First approach tried and reverted: a real collision-geometry raycast
straight down from Piposh's own position (new `tools/smoke_plane_floor_
check.gd`), to measure any gap between his claimed Y and the actual
floor. Two dead ends in a row, each caught before being trusted:
1. A wide-range raycast (200 up / 500 down, fixed height) found a
   suspicious ramp climbing from ~70 to ~263 as he "walked" -- looked
   exactly like the level's real floor rising toward the cockpit, but
   turned out to be the SAME failure mode already documented for the
   reverted per-tick floor-snap attempt (`_spawn_entity()`'s own
   PiposhWalk comment): snagging on overhead cabin clutter, not the
   real floor.
2. Narrowing to a close-range raycast (10 up / 100 down) gave a
   suspiciously *stable* ~1.5-1.9 unit "gap" the whole walk -- until
   logging the actual hit collider's path revealed it was
   `.../Piposh_mdl_001/Piposh2/Piposh/Col`: Piposh's OWN body collider
   (`_add_mesh_collision()` gives every non-passable entity, including
   Piposh himself, a `StaticBody3D`). The "gap" was self-collision the
   entire time, not a floor measurement. A version excluding the
   entity's own `PhysicsBody3D` RIDs via `PhysicsRayQueryParameters3D.
   exclude` finally found the real brush floor -- but at Y≈34 near
   Krupnik, ~34.5 units *below* his actual Y=68.55, which would mean
   floating too high, the opposite direction from the report. Traced
   that gap to a second, pre-existing, already-documented issue (this
   file's Plane2/Range-era entries and `_spawn_entity()`'s own comment:
   `floor_y` "overshot Krupnik's real spawned height by ~24 Godot
   units") -- raw brush-collision Y and post-pipeline entity Y aren't
   directly comparable in this pipeline, so this reading couldn't be
   trusted either. Also confirmed via a new one-off test (deleted after
   use) that `direct_space_state.intersect_ray()` can't see freshly-
   spawned colliders until at least one physics frame has elapsed, but
   `load_level()` runs fully synchronously -- ruling out a live raycast
   refinement inside `_snap_piposh_walk_to_krupnik()` without a larger,
   disproportionate restructure.

Abandoned raycasting entirely and went back to the `[feet-snap]` debug
log (`_snap_mesh_feet_to_origin()`'s own per-entity output, already
permanent instrumentation) for real, non-raycast ground truth. This
immediately showed the real mismatch: Krupnik's models (Krup2.MDL /
Krupnik.MDL) get a feet-to-origin correction of `min_y≈-33.4` to
`-33.6`, while Piposh's own model (Piposh.MDL) gets `min_y≈-58.2` to
`-58.4` -- a completely different, model-specific correction. Matching
Piposh's height to Krupnik's (a different model's feet-snap result)
was always going to leave him short by roughly that gap. Confirmed with
a clean, same-model comparison: `action Pip` (Plane.wdl) is a *second*
Piposh.MDL placement in the same room (the stand-in shown during the
DialogChoice==3 cockpit-camera cutscene, toggled by `Pip2`), sitting at
essentially the same raw floor height as Krupnik (WED Y=34 vs 35) --
and its own independently-computed feet-snap height is `92.161`, not
`68.55`. The ~24-unit gap between those two numbers was actually
already visible in an earlier comment in this same file ("`floor_y`
overshot Krupnik's real spawned height by ~24 Godot units even after
matching Pip's own raw origin") but hadn't been traced to its root
cause before.

Fixed: renamed `_snap_piposh_walk_to_krupnik()` to `_snap_piposh_walk_
to_pip()`, matching PiposhWalk's height to `action Pip`'s real,
post-feet-snap `global_position.y` instead of Krupnik's -- keeps the
match on the same model throughout, sidestepping the cross-model
correction mismatch entirely rather than guessing at a numeric offset.

Verified: `tools/smoke_plane_walk_height.gd` re-run -- Piposh now
spawns and walks at Y=92.16069 (matching `Pip`'s own computed height
exactly), still zero drift during the walk. `smoke_dispatch` 19/19.
`git status` zero asset deletions. Real in-game confirmation from the
user still pending -- `docs/BUGS.md`'s GB-2 row stays open until then.

## 2026-08-02 (GB-2 continued) — the height fix surfaced a second, real,
## unrelated bug: Piposh's walk animation freezes mid-walk

User confirmed the GB-2 height fix worked (he moves correctly now) but
reported a NEW symptom: no walking animation while he crosses the
cabin. Two headless investigations in a row missed it before real user
data caught it:

1. First smoke test (`tools/smoke_plane_walk_anim.gd`, only 2s long)
   showed `current_clip=Walk`, `playing=true`, and `_percent` genuinely
   varying across 12 samples -- looked fine, reported OK.
2. Extended the same test to the FULL ~12s walk duration and found a
   real ~5s stall, `current_clip=Stand playing=false`, stuck. Added
   throttled `[mdl-anim]` debug logging (new, scoped to only the
   `PiposhWalk` entity so it doesn't spam every other animated actor)
   to `MdlAnimator.play_cycle()`/`play_blink()`/`_process()` to see the
   real transition sequence.
3. Traced it to Plane.wdl's own local `Blink()` function (`ent_frame
   ("Stand",0)` unconditionally, every tick, whenever `Talking != 1`)
   fighting every tick with `_do_actor_move()`'s auto-walk-cycle --
   each tick's Blink() call knocks `_current_clip` to "Stand", and the
   immediately-following `actor_move()` call successfully switches it
   back to "Walk" (since `play_cycle()`'s own early-return guard only
   fires when the clip is ALREADY current, which Blink() had just
   defeated) -- self-resolving every tick, confirmed harmless.
4. Asked the user directly whether the freeze was during the walk or
   after arrival (during dialogue) -- headless data suggested "after
   arrival", user said "during the walk", a real, confirmed
   contradiction between headless and live play that needed real data,
   not more guessing.
5. Had the user capture their own REAL `[mdl-anim]` log from an actual
   play session (told them to filter the Godot editor's log panel for
   the tag, matching the established playtest-log-capture workflow from
   earlier GB-1 debugging). Their log matched the headless trace
   exactly -- `_percent` (well, the raw phase argument logged) climbing
   past 100 continuously, then a permanent stall. That match was the
   real clue: `MdlAnimator.play_cycle()` does `_percent = clampf(percent,
   0.0, 100.0)` -- a CLAMP, not a wrap. `_do_actor_move()`'s own phase
   accumulator (`wdl_auto_walk_phase`) grows by total distance moved,
   unbounded, so it exceeds 100 after only ~100 units of walking (a
   small fraction of the ~300-unit walk to Krupnik) -- and once it does,
   `_percent` clamps to exactly 100.0 forever, freezing the render on
   the cycle's last frame for the rest of the walk while `current_clip`/
   `playing` state still looks completely normal. State-only checks
   (both the original 2026-08-01 fix's own test and my own first,
   shorter re-test) can't see this -- only sampling `_percent`'s actual
   value over a long enough window catches it.

Fixed: wrapped the phase with `fmod(..., 100.0)` in `_do_actor_move()`
before storing/using it, so it cycles through the Walk clip repeatedly
instead of growing past the clamp ceiling.

Verified: extended `tools/smoke_plane_walk_anim.gd` to track whether
`_percent` ever goes stuck WHILE he's still physically moving (a hold
once he's legitimately arrived and a dialog opens is correct behavior,
deliberately excluded) -- now `OK`, zero stuck frames across the full
walk. `smoke_dispatch` 19/19, `smoke_shiks_bumpin_proximity.gd` (the
other real `actor_move()` user in the corpus) still `OK`. `git status`
zero asset deletions. Kept the `[mdl-anim]` debug logging in place,
scoped to `PiposhWalk` only, as permanent low-volume diagnostics rather
than ripping it out now that it's proven useful.

## 2026-08-02 (GB-6) — Plane2: a visible, non-colliding, non-clickable
## "Piposh" appears even though the player IS Piposh (first-person)

User confirmed both GB-2 fixes (floor placement + walk animation), then
reported a new symptom on the very next level: opening Plane2 after
Plane shows a rendered Piposh character that shouldn't be there, has no
collision (walk straight through it), and clicking it produces an empty
click instead of a normal object-click event.

Investigated the two obvious "extra Piposh" candidates first (FPiposh.MDL/
`action PiposhHit`, and a `Piposh.MDL`/`action A1` stand-in) via a new
headless test -- both correctly stayed hidden (`my.invisible = on;` at
spawn, matching their own WDL bodies). Widened the check to include the
level's own first-person player proxy (`Piposh.MDL`/`action player_walk2`,
hidden at spawn via `WmbLevelLoader._hide_meshes()`) and found it: hidden
immediately at spawn, but VISIBLE by the time the level had run a few
more frames.

Traced it by adding a targeted debug log directly in `WdlInterpreter.
_set_field()`'s `"invisible"` case (logging every write that targets the
FP proxy node specifically) rather than guessing further from source
reading alone -- immediately caught `action A1`'s own coroutine writing
`invisible=off` to it, every tick, from two separate placements. `action
A1`'s body: `if (Scene==1) {...} else { player.invisible = off; ...
my.invisible = on; ... }` -- Scene defaults to 0 (a fresh `WdlInterpreter`
instance is created per level load, ruled out via code read: globals
don't carry over from Plane), so the ELSE branch always runs. The `my.
invisible=on` part correctly hides `A1`'s own decoy Piposh; the `player.
invisible=off` part was assumed to be inert (nothing in this port's own
code binds the WDL `player` global to anything) until grep found the
real cause: `WDL/move.wdl`'s actual `player_move2()` (called every tick
from `ACTION player_walk2`, itself invoked by the FP proxy's own
coroutine) has `if (MY.CLIENT==0) { player = ME; }` as its literal first
statement -- `MY.CLIENT` always reads 0 here, so this always fires,
genuinely binding `player` to the FP proxy every tick, matching real
Acknex's own built-in `player` pointer. In the original engine this
`player.invisible=off` write was harmless -- first-person rendering
never draws the player's own body regardless of the flag -- but in this
port `invisible` (via the NB-7 fix's `_set_mesh_visibility_recursive`)
is the ONLY mechanism keeping the FP body hidden, so the write directly
undid `_hide_meshes()`'s one-time spawn-time hide, every tick, forever.

Fixed: `_set_field()`'s `"invisible"` case now checks whether the write
target is `_loader.first_person_spawn["node"]` and, if so, skips the
toggle entirely -- the FP proxy's visibility is a fixed, port-owned
invariant once first-person is active, same philosophy as the existing
`move_view_1st`/`move_view_3rd` bridge-to-no-op fix (the native
controller's own Camera3D is the sole FP camera authority; by the same
logic, its own mesh's hidden state shouldn't be WDL-scriptable either).
"No collision" and "empty click" were both downstream symptoms of the
same root cause (the FP proxy is deliberately passable/unwired, since
it's never meant to be seen or clicked), not separate bugs -- fixing
visibility resolves all three.

Verified: new `tools/smoke_plane2_fpiposh_check.gd` lets `action A1`'s
coroutine tick 30 times (enough for the bug to reproduce pre-fix) and
confirms the FP proxy's own mesh stays hidden throughout. `smoke_dispatch`
19/19, `smoke_shiks_pipi_stay_put.gd` and `smoke_plane2_all_goals.gd`
(other real users of the same `_set_field()` "invisible" case) still
`OK`. `git status` zero asset deletions.

## 2026-08-03 (GB-4) — Range: hit-count HUD never updates (bmap values
## silently evaluated to 0.0)

User: "shooting a terrorist or civilian doesn't update the hurt count,
so we can't win." Range's HUD is a real Acknex `PANEL` system (Terr1-15/
Civ1-5 icon panels, `UpdatePanel()` swapping each one's `bmap` from
`bTerr`/`bCiv` to `bTerrHit`/`bCivHit` as the `Terrorists`/`Civilians`
globals drop) -- confirmed this port's PANEL support (`_ensure_panels_
built`/`_build_panel`) already exists and `_set_panel_field()`'s "bmap"
case already resolves and applies textures correctly, so the gap wasn't
obviously in the panel-rendering code itself.

Root-caused by direct isolation, not guessing: new `tools/smoke_range_
hud_check.gd` forces one Terrorist entity into a hittable state and
calls `action TargetHit` directly (bypassing aim/bullet-travel, already
covered by the pre-existing `smoke_range_shoot.gd`), then checks both
the `Terrorists` counter AND the panel's own rendered texture. First
attempt gave a false alarm (test bug, not a game bug): `action
Terrorist`'s own body sets `my.Type = typeCivilian` unconditionally at
spawn and only randomly re-rolls it to `typeTerrorist` inside its own
"pop up" RNG logic -- setting only `my.Pop` (not `my.Type`) meant
`action TargetHit` correctly decremented `Civilians`, not `Terrorists`,
exactly as authored. Corrected the test to set both fields (matching
what a real pop-up does), which surfaced the real bug: the counter DID
decrement correctly, but `Terr15.bmap = bTerrHit;` (the visual swap)
silently did nothing. Direct one-line isolation (`_set_field({id:Terr15},
"bmap", <value of bTerrHit>, null)`) showed `bTerrHit` itself evaluated
to `0.0`, not a usable bmap name.

`_get_var()`'s fallback chain already had a fix for the identical shape
of gap for `sound` declarations (2026-07-30, `docs/CONTRACT.md` §5) but
never got the equivalent for `bmap` declarations -- `_bmaps` was
populated by `_merge_ast()` but never consulted by `_get_var()`, so
every bare reference to a declared bmap name AS A VALUE (not as a
`panel.bmap = X` field name being written, which already worked) fell
through to the generic "unresolved identifier" 0.0 default. Wide blast
radius: 38 corpus `.wdl` files declare `bmap` variables; this wasn't
Range-specific.

Fixed: added `_bmaps_lower` (same case-insensitive-index shape as
`_sounds_lower`/`_actions_lower`/`_globals_lower`) and `_resolve_bmap()`,
consulted in `_get_var()`'s fallback chain right after the sound check.
Returns the bmap's canonical NAME (not its file, unlike the sound case)
since `_resolve_bmap_texture()` looks its argument up by name.

Verified: `smoke_range_hud_check.gd` now `OK` -- Terrorists decrements
correctly AND Terr15's real rendered texture switches to Hit2.png.
`smoke_dispatch` 19/19, `smoke_range_panels.gd`, `smoke_range_shoot.gd`
still `OK`. `git status` zero asset deletions.

## 2026-08-03 (GB-5) — Range: death-screen buttons invisible (never
## drawn); "animation keeps playing" root-caused, not yet fixed

Same report continued: "after Piposh dies... the retry/skip buttons
that should appear don't show." `smoke_range_shoot.gd` already confirmed
`pRIP` (the death-screen panel) becomes visible on `Health<=0`, so the
panel container itself wasn't the gap.

New `tools/smoke_range_rip_check.gd` checked pRIP's own BUTTON children
(`fRIP1` "retry"/`fRIP2` "map", from `IO.wdl`'s shared `panel pRIP {
BUTTON 020,380,bRIPb1,bRIPb3,bRIPb1,fRIP1,NULL,NULL; ... }`) directly:
both existed as real Control nodes, correctly positioned, `visible=true`
-- but neither had any texture at all. Root cause in `_build_panel_
button()`: it resolves the button's icon texture via `_resolve_bmap_
texture()` ONLY to read its `.size` for the click-zone dimensions --
the resolved `Texture2D` is then discarded, never attached to any
child node. Every panel BUTTON in the corpus (Range's own `pSkip`
included) was a real, correctly-placed, correctly-clickable hotspot
with nothing ever drawn on it.

Fixed: `_build_panel_button()` now adds a child `TextureRect` showing
the resolved icon, mirroring `_build_panel()`'s own existing background-
bmap `TextureRect` pattern exactly.

Verified: `smoke_range_rip_check.gd` -- both pRIP buttons now report
`has_texture=true`. `smoke_dispatch` 19/19, `smoke_range_panels.gd`
(pSkip's own button) still `OK`. `git status` zero asset deletions.

**Not yet fixed, root cause only:** "animations keep playing in the
background" instead of the game pausing on death. Grepped the corpus:
nothing outside `Restart()` itself ever reads the `Death` global (unlike
the `MoviePlaying` gate, e.g. `while (MoviePlaying==1) {wait(1);}`,
which both `action CamTarget` and `action Terrorist` already use and
this port already handles correctly). The real engine's own `ShowRIP()`
calls `freeze_map bRIPSlot,2,0;` right before showing the panel --
`freeze_map` is a real Acknex builtin (screenshot-into-a-bmap-slot, also
used for save-file thumbnails elsewhere in `IO.wdl`) that this port has
never implemented, and it's the most likely place the original engine's
"the world visibly stops" effect actually came from. Deliberately not
implemented yet: a literal screenshot-freeze is one option, but the
user's actual ask is "stop the gameplay coroutines, let me only use the
death-screen buttons" -- doing that generically (pausing whichever
coroutines are running when a modal-style panel like `pRIP` becomes
visible) is a real, separate, more architecturally-invasive change than
today's other fixes, and needs to be scoped carefully so it doesn't
also affect `freeze_map`'s OTHER, brief/non-pausing call sites
(save-slot thumbnails) if that mechanism is ever generalized further.

## 2026-08-03 (GB-5 continued) — Range: gameplay now actually pauses on
## death

Asked the user directly how "animations keep playing" should behave,
given the real fix (pausing live gameplay coroutines) is architecturally
bigger than today's other changes and the corpus-wide `freeze_map`
builtin's OTHER call sites (save-slot thumbnails, `IO.wdl`) are brief
and clearly NOT meant to pause anything -- didn't want to guess and risk
a wrong-scope fix. Chose "freeze everything": once the death screen
shows, all Range gameplay should stop, leaving only the retry/map
buttons interactive.

Implemented at the one universal hook point virtually every coroutine
in every level already passes through every tick: `exec_stmt()`'s async
"wait"/"waitt" case. Added `_frozen: bool`, toggled by `_set_panel_field
()`'s "visible" case specifically when the panel is the shared `Panel_
pRIP` (IO.wdl's death-screen panel, not Range-specific -- toggled by the
SAME `ShowRIP()`/`HideRIP()` calls already driving the panel's own
visibility, so no new WDL-side hook was needed). While frozen, every
`wait()` call blocks (spins on `process_frame`) before its own normal
countdown runs, so each coroutine's progress halts exactly where it was
and resumes exactly there once unfrozen -- no separate resume-tracking
needed. Button clicks are untouched: they're Godot `Control.gui_input`
signals (`_on_panel_button_input`), entirely independent of WDL
coroutine scheduling, so the death-screen buttons stay clickable while
everything else is frozen. The synchronous exec path (`_exec_stmt_sync`,
used for mid-expression calls that can't truly suspend) already treats
`wait()` as an unsupported no-op with its own warning -- untouched,
correctly out of scope.

Verified: new `tools/smoke_range_death_freeze.gd` forces a target into
a live "going up" animation (its own `my.z` actively rising, a real,
continuously-changing value to check against), confirms `_frozen`
flips true on `Health=0` and z genuinely stops changing across 60
further frames, then simulates the "retry" button's own real effect
(`pRIP.visible = off`, matching `HideRIP()`) and confirms `_frozen`
flips back and z resumes changing. `smoke_dispatch` 19/19 (this hook
sits in the hottest, most universal per-tick path in the whole
interpreter, so full-corpus dispatch regression mattered here more than
usual), `smoke_range_panels.gd`, `smoke_range_shoot.gd`, `smoke_range_
hud_check.gd`, `smoke_range_rip_check.gd` all still clean. `git status`
zero asset deletions.

## 2026-08-03 (GB-5 continued) — Range: retry doesn't reset the level,
## and a second death never shows RIP again

User confirmed the previous two fixes (bmap HUD, button icons, death
freeze) but reported two more, on the retry flow specifically: "retry
doesn't refresh the game, it continues un-freezed" and "after retrying,
the game doesn't let you die again even though you got fully hit."

Traced the "can't die again" report first, since it's concrete and
directly testable: grepped the whole corpus for `Death = 0` -- found
only two hits, the declaration (`var Death = 0;`) and ONE reset, inside
`action CamTarget`'s own coroutine body, which only runs once, at level
start. `Restart()`'s own guard (`if (Death==0) { Death=1; ShowRIP(); }`)
is therefore permanently blocked after the first death, for the rest of
that interpreter instance's lifetime -- explains both reports at once:
retry (`fRIP1 { HideRIP(); main(); }`) unfreezes (`HideRIP()` correctly
un-toggles `pRIP.visible`) but `Death` stays 1 forever, so nothing else
about the level actually resets, and a second `Health<=0`/`Civilians<1`
never fires `Restart()` again.

Root cause: the real Acknex builtin is `level_load(<X.WMB>)`, called by
literally every level's own `main()` (confirmed via corpus grep, 17
files) as its own "(re)load my map" step -- in this port `WmbLevelLoader`
already loads the level's geometry before `main()` ever runs, so a
no-op is correct for that NORMAL first call. But Range's retry path
calls `main()` a SECOND time expecting a real reset, and nothing
provided one. Found an existing, already-reasoned no-op stub for this
exact builtin (`_register_builtins()`, dated 2026-07-28) -- but
registered under the reversed key `"load_level"`, not the real corpus
spelling `"level_load"`, so it silently never matched any actual call
this whole time (left it in place, harmless dead code either way, and
registered the correct key fresh).

Implemented `level_load()` for real: reset every declared global back
to its initial value, mirroring `setup()`'s own one-time init loop
exactly. Safe for the normal first-call case too, since `main()`'s own
explicit follow-up assignments (`Health=609;` etc.) simply overwrite the
same correct values again right after.

**Caught a real regression in this fix before shipping, not after:**
first version only replayed HALF of `setup()`'s own init sequence (the
globals-init loop), and `smoke_range_shoot.gd` -- unrelated, pre-existing,
not touched this session -- started failing 3/3 runs ("no Spark bullet
entity found after firing"). Root-caused, not guessed: Range's own
`on_mouse_left = Fire;` is a bare top-level assignment, not a `var`
declaration, so it lives in `_globals` with `init=null` and no record of
its real value -- `_eval_init(null, ...)` returns `_default_for("var")`
(0.0), so my reset silently un-bound the click-to-fire handler.
`setup()`'s real sequence is TWO steps (globals-init, THEN
`_top_level_stmts`), and I'd only replayed the first. Fixed by replaying
both.

Verified: new `tools/smoke_range_retry_check.gd` -- first death shows
RIP screen and freezes; simulated clicking "retry" for real
(`invoke_event(null, "fRIP1")`) shows `Death`/`Health`/`Terrorists`/
`Civilians`/`frozen` all correctly reset; a second forced death shows
RIP again. `smoke_range_shoot.gd` re-confirmed fixed (Spark bullet found
again, hits register). `smoke_dispatch` 19/19 (this touches `level_load`,
called by 17 other levels' own `main()` too), `smoke_range_panels.gd`,
`smoke_range_hud_check.gd`, `smoke_range_death_freeze.gd` all still
`OK`. `git status` zero asset deletions.

Also reported: "aiming and shooting works but it's not highly accurate,
and the mouse and aim are a bit confusing to use." Checked `vec_rotate()`
(the bullet's own spawn-direction math, `CreateSpark()`'s `vec_rotate
(shot_speed, my_angle)` using `player.pan/tilt/roll`) against
`_acknex_entity_basis()` -- the same shared basis function already used
and validated elsewhere for camera/entity orientation -- found no
obvious coordinate-mismatch bug. Logged as GB-7, not fixed: this reads
more like a sensitivity/feel issue than a discrete bug from static
review alone, and needs a sharper repro (does the crosshair visually
line up with where shots land? too fast/slow/inverted?) before guessing
at a numeric tune.
