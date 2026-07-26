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

**2026-07-27: the face-orient heuristic is now deleted entirely** (not
patched again) — every IDPO model uses the same one rule as A5: correct
handedness, keep authored facing, no exceptions. Everything below marked
FIX reflects this new pipeline and has never been human-confirmed in this
form — needs a full fresh sweep, not spot checks of the previously-reported
items only, since 315 models changed at once.

| Item | Status | Note |
|---|---|---|
| Studio: Sfan (fan) | OK | Confirmed correct by user (unaffected by this change — was already on this exact rule). |
| Studio: Ami, Naknik | FIX | Now on the uniform no-heuristic rule. Needs test. |
| Start: Crowd, Crowd2, Yachdal, Genia | FIX | Reported 90° off under the *previous* (legacy-heuristic) attempt — that attempt is gone now, this is a genuinely different result. Needs test. |
| Shiks: ShikFond ("ShikX"), Wwheel (water wheel) | FIX | Same — reported 90° off under the now-deleted heuristic attempt. Needs test. |
| Shiks: Bus | **?** | Reported 180° off twice, unchanged both times (it was already on the no-heuristic rule before this fix — this fix doesn't touch it). Likely a genuine one-off exception, not the heuristic problem, but no fix applied without a confirmed re-check first — see CONTRACT.md #2 on why guessing here is exactly the mistake to avoid repeating. |
| Plane/Plane2: B747 | FIX | Same rule as Bus, unaffected by this change. Needs re-confirmation. |
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

## Positioning / sinking

| Item | Status | Note |
|---|---|---|
| All levels: fans/curtains/light-rigs/set-dressing | FIX | `_should_feet_snap` had been inverted from opt-out to opt-in, silently un-snapping everything not on a whitelist. Restored opt-out (matches original documented behavior). Needs re-test. |
| Shiks: camera/characters below floor | BUG | Not explained by the feet-snap fix (these were already snapped). Need `[copy-cam]`/`[feet-snap]` console logs from an actual run. |
| Plane2: control panel too low, an animation not positioned near Krupnik | BUG | Not investigated — need the specific entity name(s). |

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
| Range (shooting gallery) | FIX | Built from scratch per `Range.wdl` — targets, aiming, health, win/lose. First playtest found two bugs, both fixed: could exit to free/3rd-person view (now locked to the aim camera), no visible health/count HUD (now a real on-screen label, was previously hidden behind the F10 debug overlay). User also wants an intro scene before it starts (`Range.wdl`'s boarding dialog was simplified out) — not yet built, needs a scope decision. |
| Plane2: TV should show an animation inside, currently blank | BUG | Not investigated. |

All other levels: not yet playtested — treat `LEVELS.md` "generic/custom
director" as pipeline-ready, not gameplay-verified, until a row exists here.
