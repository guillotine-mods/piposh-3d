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

## Camera

| Item | Status | Note |
|---|---|---|
| Studio, Town, generic scripted levels | FIX | Removed an undocumented +14 lift / tilt-softening hack that contradicted the source engine's exact 1:1 camera copy. Needs re-test. |
| Shiks: camera position | OK-ish | User confirmed "works better." |
| Shiks: camera fly motion | FIX | Was straight waypoint-to-waypoint hops ("blocky"); now a continuous Catmull-Rom spline. Needs re-test. |
| Plane2: static camera after goal-movie, should resume walking | BUG | Confirmed the level *should* enter FP mode; bug is inside the complex goal-movie state machine. Need exact repro (F10 mode readout + trigger sequence). |
| Range | FIX | Could fall back to free/3rd-person movement mid-game — fixed via explicit `_steal_camera()`. Needs re-test. |
| Shiks: water wheel / turn vase rotation | FIX | Both used hardcoded Godot world-axis rotation (`rotation_degrees.z/.x +=`) instead of Acknex's own local tilt/roll semantics (`Shiks.wdl`: `my.roll += 5` / `my.tilt += 20*time; my.roll += 20*time`) — only coincidentally correct when pan=0. Added `_set_entity_tilt_roll()` and used it for both. Needs test. |

## Positioning / sinking

| Item | Status | Note |
|---|---|---|
| All levels: fans/curtains/light-rigs/set-dressing | FIX | `_should_feet_snap` had been inverted from opt-out to opt-in, silently un-snapping everything not on a whitelist. Restored opt-out (matches original documented behavior). Needs re-test. |
| Shiks: camera/characters below floor | BUG | Not explained by the feet-snap fix (these were already snapped). Need `[copy-cam]`/`[feet-snap]` console logs from an actual run. |
| Plane/Plane2: cockpit control panel too low | FIX | Identified via user screenshot: `Cockpit.MDL` (blank-action scenery near Krupnik), mesh measured to hang mostly below its own origin — was wrongly excluded from feet-snap as "attachment scenery". Removed the exclusion. Needs test. |

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
| Range (shooting gallery) | BUG | Still not functional per second playtest: can't aim/shoot, no targets pop up. Found and fixed one real bug (a HUD skip-button that's been visible+click-blocking game-wide the whole time, never explicitly hidden anywhere — that's why "a skip button" appeared). Could not find further explanation via code re-reading; added debug logging (`_begin_range`/`_update_range`/`_range_fire` all log to console now) to pin down the actual failure point from the next report instead of guessing again. Also still wants an intro scene before it starts (`Range.wdl`'s boarding dialog was simplified out) — not built, needs a scope decision. |
| Plane2: Krupnik hammer animation, TV animation | FIX | Read `Plane2.wdl` directly: Krupnik should continuously scrub a "Hammer" swing animation (was a single frozen pose), TV should cycle 12 skins as a flipbook effect (was never animated at all). Both implemented to match source. Needs re-test. |

All other levels: not yet playtested — treat `LEVELS.md` "generic/custom
director" as pipeline-ready, not gameplay-verified, until a row exists here.
