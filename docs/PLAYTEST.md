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
| Studio | Reported broken (2026-07-26) | Wall click bug root-caused: `AFG_Card` was wrongly wired to the same `ShikKlik`/Shiks action as `ShikNote` (guessed from wall proximity). Real behavior implemented (Afgan.wdl 32-card collectible). Needs re-test to confirm both wall items are now independently correct — see SESSION_LOG. |
| (18 levels: AsyAct1-3, Credits, Dutyfree, InShrine, Inn, Intro6, MOI, Mansion, Olympic, Outro, Plane2, Race, Studio, Taxi, Temple, Travel) | Fix applied, not playtested (2026-07-26) | All contain `AFG_Card` entities affected by the same fix. Card-pickup click now works and persists; HUD card-reveal fade (`AFG_Show`) not yet ported. |
| (general) | Reported broken (2026-07-26) | Some MDL models face the wrong direction. Specific model(s)/level(s) not yet identified — need user to name one so `smoke_orient.gd` can check it deterministically instead of guessing across ~640 models. |
| (general) | Reported broken (2026-07-26) | Camera and/or characters sink below where they should stand; also "camera is off" and "some assets not in correct place / not pointing right direction" in general. Feet-snap math checked out for the logged Start/Menu/Studio/Shiks entities (internally consistent with floor_y), so the cause (if real) is elsewhere — need a specific level + whether it's player/NPC/camera + rough magnitude before instrumenting further. |

All other levels: not yet playtested and reported on — treat `LEVELS.md`
"generic/custom director" status as pipeline-ready, not gameplay-verified,
until an entry appears here.
