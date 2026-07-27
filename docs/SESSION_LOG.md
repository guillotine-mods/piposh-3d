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
