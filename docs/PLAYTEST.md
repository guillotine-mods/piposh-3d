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
| (general) | Reported broken (2026-07-26) | Camera/characters sink below where they should stand ("Ami level characters a bit lower"). Feet-snap math checked out for the logged Start/Menu/Studio/Shiks entities (internally consistent with floor_y), so cause is elsewhere if real — need exact level + magnitude. |
| (general) | Reported broken (2026-07-27) | "Levels not correctly loaded after Plane2." Plane2→Range transition matches the original script (`Plane2.wdl` `Run("Range.exe")`) so the mapping itself is correct; root cause of whatever looks wrong after that point is still unknown — need specifics. |

All other levels: not yet playtested and reported on — treat `LEVELS.md`
"generic/custom director" status as pipeline-ready, not gameplay-verified,
until an entry appears here.
