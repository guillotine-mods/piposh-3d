# Bug tracker

A working list of known issues, separate from `docs/PLAYTEST.md` (which
tracks asset-level correctness — facing, positioning, camera angles against
the original game) and `docs/SESSION_LOG.md` (the permanent record of *how*
each fix was found and verified, written after the fact). This file is the
*queue*: what's still open, referenced by ID.

**Workflow:** say "let's work on `GB-2`" (or however you refer to it) to
start on an entry. Once a fix ships and you've confirmed it in-game, delete
that row — don't leave it marked "done," just remove it. The fix's own
history stays in `docs/SESSION_LOG.md` and the commit that made it; this
file only needs to reflect what's still outstanding.

**Adding new bugs:** append a row to the right section with the next free
number in that prefix (don't reuse numbers from deleted rows, so an ID
never means two different things across a conversation). A one-line
description is enough — add detail if you have it (which level, what you
expected vs. what happened), but don't feel obliged to.

**IDs:** `GB-*` = game-breaking, `QOL-*` = quality of life, `NB-*` =
non-breaking bugs. Prefix groups are just for scanning; nothing stops a
QOL item from being promoted to GB (or the reverse) by moving the row.

---

## Game-breaking bugs

| ID | Description | Note |
|---|---|---|
| GB-3 | Plane2: Piposh spawns lower than the plane's surface, and the character can't move. | Fixed commit `b98470e` (two separate bugs: a wrong-deck floor snap, and a camera-authority deadlock that zeroed the native controller's movement every tick). Needs re-verification in-game before closing. |
| GB-4 | Range: the upper HUD doesn't update when a citizen or terrorist is hit. | Fix shipped 2026-08-03, pending in-game confirmation. Root cause: `bmap`-declared identifiers (e.g. `bTerrHit`) evaluated to `0.0` when read as a value (only sound declarations had this fallback, not bmaps) — every `panel.bmap = X;` write across the whole corpus was a silent no-op. See `docs/SESSION_LOG.md` 2026-08-03 (GB-4). |
| GB-5 | Range: after Piposh dies, animations keep playing instead of stopping, and the retry/skip buttons that should appear don't show. | Fix shipped 2026-08-04, pending in-game confirmation. Four separate bugs: (1) the retry/map buttons on the death screen had no icon ever drawn — same gap affected every panel BUTTON in the corpus, e.g. Range's own pSkip. (2) nothing paused gameplay on death — the shared `pRIP` death-screen panel becoming visible now freezes every WDL coroutine's own progress, resuming exactly where it left off once hidden again; buttons stay clickable throughout. (3) `Death` (gates `Restart()`'s own guard) was only ever reset once, at level start, so a second death never showed RIP again — implemented `level_load()` (called by every level's own retry path) to reset it. (4) that fix's own first draft was too broad (reset ALL globals, not just `Death`) and caused a real regression, confirmed live: retrying re-triggered the intro dialogue on top of the still-running shooting view, and every terrorist got stuck unable to pop up (their own coroutines re-blocked on the same `MoviePlaying` gate) — "no hit registers, can't beat the stage" and "dying starts the dialogue again" were the same bug. Narrowed to reset only `Death`. See `docs/SESSION_LOG.md` 2026-08-03/04 (GB-5, continued, and take two). |
| GB-7 | Range: aiming/shooting works but isn't very accurate, and the mouse/aim controls feel confusing; retry doesn't reset the cursor/aim; the skip button after 3 losses isn't clickable/on top. | Fix shipped 2026-08-04, pending in-game confirmation. Four separate bugs, all in the same aiming path: (1) `_enable_first_person()` is the only place `Input.mouse_mode` gets captured/hidden, but Range aims via a scripted camera (`action CamTarget` rotates `camera.pan/tilt` from raw mouse delta, `mickey.x/y`), not the first-person player path, so the OS cursor stayed visible/free-roaming, disconnected from the actual aim direction — fixed generically: any scripted-camera level whose WDL references `mickey` now also captures the mouse. (2) retrying didn't restore the camera's original pan/tilt/roll, so aim drifted further off with each retry — fixed by recording each spawned entity's original pan/tilt/roll as immutable `wdl_spawn_*` meta at spawn time, and having `level_load()` reset the `player` entity back to it. (3) the skip panel (`pSkip`) had no explicit `layer`, defaulting to z-index 0 same as every other panel, so it could render behind/under other HUD panels and be unclickable — fixed by defaulting any panel that declares at least one `BUTTON` to z-index 50 unless it sets its own `layer`. (4) **the actual root cause of "aims higher than where the gun points," found after ruling out several math hypotheses by direct empirical testing**: `_set_entity_pan()` unconditionally hard-reset an entity's `tilt`/`roll` meta to `0.0` on every call, as a leftover assumption that pan-only entities never combine pan with tilt. `action CamTarget` sets `my.pan` then `my.tilt` every single tick, so the pan write silently wiped tilt to 0 immediately before the tilt line even ran — vertical aim had never worked at all in this port; the camera (and every bullet, via `vec_rotate` using `player.tilt`) could only ever point horizontally regardless of vertical mouse movement. Fixed by making `_set_entity_pan()` read and preserve the entity's current tilt/roll from meta, symmetric to how `_set_entity_tilt_roll()` already preserved pan. See `docs/SESSION_LOG.md` 2026-08-04 (GB-7, GB-7 continued). |

## Quality of life

| ID | Description |
|---|---|
| QOL-1 | Main menu text is too small — make it bigger. |
| QOL-2 | Level-select screen needs to be easier/more comfortable to use on both mobile and PC. |
| QOL-3 | Some voice lines have an echo baked in; needs an edited (de-echoed) version, with a settings toggle to choose which one to use. |
| QOL-4 | Add a load / save / quick-save option on the right side of the screen. |
| QOL-5 | Move the skip button to the right side. |
| QOL-6 | Add a right-side menu: debug, mouse-look toggle, level select, settings, and separate volume sliders for SFX / Music / Voice — default voice ~30-40% louder than music and SFX. |
| QOL-7 | Add subtitles (on-screen text for voice lines / dialogue). |

## Non-breaking bugs

| ID | Description |
|---|---|
| NB-1 | Main menu background image glitches — either swap it for a different image, or animate the original menu background instead. |
| NB-2 | Mobile: no 3D (look/turn) movement, and no equivalent of right-click for the choice cursor. |
| NB-3 | Lighting flickers and doesn't match the original game; no shadows. |
| NB-4 | The green "overlay" HUD panel flickers. |
| NB-5 | Loading text isn't centered — sits a bit too far right/down. |
| NB-6 | "Sticker clicked/found" text isn't centered — sits a bit too far right/down. |

---

_Last edited: 2026-08-04 (GB-7 expanded: cursor-reset-on-retry and skip-button-layer fixes, plus the tilt-reset root cause of the aim mismatch; all pending confirmation)._
