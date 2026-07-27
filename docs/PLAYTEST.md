# Playtest status (is the game actually done?)

`docs/LEVELS.md` tracks pipeline coverage (JSON extracted? brush built? sky
set?) — necessary but not sufficient. This file tracks whether a level
actually *plays right*, from a human running it in Godot. A level can be
100% green in `LEVELS.md` and still be wrong here.

**Status values:** `OK` (confirmed correct) / `FIX` (changed, awaiting
re-test) / `BUG` (reported broken, not yet fixed) / `?` (unresolved /
contradictory — see note). Full investigation history for every row lives
in `docs/SESSION_LOG.md`; this table is current state only — stale rows get
replaced, not appended to, so it stays scannable.

## Facing / orientation

**2026-07-27: found and fixed a CLI bug that silently kept the "deleted"
heuristic running for every asset actually generated** (module default was
correct, `main()`'s flag handling overrode it back on — see SESSION_LOG).
Regenerated all 375 IDPO models again through the corrected CLI. Also added
a human-confirmed +90° correction for the 4 models still wrong after that,
via the (now wired-up) `mdl_yaw_allowlist.json` mechanism — not a heuristic
guess, a recorded measurement.

| Item | Status | Note |
|---|---|---|
| Studio: Sfan (fan) | OK | Confirmed correct by user. |
| Studio: Ami, Naknik | FIX | On the uniform no-heuristic rule, regenerated through the corrected CLI. Needs test. |
| Start: Crowd, Crowd2, Genia | FIX | `+90°` correction via `mdl_yaw_allowlist.json` (not re-reported wrong after applying, tentatively holding). Needs explicit re-confirmation. |
| Start: Yachdal (DefineYachdel) | FIX | `+90` was the wrong direction (still 90° off after applying it) — flipped to `-90`/`270`. Needs test. |
| Shiks: ShikFond ("ShikX") | FIX | On the uniform no-heuristic rule, regenerated through the corrected CLI. Needs test. |
| Shiks: Wwheel (water wheel) facing | FIX | On the uniform no-heuristic rule. Separately, its *spin axis* was also wrong — see Camera/Positioning section below. Needs test. |
| Shiks: Bus | **?** | Reported 180° off twice, unchanged both times. Likely a genuine one-off needing its own measured correction (same mechanism as Crowd/Yachdal/Genia above) — need the exact degree/direction, or at minimum reconfirmation against this latest build. |
| Plane/Plane2: B747 | FIX | Same rule as Bus, unaffected by recent changes. Needs re-confirmation. |
| Plane: "Pip" vs "PiposhWalk" | ? | Which one did "Piposh in Plane 90 off" mean? `PiposhWalk` faces its movement direction (shared formula, unlikely buggy); `Pip` is stationary with a static angle (if wrong, the bug is in `Piposh2.MDL` itself). Need to know which. |
| Intro cutscenes | BUG | Reported wrong, unconfirmed root cause. 69/135 Intro models are IDPO. Need one specific model name to test. |
| "Other mid scenes ~90° off" | BUG | No specific model named yet. |

**2026-07-27: batch verification tooling added** — `tools/gallery_facing.gd`
(all 236 character models, or an explicit list, laid out in a grid with a
red +X reference arrow per model) replaces testing one model at a time via
`smoke_orient.gd`. Run with `godot --headless -s res://tools/gallery_facing.gd
-- --all` (paginates 36/image) or with explicit stem names for a smaller
set. Not yet run/confirmed — this is the fastest path to closing out every
`?`/`FIX`-needs-retest row above in one or two screenshots instead of
one-off reports.

## Camera

| Item | Status | Note |
|---|---|---|
| Studio, Town, generic scripted levels | FIX | Removed an undocumented +14 lift / tilt-softening hack that contradicted the source engine's exact 1:1 camera copy. Needs re-test. |
| Shiks: camera position | OK-ish | User confirmed "works better." |
| Shiks: camera fly motion | FIX | Was straight waypoint-to-waypoint hops ("blocky"); now a continuous Catmull-Rom spline. Needs re-test. |
| Plane2: static camera after goal-movie, should resume walking | BUG | Confirmed the level *should* enter FP mode; bug is inside the complex goal-movie state machine. Need exact repro (F10 mode readout + trigger sequence). |
| Range | FIX | Could fall back to free/3rd-person movement mid-game — fixed via explicit `_steal_camera()`. **2026-07-27: root-caused a second, separate camera bug from a real playtest debug-log dump** — `ensure_scripted_view()`'s generic "any Cam entity" fallback was also grabbing Range's unrelated leftover intro-movie camera entity (`Cam_mdl_124`) and fighting with `_update_range` every frame via `_update_town_cam()`. Fixed with an explicit `_is_range_level()` branch + defensive guard. This fallback is a general risk for any future custom-directed level with a leftover generic "Cam" entity — see SESSION_LOG. Needs re-test (does aim/shoot/target-popup actually work now). |
| Shiks: water wheel / turn vase rotation | FIX | Both used hardcoded Godot world-axis rotation (`rotation_degrees.z/.x +=`) instead of Acknex's own local tilt/roll semantics (`Shiks.wdl`: `my.roll += 5` / `my.tilt += 20*time; my.roll += 20*time`) — only coincidentally correct when pan=0. Added `_set_entity_tilt_roll()` and used it for both. Needs test. |

## Positioning / sinking

| Item | Status | Note |
|---|---|---|
| All levels: fans/curtains/light-rigs/set-dressing | FIX | `_should_feet_snap` had been inverted from opt-out to opt-in, silently un-snapping everything not on a whitelist. Restored opt-out (matches original documented behavior). Needs re-test. |
| Shiks: camera/characters below floor | BUG | Not explained by the feet-snap fix (these were already snapped). Need `[copy-cam]`/`[feet-snap]` console logs from an actual run. |
| Plane/Plane2: cockpit control panel too low | FIX | Identified via user screenshot: `Cockpit.MDL` (blank-action scenery near Krupnik), mesh measured to hang mostly below its own origin — was wrongly excluded from feet-snap as "attachment scenery". Removed the exclusion. Needs test. |

**2026-07-27: batch verification tooling added** — `tools/gallery_feet_snap.gd`
renders the 6 stems currently excluded from feet-snap (B747/TV/Biplane/
Biplane2/Hanger/Towerw) plus 5 known-good regression guards (Sfan/Curtain/
StudioL/Shtomba/Cockpit) as RAW vs. SNAPPED rows against a floor-plane
reference, mirroring `_snap_mesh_feet_to_origin`'s exact math. Run with
`godot --headless -s res://tools/gallery_feet_snap.gd` (no args = default
set). Answers, per excluded stem, "legitimately floating (e.g. B747 as a
flying plane) or wrongly hanging below floor (the Cockpit bug shape)?" — not
yet run/confirmed.

