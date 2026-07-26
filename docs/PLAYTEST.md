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
| Studio | Reported broken (2026-07-26) | Wall has two clickable items (ShikNote note + AFG_Card); only the one that leads to the Shiks scene actually responds to clicks, the other does nothing. Under investigation, see SESSION_LOG. |
| (general) | Reported broken (2026-07-26) | Some MDL models face the wrong direction. Specific model(s)/level(s) not yet identified — need user to name one so `smoke_orient.gd` can check it deterministically instead of guessing across ~640 models. |
| (general) | Reported broken (2026-07-26) | Camera and/or characters sink below where they should stand. Specific level(s) and whether it's player, NPC, or camera not yet identified. |

All other levels: not yet playtested and reported on — treat `LEVELS.md`
"generic/custom director" status as pipeline-ready, not gameplay-verified,
until an entry appears here.
