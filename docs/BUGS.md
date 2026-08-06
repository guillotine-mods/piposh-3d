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
| GB-7 | Range: aiming/shooting works but isn't very accurate, and the mouse/aim controls feel confusing; retry doesn't reset the cursor/aim; the skip button after 3 losses isn't clickable/on top. | Fix shipped 2026-08-04, pending in-game confirmation (round 2 — user confirmed items 1/2/4 still broken and 3 partially broken after round 1; all addressed below). Round 1: (1) mouse capture for scripted-camera aiming. (2) camera reset to spawn pose on retry. (3) button-panel z-index default. (4) `_set_entity_pan()` no longer zeroing tilt/roll every tick. Round 2, after live re-test: (5) pSkip's z-index (50 vs pRIP's 20) was already correct in the built scene but still rendered underneath in real play — z-index alone isn't reliable enough for this project's Control hierarchy on its own; added an explicit post-build tree reorder (sort panels by z-index, `move_to_front()` each in order) as a second, more robust guarantee, matching how `GameHud.show_dialog()` already hedges the same way. (6) retry's camera-pose reset was deferred to `level_load()`, which sits behind `main()`'s own `wait(3)` — `action CamTarget` resumed live during that gap on the stale pre-death orientation, then snapped hard once the deferred reset landed ("retry... messes with the view"); moved the camera-pose reset to fire synchronously the instant the death screen hides instead (no gap, no snap), while `Death`'s own reset had to stay deferred — resetting it early raced against `Health` (only reset by `main()`'s later `Health=609;`) and let `action CamTarget`'s own `Restart()` call re-trigger immediately, re-showing RIP right after retrying. (7) **the real reason shots still didn't land on the crosshair even after the tilt fix**: there was no crosshair at all — `pan_cross_show()` is a real, portable WDL function (`WDL/weapons.wdl`) that positions a real panel using `screen_size`, and was already being called correctly, but `screen_size` itself was entirely unresolved (silently read as (0,0)), so the crosshair panel rendered at (-7,-7) instead of screen-center — clipped almost entirely off-screen. Combined with the OS cursor being hidden by the mouse-capture fix, the player had no on-screen aim reference at all. Fixed generically: `screen_size` now resolves to this port's fixed 640×480 panel design space (the same value used by every other `screen_size` consumer in the corpus — Golf's Booth/OnAir, Shooter's Overmap). Round 3, after live re-test again ("crosshair is better, but still hard to control with the mouse, and the location doesn't reset when restarting"): (8) the mouse stayed captured (hidden/locked) the ENTIRE time the death screen was up, so the player had no visible cursor to click Retry/Skip with at all — fixed by switching to a visible mouse while `pRIP` is shown and restoring whatever mode was active before once it hides, mirroring how `GameHud.show_dialog()` already does this for regular dialogue choices. (9) that same blind mouse-hunting was ALSO why the aim reset looked like it wasn't working: `mickey` (mouse delta) keeps accumulating every frame regardless of freeze state, so whatever motion happened clicking Retry was still sitting there the instant `action CamTarget` resumed, and got applied on top of the just-reset spawn pose before it ever reached the camera — fixed by clearing the accumulated delta in the same synchronous burst as the pose reset. Round 4 (QOL, user request rather than a new report): added a `Space` key that recenters the aim back to spawn pose at any time (not just on retry), and the OS cursor now warps to the window center whenever it becomes visible (death screen, or a `Space` recenter) instead of being left wherever it silently drifted to while captured. Round 5, after live re-test again ("still not 100% working... the skip button is still beneath the graphic that's shown when we die", "the pointer should be reset after we click to restart, not after we die"): (10) two prior pSkip-vs-pRIP z-order fixes (round 1's z-index default, round 2's `move_to_front()` tree reorder) both should have worked within `GameHud`'s single shared `CanvasLayer` and both still didn't — moved to a mechanism this project already relies on and knows works: `GameHud` now has a SECOND `CanvasLayer` (layer 21, above its own 20) that any button-bearing panel without an explicit `layer` mounts on instead, which always draws over the normal one unconditionally, the same guarantee already used for the loading screen/level-select menu. (11) moved the cursor-to-center warp from the moment `pRIP` becomes visible (death) to the moment it hides again (clicking Retry), per the request. See `docs/SESSION_LOG.md` 2026-08-04 (GB-7, GB-7 continued, GB-7 continued round 2, GB-7 continued round 3, GB-7 round 4) and 2026-08-06 (GB-7 round 5). |

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

_Last edited: 2026-08-06 (GB-7 round 5: pSkip moved to a dedicated overlay CanvasLayer after two z-order fixes didn't hold, and the cursor-center warp moved from death to the Retry click; all pending confirmation)._
