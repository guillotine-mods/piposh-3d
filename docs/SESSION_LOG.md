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