## Clicks / interaction

| Item | Status | Note |
|---|---|---|
| Studio: ShikNote / AFG_Card wall items | FIX | `AFG_Card` was wrongly aliased to Shiks' click action; now runs its real Afgan.wdl card-pickup behavior. Confirmed working. |
| Plane2: AFG_Card unclickable | FIX | A second wiring pass was silently overwriting the correct one; removed the duplicate. Needs re-test. |
| Plane2: AFG card pickup shows nothing on screen | FIX | Was attaching to an inactive camera reference in first-person mode; fixed. Needs re-test. |
| 18 levels with AFG_Card (AsyAct1-3, Credits, Dutyfree, InShrine, Inn, Intro6, MOI, Mansion, Olympic, Outro, Plane2, Race, Studio, Taxi, Temple, Travel) | FIX | Same generic fix applies everywhere the entity appears. Not individually playtested. |

## New features

| Item | Status | Note |
|---|---|---|
| Range (shooting gallery) | FIX | Debug logging added last round paid off: user pasted a real playtest console dump, which showed `_update_range`'s aim/fire lines interleaved with repeating `[copy-cam] cam_entity=Cam_mdl_124` spam — `ensure_scripted_view()`'s generic "any Cam entity" fallback was grabbing Range.wmb's unrelated leftover intro-movie camera and fighting with Range's own `CamTarget` system every frame via `_update_town_cam()`. Fixed with an explicit Range branch + defensive guard (see Camera section). Also added an F4 dev level-select so Range can be reached directly without replaying Plane→Plane2 first. Needs re-test: does aim/shoot/target-popup actually work now. Still wants an intro scene before it starts (`Range.wdl`'s boarding dialog was simplified out) — not built, needs a scope decision. |
| Plane2: Krupnik hammer animation, TV animation | FIX | Read `Plane2.wdl` directly: Krupnik should continuously scrub a "Hammer" swing animation (was a single frozen pose), TV should cycle 12 skins as a flipbook effect (was never animated at all). Both implemented to match source. Needs re-test. |
| F4 dev level-select overlay | FIX | New debug feature (not in original game): press F4 in any level to open a click-to-jump list of every converted level. Built so Range (and any other late-chain level) can be tested directly. Untested by user yet but low-risk (debug-only UI, no gameplay logic touched). |

**2026-07-27: static WDL-action audit.** Cross-checked every one of the ~79
genuine action names `wdl_director.gd` dispatches on against real
`action X { ... }` definitions across all of `original/piposh3d/*.wdl` +
`original/piposh3d/WDL/*.wdl`: 100% have a real matching source
definition — no fabricated/hallucinated action names anywhere in the port.
A targeted spot-check of one non-trivial case (`action Naknik` in
`Studio.wdl`, the Genia dialogue-branching state machine) confirmed a
faithful, line-for-line-equivalent port. A full line-by-line body audit of
all 79 isn't automatable (the same action name has unrelated bodies across
~135 different per-level `.wdl` files) — deeper coverage would need more
manual spot-checks like this one, level by level, not a blanket script.

All other levels: not yet playtested — treat `LEVELS.md` "generic/custom
director" as pipeline-ready, not gameplay-verified, until a row exists here.
