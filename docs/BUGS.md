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
| GB-1 | Shiks: no text / animation / voice during the 2nd dialogue, regardless of which choice is picked. | Root cause found and fixed 2026-08-02 via a real console capture + headless reproduction: `action MyCamera`'s chase loop force-closes the dialog (`Dialog.visible = off;`, every tick, ~10s) while `action Piposh2` is re-showing a stale dialogue-1 box (`DialogIndex` is never reset in the WDL source) — Piposh2's own code falls through to a voice-wait loop with no new line ever started, and the interpreter's per-caller voice-debounce (built for a *different* idiom) made that wait permanent instead of an instant pass-through like real Acknex would give it. Fixed in the debounce itself, not the WDL source. Needs in-game re-verification before closing. |
| GB-2 | Plane: Piposh's placement is "wrong" during the first part of the entry scene. | Plane's spawn-height half of this (Piposh floating above/below the cabin floor) was fixed twice (commits `5540f00`, and a wrong first attempt before it) — confirmed matching Krupnik's height. If this is the same issue, needs re-verification in-game; if it's a *different* "wrong placement" (e.g. facing, timing, path), needs a fresh description. |
| GB-3 | Plane2: Piposh spawns lower than the plane's surface, and the character can't move. | Fixed commit `b98470e` (two separate bugs: a wrong-deck floor snap, and a camera-authority deadlock that zeroed the native controller's movement every tick). Needs re-verification in-game before closing. |
| GB-4 | Range: the upper HUD doesn't update when a citizen or terrorist is hit. | Not yet investigated. |
| GB-5 | Range: after Piposh dies, animations keep playing instead of stopping, and the retry/skip buttons that should appear don't show. | Not yet investigated. |

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

_Last edited: 2026-08-01._
