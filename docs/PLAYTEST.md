# Playtest status (is the game actually done?)

`docs/LEVELS.md` tracks pipeline coverage (JSON extracted? brush built? sky
set?) — that's necessary but says nothing about whether a level actually
*plays right*. This file is the other half: status from someone actually
running the level in Godot and looking at it. The goal is a **complete,
correct game**, not a fully green `LEVELS.md` board — a level can be 100%
"done" there and still be wrong in play.

States: `Not tested` / `Reported broken` (symptom + date) / `Confirmed
working` (date). Update this whenever the user reports back on a playtest —
see `docs/SESSION_LOG.md` for the full investigation behind each entry.

| Level | Status | Notes |
|-------|--------|-------|
| Studio | Fix applied, needs re-test (2026-07-27) | Wall click bug root-caused and fixed: `AFG_Card` now runs its real Afgan.wdl card-pickup behavior instead of a guessed Shiks alias; HUD card-reveal now shows something (simplified, no fade). Needs re-test. |
| (18 levels with AFG_Card: AsyAct1-3, Credits, Dutyfree, InShrine, Inn, Intro6, MOI, Mansion, Olympic, Outro, Plane2, Race, Studio, Taxi, Temple, Travel) | Fix applied, not playtested (2026-07-27) | Same AFG_Card fix applies here (game-wide mechanic, fixed once generically). |
| Studio, Shiks, Town, and every other scripted-camera level | Fix applied, needs re-test (2026-07-27) | Removed an undocumented +14 camera lift and a tilt-softening hack in `_copy_cam` that contradicted the original engine's exact 1:1 camera copy (`Studio.wdl` `TheCam`/`TheCam2`). Explains both the general "camera is off" report and "floating below a bit" in Shiks specifically. Needs playtest across at least Studio/Shiks/one generic level. |
| Intro2-16 (cutscenes) | Hypothesis, unconfirmed (2026-07-27) | Reported MDL facing wrong. 69/135 models used in Intro levels are IDPO format — the format CONTRACT.md already flags as historically unreliable for facing. `--fix-idpo` toggle exists in `convert_mdl.py`/`smoke_orient.gd` but not yet verified (needs a rendered comparison; sandbox can't run it here — see SESSION_LOG). Do not flip the global default without this confirmation. |
| All levels (any non-whitelisted scenery prop) | Major regression fixed (2026-07-27) | `_should_feet_snap` had been inverted from opt-out (snap by default, matching the original documented behavior) to opt-in (only a name whitelist), silently un-snapping every prop not on that list game-wide. Restored opt-out. Explains Studio's fans/lights/curtains sinking, and likely the separately reported "Plane level assets not in place." Needs re-test. |
| Plane2 | Fix applied, needs re-test (2026-07-27) | AFG_Card was being wired correctly, then immediately re-wired wrong by a second function (`_wire_first_person_clickables`), breaking its click in this level specifically (Studio was unaffected). Fixed by removing the duplicate wiring. `PiposhHit`/background `BiPlane2` checked against source WDL and confirmed correctly non-interactive — not bugs. |
| Shiks | Reported broken, unexplained (2026-07-27) | Camera and non-Piposh characters reported below floor; feet-snap regression above does not explain this (these entities were already on the old whitelist). Still needs the `[copy-cam]`/`[feet-snap]` debug logs to diagnose — not yet provided. |
| Plane2 | Reported broken, unexplained (2026-07-27) | After the goal-collection "movie," user expects to resume first-person walking but sees a static exterior camera instead. Confirmed the level *should* enter FP mode (has `player_walk2`, not in the cutscene-forcing list) — bug is inside the Plane2 goal-movie state machine, too complex to guess a fix into without a repro. Asked user to check the F10 debug overlay (`mode=`) and describe the exact trigger sequence. |
| Plane2 | Fix applied, needs re-test (2026-07-27) | AFG card pickup showed nothing on screen — `_show_afg_card()` was attaching to the wrong (inactive) camera reference in first-person mode. Fixed to use the actually-active viewport camera. |
| Shiks | Gap identified, not fixed (2026-07-27) | Camera fly-to sequence moves in 3 straight waypoint segments ("blocky") instead of one smooth flow; path data has an unused `bezier` field. Scoped, not fixed — ask user if this is worth prioritizing now. |
| Studio (Sfan fan) | Targeted experiment, needs visual confirmation (2026-07-27) | Fan reported facing 180° backwards. Confirmed Sfan is IDPO format; applied the CONTRACT-documented `--fix-idpo` handedness fix to *only* this model (it's "faceless" so the face-orient heuristic never touched it either way — isolated, no risk to the 5 models `verify_mdl_facing.py` depends on). Not yet visually confirmed. |
| Range | Scope question, not a parsing bug (2026-07-27) | "Camera not in the right place, stage doesn't start." Range's entities (Handgun/Terrorist/TNT/CamTarget) are a full shooting-range minigame with zero director logic implemented (`LEVELS.md` lists it "generic", not a custom chapter) — geometry parses fine, but no gameplay was ever written for it. This needs new feature work, not a re-parse. Asked user whether to scope/build it. |
| All IDPO models (750/1298 of the game) | Attempted global fix, reverted (2026-07-27) | Tried making `FIX_IDPO`/no-`FACE_ORIENT` the default game-wide; `check_all.ps1` caught that this regresses 5 models (Crowd, Crowd2, Yachdal, Genia, Island) with an existing, tested, session-specific facing fix, because the face-orient heuristic and IDPO winding convention are coupled. Reverted cleanly (diff against committed GLBs came back empty). Documented the coupling so this isn't re-attempted blind. |
| (general) | Reported broken (2026-07-27) | "Levels not correctly loaded after Plane2." Plane2→Range transition matches the original script (`Plane2.wdl` `Run("Range.exe")`) so the mapping itself is correct; likely the same static-camera-after-movie issue above, not a separate routing bug. |
| (general) | Reported broken (2026-07-27) | "Some assets in other mid scenes pointing 90° off." No specific level/model named yet — need one to apply the same isolated `--fix-idpo --only <model>` test rather than guessing broadly again (see the Sfan row above for why a blanket change is unsafe). |

All other levels: not yet playtested and reported on — treat `LEVELS.md`
"generic/custom director" status as pipeline-ready, not gameplay-verified,
until an entry appears here.
