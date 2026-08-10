extends Node
## Generic WDL runtime: executes the AST tools/parse_wdl.py produces
## (assets/converted/wdl_ast/{Level}.json) directly, instead of a level
## getting its behavior from a hand-ported wdl_director.gd chapter. Built
## 2026-07-28 to replace per-level hand-porting with one engine — see
## docs/CONTRACT.md and docs/SESSION_LOG.md for the reasoning and the
## parity-test rule this must pass before driving content nobody has
## verified yet.
##
## Only statement execution (exec_block/exec_stmt/exec_while/exec_if) is
## coroutine-aware (uses `await`), since only `wait()`/`waitt()` ever yield
## in real WDL — expression evaluation is plain synchronous recursion.

const GameHud = preload("res://scripts/ui/game_hud.gd")
const MdlAnimator = preload("res://scripts/engine/mdl_animator.gd")
const WmbLevelLoader = preload("res://scripts/engine/wmb_level_loader.gd")

const AST_DIR := "res://assets/converted/wdl_ast/"

var _globals: Dictionary = {}
var _globals_lower: Dictionary = {}  # lowercase name -> canonical name, kept in sync with _globals -- see _index_global()
var _functions: Dictionary = {}
var _functions_lower: Dictionary = {}  # same O(1)-fallback idea as _globals_lower, for _call()
var _actions: Dictionary = {}
var _actions_lower: Dictionary = {}  # lowercase name -> canonical name, see _resolve_action()
var _sounds: Dictionary = {}
var _sounds_lower: Dictionary = {}  # lowercase name -> canonical name, same pattern as _actions_lower
var _bmaps: Dictionary = {}  # bmap resource name -> file (e.g. "Hit1.pcx"), see _merge_ast()
var _bmaps_lower: Dictionary = {}  # lowercase name -> canonical name, same pattern as _sounds_lower
## Raw parsed panel declarations (tools/parse_wdl.py's `panels` AST
## section) keyed by name, merged in setup() the same way functions/
## actions/etc. are -- see _merge_ast(). Turned into real Control nodes
## (`_panel_nodes`) lazily/once via _ensure_panels_built(), not here.
var _panels_ast: Dictionary = {}
## name -> the live Control node, built from `_panels_ast` -- see
## _ensure_panels_built()/_resolve_entity()'s panel-name lookup.
var _panel_nodes: Dictionary = {}
## Bare top-level assignment statements (e.g. Range.wdl's `on_mouse_left =
## Fire;`, written outside any function/action) -- see
## tools/parse_wdl.py's parse_top_decl() for why these needed their own
## AST section. Run once in setup(), after globals are initialized (so an
## `on_` binding's _assign() symbol-capture special case can already see
## the action/function it names).
var _top_level_stmts: Array = []
## Consumed by exec_stmt()'s "wait"/"waitt" case -- see its own comment.
## Set once per level in begin_level(), right before main()'s coroutine
## starts, so only its opening wait() (virtually every level's main()
## starts with one, e.g. `wait(3);`) is skipped, not any later wait()
## call anywhere else.
var _skip_next_main_wait := false
## GB-5 (2026-08-03, Range): set/cleared by _set_panel_field()'s "visible"
## case whenever the shared IO.wdl `pRIP` death-screen panel toggles --
## see its own comment. Consumed by exec_stmt()'s "wait"/"waitt" case,
## the one yield point virtually every coroutine passes through every
## tick, so every entity's own progress genuinely halts while frozen
## (button clicks are Godot Control signals, entirely independent of WDL
## coroutine scheduling, so the death-screen buttons stay clickable).
var _frozen := false
var _loader: WmbLevelLoader
var _camera: Camera3D
var _hud: GameHud
var _level_stem := ""
## Scratch VECTOR/ANGLE globals (`temp`, `my_angle`, ...) -- real Acknex
## structs, not entities. See _vec_get()/_vec_put().
var _vectors: Dictionary = {}
## Lazily loaded from _loader.last_level_data -- see _do_scan_path().
var _paths_cache: Array = []
var _paths_loaded := false
## Engine.get_process_frames() value of the most recent camera.x/y/z or
## .pan/.tilt/.roll write -- see is_driving_camera_this_frame().
var _camera_control_frame := -1
var _running := true
var _total_frames := 0
## Acknex's implicit `result` variable -- the return value of whichever
## builtin/user function `_call()` most recently ran, readable as a bare
## `result` identifier immediately after (e.g. the corpus-wide
## `if (snd_playing(X)==0) { play_sound(...); X=result; }` ambiance-loop
## idiom). See _get_var()'s "result" case and _call().
var _last_result: Variant = 0.0
var _warned_builtins: Dictionary = {}
var _builtins: Dictionary = {}
## Entities with `enable_impact`/`enable_push`/`enable_entity = on`, for the
## non-physics-body half of that mechanism -- see
## _ensure_impact_area()/_check_impact_proximity()'s comments.
var _impact_zones: Array = []
## node (the impact zone) -> Dictionary of {other_node: true} currently
## within range, so proximity firing is edge-triggered, not per-frame.
var _impact_touching: Dictionary = {}
## Raw mouse motion accumulated since the last _process() tick, exposed as
## the `mickey.x`/`mickey.y` scratch vector (see _vec_field_slot()'s
## generic fallback in _get_field() -- `mickey` needs no special-case
## field routing, just to be kept live in `_vectors` like `temp`/`my_angle`
## already are). Real Acknex `mickey` is a per-tick delta that resets
## itself; mirrored here by zeroing after each _process() read. Range.wdl's
## `action CamTarget`/`action Handgun` (mouse-look aim) are the confirmed
## live use (2026-08-01) -- reported as "the character doesn't move" when
## this was always zero.
var _mouse_delta := Vector2.ZERO
## True for exactly one _process() tick after a real left-click -- the
## non-physics-body half of `on_mouse_left = FuncName;` (Acknex's global
## click-event binding, e.g. Range.wdl's `on_mouse_left = Fire;`, the
## entire firing mechanism for its shooting-gallery gameplay). See
## _assign()'s "on_" symbol-capture case and _check_mouse_click().
var _mouse_left_clicked := false
## GB-7 continued (2026-08-04, Range): "hard to control [the death
## screen] with the mouse" / "the [aim] location doesn't reset when
## retrying." `level_runner.gd` captures the mouse (hidden, locked,
## relative-delta-only) for the whole time a scripted-camera-aiming level
## is running, including while `pRIP` is showing -- meaning the player had
## NO visible cursor at all to aim the Retry/Skip click with, only Godot's
## own internal virtual cursor position (invisible, silently tracked from
## accumulated relative motion), explaining "hard to control": clicking
## the death-screen buttons meant blindly wiggling the mouse with no
## visual feedback at all. Remembers whatever mouse mode was active right
## before `pRIP` showed (see `_set_panel_field()`'s "visible" case) so it
## can be restored exactly once the screen hides again, rather than
## hardcoding CAPTURED (this freeze/unfreeze pairing is generic across any
## level using the shared pRIP panel, not just scripted-camera-aiming
## ones). `-1` (Godot's mouse-mode enum never returns/accepts a negative
## value) means "nothing to restore" -- i.e. pRIP was never actually
## visible when this would be read.
var _mouse_mode_before_rip: int = -1
## GB-7 continued (2026-08-06, Range): "it spawns correctly in the
## middle but now 180 degrees back." Checked the spawn pose itself
## first -- `wdl_spawn_pan`, run through the same
## `_acknex_entity_basis()` math used everywhere else, faces every
## Range target correctly (confirmed by bearing, every one within ~30
## degrees), so the recorded spawn value and the reset math are both
## fine. The actual cause: `_warp_mouse_to_center()`
## (`Input.warp_mouse()`) can itself generate a synthetic
## `InputEventMouseMotion` reporting the jump it just caused -- a known
## Godot behavior, and that synthetic event isn't guaranteed to arrive
## in the same frame the warp call was made. It landed in
## `_mouse_delta`/`mickey` on a LATER frame, after the explicit same-
## frame clear in `_set_panel_field()`'s "visible" case had already run
## -- `action CamTarget`'s own next tick then read it as a huge real
## mouse delta (`my.pan = my.pan - mickey.x/SEN;`) and spun the just-
## reset spawn pose most of the way back around, matching "spawns in
## the middle but 180 degrees back" (a several-hundred-pixel warp /
## SEN=3 easily covers that). Set by `_warp_mouse_to_center()`, consumed
## by `_process()` -- see both their own comments.
var _mouse_delta_suppress_frames := 0


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
func _exit_tree() -> void:
	# Every spawned action/main() coroutine checks this each statement (see
	# exec_stmt) so they wind down cleanly instead of touching a freed node
	# when a level ends/reloads mid-script.
	_running = false


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse_delta += (event as InputEventMouseMotion).relative
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_mouse_left_clicked = true


func _process(_delta: float) -> void:
	_total_frames += 1
	_check_impact_proximity()
	if not _particles.is_empty():
		_update_particles(_delta)
	# See `_mouse_delta_suppress_frames`'s own comment -- discard whatever
	# accumulated (including a synthetic post-warp motion event) instead
	# of feeding it into `mickey` as if the player had actually moved the
	# mouse that far.
	if _mouse_delta_suppress_frames > 0:
		_mouse_delta_suppress_frames -= 1
		_mouse_delta = Vector2.ZERO
	_vectors["mickey"] = Vector3(_mouse_delta.x, _mouse_delta.y, 0.0)
	# GB-7 continued (2026-08-04, Range): "shots don't land where crosshair
	# points" / "the mouse and aim are confusing." `screen_size` was
	# entirely unresolved (silently read back as (0,0) via the generic
	# scratch-vector fallback -- see _get_field()'s own comment), and
	# `WDL/weapons.wdl`'s real, portable `pan_cross_show()` (called by
	# Range/Final/Shooter right where they switch into scripted-camera
	# mouse-look aiming, all with the identical `cross_pos.x=-7;
	# cross_pos.y=-7; pan_cross_show();` idiom) positions its crosshair
	# panel as `cross_pan.pos_x = (screen_size.x/2) + cross_pos.x;` --
	# with screen_size stuck at (0,0), the crosshair landed at (-7,-7),
	# clipped almost entirely off the top-left corner of the screen
	# instead of centered, so the player had no usable on-screen
	# reference for where they were actually aiming (combined with the
	# OS cursor being hidden by the mouse-capture fix, no reference at
	# all) even though `pan_cross_show()` itself was already a real,
	# already-executable WDL function needing no native bridging -- this
	# was the only missing piece. This port's own panel design space is a
	# fixed 640x480 regardless of real window size (`GameHud.DESIGN`,
	# already what every panel's pos_x/pos_y is authored against), which
	# is exactly what `video_mode=6` (640x480, Range's own declared video
	# mode) means `screen_size` should read as in the original engine --
	# same fixed value works for the OTHER corpus users of screen_size
	# too (Golf's Booth/OnAir, Shooter's Overmap), so this isn't a
	# Range-specific value.
	_vectors["screen_size"] = Vector3(GameHud.DESIGN.x, GameHud.DESIGN.y, 0.0)
	_mouse_delta = Vector2.ZERO
	_check_mouse_click()
	_update_panel_windows()


## `on_mouse_left = FuncName;`'s runtime half -- see _assign()'s "on_"
## symbol-capture case for how the binding itself gets stored. Fires the
## bound action/function once per real click, `my=null` (a global input
## binding has no entity context, same as main()'s own body -- confirmed
## safe: `invoke_event()` already handles `my==null` for exactly this
## reason, and Range's `action Fire` -- the only real user of this --
## touches only globals, never `my.*`).
func _check_mouse_click() -> void:
	if not _mouse_left_clicked:
		return
	_mouse_left_clicked = false
	# `_get_var()`'s generic fallback for a never-assigned identifier is
	# `0.0`, and `str(0.0)` is a non-empty string -- so a plain "read
	# on_mouse_left and check for empty" can't actually tell "never bound"
	# apart from "bound to something," and fired invoke_event(null,"0")
	# on every single click in every level that never assigns
	# on_mouse_left (confirmed live via a real console capture, 2026-08-01,
	# Shiks: `INVOKE my=<null> event=0.0` / `NOT FOUND`, once per click,
	# alongside the real click this was investigating -- harmless on its
	# own since it always fails to resolve, but real noise obscuring
	# every other invoke_event() log line). Check the global actually
	# exists first instead.
	if _resolve_symbol(_globals, _globals_lower, "on_mouse_left") == "":
		return
	var bound := str(_get_var("on_mouse_left", null))
	if bound != "":
		invoke_event(null, bound)


func setup(level_stem: String, loader: WmbLevelLoader, camera: Camera3D, hud: GameHud = null) -> bool:
	_level_stem = level_stem
	_loader = loader
	_camera = camera
	_hud = hud
	if _hud and not _hud.dialog_choice.is_connected(_on_dialog_choice):
		_hud.dialog_choice.connect(_on_dialog_choice)
	_register_builtins()
	var ast := _load_ast(level_stem)
	if ast.is_empty():
		return false
	_merge_ast(ast, {})
	_merge_includes_recursive(ast.get("includes", []), {level_stem.to_lower(): true})
	for g in _globals.values():
		g["value"] = _eval_init(g.get("init"), null, g.get("kind", "var"))
	for stmt in _top_level_stmts:
		_exec_stmt_sync(stmt, null)
	_ensure_panels_built()
	return true


## `ShowDialog()`'s corresponding response half: GameHud's dialog panel
## emits this when the player clicks an option button (1/2/3). Sets the
## `DialogChoice` global directly -- the script's own already-written
## per-tick polling loop (`while (DialogIndex==X) { if (DialogChoice==1)
## {...} ...}`, present in every level that calls ShowDialog) picks it up
## naturally on its next `wait(1)` iteration. See _do_show_dialog().
func _on_dialog_choice(choice: int) -> void:
	PiposhDebug.log_msg("dialog-choice", "CLICK choice=%d DialogIndex=%s (before set)" % [
		choice, _get_var("DialogIndex", null)
	])
	_set_var("DialogChoice", float(choice), null)


## `include <X.wdl>` chains transitively -- IO.wdl (included by nearly every
## level) itself includes a dozen more files (DIalog.wdl, movement.wdl,
## actors.wdl, weapons.wdl, ...), so real, widely-used functions like
## ShowDialog live two hops away from the level's own script, not one. A
## single-level merge silently left them all unavailable. `visited` guards
## against an include cycle (none confirmed in the corpus, but cheap
## insurance) and against re-parsing the same shared file many times.
func _merge_includes_recursive(includes: Array, visited: Dictionary) -> void:
	for inc in includes:
		var inc_stem := String(inc).get_basename()
		var key := inc_stem.to_lower()
		if visited.has(key):
			continue
		visited[key] = true
		var inc_ast := _load_ast(inc_stem)
		if inc_ast.is_empty():
			continue
		_merge_ast(inc_ast, {})
		_merge_includes_recursive(inc_ast.get("includes", []), visited)


## `init` from tools/parse_wdl.py is a single AST-node Dictionary for
## `NAME = expr;`, but an Array of AST nodes for the comma-list array-init
## form (`var I[3] = 0,0,0;`) -- _eval() only ever handles single nodes, so
## the two shapes must be told apart before calling it, not assumed uniform
## (crashed here originally: "Trying to assign Array to Dictionary").
func _eval_init(init_val: Variant, my, kind: String) -> Variant:
	if init_val == null:
		return _default_for(kind)
	if init_val is Array:
		var out: Array = []
		for item in init_val:
			out.append(_eval(item, my))
		return out
	return _eval(init_val, my)


## Shared across every WdlInterpreter instance (each level creates a new
## one via WdlInterpreter.new(), so a per-instance cache wouldn't help).
## Nearly every level `include`s IO.wdl, which itself includes ~12 more
## files (DIalog/movement/actors/weapons/war/...) -- without this, that
## whole chain is re-read from disk and re-JSON-parsed on *every* level
## transition. Plausible concrete cause of "scenes stuck a bit when
## starting" reported 2026-07-28; the shared files never change at
## runtime, so caching them for the process lifetime is safe.
static var _ast_cache: Dictionary = {}


func _load_ast(stem: String) -> Dictionary:
	var key := stem.to_lower()
	if _ast_cache.has(key):
		return _ast_cache[key]
	var path := AST_DIR + stem + ".json"
	if not (ResourceLoader.exists(path) or FileAccess.file_exists(path)):
		_ast_cache[key] = {}
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_ast_cache[key] = {}
		return {}
	var data = JSON.parse_string(f.get_as_text())
	var result: Dictionary = data if typeof(data) == TYPE_DICTIONARY else {}
	_ast_cache[key] = result
	return result


func _merge_ast(ast: Dictionary, _ctx: Dictionary) -> void:
	for fname in ast.get("functions", {}):
		if not _functions.has(fname):
			_functions[fname] = ast["functions"][fname]
			_index_symbol(_functions_lower, String(fname))
	for aname in ast.get("actions", {}):
		if not _actions.has(aname):
			_actions[aname] = ast["actions"][aname]
			_index_symbol(_actions_lower, String(aname))
	for decl in ast.get("globals", []):
		var name: String = decl.get("name", "")
		if name != "" and not _globals.has(name):
			_globals[name] = {"kind": decl.get("kind", "var"), "init": decl.get("init"), "value": null}
			_index_global(name)
	for k in ast.get("sounds", {}):
		if not _sounds.has(k):
			_sounds[k] = ast["sounds"][k]
			_index_symbol(_sounds_lower, String(k))
	for k in ast.get("bmaps", {}):
		if not _bmaps.has(k):
			_bmaps[k] = ast["bmaps"][k]
			_index_symbol(_bmaps_lower, String(k))
	# Panel *names* are effectively global too (Dialog.wdl's own panels,
	# Range's GUI/Terr*/Civ*, IO.wdl's pRIP/pSkip/pCongrat-shaped screens
	# all get `include`d the same way functions/actions do) -- same
	# first-writer-wins merge order as everything else above (the level's
	# own definition, merged first in setup(), always beats a same-named
	# one pulled in later via include).
	for k in ast.get("panels", {}):
		if not _panels_ast.has(k):
			_panels_ast[k] = ast["panels"][k]
	_top_level_stmts.append_array(ast.get("top_level_stmts", []))


## Every exact-case symbol table (`_globals`, `_functions`, `_actions`,
## `_sounds`) needs the same case-insensitive fallback: the WDL corpus
## itself is not consistently cased between a symbol's declaration and its
## use as a bare-identifier reference (2026-07-30: e.g. Olympic.wdl declares
## `action GiveNut` but every placement's `my.event = givenut;` uses
## lowercase -- confirmed via corpus survey, not an isolated typo --
## Dutyfree's `Talktome`/`talktome` is the same shape). One pattern, used
## for all four tables, instead of a bespoke fix each time a new symbol kind
## turned out to need it. `lower_table` maps lowercase name -> canonical
## name and must be kept in sync via `_index_symbol()` whenever `table`
## gains a key.
func _resolve_symbol(table: Dictionary, lower_table: Dictionary, name: String) -> String:
	if table.has(name):
		return name
	var canonical = lower_table.get(name.to_lower())
	if canonical != null and table.has(canonical):
		return str(canonical)
	return ""


func _index_symbol(lower_table: Dictionary, name: String) -> void:
	lower_table[name.to_lower()] = name


func _resolve_action(name: String) -> String:
	return _resolve_symbol(_actions, _actions_lower, name)


func _resolve_function(name: String) -> String:
	return _resolve_symbol(_functions, _functions_lower, name)


func _resolve_sound(name: String) -> String:
	return _resolve_symbol(_sounds, _sounds_lower, name)


func _resolve_bmap(name: String) -> String:
	return _resolve_symbol(_bmaps, _bmaps_lower, name)


# ---------------------------------------------------------------------------
# Acknex panel/text HUD objects (bmap-based 2D overlays: health bars, hit
# icons, win/lose screens, ...) -- see tools/parse_wdl.py's parse_panel()
# for the AST shape this reads. Previously a complete gap (docs/CONTRACT.md,
# "PANEL objects... known gap, not built") -- every `panel {...}` block was
# silently discarded at parse time, so nothing using one could ever render.
# Reported live (2026-08-01, Range): "all of the HUD / Screens aren't shown
# on screen." Built generically off the parsed data, not per-level: any
# level with `panel`/`text` declarations gets this for free.
# ---------------------------------------------------------------------------
var _panels_built := false
## Per-frame "window" (progress-bar) fills to keep in sync with their bound
## WDL variable -- {"control": TextureRect, "var": String, "width": float}.
var _panel_windows: Array = []


func _ensure_panels_built() -> void:
	if _panels_built or _hud == null:
		return
	_panels_built = true
	for pname in _panels_ast:
		_build_panel(String(pname), _panels_ast[pname])
	_reorder_panels_by_layer()


## GB-7 continued (2026-08-04, Range): pSkip (z_index=50, see _build_panel()'s
## button-layer default) still rendered BENEATH pRIP (z_index=20) in-game,
## confirmed live even after directly verifying both nodes' own z_index
## values are correct in the built scene tree. z_index alone isn't a
## reliable enough draw-order guarantee for this project's Control
## hierarchy on its own -- GameHud's own show_dialog() already hedges the
## same way, pairing a z_index with an explicit move_to_front() call rather
## than trusting z_index in isolation. Belt-and-suspenders fix: once, right
## after every panel is built, physically reorder them as tree siblings to
## match their declared z_index (lowest first, highest last) -- Godot draws
## later siblings on top by default, so this guarantees correct layering
## regardless of whether z_index sorting alone takes effect, and needs no
## re-sorting afterward since z_index is fixed at build time and never
## changes at runtime.
func _reorder_panels_by_layer() -> void:
	var ordered: Array = _panel_nodes.values()
	ordered.sort_custom(func(a, b): return a.z_index < b.z_index)
	for node in ordered:
		node.move_to_front()


func _panel_field_first(fields: Dictionary, key: String, default: String = "") -> String:
	var occurrences: Array = fields.get(key, [])
	if occurrences.is_empty() or (occurrences[0] as Array).is_empty():
		return default
	return str(occurrences[0][0])


func _build_panel(pname: String, decl: Dictionary) -> void:
	var fields: Dictionary = decl.get("fields", {})
	var root := Control.new()
	root.name = "Panel_" + pname
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.position = Vector2(
		float(_panel_field_first(fields, "pos_x", "0")),
		float(_panel_field_first(fields, "pos_y", "0"))
	)
	# GB-7 continued (2026-08-04, Range): "the skip button... should be
	# clickable and on top of the other HUDs." Range's own `panel pSkip`
	# declares no `layer` at all (defaults to 0), while the HUD panels it
	# needs to sit above explicitly do (`GUI` layer=1, `Terr*`/`Civ*`
	# layer=2/3) -- every OTHER button-containing panel in the corpus
	# remembered an explicit high layer (pSkip's own sibling `pCongrat`:
	# layer=4; the shared `pRIP`: layer=20), so this reads as a genuine
	# authoring oversight specific to pSkip, not an intentional "sits
	# behind everything" design. A button a player is meant to click
	# should never be silently buried behind non-interactive background
	# panels just because its own WED author forgot a layer value --
	# default any button-containing panel that omits one to a high
	# z-index instead of the generic 0 fallback.
	var has_button: bool = not (fields.get("button", []) as Array).is_empty()
	var has_explicit_layer: bool = not (fields.get("layer", []) as Array).is_empty()
	var layer_default := "50" if has_button else "0"
	root.z_index = clampi(int(_panel_field_first(fields, "layer", layer_default)), -4096, 4096)
	root.visible = false  # every real usage in the corpus explicitly turns panels on when needed
	# GB-7 continued (2026-08-06, Range): "the skip button is still beneath
	# the graphic that's shown when we die." Two prior attempts at this
	# (the z_index default above, then an explicit tree reorder --
	# _reorder_panels_by_layer()) both should have put a button panel like
	# this on top within GameHud's own shared CanvasLayer, and both were
	# reported live as not actually fixing it. Moved to a mechanism this
	# project already relies on and knows works reliably instead: any
	# button-bearing panel that never claimed its own explicit layer (the
	# exact same "author forgot a layer value" case as above) mounts on
	# GameHud's dedicated overlay CanvasLayer instead, which always draws
	# over everything in its normal one regardless of z_index/tree order --
	# see GameHud._overlay_layer's own comment. A panel WITH an explicit
	# layer (pRIP=20, pCongrat=4) keeps its author-intended position in the
	# normal stack instead.
	var use_overlay := has_button and not has_explicit_layer
	var panel_root: Control = _hud.get_overlay_panel_root() if use_overlay else _hud.get_panel_root()
	panel_root.add_child(root)
	_panel_nodes[pname.to_lower()] = root

	var bmap_name := _panel_field_first(fields, "bmap")
	if bmap_name != "":
		var tex := _resolve_bmap_texture(bmap_name)
		if tex != null:
			var tr := TextureRect.new()
			tr.name = "Bmap"
			tr.texture = tex
			tr.size = tex.get_size()
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			root.add_child(tr)
			root.set_meta("wdl_bmap_rect", tr)

	for window_args in fields.get("window", []):
		_build_panel_window(root, window_args)
	for button_args in fields.get("button", []):
		_build_panel_button(root, button_args)


## `window x,y,width,height,bmap,var,orientation;` -- a fill-proportional
## progress bar (Range.wdl's health bar: `window 15,58,609,15,bpass,
## health2,0;`). The bound variable's own natural range matches the
## declared width exactly in every corpus usage checked (Health2 climbs
## 0-609, width=609) -- Acknex's `window` element uses the width itself as
## the implicit 100% reference, not a separate declared max.
##
## The referenced bmap (`pass.png`, confirmed via direct pixel-size check)
## is exactly 2x the declared width -- a standard "fill bar" sprite
## convention: reveal more of the LEFT portion via a growing crop region
## as the value rises, not a single image meant to be squashed to fit.
## Cropped with an AtlasTexture region (updated per-frame in
## _update_panel_windows()) rather than resizing the TextureRect's own
## `.size` directly -- confirmed live that doesn't work here: Godot
## recomputes a TextureRect's minimum size from its texture on the next
## layout pass and snaps `.size` straight back to the texture's full
## 1218px width unless `expand_mode` is set to ignore it, which still
## wouldn't give the right crop -- just a squashed full image.
func _build_panel_window(root: Control, args: Array) -> void:
	if args.size() < 6:
		return
	var x := float(args[0])
	var y := float(args[1])
	var w := float(args[2])
	var h := float(args[3])
	var bmap_name := str(args[4])
	var var_name := str(args[5])
	var fill := TextureRect.new()
	fill.name = "Window_" + var_name
	fill.position = Vector2(x, y)
	fill.size = Vector2(w, h)
	fill.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tex := _resolve_bmap_texture(bmap_name)
	if tex != null:
		var atlas := AtlasTexture.new()
		atlas.atlas = tex
		atlas.region = Rect2(0, 0, w, h)
		fill.texture = atlas
	root.add_child(fill)
	_panel_windows.append({"control": fill, "var": var_name, "width": w, "height": h})


## `button x,y,bmap_up,bmap_down,bmap_over,onclick,arg1,arg2;` -- a
## clickable hotspot (Range's pSkip: `button = 0,0,bSkip,bSkip,bSkip,D1,
## null,null;`). Only the up-state bmap and the onclick target matter here
## -- no hover/press visual-state swap (cosmetic, not blocking any of the
## reported behavior).
func _build_panel_button(root: Control, args: Array) -> void:
	if args.size() < 6:
		return
	var x := float(args[0])
	var y := float(args[1])
	var bmap_name := str(args[2])
	var onclick := str(args[5])
	var btn := Control.new()
	btn.name = "Button_" + onclick
	btn.position = Vector2(x, y)
	var tex := _resolve_bmap_texture(bmap_name)
	btn.size = tex.get_size() if tex != null else Vector2(32, 32)
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.set_meta("wdl_onclick", onclick)
	btn.gui_input.connect(_on_panel_button_input.bind(btn))
	root.add_child(btn)
	# GB-5 (2026-08-03, Range): `tex` was resolved only to size the click
	# zone -- never actually drawn, so every panel BUTTON (pRIP's retry/
	# map buttons, pSkip's skip button, ...) was a real, correctly-placed,
	# correctly-clickable hotspot with NOTHING visibly rendered on it.
	# Reported live as "the retry/skip buttons that should appear don't
	# show". Mirrors _build_panel()'s own background-bmap TextureRect.
	if tex != null:
		var tr := TextureRect.new()
		tr.name = "Icon"
		tr.texture = tex
		tr.size = tex.get_size()
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(tr)


func _on_panel_button_input(event: InputEvent, btn: Control) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			get_viewport().set_input_as_handled()
			invoke_event(null, str(btn.get_meta("wdl_onclick", "")))


func _update_panel_windows() -> void:
	for w in _panel_windows:
		var control: TextureRect = w["control"]
		if not is_instance_valid(control):
			continue
		var value := _to_num(_get_var(str(w["var"]), null))
		var full: float = w["width"]
		var clamped := clampf(value, 0.0, full)
		control.size.x = clamped
		var atlas := control.texture as AtlasTexture
		if atlas != null:
			atlas.region = Rect2(0, 0, maxf(clamped, 0.01), float(w["height"]))


const GFX_DIR := "res://assets/converted/gfx/"
## lowercase filename -> real filename, built once and reused for the
## process lifetime -- same caching rationale as `_ast_cache` (the GFX
## folder's contents never change at runtime). Without this,
## `_resolve_bmap_texture()`'s directory-scan fallback re-listed the
## entire folder from scratch for every unresolved bmap; harmless for a
## single lookup, but `_ensure_panels_built()` now runs for every panel
## in the fully include-merged AST (every level pulls in IO.wdl's and
## DIalog.wdl's shared panels too, most of whose bmaps were never
## actually converted -- SDK template screens this game never uses),
## so a level with dozens of merged panels could trigger dozens of full
## rescans. Confirmed live (2026-08-01): Plane2's first 3 frames went
## from ~1.6s (Start, fewer merged panels) to ~5.9s -- reported as "the
## last commit made all levels stuck," which for a level with enough
## unresolved panels a multi-second stall genuinely reads as.
static var _gfx_dir_cache: Dictionary = {}
static var _gfx_dir_cache_built := false


static func _ensure_gfx_dir_cache() -> void:
	if _gfx_dir_cache_built:
		return
	_gfx_dir_cache_built = true
	var dir := DirAccess.open(GFX_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir():
			_gfx_dir_cache[fn.to_lower()] = fn
		fn = dir.get_next()


## `bmap`'s referenced file (e.g. `<Hit1.pcx>`) never matches a converted
## filename literally -- this corpus's GFX conversion always emits `.png`.
## Self-contained (not reusing GameHud._resolve_gfx()) so panel rendering
## doesn't depend on GameHud's private implementation details, and still
## works if a panel is ever needed without a GameHud instance.
func _resolve_bmap_texture(bmap_var_name: String) -> Texture2D:
	if bmap_var_name == "":
		return null
	var file := ""
	if _bmaps.has(bmap_var_name):
		file = _bmaps[bmap_var_name]
	else:
		var low := bmap_var_name.to_lower()
		for k in _bmaps:
			if String(k).to_lower() == low:
				file = _bmaps[k]
				break
	if file == "":
		return null
	return _resolve_gfx_texture_by_stem(file.get_basename(), file)


## Given a bare stem (e.g. "Wart", from `create(<Wart.pcx>,...)`'s own
## literal filename argument, get_basename()'d), finds the matching
## converted PNG under assets/converted/gfx/ -- shared by
## `_resolve_bmap_texture()` (which first resolves a `bmap` symbol name to
## its own declared file) and `_do_create()`'s own bitmap-sprite fallback
## (which already has a raw filename, no symbol indirection needed).
## `full_file`, when given, is tried as a last-resort literal path (some
## converted names don't lowercase-stem cleanly).
func _resolve_gfx_texture_by_stem(stem: String, full_file: String = "") -> Texture2D:
	var candidates := [GFX_DIR + stem + ".png", GFX_DIR + stem.to_lower() + ".png"]
	if full_file != "":
		candidates.append(GFX_DIR + full_file)
	for path in candidates:
		if ResourceLoader.exists(path):
			var tex := load(path) as Texture2D
			if tex != null:
				return tex
	# Last resort: cached case-insensitive filename lookup (mixed-case
	# originals) -- see _ensure_gfx_dir_cache()'s docstring.
	_ensure_gfx_dir_cache()
	var want := (stem + ".png").to_lower()
	if _gfx_dir_cache.has(want):
		return load(GFX_DIR + _gfx_dir_cache[want]) as Texture2D
	return null


func _get_panel_field(node: Control, low: String) -> Variant:
	match low:
		"visible":
			return 1.0 if node.visible else 0.0
		"pos_x":
			return node.position.x
		"pos_y":
			return node.position.y
		"alpha":
			return node.modulate.a * 100.0
		_:
			return 0.0


func _set_panel_field(node: Control, low: String, value: Variant) -> void:
	match low:
		"visible":
			var was_visible := node.visible
			node.visible = _truthy(value)
			# GB-5 (2026-08-03, Range): "animations keep playing in the
			# background" after death. The real engine's own `ShowRIP()`
			# calls `freeze_map` right before showing pRIP -- unimplemented
			# here (a screenshot-into-a-bmap builtin also used for save-file
			# thumbnails elsewhere in IO.wdl), and nothing in the WDL source
			# reads the `Death` global outside `Restart()` itself, so no
			# other coroutine ever knew to stop. `pRIP` is IO.wdl's shared,
			# corpus-wide death-screen panel (not Range-specific), so this
			# generically pauses gameplay for any level using it.
			if String(node.name).to_lower() == "panel_prip":
				var now_visible := _truthy(value)
				if now_visible:
					_frozen = true
					# GB-7 continued (2026-08-04, Range): "hard to
					# control [the death screen] with the mouse." See
					# `_mouse_mode_before_rip`'s own comment -- the
					# player had no visible cursor to click Retry/Skip
					# with at all while the mouse stayed captured.
					# Mirrors GameHud.show_dialog()'s own existing
					# "need a real OS cursor for hit-testing" handling.
					_mouse_mode_before_rip = Input.mouse_mode
					PiposhDebug.log_msg("mouse-mode", "pRIP shown, saved=%s -> VISIBLE" % [_mouse_mode_before_rip])
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				elif was_visible:
					# Unfreeze immediately -- matches `HideRIP()`'s own
					# `pRIP.visible = off;`, which always runs synchronously
					# BEFORE `main()`'s own `wait(3);` gap (fRIP1: `HideRIP();
					# main();`). NOT deferred to `_do_level_load()` (tried
					# that: `main()`'s own opening `wait(3);` is itself gated
					# by this SAME `_frozen` flag, so `main()` could never
					# reach `level_load()` to release a freeze it was itself
					# blocked behind -- a self-deadlock).
					_frozen = false
					if _mouse_mode_before_rip != -1:
						PiposhDebug.log_msg("mouse-mode", "pRIP hidden, restoring -> %s" % [_mouse_mode_before_rip])
						Input.mouse_mode = _mouse_mode_before_rip as Input.MouseMode
						_mouse_mode_before_rip = -1
					# GB-7 continued (2026-08-06, Range): "the pointer
					# should be reset after we click to restart the
					# stage, not after we die." Moved from the `now_visible`
					# (death) branch above to here -- warping right as pRIP
					# shows meant the cursor jumped the instant the player
					# died, before they'd even clicked anything; the player
					# wanted the reset tied to the Retry click itself
					# instead, the same moment gameplay actually resumes.
					_warp_mouse_to_center()
					# GB-7 continued (2026-08-04, Range): "the [aim]
					# location doesn't reset when we're restarting."
					# Whatever mouse motion the player made clicking
					# Retry (blind, while pRIP was visible -- `mickey`
					# keeps accumulating every _process() tick
					# regardless of `_frozen`, only CONSUMING it is
					# gated) was still sitting in `mickey` the instant
					# `action CamTarget` resumed, and its own very first
					# post-resume statements (`my.pan = my.pan -
					# mickey.x/SEN; my.tilt = ...;`) apply it BEFORE ever
					# reaching `camera.pan = my.pan;` -- so a leftover
					# click-motion delta nudged the aim away from the
					# reset spawn pose within the same tick it was
					# reset, making the reset below look like it never
					# happened. `_warp_mouse_to_center()` above already
					# clears `_mouse_delta`/`mickey` (and arms a multi-
					# frame guard against its OWN synthetic motion event --
					# see `_mouse_delta_suppress_frames`'s own comment),
					# which covers this too.
					# GB-7 continued (2026-08-04, Range): "retry... messes
					# with the view." Reset the camera's spawn pan/tilt/roll
					# HERE too, synchronously, rather than waiting for
					# `_do_level_load()` -- `action CamTarget` resumes
					# ticking (unfrozen, above) well before `main()`'s own
					# `wait(3);` gap clears, so leaving the camera reset
					# behind that gap let CamTarget respond to live mouse
					# input on the STALE pre-death orientation for that
					# whole window, then SNAP once the deferred reset
					# finally landed. Deliberately NOT resetting `Death`
					# here too, even though it's the same "retry state"
					# conceptually -- see `_do_level_load()`'s own comment
					# for why that one specifically has to stay deferred.
					_reset_camera_spawn_pose()
					# GB-7 continued (2026-08-07, Range): "restarting the
					# stage after dying should reset the enemies on
					# screen as well." Same trigger, same synchronous
					# burst -- see _reset_all_entities_to_spawn()'s own
					# comment.
					_reset_all_entities_to_spawn()
		"pos_x":
			node.position.x = _to_num(value)
		"pos_y":
			node.position.y = _to_num(value)
		"alpha":
			node.modulate.a = clampf(_to_num(value) / 100.0, 0.0, 1.0)
		"transparent":
			pass  # cosmetic fade-state flag, not needed for visible/invisible correctness
		"bmap":
			var tr: TextureRect = node.get_meta("wdl_bmap_rect", null)
			if tr != null:
				var tex := _resolve_bmap_texture(str(value))
				if tex != null:
					tr.texture = tex
					tr.size = tex.get_size()


func _default_for(kind: String) -> Variant:
	match kind:
		"string":
			return ""
		"vector":
			return Vector3.ZERO
		"entity":
			return null
		_:
			return 0.0


func has_main() -> bool:
	return _functions.has("main")


## Spawns main() (if present) plus one coroutine per placed entity whose
## WMB `action` matches a parsed `action NAME { ... }` block — the generic
## replacement for wdl_director.gd's per-level `_begin_X()` dispatch.
func begin_level() -> void:
	if _functions.has("main"):
		_skip_next_main_wait = true
		_run_coroutine(_functions["main"].get("body", {}), null)
	if _loader == null:
		print("[wdl] begin_level: no loader, no entity actions started")
		return
	var root: Node = _loader.get_node_or_null("Entities")
	if root == null:
		print("[wdl] begin_level: no Entities node found under loader")
		return
	var started := 0
	var total := 0
	var unmatched := {}
	for node in root.get_children():
		if not (node is Node3D):
			continue
		total += 1
		var action := str(node.get_meta("action", ""))
		if action == "":
			continue
		var resolved_action := _resolve_action(action)
		if resolved_action != "":
			node.set_meta("wdl_skills", (node.get_meta("skills", []) as Array).duplicate())
			_seed_look_at_me_flag1(node, action)
			_seed_pipi_flag1_stay_put(node, action)
			_seed_genia_facing(node, action)
			_seed_reveal_only_hidden(node, _actions[resolved_action].get("body", {}))
			_seed_static_pose_if_never_animated(node, _actions[resolved_action].get("body", {}))
			_run_coroutine(_actions[resolved_action].get("body", {}), node)
			# GB-7 continued (2026-08-07, Range): see `_reset_entity_to_spawn()`'s
			# own comment -- captured HERE, after `_run_coroutine()` returns,
			# so it reflects whatever the action's own synchronous init
			# statements (everything before its first `wait()`) already
			# computed, e.g. `action Terrorist`'s own `my.OriginalZ = my.z;`.
			# `_run_coroutine()` only returns this early because coroutines
			# run purely synchronously up to their first real yield point --
			# by the time control comes back here, that init has already
			# happened for real, not merely been scheduled.
			node.set_meta("wdl_spawn_custom_fields", _snapshot_custom_fields(node))
			node.set_meta("wdl_spawn_skills", (node.get_meta("wdl_skills", []) as Array).duplicate())
			started += 1
		else:
			unmatched[action] = unmatched.get(action, 0) + 1
	print(
		"[wdl] begin_level: main=%s entities=%d action_coroutines_started=%d unmatched_actions=%s"
		% [_functions.has("main"), total, started, unmatched]
	)


## `action LookAtMe` (Start.wdl and others -- confirmed via corpus grep,
## also used by Shiks/Town's own patrol-camera entities under the same
## action name) branches its whole camera behavior on `my.flag1`, a
## WED-authored per-entity checkbox this port has no verified bit mapping
## for (docs/CONTRACT.md §4.1 "known gaps" -- only bit0=INVISIBLE and
## bit10=PASSABLE are confirmed; FLAG1-8's actual bits are not). Rather than
## guess a bit position that would apply -- possibly wrongly -- to every
## other `my.flagN` read in the whole corpus, this seeds `flag1` only for
## `LookAtMe` entities specifically, from a concrete, verified textual clue
## found while diagnosing a real report (2026-07-30, see docs/SESSION_LOG.md
## "camera is still not exactly right"): `action LookAtMe`'s `flag1==on`
## branch hardcodes `camera.pan = 270;` with no look-at math, and in
## Start.wmb, exactly one of its two `LookAtMe` placements is independently
## authored with pan=270 (the other is 90) -- too specific a match to be
## coincidence, reads as the level designer deliberately setting that
## entity's own facing to match what its branch does. User-confirmed
## approach (asked directly, not assumed) after the bit-mapping dead end.
## If a level ever has a `LookAtMe` placement that doesn't fit this
## pattern, this heuristic will guess wrong for it -- not a silent
## certainty, a stated inference pending real playtest confirmation.
const LOOK_AT_ME_FLAG1_ON_PAN := 270.0
const LOOK_AT_ME_FLAG1_PAN_TOLERANCE := 15.0


func _seed_look_at_me_flag1(node: Node3D, action: String) -> void:
	if action.to_lower() != "lookatme":
		return
	if node.has_meta("wdl_custom_flag1"):
		return  # already set (e.g. re-entrant setup) -- don't clobber a runtime write
	var pan := float(node.get_meta("pan", 0.0))
	var diff := absf(fposmod(pan - LOOK_AT_ME_FLAG1_ON_PAN + 180.0, 360.0) - 180.0)
	node.set_meta("wdl_custom_flag1", 1.0 if diff <= LOOK_AT_ME_FLAG1_PAN_TOLERANCE else 0.0)


## NB-7 follow-up (2026-08-02, Shiks): `action Pipi` (3 placements, one
## per camera-cut shot) has `if((Talking==14)&&(my.flag1==off)){my.x=XX;
## ...}` -- `XX` is set once by `action Dummy { XX = my.x; }`, so any
## Pipi placement that reaches Talking==14 with flag1 off teleports its
## own X coordinate to wherever Dummy sits (a totally different part of
## the map, ~13600 units away for the far placements) -- clearly meant
## to move only the ONE placement representing the "real" walking-away
## Piposh (the near, scale=1.0 one, confirmed working) to where Dummy is,
## not the far, dramatically-scaled cutaway placements meant to stay put
## for their own shot (the bus/phone-booth PipCell.MDL and the pigeon-
## shot Piposh.MDL, both reported/confirmed missing -- a real Godot
## screenshot showed the camera correctly framing empty air where either
## should be, ~13000+ units from where the entity actually ended up).
## `flag1` has no verified WED bit mapping in this port (docs/CONTRACT.md
## known gap, same one `_seed_look_at_me_flag1` above works around) --
## every entity's flag1 silently defaults to "off", so this teleport
## fires unconditionally for every Pipi placement instead of only the one
## it was meant for. Same narrow, measured-signal approach as
## `_seed_look_at_me_flag1`: a Pipi placement authored with a
## significantly non-1.0 scale is, by construction, one of the special-
## purpose cutaway props (Preserve authored scales -- see
## `_spawn_entity()`'s own comment -- so this scale difference is itself
## real, measured WED data, not a guess) rather than the ordinary,
## scale=1.0 walking character, so it gets flag1 seeded on to skip the
## teleport and stay in the shot it belongs to.
const PIPI_STAY_PUT_SCALE_THRESHOLD := 1.5


func _seed_pipi_flag1_stay_put(node: Node3D, action: String) -> void:
	if action.to_lower() != "pipi":
		return
	if node.has_meta("wdl_custom_flag1"):
		return  # already set (e.g. re-entrant setup) -- don't clobber a runtime write
	if node.scale.x >= PIPI_STAY_PUT_SCALE_THRESHOLD:
		node.set_meta("wdl_custom_flag1", 1.0)


## Reported live (2026-08-09, Smash): "The Genia model is walking to the
## correct direction but facing the wrong way, he needs to be facing 90
## degrees to his left." `action WalkGeniaWalk` (Smash.wdl) moves its own
## entity purely via direct position writes (`my.y = my.y - 10*time;`) --
## it never touches `my.pan` anywhere in its own body, so whatever facing
## the model renders with is entirely WED's own static authored angle.
## Confirmed via the level JSON: Genia's own placement has `angle_gs =
## [0,0,0]` -- no rotation authored at all -- while its own movement is
## along Acknex -Y, which this port's `_gs_to_godot()` maps to +Godot Z.
## At pan=0, `_do_actor_move()`'s own established forward convention
## (`Vector3(cos(pan),0,-sin(pan))`) points along +Godot X, not +Z --
## the model was never actually facing its own direction of travel, WED's
## authored angle notwithstanding. `pan=0 - 90` aims it at +Z instead,
## matching the walk direction and the reported "off by 90°" correction.
## Scoped to this one action, matching `_seed_look_at_me_flag1()`'s own
## precedent, rather than a general re-interpretation of authored angles
## (which would risk every other static, non-turning placement in the
## corpus, not just this one).
func _seed_genia_facing(node: Node3D, action: String) -> void:
	if action.to_lower() != "walkgeniawalk":
		return
	if node.has_meta("wdl_genia_facing_seeded"):
		return
	node.set_meta("wdl_genia_facing_seeded", true)
	_set_entity_pan(node, float(node.get_meta("pan", 0.0)) - 90.0)


## Generic fix for "reveal-only" actors: an action whose only
## `my.invisible = ...` assignments (anywhere in its body, however deeply
## nested in if/while) ever set it to `off` (visible), never `on` (hidden).
## If the entity's own WED-authored flag doesn't already mark it invisible
## (`_ensure_impact_area`'s sibling concern -- see wmb_level_loader.gd's
## `flag_invisible`), such an action's reveal statement is a structural
## no-op: the entity is visible from frame 1 regardless, defeating the
## obvious intent of a staged "become visible at the right story beat"
## reveal. Confirmed live (2026-08-01, Shiks): `action Weasel` only ever
## does `my.invisible = off` when `CamShow == 6`, with no initializer and
## no re-hide branch; Shiks.json's raw WED flags for that entity (256,
## bit0 clear) confirm it truly is authored visible, not a flag-decode
## bug -- so the model sits in the open from the very first frame and
## whatever the camera happens to look at early (this port's `scan_path`
## waypoint-following is an *approximate* reconstruction of the original
## path, not byte-exact -- see `_do_scan_path()`) can expose it well
## before its intended CamShow==6 reveal. Unlike the Weasel-specific
## conclusion, this scan itself is generic (AST-shape based, not keyed on
## action/level name) so it transparently protects any other
## similarly-authored reveal-only actor in the corpus without needing a
## per-level special case.
## 2026-08-09 extension (Smash): a SECOND, related shape reported live --
## "standing Piposh... appears both falling and on the floor when the
## game starts." `action PiposhFall` hides itself and sets
## `MoviePhase = 1;` at the exact instant it "lands"; the separate,
## already-on-the-ground `action PipTalk` entity is meant to reveal at
## that same instant (`if ((MoviePhase==1)||(MoviePhase==3)) {
## my.invisible=off; ...}`), a designer-intended entity swap. But
## unlike every OTHER staged-reveal action in the corpus (`BigBad`/
## `Bads`/`PipPee`/`PipSit`/`Mendy`/`Ami`, all a single exhaustive
## `if(cond){invisible=off;...}else{invisible=on;...}` that
## self-corrects the instant it's first reached, and Olympic's OWN,
## differently-written `PipTalk`, same exhaustive shape), Smash's
## `PipTalk` writes its reveal and its ONLY hide (`if (Ride>0)
## {invisible=on;...}`) as two SEPARATE, non-complementary
## `if`-statements -- both false on the very first tick (`MoviePhase`
## and `Ride` both start at 0), so neither ever runs, and WED's own
## raw "visible" authoring (confirmed via the level JSON's own `flags`
## field, same 256/bit0-clear value already confirmed genuine for
## Shiks' `Weasel` above) is left in effect the whole time PiposhFall
## is also visible and falling. `_has_exhaustive_invisible_toggle()`
## below distinguishes the two shapes structurally (does SOME if/else
## pair in the body set `invisible` to opposite values in its two
## branches, guaranteeing a correct, self-managed value on tick 1
## regardless of the entity's raw WED state) rather than adding a
## name-specific special case -- transparently covers any other
## corpus action with this exact "two independent, non-exhaustive
## show/hide conditions" gap too.
func _seed_reveal_only_hidden(node: Node3D, body: Dictionary) -> void:
	if bool(node.get_meta("invisible", false)):
		return  # WED already starts it hidden -- nothing to fix.
	if _has_exhaustive_invisible_toggle(body):
		return  # self-corrects the instant its own if/else is first reached.
	if _has_unconditional_leading_invisible_set(body):
		# `action PIPI`/`action Handgun`-style: `my.invisible = on;` (or
		# `off`) is the body's own literal FIRST statement, unconditional,
		# guaranteed to run before anything else on this entity's own
		# synchronous priming tick in begin_level() -- already correctly
		# self-managing regardless of WED's raw flag, nothing to add here.
		return
	# [seen_show, seen_hide] as an Array, not two local bools: GDScript
	# lambdas capture primitives by value, so a closure mutating outer
	# `bool` locals silently never propagates back -- first version of
	# this fix looked correct and did nothing. Recursing with explicit
	# return values (no closure) instead.
	var seen := _scan_invisible_assignments(body)
	if seen[0]:
		node.visible = false


## True if `body`'s own top-level statements (not nested inside any
## if/while) include an unconditional `my.invisible = <bool>;` before the
## first `wait()`/`waitt()` -- i.e. something genuinely guaranteed to run
## during begin_level()'s own synchronous coroutine-priming pass, before
## the level ever renders, same as `action PIPI`/`action Handgun`'s own
## literal first statement.
func _has_unconditional_leading_invisible_set(body: Dictionary) -> bool:
	for stmt in body.get("body", []):
		var t := str(stmt.get("t", ""))
		if t == "wait" or t == "waitt":
			return false  # nothing after this is guaranteed synchronous
		if t != "expr_stmt":
			continue
		var ex: Dictionary = stmt.get("expr", {})
		if str(ex.get("t", "")) != "assign" or str(ex.get("op", "")) != "=":
			continue
		var target: Dictionary = ex.get("target", {})
		if str(target.get("t", "")) != "field" or str(target.get("name", "")).to_lower() != "invisible":
			continue
		var obj: Dictionary = target.get("obj", {})
		if str(obj.get("t", "")) == "id" and str(obj.get("name", "")).to_lower() == "my":
			return true
	return false


## True if `n` contains an "if" statement (however deeply nested) whose
## "then" and "else" branches assign `my.invisible` to OPPOSITE values --
## see _seed_reveal_only_hidden()'s own extended docstring for why this
## (not just "does a hide exist anywhere") is the real self-correcting
## signal.
func _has_exhaustive_invisible_toggle(n: Variant) -> bool:
	if n is Dictionary:
		if str(n.get("t", "")) == "if" and n.get("else") != null:
			var then_seen := _scan_invisible_assignments(n.get("then", {}))
			var else_seen := _scan_invisible_assignments(n.get("else", {}))
			if (then_seen[0] and else_seen[1]) or (then_seen[1] and else_seen[0]):
				return true
		for key in n.keys():
			if _has_exhaustive_invisible_toggle(n[key]):
				return true
	elif n is Array:
		for item in n:
			if _has_exhaustive_invisible_toggle(item):
				return true
	return false


## Returns [seen_show, seen_hide] for `my.invisible = <bool>` assignments
## found anywhere in the given AST subtree (however deeply nested in
## if/while). See _seed_reveal_only_hidden()'s docstring for why only
## statements targeting `my` specifically (not `player`/other objects)
## count.
func _scan_invisible_assignments(n: Variant) -> Array:
	var seen_show := false
	var seen_hide := false
	if n is Dictionary:
		if str(n.get("t", "")) == "assign" and str(n.get("op", "")) == "=":
			var target: Dictionary = n.get("target", {})
			if str(target.get("t", "")) == "field" and str(target.get("name", "")).to_lower() == "invisible":
				var obj: Dictionary = target.get("obj", {})
				if str(obj.get("t", "")) == "id" and str(obj.get("name", "")).to_lower() == "my":
					var val: Dictionary = n.get("value", {})
					if str(val.get("t", "")) == "bool":
						if bool(val.get("v", false)):
							seen_hide = true
						else:
							seen_show = true
		for key in n.keys():
			var sub := _scan_invisible_assignments(n[key])
			seen_show = seen_show or sub[0]
			seen_hide = seen_hide or sub[1]
	elif n is Array:
		for item in n:
			var sub := _scan_invisible_assignments(item)
			seen_show = seen_show or sub[0]
			seen_hide = seen_hide or sub[1]
	return [seen_show, seen_hide]


## `MdlAnimator.setup_from_stem()`'s own fallback -- when a model has no
## "Stand" clip, only "Frame" -- assumes any such entity wants "Frame"
## looped (correct for fan/smoke/falling-debris props whose own WDL
## scripts drive `ent_cycle("Frame", my.skill1)` themselves over time,
## e.g. Ziggy's FCloud, Plane's Cow/Ship/PisaFall). Wrong for a static
## prop that just happens to store its one fixed pose under a clip named
## "Frame" -- confirmed twice independently (2026-08-01, Plane2):
## AFG_Card (Afgan.wdl's clickable collectible flight badge) and Sikot
## (a clickable static NPC/prop) both never call `ent_frame`/`ent_cycle`
## anywhere in their own action body at all, yet both were left actively
## cycling through "Frame"'s poses by the loader-time fallback, reported
## live as "animating instead of being static." Generic fix, not a
## per-action hardcode (the first attempt, an `action=="afg_card"` check
## plus a `MdlAnimator.hold_autoplay` export, worked but doesn't
## generalize -- Sikot needed the exact same fix under a different name,
## confirming this is a real corpus-wide pattern, not a one-off):
## statically scans the action's own AST body (however deeply nested in
## if/while) for any `ent_frame`/`ent_cycle` call; if it never animates
## itself, whatever pose MdlAnimator's own fallback landed on gets held
## static instead of cycled. Runs once per entity at `begin_level()`,
## before the first frame ever renders, so there's no visible flicker
## even though it corrects an already-started cycle.
func _seed_static_pose_if_never_animated(node: Node3D, body: Dictionary) -> void:
	# Checked BEFORE the ent_frame/ent_cycle scan below, not after: an
	# action can call actor_move() in its always-reached walk loop while
	# ALSO calling ent_frame() somewhere else entirely -- e.g. Plane.wdl's
	# `action PiposhWalk` walks Piposh in via actor_move() alone, but its
	# own body has an `ent_frame("Take",100)` buried inside a dialogue-
	# choice branch only reachable much later, after he's already
	# arrived and is talking. Scanning the WHOLE body for "any ent_frame/
	# ent_cycle anywhere" found that unrelated later call and (wrongly)
	# concluded this action handles its own animation, so it never got
	# real walk-cycle treatment and froze to a static pose from level
	# start instead -- moving with zero animation the whole way in.
	# Real Acknex's own actor_move() auto-selects a walk cycle as a
	# built-in convenience; this port's straight-line _do_actor_move()
	# doesn't, so any action that calls actor_move() gets one driven
	# for it instead (see _do_actor_move()'s own "wdl_auto_walk_anim"
	# comment) -- regardless of what else is elsewhere in its body.
	# Reported live (2026-08-01, Plane): "there's no walking animation
	# when he enters the frame and walks."
	if _scan_for_calls(body, ["actor_move"]):
		node.set_meta("wdl_auto_walk_anim", true)
		return
	if _scan_for_calls(body, ["ent_frame", "ent_cycle"]):
		return
	var anim := node.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim == null or not bool(anim.get("_playing")):
		return
	var clip := str(anim.get("_current_clip"))
	if clip != "":
		anim.play_frame(clip, 0.0)


## True if the given AST subtree contains a `call` expression whose name
## (case-insensitive) is in `names`, anywhere, however deeply nested.
func _scan_for_calls(n: Variant, names: Array) -> bool:
	if n is Dictionary:
		if str(n.get("t", "")) == "call" and str(n.get("name", "")).to_lower() in names:
			return true
		for key in n.keys():
			if _scan_for_calls(n[key], names):
				return true
	elif n is Array:
		for item in n:
			if _scan_for_calls(item, names):
				return true
	return false


## Same shape as _scan_for_calls() but for a bare identifier reference
## (`{"t":"id","name":X}`, e.g. `mickey` in `my.pan = my.pan - mickey.x /
## SEN;` -- parsed as a field access whose `obj` is an "id" node, not a
## "call") anywhere in the AST, not just as a function-call target.
func _scan_for_identifier(n: Variant, name: String) -> bool:
	if n is Dictionary:
		if str(n.get("t", "")) == "id" and str(n.get("name", "")).to_lower() == name:
			return true
		for key in n.keys():
			if _scan_for_identifier(n[key], name):
				return true
	elif n is Array:
		for item in n:
			if _scan_for_identifier(item, name):
				return true
	return false


## GB-7 (2026-08-04, Range): "shots don't land where crosshair points."
## `_enable_first_person()` is the only place `Input.mouse_mode` gets
## captured (hidden + locked) -- but Range's own aiming is entirely
## script-driven (`action CamTarget`: `my.pan = my.pan - mickey.x/SEN;
## camera.pan = my.pan;`), a scripted-camera level, not a first-person
## `player_walk*` one, so it never goes through that path. The OS cursor
## stayed visible and free-roaming the whole time -- camera rotation is
## driven by raw mouse DELTA (mickey), completely independent of the
## cursor's own screen position, so a player naturally aiming with their
## visible cursor (at the time the only on-screen reference they had --
## `pan_cross_show()`'s own crosshair panel wasn't rendering correctly
## either yet, see `screen_size`'s own comment in `_process()`) would see
## shots consistently land away from it.
## Used by level_runner.gd to decide whether a scripted-camera level
## should ALSO capture the mouse, the same way first-person levels do.
func uses_mickey_aiming() -> bool:
	for a in _actions.values():
		if _scan_for_identifier(a.get("body", {}), "mickey"):
			return true
	for f in _functions.values():
		if _scan_for_identifier(f.get("body", {}), "mickey"):
			return true
	return false


func _run_coroutine(body: Dictionary, entity) -> void:
	exec_block(body, entity)


# ---------------------------------------------------------------------------
# Statement execution (coroutine-aware)
# ---------------------------------------------------------------------------
class BreakSignal:
	pass


class ReturnSignal:
	var value: Variant
	func _init(v: Variant) -> void:
		value = v


## Acknex's `MY`/`ME` is a genuine reassignable pointer register, not just a
## read-only "current entity" keyword -- `my = someOtherEntity;` followed by
## a bare library-action call (`actor_explode();`, `_gib(20);`, etc.) is a
## common corpus idiom for "run this generic helper action ON a different
## entity than the one currently executing", e.g. WDL/weapons.wdl's
## `ACTION actor_explode {...; remove(ME);}` is meant to explode and remove
## WHATEVER entity `my` was pointing at when it was invoked, not always the
## caller itself. `_get_var()`'s "my"/"me" case has always correctly
## returned the real, live `my` parameter -- but `_set_var()` (reached via
## plain assignment, `_assign()`'s "id" target case) has no matching
## special-case, so `my = X;` silently wrote to a dead `_globals["my"]`
## entry nothing ever reads back, leaving `my` pointing at the ORIGINAL
## caller for the rest of the coroutine. Confirmed live (2026-08-08,
## Plane3): `action BadBird`'s own catch-the-vase sequence does exactly
## `my = TheVase; _gib(20); actor_explode(); my = Birdy;` -- with the
## reassignment a no-op, `actor_explode()`'s own `remove(ME);` (after
## several real wait()s) removed BadBird itself instead of the vase,
## permanently halting BadBird's own coroutine (see _entity_alive()) and
## blocking the level's `Run("Smash.exe")` transition -- exactly the
## "he's getting stuck mid flight where the vase is" report. Intercepted
## here, in the one place that already walks a block's own top-level
## statement list, rather than in `_set_var()` itself: a real per-coroutine
## pointer register needs `my` mutable for every statement AFTER the
## reassignment within this same block (and everything they call), which
## only this loop -- not a single assignment's own evaluation -- can thread
## through. Scoped to this block: a reassignment inside a nested if/while
## does not propagate back out to the enclosing block, an acceptable gap
## given every real corpus usage found reassigns and consumes `my` as
## direct siblings in one block, exactly like BadBird's own shape above.
func exec_block(block: Dictionary, my) -> Variant:
	var current_my = my
	for stmt in block.get("body", []):
		if str(stmt.get("t", "")) == "expr_stmt":
			var ex: Dictionary = stmt.get("expr", {})
			if str(ex.get("t", "")) == "assign" and str(ex.get("op", "")) == "=":
				var tgt: Dictionary = ex.get("target", {})
				if str(tgt.get("t", "")) == "id" and str(tgt.get("name", "")).to_lower() in ["my", "me"]:
					current_my = _eval(ex.get("value"), current_my)
					continue
		var sig = await exec_stmt(stmt, current_my)
		if sig != null:
			return sig
	return null


## Guards a resumed coroutine's use of `my`. Reproduced 2026-07-30
## (docs/SESSION_LOG.md, tools/smoke_remove_race.gd): when an entity has
## both a persistent `action X { while(1){...} }` coroutine and a
## click-triggered handler that calls `remove(my)` on itself (the standard
## WDL shape, e.g. WDL/Afgan.wdl's AFG_Card/AFG_Take), the two coroutines
## can end up resumed within the same synchronous signal-dispatch window --
## at that exact instant `is_instance_valid()`/`is_inside_tree()` both
## still read true for the just-removed node, yet simply passing that same
## reference into any *other* Node3D-typed parameter (e.g. `_eval()`)
## crashed the engine outright ("previously freed, not a subclass of the
## expected argument class") until every `my`/`entity` parameter in this
## file was untyped (removing GDScript's strict argument-type validation,
## which is what actually crashed, not the object state itself). With that
## fix a dangling `my` degrades to recoverable per-call `SCRIPT ERROR`s
## instead of a hard engine crash -- better, but `_entity_alive()` must
## still make the loop actually stop, and `my == null` is **not** a safe
## check for a dangling reference here: for a genuinely freed instance,
## GDScript's `==` can itself misreport (confirmed empirically -- this
## function's own `my == null` branch was observed returning true for a
## definitely-non-null-originally, definitely-freed `my`, which is why the
## loop kept spinning and erroring every frame instead of stopping after
## this function was first added). `typeof(my) == TYPE_NIL` inspects the
## Variant's own type tag rather than dispatching an equality operator
## through the (possibly corrupted) object, and is the check that actually
## works.
func _entity_alive(my) -> bool:
	if typeof(my) == TYPE_NIL:
		return true
	if not is_instance_valid(my):
		return false
	return not my.has_meta("wdl_removed")


func exec_stmt(stmt: Dictionary, my) -> Variant:
	if not _running or not _entity_alive(my):
		return ReturnSignal.new(null)
	match str(stmt.get("t", "")):
		"block":
			return await exec_block(stmt, my)
		"local_decl":
			for decl in stmt.get("decls", []):
				var v = _eval_init(decl.get("init"), my, decl.get("kind", "var"))
				var dname: String = decl.get("name")
				_globals[dname] = {"kind": decl.get("kind", "var"), "init": null, "value": v}
				_index_global(dname)
			return null
		"expr_stmt":
			# A bare top-level call to a USER function (not a builtin) gets
			# a real, awaitable coroutine instead of _call()'s normal
			# synchronous-to-completion path -- see
			# _call_user_function_async()'s docstring for why this specific
			# shape needs it. Nested calls (inside a larger expression,
			# `a = b + Foo();`) are unaffected -- WDL never needs a
			# mid-expression `wait()`, only real WDL scripts calling a
			# genuinely long-running shared function as their own tail
			# statement do, and this only fires for that exact shape.
			var top_expr: Dictionary = stmt.get("expr", {})
			if str(top_expr.get("t", "")) == "call":
				var fname := str(top_expr.get("name", ""))
				if not (fname.to_lower() in BRIDGE_OVER_SHARED_FUNCTIONS):
					var resolved := _resolve_function(fname)
					if resolved != "":
						_last_result = await _call_user_function_async(resolved, top_expr.get("args", []), my)
						return null
					# Acknex lets an `action NAME {...}` be invoked like a
					# plain function too (no separate "callable" concept --
					# both are just named statement blocks); `_call()`'s
					# normal dispatch only ever checked `_functions`, never
					# `_actions`, for a bare call target. Confirmed live
					# (2026-08-01, Plane2): `action player_walk2`'s tail
					# statement is `player_move2();`, and `player_move2`
					# is itself declared with `ACTION`, not `function` --
					# unresolved, this fell all the way through to the
					# generic "unbridged builtin" no-op, so its entire body
					# (including the real "all 4 side-quest goals done ->
					# Run(Range.exe)" check, the actual report) never ran
					# even once, let alone as an ongoing per-frame check.
					#
					# 2026-08-09 continued (Desert): see
					# _call_user_function_async()'s own docstring for why
					# this is now `_run_coroutine()`-style fire-and-forget
					# (no `await`) instead of blocking this ENTIRE caller
					# until the action's own body fully returns -- applies
					# here too, same underlying mechanism, same reasoning.
					var resolved_action := _resolve_action(fname)
					if resolved_action != "":
						exec_block(_actions[resolved_action].get("body", {}), my)
						return null
			_eval(top_expr, my)
			return null
		"if":
			if _truthy(_eval(stmt.get("cond"), my)):
				return await exec_stmt(stmt.get("then"), my)
			elif stmt.get("else") != null:
				return await exec_stmt(stmt.get("else"), my)
			return null
		"while":
			var guard := 0
			var who: String = str(my.name) if (my != null and is_instance_valid(my)) else "main"
			# GB-1 fix (2026-08-02, Shiks): `while (GetPosition(Voice) <
			# 1000000) {...}` ("idiom A", a one-time blocking wait -- see
			# _do_get_voice_position()'s own comment for "idiom B", the
			# perpetual-poll shape the consumed-generation debounce was
			# actually built for) only ever needs to see "finished" ONCE
			# to exit, by construction -- there's no way for it to
			# "re-fire" a side effect the way idiom B can, so it should
			# never be starved by an EARLIER, unrelated while-loop (same
			# caller) having already consumed the current generation.
			# Real Acknex has no such concept at all: GetPosition(Voice)
			# just reports actual playback state to every caller, every
			# time. Confirmed live: Shiks' `action Piposh2`, after
			# choice 3, re-shows a stale DialogIndex=1 box (DialogIndex
			# is never reset -- corpus data, not a bug to "fix" by
			# editing the WDL) which `action MyCamera`'s still-running
			# chase loop (`Dialog.visible = off;`, unconditional, every
			# tick for ~10s) then force-closes before any real click --
			# Piposh2 falls through to the shared reaction-wait loop
			# with DialogChoice still 0, no new sPlay() ever happens, and
			# the OLD generation was already consumed by the PREVIOUS
			# wait loop moments earlier -- permanently stuck. Clearing
			# consumption for `my` right as a NEW GetPosition(Voice)-
			# gated while loop begins gives it the same one-time-fresh
			# read idiom A always needs, without touching idiom B's own
			# debounce at all (that lives entirely inside a perpetual
			# while(1)'s nested `if`, never inside a fresh "while"
			# dispatch like this one).
			if my != null and _scan_for_calls(stmt.get("cond"), ["getposition"]):
				_voice_finished_consumed_by.erase(my)
			# _entity_alive() guards each loop iteration the same way
			# exec_stmt's own top-level guard does -- a *different*
			# coroutine on the same entity can free `my` between
			# iterations (see _entity_alive()'s and _do_remove()'s
			# docstrings for the full reentrant-removal story this guards
			# against, root-caused and fixed 2026-07-30).
			while _entity_alive(my) and _truthy(_eval(stmt.get("cond"), my)):
				var sig = await exec_stmt(stmt.get("body"), my)
				if sig is BreakSignal:
					break
				if sig is ReturnSignal:
					return sig
				guard += 1
				if guard == 512:
					# Diagnostic for the 2026-07-29 "visible but static" report:
					# a while-loop body that never itself hits a real `wait()`
					# (e.g. it only calls a user function that was *supposed*
					# to wait() internally -- _exec_block_sync can't actually
					# suspend, see its own docstring) spins hundreds of times
					# per frame instead of once per tick, which reads as the
					# whole game freezing even though it's technically still
					# running. Logged once per offending loop, not every
					# iteration, so this can't itself flood the console.
					_warn_once("while-loop spinning without wait() -- entity=%s" % who)
				if guard % 4096 == 0:
					await get_tree().process_frame  # runaway-loop safety valve
			return null
		"wait", "waitt":
			var n := 1
			if stmt.get("n") != null:
				n = int(_eval(stmt.get("n"), my))
			if my == null and _skip_next_main_wait:
				# `main()`'s own opening `wait(3);` (or similar, corpus-wide
				# -- confirmed via grep, virtually every level's main()
				# starts with one) existed to give the original engine's
				# own, genuinely slow level load a moment to actually
				# finish before gameplay started. Reported live
				# (2026-08-01): "in the original game there's a sleep/wait
				# function for 3 seconds before each level actually
				# starts... loads very quickly anyway on modern devices."
				# Consumed once per level (see begin_level()) so only
				# main()'s own first wait is affected -- every other
				# wait() in the game, including any later ones inside
				# main() itself, is untouched.
				_skip_next_main_wait = false
				n = 1
			# GB-5 (2026-08-03, Range): see _frozen's own declaration and
			# _set_panel_field()'s "visible" case. Every WORLD coroutine's
			# own progress genuinely halts here while the death screen is
			# up -- resumes exactly where it left off once unfrozen.
			#
			# GB-9 continued (2026-08-08, Range): "the skip [button]
			# doesn't pass us to the next level" -- confirmed live the
			# click DOES register (its own sPlay("SFX138.WAV") audibly
			# plays) but never gets any further. pSkip's own button
			# (function D1: `sPlay(...); while (GetPosition(Voice) <
			# 1000000) { wait(1); } Run("Plane3.exe");`) is deliberately
			# clickABLE while pRIP is still showing (this file's own
			# "button clicks are Godot Control signals, entirely
			# independent of WDL coroutine scheduling" design, same
			# section as _frozen's declaration) -- but the coroutine IT
			# STARTS still hit this SAME blanket freeze gate on its own
			# first `wait(1)`, and unlike Retry's `fRIP1 { HideRIP();
			# main(); }` (which clears `_frozen` synchronously, as part
			# of the SAME statement, before `main()`'s own first wait is
			# ever reached), nothing about clicking Skip ever unfreezes
			# anything -- pRIP stays up by design, so D1's own wait
			# blocked forever, and `Run()` was never reached. `fRIP2`
			# ("return to map", pRIP's other button) has the identical
			# shape (`waitt(60); ...; wait(1);`) and would deadlock the
			# same way. Both -- and every other panel-button-invoked
			# function in the corpus -- are bare functions, never tied to
			# a world entity (`my` is always null for an `invoke_event(
			# null, ...)` call from `_on_panel_button_input()`), unlike
			# every actual WORLD coroutine `_frozen` is meant to pause
			# (Terrorist/Civilian/CamTarget/Handgun, all started with
			# their own entity as `my`). `main()`'s own `my == null` wait
			# already gets special-cased just above (`_skip_next_main_
			# wait`) for the same reason: bare, UI/level-lifecycle-driven
			# coroutines aren't part of the "world" this freeze pauses.
			while _frozen and _running and my != null:
				await get_tree().process_frame
			for i in maxi(n, 1):
				await get_tree().process_frame
				if not _running:
					break
			return null
		"return":
			var v = _eval(stmt.get("value"), my) if stmt.get("value") != null else null
			return ReturnSignal.new(v)
		"break":
			return BreakSignal.new()
		"label", "goto":
			_warn_once("goto/label (%s)" % str(stmt.get("name", stmt.get("label", ""))))
			return null
		_:
			return null


# ---------------------------------------------------------------------------
# Expression evaluation (synchronous)
# ---------------------------------------------------------------------------
func _eval(e: Variant, my) -> Variant:
	if e == null:
		return null
	var d: Dictionary = e
	match str(d.get("t", "")):
		"num":
			return float(d.get("v", 0.0))
		"str":
			return str(d.get("v", ""))
		"res":
			return str(d.get("v", ""))
		"bool":
			return 1.0 if bool(d.get("v", false)) else 0.0
		"null":
			return null
		"id":
			return _get_var(str(d.get("name", "")), my)
		"field":
			return _get_field(d.get("obj"), str(d.get("name", "")), my)
		"index":
			var obj = _eval(d.get("obj"), my)
			var idx := int(_eval(d.get("idx"), my))
			if obj is Array and idx >= 0 and idx < obj.size():
				return obj[idx]
			return 0.0
		"unop":
			var v = _eval(d.get("expr"), my)
			if d.get("op") == "-":
				return -float(v) if v != null else 0.0
			if d.get("op") == "!":
				return 0.0 if _truthy(v) else 1.0
			return v
		"binop":
			return _binop(str(d.get("op")), d.get("l"), d.get("r"), my)
		"ternary":
			return _eval(d.get("a"), my) if _truthy(_eval(d.get("cond"), my)) else _eval(d.get("b"), my)
		"assign":
			return _assign(str(d.get("op")), d.get("target"), d.get("value"), my)
		"call":
			if str(d.get("name", "")).to_lower() == "getposition":
				return _do_get_voice_position(my, _call_site_id(d))
			return _call(str(d.get("name", "")), d.get("args", []), my)
		_:
			return null


## GDScript's float() throws ("Nonexistent 'float' constructor") on anything
## that isn't already numeric-ish -- an Array or a Node3D (entity reference)
## reaching here is expected WDL usage (`if (my)` / `if (you)` entity-valid
## checks, `vec_*` out-params that are no-ops and stay null/Array), not a
## bug in the script being interpreted. Crashed here originally on exactly
## this. See docs/SESSION_LOG.md 2026-07-28.
func _to_num(v: Variant) -> float:
	if v == null:
		return 0.0
	match typeof(v):
		TYPE_FLOAT, TYPE_INT, TYPE_BOOL:
			return float(v)
		TYPE_STRING:
			return 0.0
		_:
			# Node3D (entity ref), Array (unimplemented vec_* out-param), or
			# anything else: not a number, but truthy as "exists".
			return 1.0 if v is Node3D else 0.0


func _binop(op: String, ln: Variant, rn: Variant, my) -> Variant:
	if op == "&&":
		return 1.0 if (_truthy(_eval(ln, my)) and _truthy(_eval(rn, my))) else 0.0
	if op == "||":
		return 1.0 if (_truthy(_eval(ln, my)) or _truthy(_eval(rn, my))) else 0.0
	var l = _eval(ln, my)
	var r = _eval(rn, my)
	if op == "+" and (typeof(l) == TYPE_STRING or typeof(r) == TYPE_STRING):
		return str(l) + str(r)
	var lf := _to_num(l)
	var rf := _to_num(r)
	match op:
		"+":
			return lf + rf
		"-":
			return lf - rf
		"*":
			return lf * rf
		"/":
			return lf / rf if rf != 0.0 else 0.0
		"==":
			return 1.0 if _loose_eq(l, r) else 0.0
		"!=":
			return 0.0 if _loose_eq(l, r) else 1.0
		"<":
			return 1.0 if lf < rf else 0.0
		">":
			return 1.0 if lf > rf else 0.0
		"<=":
			return 1.0 if lf <= rf else 0.0
		">=":
			return 1.0 if lf >= rf else 0.0
		"&":
			return float(int(lf) & int(rf))
		"|":
			return float(int(lf) | int(rf))
		"^":
			return float(int(lf) ^ int(rf))
	return 0.0


func _loose_eq(l: Variant, r: Variant) -> bool:
	# Entity-reference / null identity checks (`you == null`, `target == my`)
	# are common WDL patterns -- compare by GDScript's own identity/equality
	# instead of coercing an entity reference through float() (crashes; see
	# _to_num()). But only when *both* sides are that kind of reference:
	# GDScript's `==` throws "Invalid operands 'float' and 'Object'" if only
	# one side is (e.g. `target == 0`, a common WDL "no entity" sentinel
	# check) -- and a live entity reference is never equal to a bare number
	# anyway, so that case is just false, not a crash.
	var l_ref := l == null or l is Node3D
	var r_ref := r == null or r is Node3D
	if l_ref and r_ref:
		return l == r
	if l_ref or r_ref:
		return false
	if typeof(l) == TYPE_STRING or typeof(r) == TYPE_STRING:
		return str(l) == str(r)
	return _to_num(l) == _to_num(r)


func _truthy(v: Variant) -> bool:
	if v == null:
		return false
	if typeof(v) == TYPE_STRING:
		return v != ""
	if v is Node3D:
		return true  # a live entity reference is truthy (`if (you)` etc.)
	return _to_num(v) != 0.0


# ---------------------------------------------------------------------------
# Variable / entity-field access
# ---------------------------------------------------------------------------
func _get_var(name: String, my) -> Variant:
	var low := name.to_lower()
	if low == "my" or low == "me":
		# `ME` is Acknex's other name for the current entity, same as `MY`
		# -- confirmed live (2026-08-01, Range): `ACTION Spark`'s bullet
		# movement is entirely `move(ME, nullskill, fireball_speed)`
		# (WDL/weapons.wdl), so without this every bullet's own move()
		# call resolved to a null entity and silently did nothing.
		return my
	if low == "you" or low == "then":
		return null  # proximity-scan pointers -- not tracked generically yet
	if low == "camera":
		return _camera
	if low == "time":
		return get_process_delta_time() * 16.0  # Acknex TIME ~ ticks at 16Hz
	if low == "total_frames":
		# Real Acknex built-in engine frame counter. Almost every level's
		# main() ends with `while (total_frames == 0) { wait(1); }` ("wait
		# until engine has started running") -- left as an ordinary global
		# (permanently 0) this loop never exits, silently stalling main()
		# forever. Confirmed via corpus grep: this exact idiom appears in
		# dozens of level scripts, not just Intro2. See docs/SESSION_LOG.md
		# 2026-07-28.
		return float(_total_frames)
	if low == "random":
		return 0.0
	if low == "result":
		return _last_result
	var global_canonical := _resolve_symbol(_globals, _globals_lower, name)
	if global_canonical != "":
		return _globals[global_canonical].get("value")
	# `sound Cockpit = <SFX089.WAV>;` declarations were parsed into
	# `_sounds` but never read here -- found 2026-07-30 chasing a real
	# gameplay report ("audio from talks is not being played"): every
	# reference to a declared sound name (e.g. `play_entsound(my, cockpit,
	# 300)` in WDL/Afgan-style ambiance loops) silently evaluated to 0.0
	# instead of the WAV filename, so AudioBus.play_sfx("0.0") failed and
	# reset the *shared* voice-finished state every tick it ran -- and
	# since that shared state is also what `GetPosition(Voice)` reads,
	# a broken ambiance sound running concurrently with a real dialogue
	# line falsely marked the dialogue "finished" as soon as the very next
	# tick, cutting it off almost immediately. See docs/CONTRACT.md §5.
	var sound_canonical := _resolve_sound(name)
	if sound_canonical != "":
		return str(_sounds[sound_canonical])
	# GB-4 (2026-08-03, Range): `bmap bTerrHit = <Hit2.pcx>;` declarations
	# were parsed into `_bmaps` but never read here, same shape of gap as
	# the `_sounds` one above -- every reference to a declared bmap name
	# as a VALUE (not a `panel.bmap = X` field name, which _set_panel_field
	# already handles fine, but the right-hand side X itself) silently
	# evaluated to 0.0. Confirmed live: Range's `UpdatePanel()` does
	# `Terr15.bmap = bTerrHit;` on every hit, but `bTerrHit` evaluated to
	# 0.0, so `_resolve_bmap_texture(str(0.0))` found no texture named
	# "0" and the write was a silent no-op -- the hit-count HUD icons
	# never visually changed even though the underlying Terrorists/
	# Civilians counters (and win/lose logic reading them) were correct
	# the whole time. Returns the canonical bmap NAME (not the file, unlike
	# the sound case above) since `_resolve_bmap_texture()` looks its
	# argument up by name, not by file.
	var bmap_canonical := _resolve_bmap(name)
	if bmap_canonical != "":
		return bmap_canonical
	return 0.0


func _set_var(name: String, value: Variant, my) -> void:
	var canonical := _resolve_symbol(_globals, _globals_lower, name)
	if canonical != "":
		name = canonical
	if not _globals.has(name):
		_globals[name] = {"kind": "var", "init": null, "value": null}
		_index_global(name)
	_globals[name]["value"] = value
	# Reported live (2026-08-10, Town): "there are no running cars." Real
	# Acknex's VECTOR type is the same 3-float struct as a plain scalar
	# variable, with no separate declared-type system -- `force = my.
	# skill1;` (a bare scalar assign, SportCar's own idiom) is standard
	# Acknex shorthand for "set only my .x component", and elsewhere the
	# SAME name is read/written via `.x`/`.y`/`.z` (move_gravity2()'s own
	# `TIME*force.x`, `force.Y=0;`) through the separate `_vectors`
	# scratch store (see _vec_get()'s docstring). Those were two
	# disconnected storage locations before this -- a bare-scalar write
	# never reached the vector side, so `force.x` always read back as 0
	# regardless of what the script just "set", and any ground actor
	# built on this idiom (Town/Fight/Mount/Mine/Race/WDL/Cards.wdl/
	# WDL/PWF.wdl's own move_gravity()-style functions) silently
	# accumulated zero speed forever. Confirmed via headless trace: a
	# spawned TownCar's own `force=my.skill1;` had no observable effect
	# on its `_SPEED_X`/`_SPEED_Y` at all. Mirroring the scalar into the
	# vector store's `.x` here (leaving `.y`/`.z` alone, matching the
	# real "only x is set" contract -- SportCar's own callee immediately
	# zeroes Y/Z itself right after, which only makes sense under this
	# reading) keeps both views of the same underlying name in sync,
	# harmless for any name that's never read as a vector.
	if typeof(value) in [TYPE_FLOAT, TYPE_INT, TYPE_BOOL]:
		var vname := name.to_lower()
		var v: Vector3 = _vectors.get(vname, Vector3.ZERO)
		v.x = float(value)
		_vectors[vname] = v


## `_get_var`/`_set_var` are the single hottest path in the whole
## interpreter -- every bare identifier read/write in every expression, for
## every entity's action coroutine, every frame. Recursive `include`s (added
## 2026-07-28) mean `_globals` can now hold several hundred entries (every
## level pulls in IO.wdl's entire ~13-file shared-library tree), so the
## previous "scan every key doing .to_lower()" case-insensitive fallback
## went from a small linear scan to a real per-frame, per-entity O(n)
## bottleneck -- confirmed as the likely cause of a severe slowdown reported
## right after that include fix landed. This index makes the fallback O(1).
func _index_global(name: String) -> void:
	_index_symbol(_globals_lower, name)


func _deindex_global(name: String) -> void:
	var low := name.to_lower()
	if _globals_lower.get(low) == name:
		_globals_lower.erase(low)


func _resolve_entity(obj: Variant, my):
	# Untyped return -- same reason as _resolve_arg_entity(): `my` (or `v`)
	# can be a dangling reference, and a typed Node3D return crashed on one
	# ("Trying to return a previously freed instance"), confirmed via
	# tools/smoke_remove_race.gd.
	#
	# A genuinely-unresolved bare identifier (e.g. `entSaveLoadMenu`, a
	# PANEL reference this interpreter doesn't understand yet -- PANEL
	# objects are a known, documented gap, see docs/CONTRACT.md) must
	# return null here, NOT fall back to `my`. Falling back to `my` used to
	# let an unrelated write like `entSaveLoadMenu.visible = 1;` land on
	# whatever entity happened to be running the action -- which, for a
	# Cam entity's own action script, is the camera itself, so an
	# unrelated PANEL write could silently toggle camera state. Only `my`/
	# `camera` keywords and expressions that actually evaluate to a live
	# Node3D should ever resolve to something; everything else is null,
	# and _get_field()/_set_field() already treat null as a safe no-op.
	if obj == null:
		return my
	if obj is Dictionary and obj.get("t") == "id" and str(obj.get("name", "")).to_lower() in ["my", "me"]:
		return my
	if obj is Dictionary and obj.get("t") == "id" and str(obj.get("name", "")).to_lower() == "camera":
		return _camera
	if obj is Dictionary and obj.get("t") == "id" and str(obj.get("name", "")).to_lower() == "dialog" and _hud != null:
		return _hud
	if obj is Dictionary and obj.get("t") == "id":
		var idname := str(obj.get("name", "")).to_lower()
		if _panels_ast.has(idname) or _panel_nodes.has(idname):
			_ensure_panels_built()
			if _panel_nodes.has(idname):
				return _panel_nodes[idname]
	var v = _eval(obj, my)
	return v if (is_instance_valid(v) and v is Node3D) else null


func _get_field(obj_expr: Variant, field: String, my) -> Variant:
	var node = _resolve_entity(obj_expr, my)
	var low := field.to_lower()
	if node == null or not is_instance_valid(node):
		# Scratch VECTOR/ANGLE fallback (`temp.x`, `my_angle.pan`, ...) --
		# see _vec_get()'s docstring. Must be checked here, not only inside
		# vec_set/vec_sub/vec_to_angle's own argument resolution: plain WDL
		# statements like `temp.x = TARGET_X - MY.X;` go through this exact
		# function via ordinary field-assignment, not through those
		# builtins. Returning 0.0 unconditionally here (the old behavior)
		# meant `temp`'s components were silently dropped on every write,
		# so `temp` always read back as a zero vector regardless of what
		# the script "set" it to -- confirmed as the actual cause of
		# `vec_to_angle` always computing a zero-length direction (a
		# stale-target symptom that looked identical to, but was distinct
		# from, the earlier `scan_path`/custom-field fixes).
		var slot := _vec_field_slot(low)
		if slot >= 0 and obj_expr is Dictionary and obj_expr.get("t") == "id":
			var vname := str(obj_expr.get("name", "")).to_lower()
			var v: Vector3 = _vectors.get(vname, Vector3.ZERO)
			return v[slot]
		return 0.0
	if node == _camera:
		return _get_camera_field(low)
	if node == _hud:
		# `Dialog` (WDL/DIalog.wdl's PANEL) -- the only field any script
		# actually reads is `.visible`, always to gate a `while (Dialog.visible
		# == on) { ... wait(1); }` idiom waiting for the choice panel to close
		# after a click. Genuinely unresolved before this (no generic PANEL
		# support, docs/CONTRACT.md known gap), which silently read 0.0/off
		# forever -- harmless on its own, but it meant that gating loop always
		# fell through on the SAME frame `ShowDialog()` just opened the panel,
		# so the script re-called `ShowDialog()` (which resets `DialogChoice`
		# to 0, see `_do_show_dialog`) every subsequent frame with nothing
		# ever blocking it long enough for a real click to be read before
		# being reset again. Confirmed live (2026-07-31, Shiks: "after
		# choosing, the talk isn't starting"). Bridged to the real HUD state.
		if low == "visible":
			var is_open := _hud.is_dialog_open()
			# GB-1 heartbeat, same throttling idea as _do_get_voice_
			# position()'s own -- answers "does this caller's
			# while(Dialog.visible==on) gate ever actually see the box as
			# open, or does it race past instantly" without flooding the
			# log every tick a dialog gate is blocking (which is normal,
			# expected, and would otherwise fire constantly in any level
			# with a dialogue choice).
			var who_dh := str(my.name) if (my != null and is_instance_valid(my)) else "<null>"
			var dh_count := int(_dialog_visible_read_heartbeat.get(who_dh, 0)) + 1
			_dialog_visible_read_heartbeat[who_dh] = dh_count
			if dh_count % 60 == 1:
				PiposhDebug.log_msg("dialog-choice", "DIALOG_VISIBLE_READ by=%s is_open=%s" % [who_dh, is_open])
			return 1.0 if is_open else 0.0
		return 0.0
	if node is Control:
		return _get_panel_field(node, low)
	var gs := _godot_to_gs(node.global_position)
	match low:
		"x":
			return gs.x
		"y":
			return gs.y
		"z":
			return gs.z
		"pan":
			return float(node.get_meta("pan", 0.0))
		"tilt":
			return float(node.get_meta("tilt", 0.0))
		"roll":
			return float(node.get_meta("roll", 0.0))
		"skin":
			return float(node.get_meta("skin", 1.0))
		"invisible":
			return 0.0 if node.visible else 1.0
		"passable":
			return 1.0 if bool(node.get_meta("passable", false)) else 0.0
		_:
			if low.begins_with("skill"):
				var idx := int(low.substr(5)) - 1
				var arr: Array = node.get_meta("wdl_skills", [])
				if idx >= 0 and idx < arr.size():
					return arr[idx]
				return 0.0
			# Generic custom-field fallback -- real Acknex entities can carry
			# arbitrary named fields beyond the fixed x/y/z/pan/.../skillN
			# set above (e.g. `_movemode`/`_target_x`/`_target_y`, the
			# actor-movement-mode bookkeeping every `scan_path`-using script
			# reads/writes -- confirmed via corpus grep, 22 files). Without
			# this, ANY custom field write was a silent no-op and every read
			# of it permanently returned 0.0 regardless of what the script
			# "set" -- found chasing a "stuck on the first frame" report
			# where `my._movemode = 1;` never actually stuck, so
			# `while (my._MOVEMODE > 0) { ... }` (a loop that also gates
			# unrelated dialogue-advancement logic in the original scripts)
			# never ran even after fixing `scan_path`'s own return value.
			return node.get_meta("wdl_custom_" + low, 0.0)


func _get_camera_field(low: String) -> Variant:
	if _camera == null:
		return 0.0
	var gs := _godot_to_gs(_camera.global_position)
	match low:
		"x":
			return gs.x
		"y":
			return gs.y
		"z":
			return gs.z
		"pan":
			return float(_camera.get_meta("pan", 0.0))
		"tilt":
			return float(_camera.get_meta("tilt", 0.0))
		"roll":
			return float(_camera.get_meta("roll", 0.0))
	return 0.0


func _set_field(obj_expr: Variant, field: String, value: Variant, my) -> void:
	var node = _resolve_entity(obj_expr, my)
	var low := field.to_lower()
	if node == null or not is_instance_valid(node):
		# Scratch VECTOR/ANGLE fallback -- see the matching comment in
		# _get_field().
		var slot := _vec_field_slot(low)
		if slot >= 0 and obj_expr is Dictionary and obj_expr.get("t") == "id":
			var vname := str(obj_expr.get("name", "")).to_lower()
			var v: Vector3 = _vectors.get(vname, Vector3.ZERO)
			v[slot] = _to_num(value)
			_vectors[vname] = v
		return
	if node == _camera:
		_set_camera_field(low, value, my)
		return
	if node == _hud:
		# `Dialog.visible = off;` -- see the matching read-side comment in
		# _get_field(). Corpus-wide, this is the only write ever seen
		# (`Dialog.visible = on;` occurs exactly once, inside the real
		# `ShowDialog()` function itself, which is force-bridged to
		# _do_show_dialog() -- see BRIDGE_OVER_SHARED_FUNCTIONS -- so it
		# never actually reaches here).
		if low == "visible" and _to_num(value) == 0.0:
			_hud.hide_dialog()
		return
	if node is Control:
		_set_panel_field(node, low, value)
		return
	match low:
		"x", "y", "z":
			var gs := _godot_to_gs(node.global_position)
			if low == "x":
				gs.x = _to_num(value)
			elif low == "y":
				gs.y = _to_num(value)
			else:
				gs.z = _to_num(value)
			node.global_position = _gs_to_godot(gs)
		"pan":
			_set_entity_pan(node, _to_num(value))
		"tilt":
			_set_entity_tilt_roll(node, _to_num(value), float(node.get_meta("roll", 0.0)))
		"roll":
			_set_entity_tilt_roll(node, float(node.get_meta("tilt", 0.0)), _to_num(value))
		"skin":
			node.set_meta("skin", value)
			var anim := node.get_node_or_null("MdlAnimator") as MdlAnimator
			if anim:
				anim.set_skin(int(_to_num(value)))
		"invisible":
			# NB-7 (2026-08-02, Shiks): WmbLevelLoader's own spawn-time
			# WED-flag handling (`_hide_meshes()`, bit0=INVISIBLE) hides
			# every child MeshInstance3D directly, leaving the entity's
			# own root node (`node` here) at its default `visible=true`.
			# This write only ever toggled THAT root node -- so an entity
			# WED-authored to start invisible and get revealed later by
			# script (a real, corpus-wide idiom: e.g. Shiks' `action Pipi`
			# placements, hidden at spawn, `my.invisible = off;` once
			# CamShow reaches the shot they belong in) had its root node
			# correctly become "visible", while the actual mesh underneath
			# stayed hidden forever -- confirmed live: "Piposh not shown"
			# in exactly the camera shots whose WED-placed stand-in was
			# spawned with the invisible flag set. Now toggles every
			# MeshInstance3D descendant to match, the same recursive shape
			# `_hide_meshes()` itself uses, so a later reveal actually
			# reveals the mesh instead of just an already-visible empty node.
			#
			# GB-6 (2026-08-02, Plane2): the first-person player proxy is an
			# exception to all of the above. WDL/move.wdl's real
			# `player_move2()` (called every tick from `ACTION player_walk2`)
			# has `if (MY.CLIENT == 0) { player = ME; }` as its own first
			# statement -- a genuine, intentional binding (MY.CLIENT always
			# reads 0 here, so this always fires), matching real Acknex's own
			# built-in `player` pointer. Plane2.wdl's `action A1` (a Piposh
			# stand-in used for a specific third-person cutscene) writes
			# `player.invisible = off;` in its own default/non-cutscene
			# branch -- harmless in the original engine, where first-person
			# rendering never draws the player's own body regardless of this
			# flag, but in this port `invisible` is the ONLY thing keeping
			# the FP body hidden (`_hide_meshes()`, spawn-time only), so that
			# write directly un-hid it: reported live as "a Piposh character
			# there... shouldn't be there... no collision... empty click" --
			# exactly the FP proxy's own already-passable, already-unwired
			# mesh, now visible. Skip the toggle entirely for that one node;
			# its visibility is a fixed port-owned invariant once first-
			# person is active, same philosophy as the existing
			# move_view_1st/move_view_3rd bridge-to-no-op fix.
			var fp_node = _loader.first_person_spawn.get("node") if _loader != null else null
			if node == fp_node:
				return
			node.visible = not _truthy(value)
			_set_mesh_visibility_recursive(node, node.visible)
		"event":
			# `my.event = HP;` -- the click-trigger target, captured as a
			# name string by _assign()'s special case above. Read back by
			# WdlDirector._handle_click_action() when this entity is
			# clicked; see invoke_event().
			node.set_meta("wdl_event", str(value))
			PiposhDebug.log_msg(
				"wdl-event",
				"CAPTURE node=%s action_meta=%s event=%s"
				% [node.name, str(node.get_meta("action", "")), str(value)]
			)
		"enable_click":
			# A common WDL pattern (`my.enable_click = on; my.event = X;`)
			# for making any entity clickable at runtime -- previously a
			# silent no-op (this field wasn't handled at all), so every
			# click-driven entity in every level running through the
			# interpreter was permanently unresponsive regardless of what
			# its own action script did. Only need to guarantee a pickable
			# Area3D exists here; WdlDirector's existing ray-pick code
			# already resolves a click by walking up to any ancestor with
			# an `action` meta (set on every entity at spawn), so no
			# additional click_action bookkeeping is needed.
			if _truthy(value):
				var had_area := _ensure_clickable_area(node)
				PiposhDebug.log_msg(
					"wdl-event",
					"ENABLE_CLICK node=%s action_meta=%s had_existing_area=%s"
					% [node.name, str(node.get_meta("action", "")), had_area]
				)
		"enable_impact", "enable_push", "enable_entity":
			# `my.enable_entity/enable_push/enable_impact = on; my.event = X;`
			# -- the physical-collision counterpart to `enable_click`
			# (corpus-wide idiom, 22 files, e.g. Shiks.wdl's `action Bumpin`:
			# walking into the entity should fire its `.event`, the same way
			# clicking one does). Previously a total no-op -- no physics
			# trigger of any kind was ever wired for these three fields, so
			# every walk-into-me interaction in the game was silently
			# unreachable. In Shiks specifically this is the ONLY way
			# `Piposh.skill2` ever becomes 2 (`action Bumped`), which gates
			# the entire rest of `action Piposh2`'s state machine (the
			# fly-through-waypoints camera sequence, `DialogIndex=2`, the
			# "camera through the window" scene) -- so the player was stuck
			# re-choosing from the very first dialogue prompt forever with
			# no way to ever progress, not a dialogue-panel bug. Reported
			# live as "dialogue is looping on the first part" (2026-07-31).
			if _truthy(value):
				_ensure_impact_area(node)
		"near":
			# `my.near = on;` -- Range/Final/Smash's shared first-person
			# weapon-view idiom (`action Handgun`/`action Warty`: never
			# touches my.x/y/z after this beyond, at most, Final's own
			# explicit `my.x = player.x;`). Reported live (2026-08-07):
			# "the gun view... in the orig game the gun is more closer and
			# we don't see the rest of the hand." Confirmed via a headless
			# transform/mesh-AABB dump: the WMB-authored placement and 0.2
			# scale are faithfully preserved (not a conversion bug), but
			# the model itself is a full forearm-sleeve + handgun mesh
			# (confirmed from its own texture atlas) reaching from ~34 to
			# ~173 units in front of the camera -- the SLEEVE end sits
			# closest, so it's the biggest, most dominant thing on screen
			# (at 34 units, the camera's own vertical FOV cone is barely
			# wider than the model's own height), while the gun itself,
			# farther away, reads as small and secondary. Godot has no
			# per-entity near-clip override to lean on here (unlike
			# whatever Acknex's own NEAR flag literally does), so instead
			# `wdl_near` marks the entity for `_set_entity_pan()`/
			# `_set_entity_tilt_roll()` (the only two places this idiom's
			# own per-tick pan/roll writes ever touch its transform) to
			# pull it toward the camera, once, by just enough that its
			# OWN farthest mesh extent (the gun end) lands at a fixed
			# close viewing distance -- see
			# `_near_weapon_adjusted_position()`'s own comment for the
			# full story, including why the pull is deferred past this
			# exact frame rather than applied immediately.
			if _truthy(value):
				node.set_meta("wdl_near", true)
				node.set_meta("wdl_near_activated_frame", Engine.get_process_frames())
		_:
			if low.begins_with("skill"):
				var idx := int(low.substr(5)) - 1
				var arr: Array = node.get_meta("wdl_skills", [])
				while arr.size() <= idx:
					arr.append(0.0)
				if idx >= 0:
					arr[idx] = value
				node.set_meta("wdl_skills", arr)
			else:
				# Generic custom-field fallback -- see the matching comment
				# in _get_field().
				node.set_meta("wdl_custom_" + low, value)


## See the "invisible" case in _set_field() above -- mirrors
## WmbLevelLoader._hide_meshes()'s own recursive shape so a WDL-driven
## reveal actually undoes what spawn-time flag-invisible hiding did,
## instead of only toggling the (otherwise-unused) root node's own
## `visible` property.
func _set_mesh_visibility_recursive(node: Node, vis: bool) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).visible = vis
	for c in node.get_children():
		_set_mesh_visibility_recursive(c, vis)


func _ensure_clickable_area(node: Node3D) -> bool:
	for c in node.get_children():
		if c is Area3D:
			(c as Area3D).input_ray_pickable = true
			return true
	var area := Area3D.new()
	area.collision_layer = 2
	area.collision_mask = 0
	area.input_ray_pickable = true
	var cs := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 28.0
	cs.shape = shape
	cs.position = _clickable_center_offset(node)
	area.add_child(cs)
	node.add_child(area)
	return false


## A click sphere at the node's own local origin (0,0,0) assumes the WED-
## authored origin sits at the mesh's visual center -- true for most props,
## but not guaranteed (e.g. a wall-mounted note/poster, whose origin is
## often a mounting/attachment point, not the middle of the visible
## graphic). Center on the actual mesh AABB instead when one exists, so the
## clickable area lines up with what's actually on screen. Reported live
## (2026-07-31): "the poster that's clickable... is a bit lower placed on
## the screen" (Shiks' ShikNote).
func _clickable_center_offset(node: Node3D) -> Vector3:
	var mi := _find_mesh_instance(node)
	if mi == null:
		return Vector3.ZERO
	var world_center: Vector3 = mi.global_transform * mi.get_aabb().get_center()
	return node.to_local(world_center)


## See the `enable_impact`/`enable_push`/`enable_entity` comment in
## _set_field(). Two complementary mechanisms, because this corpus's real
## "walk into it" collisions come from two structurally different movers:
## 1) The real player (`player_controller.gd`'s `CharacterBody3D`, a real
##    physics body) -- Area3D `body_entered` correctly detects it.
## 2) Every OTHER entity (Shiks' `action Piposh2` walking via `actor_move()`
##    into `action Bumpin`'s Snail, for example) is spawned as a plain
##    `Node3D` (see `WmbLevelLoader._spawn_entity()`), repositioned by
##    direct `global_position` assignment -- Godot's physics engine has no
##    awareness of it at all, so `body_entered` NEVER fires for these,
##    regardless of collision layers/masks. Confirmed live (2026-08-01,
##    Shiks): picking the dialogue choice that should make Piposh walk into
##    Snail and trigger the rest of the scene instead just walked in place
##    and looped back to the same dialogue prompt -- the earlier fix's own
##    verification (`tools/smoke_shiks_bumpin.gd`) called the event handler
##    directly, which only proved the *dispatch* worked, never that real
##    walking would ever reach it. `_impact_zones`/`_check_impact_proximity()`
##    below is a plain per-frame distance check against every other live
##    entity for exactly this case -- the generic analogue of Area3D
##    overlap, for movers Godot's own physics never sees.
## Deliberately NOT using `_clickable_center_offset()` here (unlike
## `_ensure_clickable_area()`): that AABB-centering is for raycasting a
## visible mesh and is correct there, but "walking into" something is a
## position-to-position proximity check, and blindly recentering on a
## mesh's AABB actively breaks it for any large/asymmetric prop -- Shiks'
## own `Snail` mesh is 424x344x89 units, so its AABB center sits ~100
## units away from the entity's own origin (where every other entity's
## `global_position` is anchored), which silently moved the whole trigger
## zone off into empty space. Confirmed live: a `tools/smoke_shiks_
## bumpin_proximity.gd` run that walks Piposh2 to within 0.2 units of
## Snail's own origin never fired, because the zone was centered ~100
## units away. Plain origin is correct for this check.
## GB-7 continued (2026-08-06, Range): "the collision isn't working."
## Investigated scaling this radius to each entity's own mesh footprint
## -- Range's `Fakeguy` (Terrorist/Civilian) targets are ~77x207x60
## units with their own origin sitting ~40 units off-center from their
## own mesh AABB (a "feet"-style pivot, not torso-centered -- see the
## feet-snap fix elsewhere in this file for the same offset), so the
## flat 28-unit radius genuinely can miss a bullet that visually struck
## the model but landed far from the origin. Tried it (farthest XZ AABB
## corner from origin, ~80 units for a Fakeguy) and reverted: confirmed
## live via `smoke_range_death_freeze.gd` failing that an 80-unit sphere
## is large enough to make TWO NEARBY TARGETS falsely detect each other
## (or unrelated static scenery) as "touching," firing `TargetHit`
## repeatedly with nothing having actually been shot -- Range places its
## 15+ targets within a comparable distance of each other in the
## gallery. `_check_impact_proximity()` treats ANY two impact-enabled
## entities within radius as touching, with no way to distinguish "a
## bullet hit me" from "another target happens to be nearby" -- widening
## the radius enough to reliably catch a fast-moving bullet anywhere on
## a large mesh necessarily ALSO reaches neighboring entities that
## should never trigger each other. Fixing this properly needs the
## bullet-vs-target check to stay narrow/precise while still covering
## the target's full mesh (e.g. centering on the mesh's own AABB instead
## of the origin, PLUS excluding same-class entities from triggering
## each other) -- a bigger change than a radius tweak, left for a
## dedicated follow-up rather than shipped half-verified. Back to the
## flat 28-unit radius for every impact zone, matching the original,
## proven-safe behavior.
## GB-8 continued (2026-08-07, Range): "it still doesn't hit far targets
## accuratley." A precisely-computed aim (bypassing real mouse control
## entirely) now lands the bullet's own true trajectory within a few
## units of a target far more often than not (10/11 across this
## session's own test runs) -- the underlying aim/travel math is sound.
## A real player's own mouse aim is never perfectly precise the way a
## synthetic test's is, though, and ANY small angular imprecision (mouse
## feel, sensitivity, a few pixels of hand tremor) translates into a
## MUCH bigger positional miss the farther the target is -- basic
## trigonometry, not a bug, but it means the flat 28-unit hit radius
## (originally sized for the unrelated "walked into it" mechanic, see
## this function's own earlier history) leaves very little real-world
## margin for error at range even once the aim math itself is correct.
## The two things that made a bigger radius unsafe before -- a brand
## new zone firing against whatever it started already overlapping (a
## projectile at its own shooter), and the XZ-only check letting a
## nearby-but-differently-positioned target claim a shot meant for
## someone else -- were both fixed (see this function's own pre-seed
## block below), so this got re-attempted scaling the radius to each
## entity's own mesh footprint instead of a flat 28 -- and then GB-8's
## own hitscan replacement (`_do_spark_hitscan()`) made the whole
## question moot, since Range's shots stopped using this mechanism at
## all. The widened radius, now with nothing left to serve, turned out
## to be actively harmful for this function's OTHER remaining use
## (targets popping up near each other) -- see this function's own
## current body for the final, reverted-back-to-flat-28 state.
func _ensure_impact_area(node: Node3D) -> void:
	if node.has_meta("wdl_impact_area"):
		return
	var area := Area3D.new()
	area.collision_layer = 0
	area.collision_mask = 1  # Player's CharacterBody3D default layer.
	area.monitoring = true
	var cs := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	# GB-8 continued (2026-08-07, Range): "without clicking all the
	# victims get 'hit' when they go up" -- reverted the mesh-based radius
	# widening (and, below, the height-aware 3D-distance switch) back to
	# the original flat 28-unit/XZ-only behavior. Both existed SOLELY to
	# help a physical bullet reliably reach a target despite this port's
	# own approximate collision -- moot now that GB-8's own hitscan
	# replacement (see `_do_spark_hitscan()`) resolves Range's shots via
	# a real raycast and never touches this mechanism at all. Left
	# active, both were actively harmful for their OTHER, still-real use
	# (Terrorist/Civilian's own impact zone checking nearby entities):
	# Range packs its targets only ~30 units apart, well inside the
	# widened ~80-unit radius, and a target's own `GoingUp`/`Dying`
	# pop-up animation is real, ongoing vertical movement -- exactly what
	# the height-aware check treats as "genuinely airborne, use full 3D
	# distance" for. As a target popped up, the 3D distance to its still-
	# resting neighbor grew past the (still nearby, pre-seeded) baseline
	# and then shrank back on the way down, reading as a fresh "just
	# walked in" approach each time -- so a target could fire its own
	# `TargetHit` purely from POPPING UP near another target, with no
	# shot ever fired. Back to the original, proven-safe flat-28/XZ-only
	# behavior, matching every other still-live use of this mechanism.
	var radius := 28.0
	shape.radius = radius
	cs.shape = shape
	area.add_child(cs)
	node.add_child(area)
	node.set_meta("wdl_impact_area", true)
	area.body_entered.connect(_on_impact_body_entered.bind(node))
	area.body_exited.connect(_on_impact_body_exited.bind(node))
	_impact_zones.append({"node": node, "radius": radius, "offset": Vector3.ZERO})
	# GB-8 continued (2026-08-07, Range): "none of my shots were
	# triggered even when they were accurate," every logged shot dying
	# within a near-constant, aim-independent distance of its target
	# (matching "distance from the FIXED shooter position," not an
	# actually-traveled bullet path). Root cause: Range's own `action
	# Spark` sets `my.enable_impact=on;` as its own very FIRST statement,
	# before it has moved at all -- and `CreateSpark()` spawns the bullet
	# AT `player.x` (the shooter's own position). The zone created here
	# is centered right on top of the shooter, so `_check_impact_proximity()`'s
	# very next tick found the shooter itself already inside the bullet's
	# own zone and fired `SparkHit` on it immediately, before its first
	# `wait(1)` (and therefore its first real movement) ever ran -- the
	# bullet never actually traveled anywhere. This is a generic gap, not
	# Spark-specific: `_impact_touching` debounces re-firing for an
	# entity that's STILL in range, but a brand new zone starts with an
	# EMPTY touching set, so anything already overlapping at the exact
	# moment `enable_impact` turns on reads as "just walked in" on the
	# very first check -- matching real physics semantics only for
	# entities that start apart and approach, never for one spawned
	# already touching another (a projectile at its own shooter, or any
	# entity created overlapping something else). Pre-seed `_impact_touching`
	# with whatever is ALREADY in range right now, silently -- so only a
	# genuinely NEW approach after this point can ever fire an event.
	var pre_touching := {}
	var entities: Node = _loader.get_node_or_null("Entities") if _loader != null else null
	if entities != null:
		for other in entities.get_children():
			if other == node or not (other is Node3D) or not is_instance_valid(other):
				continue
			if not _entity_alive(other):
				continue
			if (other as Node3D).get_meta("wdl_non_physical", false):
				continue
			var dx := node.global_position.x - (other as Node3D).global_position.x
			var dz := node.global_position.z - (other as Node3D).global_position.z
			if dx * dx + dz * dz <= radius * radius:
				pre_touching[other] = true
	_impact_touching[node] = pre_touching


## `body_entered` has no debounce of its own: a CharacterBody3D sliding
## along this Area3D's edge (common with collision push-back/momentum,
## and confirmed live via a real player's own console capture --
## 2026-08-01, Shiks) can genuinely fire body_entered/body_exited/
## body_entered again within a handful of frames for what's really one
## continuous approach. `_check_impact_proximity()`'s own NPC-mover twin
## already debounces this exact shape ("fire once on approach, not every
## frame spent overlapping") via `_impact_touching`; reusing the same
## dict here (keyed the same way, `node -> {other: true}`) gives the
## real player's own body_entered path the same guarantee, instead of
## re-firing a one-time story trigger (e.g. Shiks' `action Bumped` ->
## `Piposh.skill2 = 2;`, no idempotency guard of its own -- matching real
## WDL, which never needed one since a physical bump was never this
## trigger-happy) every time the player's collision capsule wobbles.
func _on_impact_body_entered(body: Node3D, node: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	if not _entity_alive(node):
		return
	var touching: Dictionary = _impact_touching.get(node, {})
	if touching.has(body):
		return
	touching[body] = true
	_impact_touching[node] = touching
	invoke_event(node, str(node.get_meta("wdl_event", "")))


func _on_impact_body_exited(body: Node3D, node: Node3D) -> void:
	var touching: Dictionary = _impact_touching.get(node, {})
	touching.erase(body)
	_impact_touching[node] = touching


## Per-frame distance check, the non-physics-body half of the impact
## mechanism -- see _ensure_impact_area()'s comment. `_impact_touching`
## debounces per (zone, other) pair so this fires once on approach, not
## every frame spent overlapping, matching body_entered's own semantics.
func _check_impact_proximity() -> void:
	if _impact_zones.is_empty() or _loader == null:
		return
	var entities: Node = _loader.get_node_or_null("Entities")
	if entities == null:
		return
	# `zone["node"]` must stay untyped until validity is confirmed --
	# straight to a `Node3D`-typed local throws "Trying to assign invalid
	# previously freed instance" the instant the entity's been remove()d
	# (a real WDL builtin, used corpus-wide for shooting-range targets
	# etc.), since Godot validates the object reference at the typed
	# assignment itself, before any code gets to check it. Reported live
	# (2026-08-01, Range): the level "stops"/errors right at start --
	# `[wdl-event]`-adjacent logging showed this exact error spamming
	# every single frame from the moment a target entity first got
	# removed. Same untyped-until-checked convention every other
	# entity-liveness check in this file already follows (see
	# _entity_alive()'s own `my` parameter) -- this one just didn't.
	# Stale zones are also dropped here instead of merely skipped, so a
	# level that removes many targets (a shooting range) doesn't keep
	# accumulating dead entries checked forever.
	var live_zones := []
	for zone in _impact_zones:
		var node = zone["node"]
		if not is_instance_valid(node) or not _entity_alive(node):
			_impact_touching.erase(node)
			continue
		live_zones.append(zone)
		var center: Vector3 = node.to_global(zone["offset"])
		var radius: float = zone["radius"]
		var touching: Dictionary = _impact_touching.get(node, {})
		var still_touching := {}
		for other in entities.get_children():
			if other == node or not (other is Node3D) or not is_instance_valid(other):
				continue
			if not _entity_alive(other):
				continue
			if (other as Node3D).get_meta("wdl_non_physical", false):
				continue
			# Horizontal-plane distance only (ignore Y). Movers in this port
			# are plain Node3D translated by _do_actor_move() with no floor
			# snapping (unlike the original engine's actor_move(), which
			# tracks floor height like real physics-based movement does) --
			# so a walker's Y stays pinned to its spawn height even while
			# crossing a room that sits on genuinely different ground.
			# Confirmed live (2026-08-01, Shiks): Piposh2 spawns at Y=8 and
			# walks a dead-flat line toward Bumpin at Y=-69/Z=23 -- StandHere
			# nearby is also Y=-73, confirming that room is really ~80 units
			# lower, not a data error. A full 3D sphere check can never
			# close that gap, so "walked into" NPC-vs-entity proximity uses
			# XZ distance only. The real player's Area3D/body_entered path
			# is untouched by this (CharacterBody3D floor-snaps for real).
			var other_pos: Vector3 = (other as Node3D).global_position
			# GB-8 continued (2026-08-07, Range): "without clicking all
			# the victims get 'hit' when they go up." A round-2 attempt
			# at this switched to real 3D distance whenever either side
			# of a pair had moved in height, specifically to help a
			# physical bullet in real flight reach a target regardless of
			# height -- moot now that GB-8's own hitscan replacement (see
			# `_do_spark_hitscan()`) resolves Range's shots with a real
			# raycast and never reaches this check at all. Left active,
			# it was actively harmful for the check's OTHER, still-real
			# use: Range packs its own targets only ~30 units apart, and
			# a target's own `GoingUp`/`Dying` pop-up animation is real,
			# ongoing vertical movement -- exactly what that switch
			# treated as "genuinely airborne, use full 3D distance." As a
			# target popped up, the 3D distance to its still-resting
			# neighbor grew past the (pre-seeded, already-touching)
			# baseline and then shrank back down on the way down, reading
			# as a fresh "just walked in" approach each time -- so a
			# target could fire its own `TargetHit` purely from popping
			# up near another target, no shot ever fired. Back to plain
			# XZ-only, matching every other still-live use of this
			# mechanism (see the "walked into" comment above).
			var dx := center.x - other_pos.x
			var dz := center.z - other_pos.z
			if dx * dx + dz * dz <= radius * radius:
				still_touching[other] = true
				if not touching.has(other):
					invoke_event(node, str(node.get_meta("wdl_event", "")))
		_impact_touching[node] = still_touching
	_impact_zones = live_zones


func _find_mesh_instance(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var found := _find_mesh_instance(c)
		if found:
			return found
	return null


func invoke_event(my, event_name: String) -> void:
	## Runs the action/function named by a previously-assigned `my.event`
	## as a fresh fire-and-forget coroutine on the clicked entity, the same
	## way begin_level() starts each entity's own initial action. Looked up
	## against both _actions and _functions since WDL's `.event` idiom
	## targets either (this game's own scripts only ever use actions, but
	## nothing in the format guarantees that).
	var who := str(my.name) if (my != null and is_instance_valid(my)) else "<null>"
	PiposhDebug.log_msg("wdl-event", "INVOKE my=%s event=%s" % [who, event_name])
	if event_name == "":
		return
	if not _entity_alive(my):
		return
	var resolved_action := _resolve_action(event_name)
	if resolved_action != "":
		PiposhDebug.log_msg("wdl-event", "  -> matched action%s, starting coroutine" % (
			"" if resolved_action == event_name else " (case-insensitive: %s)" % resolved_action
		))
		_run_coroutine(_actions[resolved_action].get("body", {}), my)
		return
	var resolved_fn := _resolve_function(event_name)
	if resolved_fn != "":
		PiposhDebug.log_msg("wdl-event", "  -> matched function%s, starting coroutine" % (
			"" if resolved_fn == event_name else " (case-insensitive: %s)" % resolved_fn
		))
		_run_coroutine(_functions[resolved_fn].get("body", {}), my)
		return
	PiposhDebug.log_msg("wdl-event", "  -> NOT FOUND in _actions or _functions")
	_warn_once("event target not found: " + event_name)


## 2026-07-30: in real Acknex there is only one camera object, so a script
## that writes camera.x/y/z (e.g. a Cam-entity-driven shot during a click
## interaction, WDL/Afgan.wdl-style) always affects what the player sees,
## first-person or not -- "last write this tick wins" is the whole
## mechanism, no separate ownership concept exists. This port instead has
## two distinct Camera3D nodes (the FP player's own camera vs this
## interpreter's `_camera`), and nothing reconnected them: confirmed via
## tools/smoke_plane2_playtest.gd and a real playtest report (user, this
## date) that clicking Plane2's Passenger correctly ran Cam3's
## camera.x/y/z writes every tick (364 in one run) while the *rendered*
## camera -- the player's own -- never moved at all, because FP mode
## simply turns `_camera` off (`_script_cam.current = false`) and nothing
## turns it back on for a scripted moment like this.
## LevelRunner._process() polls this each frame and, when true, switches
## visible-camera ownership to the script camera for that frame -- the
## same "whoever wrote it most recently wins" model the original engine
## uses, implemented generically (any level, any Cam-driven interaction),
## not special-cased to Plane2.
func is_driving_camera_this_frame() -> bool:
	return _camera_control_frame == Engine.get_process_frames()


func _set_camera_field(low: String, value: Variant, my) -> void:
	if _camera == null:
		return
	# 2026-07-30: logs every WDL-driven camera.* write, tagged with the
	# entity/action whose coroutine made it (PiposhDebug.ENABLED to
	# disable) -- built to actually answer "which script statement moved
	# the camera and when" against a real playtest console capture,
	# instead of guessing from source reading. Compare these timestamps'
	# ordering/frequency against the *actual* rendered camera's position
	# (log_msg("cam-actual", ...) in wdl_director.gd's _process(), same
	# tag family) to tell a real per-tick script-driven update apart from
	# a stutter/framerate artifact that only looks like "shots changing".
	var who := str(my.name) if (my != null and is_instance_valid(my)) else "<no entity>"
	PiposhDebug.log_msg("cam-write", "field=%s value=%s by=%s" % [low, value, who])
	match low:
		"x", "y", "z":
			_camera_control_frame = Engine.get_process_frames()
			var gs := _godot_to_gs(_camera.global_position)
			if low == "x":
				gs.x = _to_num(value)
			elif low == "y":
				gs.y = _to_num(value)
			else:
				gs.z = _to_num(value)
			_camera.global_position = _gs_to_godot(gs)
		"pan", "tilt", "roll":
			_camera_control_frame = Engine.get_process_frames()
			_camera.set_meta(low, _to_num(value))
			var pan := float(_camera.get_meta("pan", 0.0))
			var tilt := float(_camera.get_meta("tilt", 0.0))
			# Cameras use vec_for_angle/ang_to_vec + look_at, never the
			# entity basis (docs/CONTRACT.md #1) -- roll isn't representable
			# via look_at and is intentionally not applied here.
			var fwd := _gs_view_forward(pan, tilt)
			if fwd.length() > 0.001:
				_camera.look_at(_camera.global_position + fwd, Vector3.UP)
		"fog":
			# Reported live (2026-08-10): "when Piposh falls there's fog...
			# that don't exist in the current graphics." `camera.fog = N;`
			# (11 corpus levels, e.g. Plane2/Plane3/Smash's own main(), and
			# Plane2's own `camera.fog=0;` mid-level to disable it again)
			# was entirely unbridged -- `_set_camera_field()`'s own match
			# had no "fog" case at all, a silent no-op via GDScript's own
			# "unmatched value, do nothing" behavior. Stored as camera meta
			# here (same pattern as pan/tilt/roll) since this interpreter
			# has no direct Environment reference of its own to apply it
			# to -- `level_runner.gd`'s own live-poll loop (see its
			# `_apply_wdl_fog()`) reads this meta and drives the real
			# WorldEnvironment fog settings, the same "poll a value this
			# layer can't reach the renderer with directly" shape already
			# used for scene_map/sky_map/cloud_map.
			_camera.set_meta("fog", _to_num(value))


# ---------------------------------------------------------------------------
# GS <-> Godot conversions (mirrors tools/gs_math.py)
# ---------------------------------------------------------------------------
func _gs_to_godot(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, -v.y)


func _godot_to_gs(v: Vector3) -> Vector3:
	return Vector3(v.x, -v.z, v.y)


func _gs_view_forward(pan_deg: float, tilt_deg: float) -> Vector3:
	var p := deg_to_rad(pan_deg)
	var t := deg_to_rad(tilt_deg)
	var x := cos(p) * cos(t)
	var y := sin(p) * cos(t)
	var z := sin(t)
	return _gs_to_godot(Vector3(x, y, z))


func _acknex_entity_basis(pan_deg: float, tilt_deg: float, roll_deg: float) -> Basis:
	## Conitec ang_to_matrix (DirectX) conjugated by S=diag(1,1,-1) -> Godot
	## RH. Duplicated from WmbLevelLoader/WdlDirector (same existing
	## precedent as _acknex_entity_basis_local there) rather than coupling
	## the interpreter to either class's private helpers.
	var tilt := tilt_deg
	if tilt > 180.0:
		tilt -= 360.0
	elif tilt < -180.0:
		tilt += 360.0
	var p := deg_to_rad(pan_deg)
	var t := deg_to_rad(tilt)
	var r := deg_to_rad(roll_deg)
	var cp := cos(p)
	var sp := sin(p)
	var ct := cos(t)
	var st := sin(t)
	var cr := cos(r)
	var sr := sin(r)
	var x_dx := Vector3(ct * cp, st, ct * sp)
	var y_dx := Vector3(-cr * st * cp + sr * sp, cr * ct, -cr * st * sp - sr * cp)
	var z_dx := Vector3(-sr * st * cp - cr * sp, sr * ct, cr * cp - sr * st * sp)
	var x_g := Vector3(x_dx.x, x_dx.y, -x_dx.z)
	var y_g := Vector3(y_dx.x, y_dx.y, -y_dx.z)
	var z_g := Vector3(-z_dx.x, -z_dx.y, z_dx.z)
	return Basis(x_g, y_g, z_g)


## How far in front of the camera a `near`-flagged weapon's own farthest
## mesh extent should end up once pulled close -- see the "near" case in
## _set_field() for the full story. Comfortably past the main camera's
## own near-clip (1.0, see player_controller.gd) even with the roll/pan
## wobble these entities apply every tick, and small enough to read as a
## genuine close-up rather than the original mid-distance framing.
const NEAR_WEAPON_TARGET_DISTANCE := 40.0

## User request (2026-08-07, Range), after confirming the close-up pull
## itself worked: "make the gun a bit lower on the screen." The pull
## above only fixes depth (how close/dominant the model is); this drops
## it toward the bottom of frame too, matching a typical FPS view-model
## instead of sitting at eye-level/screen-center. Applied along the
## camera's OWN up vector at the moment of the (one-time, see this
## function's own comment) pull, not a world-space -Y offset -- so it
## reads as "lower on screen" regardless of which way the camera happens
## to be facing when this fires.
const NEAR_WEAPON_VERTICAL_DROP := 20.0


## Applies its own position pull EXACTLY ONCE per entity (guarded by
## `wdl_near_applied`), not every tick -- two earlier versions both got
## this wrong. A first attempt computed the shift once, synchronously,
## the instant `near` turned on; a second recomputed it fresh every tick
## from the entity's own LIVE (already-adjusted) position -- since that
## output becomes next tick's input, feeding the result back into its
## own `direction` calculation let the entity drift near/past the
## camera, flip `direction`'s sign, and diverge outward instead of
## converging. Fixed both of those (direction now comes from the fixed
## `wdl_spawn_position`, never mutated; the shift applies once and then
## leaves `pos` alone) -- but even then the ONE application could still
## land wrong, and did (confirmed live, `smoke_range_hitscan_check`-style
## direct dump): entity coroutines all start in the SAME synchronous
## burst during `begin_level()`, each running up to its own first real
## `wait()`. Range's own `action Handgun` sets `near = on` (triggering
## this) BEFORE its first `wait(1)`, and if that happens to run before
## `action CamTarget`'s own first `camera.x = my.x;` write (entity
## iteration order, not guaranteed), `_camera.global_position` here is
## still whatever stale/default pose the Camera3D node had, not
## CamTarget's real spawn point -- computing "direction" from that reads
## as a wildly different offset (confirmed: camera.y off by ~90 units
## from its real spawn), throwing the whole pull hundreds of units in
## the wrong place. Deferred past the synchronous startup burst entirely
## by comparing frame numbers: skip (without marking applied) until
## `Engine.get_process_frames()` has advanced past the frame `near` was
## set on, guaranteeing every OTHER entity's coroutine -- including
## CamTarget's -- has resumed via a real `wait()` at least once and
## written its own real spawn position by the time this actually fires.
func _near_weapon_adjusted_position(node: Node3D, pos: Vector3) -> Vector3:
	if node.get_meta("wdl_near_applied", false):
		return pos
	var activated_frame := int(node.get_meta("wdl_near_activated_frame", -1))
	if Engine.get_process_frames() <= activated_frame:
		return pos
	node.set_meta("wdl_near_applied", true)
	if _camera == null:
		return pos
	var result := pos
	var spawn_pos: Vector3 = node.get_meta("wdl_spawn_position", pos)
	var raw_offset := spawn_pos - _camera.global_position
	if raw_offset.length() >= 0.01:
		var direction := raw_offset.normalized()
		var acc := AABB()
		var has := false
		var stack: Array[Node] = [node]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			if n is MeshInstance3D and (n as MeshInstance3D).mesh:
				var mi := n as MeshInstance3D
				var world_aabb: AABB = mi.global_transform * mi.mesh.get_aabb()
				acc = world_aabb if not has else acc.merge(world_aabb)
				has = true
			for c in n.get_children():
				stack.append(c)
		if has:
			var max_depth := -INF
			for dx in [0.0, acc.size.x]:
				for dy in [0.0, acc.size.y]:
					for dz in [0.0, acc.size.z]:
						var corner: Vector3 = acc.position + Vector3(dx, dy, dz)
						max_depth = maxf(max_depth, (corner - _camera.global_position).dot(direction))
			var shift_amount := max_depth - NEAR_WEAPON_TARGET_DISTANCE
			if shift_amount > 0.0:
				result -= direction * shift_amount
	result -= _camera.global_transform.basis.y * NEAR_WEAPON_VERTICAL_DROP
	return result


func _set_entity_pan(node: Node3D, pan_deg: float) -> void:
	# GB-7 continued (2026-08-04, Range): "the game still seems to aim
	# higher than the actual place the gun points to." This used to
	# unconditionally zero tilt/roll on every pan write, on whatever
	# assumption held for entities that only ever set pan alone. Range's
	# own `action CamTarget` sets BOTH every tick, pan first (`my.pan =
	# my.pan - mickey.x/SEN;`) then tilt (`my.tilt = my.tilt - mickey.y/
	# SEN;`) -- the pan write was wiping tilt back to 0 immediately
	# before the tilt line even ran, every single tick, so the tilt
	# assignment always read its own just-zeroed value back and computed
	# ~0 again. Vertical aim was completely inert the whole time; the
	# camera (and therefore every shot, see CreateSpark()'s own
	# vec_rotate(shot_speed, my_angle) using player.tilt) could only ever
	# point horizontally, regardless of how far the player moved the
	# mouse vertically -- confirmed live via tools/smoke_range_aim_check.gd
	# tracing every read/write of "tilt" on the CamTarget entity across a
	# real tick. Preserve the current tilt/roll instead, the same way
	# _set_entity_tilt_roll() already preserves pan.
	var scl := node.transform.basis.get_scale()
	if scl.x <= 0.001 or scl.y <= 0.001 or scl.z <= 0.001:
		scl = Vector3.ONE
	var tilt := float(node.get_meta("tilt", 0.0))
	var roll := float(node.get_meta("roll", 0.0))
	var pos := node.global_position
	if node.get_meta("wdl_near", false):
		pos = _near_weapon_adjusted_position(node, pos)
	node.global_transform = Transform3D(_acknex_entity_basis(pan_deg, tilt, roll) * Basis.from_scale(scl.abs()), pos)
	node.set_meta("pan", pan_deg)


func _set_entity_tilt_roll(node: Node3D, tilt_deg: float, roll_deg: float) -> void:
	var scl := node.transform.basis.get_scale()
	if scl.x <= 0.001 or scl.y <= 0.001 or scl.z <= 0.001:
		scl = Vector3.ONE
	var pan := float(node.get_meta("pan", 0.0))
	var pos := node.global_position
	if node.get_meta("wdl_near", false):
		pos = _near_weapon_adjusted_position(node, pos)
	node.global_transform = Transform3D(_acknex_entity_basis(pan, tilt_deg, roll_deg) * Basis.from_scale(scl.abs()), pos)
	node.set_meta("tilt", tilt_deg)
	node.set_meta("roll", roll_deg)


# ---------------------------------------------------------------------------
# Assignment
# ---------------------------------------------------------------------------
func _assign(op: String, target: Dictionary, value_expr: Variant, my) -> Variant:
	var new_val
	if (
		op == "="
		and str(target.get("t", "")) == "field"
		and str(target.get("name", "")).to_lower() == "event"
		and typeof(value_expr) == TYPE_DICTIONARY
		and value_expr.get("t") == "id"
	):
		# `my.event = HP;` assigns the ACTION/FUNCTION *name* HP as a
		# click-trigger target -- a compile-time symbol, exactly like
		# create()'s 3rd arg in _call() below -- not a runtime read of an
		# undeclared variable HP (which would silently evaluate to 0.0 and
		# make every click-driven entity in the game permanently inert).
		new_val = str(value_expr.get("name", ""))
	elif (
		op == "="
		and str(target.get("t", "")) == "id"
		and str(target.get("name", "")).to_lower().begins_with("on_")
		and typeof(value_expr) == TYPE_DICTIONARY
		and str(value_expr.get("t", "")) in ["id", "call"]
		and (
			_resolve_action(str(value_expr.get("name", ""))) != ""
			or _resolve_function(str(value_expr.get("name", ""))) != ""
		)
	):
		# `on_mouse_left = Fire;` / `on_space = X;` -- Acknex's global input-
		# event bindings, same shape as `my.event = HP;` one level up (a
		# GLOBAL, not a field): the value is a compile-time action/function
		# symbol, not a variable read. Only captured as a symbol when it
		# actually resolves to a known action/function -- e.g. Shiks'
		# `on_space = null;` (disabling a binding) must still evaluate `null`
		# normally, not stringify it. See _check_mouse_click()'s use of
		# `on_mouse_left`, the only one of these actually wired to a real
		# input event so far (see docs/CONTRACT.md for the rest as a known
		# gap: on_space/on_enter/etc. are captured correctly but nothing
		# polls the space/enter key itself yet).
		#
		# Also accepts a "call" shape (`on_F1 = SwitchWeapon();`,
		# AsyAct3.wdl -- an equally common Acknex idiom, parens included,
		# still meaning "bind this handler" not "invoke it now"), NOT just
		# bare "id" (`on_mouse_left = Fire;`). Confirmed as a real, severe
		# bug (2026-08-01): with only "id" handled, this branch's own
		# `else: new_val = _eval(value_expr, my)` fallback ACTUALLY CALLED
		# SwitchWeapon() -- a real function, synchronously, at level
		# start, one of the new top_level_stmts this same session added
		# execution for. If a "handler" function like this contains its
		# own `while(1){...wait(1);}` (written to run forever as its OWN
		# coroutine once actually triggered by the key press), running it
		# synchronously via _exec_stmt_sync() hangs the whole level load
		# forever -- confirmed live via smoke_dispatch.gd timing out on
		# AsyAct3 specifically, the first level in the corpus using this
		# call-shaped on_ idiom.
		new_val = str(value_expr.get("name", ""))
	else:
		new_val = _eval(value_expr, my)
	if op != "=":
		var cur = _eval(target, my)
		var curf := _to_num(cur) if typeof(cur) != TYPE_STRING else 0.0
		var newf := _to_num(new_val) if typeof(new_val) != TYPE_STRING else 0.0
		match op:
			"+=":
				new_val = (str(cur) + str(new_val)) if typeof(cur) == TYPE_STRING else curf + newf
			"-=":
				new_val = curf - newf
			"*=":
				new_val = curf * newf
			"/=":
				new_val = curf / newf if newf != 0.0 else 0.0
	match str(target.get("t", "")):
		"id":
			_set_var(str(target.get("name", "")), new_val, my)
		"field":
			_set_field(target.get("obj"), str(target.get("name", "")), new_val, my)
		"index":
			var obj = _eval(target.get("obj"), my)
			var idx := int(_eval(target.get("idx"), my))
			if obj is Array:
				while obj.size() <= idx:
					obj.append(0.0)
				if idx >= 0:
					obj[idx] = new_val
	return new_val


# ---------------------------------------------------------------------------
# Builtins
# ---------------------------------------------------------------------------
## Voice.wdl (included by nearly every level via IO.wdl) declares its OWN
## `function sPlay/vPlay(...)` that drives Acknex's real MP3 DLL layer
## (dll_open/InitMp3Adv/LoadSongSlot/PlaySong/...) -- infrastructure this
## port can never bridge. User-defined functions normally take priority over
## builtins (see _call() below), which is correct for a level's own helper
## functions, but here it means Voice.wdl's real (unbridgeable, all-no-op)
## sPlay/vPlay SHADOWS this interpreter's own working AudioChannels-backed
## bridge of the exact same name -- so a dialogue line's audio never
## actually starts, `GetPosition(Voice)` reports "already finished" from the
## first tick, and the entire multi-line action races to completion in a
## single synchronous frame instead of playing out.
##
## Found 2026-07-30 chasing a real regression report ("audio from talks is
## not being played") that reappeared once the Voice/SFX channel split (see
## autoload/audio_channels.gd) removed the *accidental* masking this used to
## get from the old single-channel AudioBus: an unrelated ambiance sound
## (play_entsound) shared the same busy-flag as Voice, so it happened to
## keep GetPosition(Voice) reporting "still playing" even though sPlay
## itself was silently doing nothing. Splitting the channels correctly
## removed that cross-contamination, which is what surfaced this. Fix: these
## specific audio-primitive names always resolve to this interpreter's own
## bridge, never to a same-named WDL-source function.
##
## Also includes `actor_move` for the identical reason, one level up the
## include chain: `WDL/actors.wdl`'s real `function actor_move() { force.Y=0;
## force.Z=0; scan_floor(); move_gravity(); actor_anim(); }` depends on
## `scan_floor`/`move_gravity`/`actor_anim` -- real per-tick ground-scan/
## gravity/animation-driven-root-motion physics (`WDL/move.wdl`,
## `WDL/animate.wdl`), the same movement.wdl-family builtins the native
## Godot `CharacterBody3D` controller deliberately replaces for the player
## (user decision, see docs/CONTRACT.md) but that NPCs also route through
## for their own walking. Shadowed exactly like sPlay/vPlay: found via
## Shiks' Piposh2 (`if (Scene==1) { ...; actor_move(); if (my.x >
## StandHerePoint) { Scene=2; ...} }`) never actually moving, so `Scene`
## never left 1 -- reported live as "one correct vocal, then stuck in a
## loop." `actor_turnto` is NOT force-bridged: its real `actors.wdl`
## implementation (`angle=ang(angle-MY.PAN); ...; MY.PAN += temp*min(1,
## time);`) is fully portable once `ang()` exists as a builtin (added
## below) -- no unbridgeable dependency, so the real, more faithful
## implementation is allowed to run instead of this interpreter's cruder
## approximation.
##
## MUST NOT include `SetVoice`/`VoiceInit` — confirmed via corpus grep
## (`^function SetVoice`) that 22 different level scripts (Start, Studio,
## Plane, Intro2/3/5/6/7/8/10/11/12/14/16, Inn, Mansion, Outro, Plane3,
## Smash, Temple, VilEnd, VilInt, Ziggy) each define their OWN `function
## SetVoice { ... }` as their real per-level dialogue/scene-boot sequencer
## (sets Scene, calls the real sPlay with the right WAV, advances Talking) —
## it is NOT a shared Voice.wdl audio primitive like sPlay/vPlay, it just
## happens to share a name with the interpreter's harmless `"setvoice": ...
## -> 0.0` DLL-stub builtin. An earlier version of this list included it by
## mistake (reasoning by name-similarity to sPlay/vPlay instead of checking
## the corpus), which force-routed every level's real `SetVoice()` call to
## that no-op stub instead of letting it resolve as a user function -- so
## the whole level's scene/dialogue progression silently never advanced
## past the very first line: reported live as "vocals not played," "camera
## stuck," and "scene stuck on the first frame," for exactly Start/Studio/
## Plane, the three levels the user actually tried. `VoiceInit` removed too
## for the same reason (real function in Voice.wdl, not a name any level
## overrides, but still not this interpreter's bridge to own).
## `ShowDialog` (no args) is force-bridged too, same shape again:
## `WDL/DIalog.wdl`'s real `function ShowDialog { DialogChoice=0;
## SetDialogOptions(); ShowText(); Dialog.visible=on; }` depends on
## `SetDialogOptions`/`ShowText` (real PANEL text rendering, unbridgeable --
## no PANEL system exists here) and writing `Dialog.visible` (a PANEL
## entity reference, always unresolved -> safe no-op). Confirmed via corpus
## grep (`^function ShowDialog`) there is exactly one shared declaration,
## never overridden per-level, so forcing it is safe by the same rule as
## sPlay/vPlay/actor_move. Found via a direct report ("after talking ends
## the game doesn't move on," "no text-choosing on screen") -- every
## dialogue-choice scene in the game calls this via `DoDialog()`, and the
## real function never showed anything or reset `DialogChoice`, so every
## `while (DialogIndex==X) { if (DialogChoice==1) {...} }` polling loop
## spun forever waiting for a click that could never register.
##
## `run` (2026-07-30) is the SAME shape one more time, and it's the one
## that actually mattered most: `WDL/IO.wdl` (included by nearly every
## level) declares its own `function Run(filename) { ...file_open_write
## ("Run.txt")...; exit; }` -- the ORIGINAL game's real level-transition
## mechanism, where each "level" was a SEPARATE .exe and a wrapper launcher
## process watched `Run.txt` to know what to start next, then the current
## .exe's own `exit;` statement terminated it. Neither half makes sense in
## this single-process Godot port (no separate launcher, no real process to
## exit), and `exit;` isn't even a real statement this interpreter
## recognizes, so it silently no-ops -- meaning the shadowed real `Run()`
## did nothing at all: never called `LevelRouter`, never stopped the
## current level's script. Found via the SAME "scene doesn't move to the
## next one, loops forever" Start report: `if (Scene==6) { Run("Menu.exe");
## }` (Start.wdl's own terminal check) really was reached and really did
## call `Run(...)` -- just the real, shadowed one, which had no observable
## effect, so nothing ever stopped `LookAtMe`'s own progression loop from
## keeps advancing `Scene` on every subsequent real frame (once past the
## last value `SetVoice()` explicitly handles) forever, racing arbitrarily
## far past 6 with no terminal check ever getting another chance to catch
## it. This one demonstrates why `BRIDGE_OVER_SHARED_FUNCTIONS` entries
## need real bridges, not just no-ops: `_do_run()` actually calls
## `LevelRouter.goto_level()` *and* sets `_running = false` immediately
## (matching real Acknex's Run() halting the current level right away,
## not some frames later once the actual scene swap lands).
## `perform_handle` (2026-08-01) is the SAME shape one more time, found
## once bare-call statements to user functions could genuinely run
## forever (see exec_stmt()'s "expr_stmt" case / _call_user_function_
## async()'s docstring, added the same day): `WDL/input.wdl`'s real
## `function perform_handle() { while(1) { if(MY._SIGNAL==_HANDLE)
## {...}; wait(1); } }` is a real per-tick "is the interact key held"
## poll -- meaningless in this port, where the native player controller
## handles all real input directly and nothing ever sets `_SIGNAL`, but
## with nowhere that ever breaks its `while(1)`, it runs FOREVER once
## given a genuine coroutine. `player_move2()` (Plane2, WDL/movement.wdl)
## calls it as a plain bare statement partway through its own body, so a
## forever-running `perform_handle()` permanently blocks everything
## after it in the SAME caller -- including `player_move2()`'s own main
## loop, the only place Plane2's real "all 4 side-quest goals done ->
## Run(Range.exe)" check lives. Confirmed via corpus grep
## (`^function perform_handle`) there is exactly one shared declaration,
## same rule as every other entry here.
##
## `StartSaveLoad` (2026-08-01, "the last commit made all levels stuck
## now"): the SAME shape, but at global scale instead of one level.
## `WDL/IO.wdl`'s `function Initialize() { ...; StartSaveLoad(); }` is
## called by virtually every level's `main()` (every level includes
## IO.wdl and calls `VoiceInit(); Initialize();` near the top), and
## `StartSaveLoad`'s own body (`function StartSaveLoad { while(1) {
## if (entSaveLoadMenu.visible==on) {...}; wait(1); } }`) is a real
## per-tick save/load-menu vase-animation poll -- for a save/load menu
## this port doesn't implement (`entSaveLoadMenu` is a documented,
## pre-existing gap, see _resolve_entity()'s own comment). Before bare
## top-level calls could really suspend, this was silently inert, same
## as every other never-actually-run shared coroutine this session found
## (perform_handle, player_move2). Now that it's a genuine `while(1)`,
## calling it unconditionally from `Initialize()`'s tail statement
## permanently absorbs `Initialize()` -- and everything after
## `Initialize();` in `main()` (hiding the splash screen, playing the
## intro movies, `Start = 1;`, unblocking the real dialogue loop gated on
## `Start`) -- into a loop that never returns, for every level that calls
## `Initialize()`. Confirmed via a live trace (tools/smoke_start_stuck.gd)
## showing Start.wdl's main() stuck re-executing StartSaveLoad's own
## `if (entSaveLoadMenu.visible==on) {...} wait(1);` body forever, having
## never reached `Start = 1;`. Confirmed via corpus grep
## (`^function StartSaveLoad`) there is exactly one shared declaration.
## `move_view_1st`/`move_view_3rd`/`move_view_3rd_2` (2026-08-01, Plane2):
## `WDL/camera.wdl`'s real, faithfully-ported first/third-person camera
## functions (`function move_view_1st() { ...; CAMERA.X=player.X; ...
## CAMERA.PAN=player.PAN; ... }`) -- called every tick from
## `player_move2()`'s own main loop (`if(VView==1){Move_view_1st();}
## ...wait(1);`), exactly matching real Acknex's own per-frame camera-
## attach idiom. In real Acknex there's only one camera, so this is
## simply "the" camera update. In this port, the *native* CharacterBody3D
## controller (scripts/game/player_controller.gd) already owns real FP
## movement and its own Camera3D -- and `player` here resolves to the
## WDL-side FP proxy entity (never moved by this port; `_player_force`/
## `scan_floor`/`move_gravity`, the real movement builtins the rest of
## `player_move2()` calls, are unbridged no-ops here on purpose, see the
## project's own "keep the native controller, don't reimplement Acknex's
## movement builtins" decision). So every tick, this wrote the WDL
## script's *own* camera.* fields from a stationary entity -- and
## CameraAuthority (scripts/engine/camera_authority.gd) treats ANY
## camera.* write as "script wants control this frame", so a write EVERY
## tick permanently locked camera ownership to the (stale, never-moving)
## script camera and never handed it to the player's own Camera3D.
## Since `_physics_process()`'s movement gate requires
## `camera.current == true`, this silently zeroed the native controller's
## velocity every physics tick too -- reported live (2026-08-01): "the
## character is lower than the plane so we can't move" (the height half
## of that report was a separate, already-fixed snap_to_floor() issue;
## this is the "can't move" half). Bridged to no-ops, same precedent as
## `perform_handle`/`actor_move`: the native controller's own Camera3D is
## the sole source of truth for the FP camera in this port, so the WDL
## script's own camera-attach logic has nothing useful left to do.
const BRIDGE_OVER_SHARED_FUNCTIONS: Array[String] = [
	"splay", "vplay", "play_sound", "play_entsound", "stop_sound",
	"snd_playing", "getposition", "actor_move", "showdialog", "run",
	"perform_handle", "startsaveload",
	"move_view_1st", "move_view_3rd", "move_view_3rd_2",
]


func _call(name: String, arg_exprs: Array, my) -> Variant:
	var low := name.to_lower()
	if low == "vec_set" or low == "vec_sub" or low == "vec_to_angle":
		_last_result = _do_vector_call(low, arg_exprs, my)
		return _last_result
	if low == "move":
		_last_result = _do_move_call(arg_exprs, my)
		return _last_result
	if low == "vec_rotate":
		_do_vec_rotate(arg_exprs, my)
		return 0.0
	if low == "emit" and arg_exprs.size() >= 2:
		var particle_action := ""
		if arg_exprs.size() > 2 and typeof(arg_exprs[2]) == TYPE_DICTIONARY and arg_exprs[2].get("t") == "id":
			particle_action = str(arg_exprs[2].get("name", ""))
		_do_emit(_to_num(_eval(arg_exprs[0], my)), _vec_get(arg_exprs[1], my), particle_action)
		return 0.0
	if not (low in BRIDGE_OVER_SHARED_FUNCTIONS):
		# User-defined function call (not a builtin) -- run synchronously to
		# completion this frame (no `wait()` support inside nested function
		# calls yet; real usage here is almost entirely simple helpers).
		var resolved_fn := _resolve_function(name)
		if resolved_fn != "":
			_last_result = _call_user_function(resolved_fn, arg_exprs, my)
			return _last_result
		# Acknex allows `action NAME {...}` to be invoked like a plain
		# function too -- see exec_stmt()'s "expr_stmt" case (the async,
		# top-level-statement counterpart of this same fallback) for the
		# full story. Nested/mid-expression action-as-function calls are
		# rare but not nonexistent in the corpus; handled here the same
		# (synchronous) way _call_user_function() already runs nested
		# function calls, for consistency.
		var resolved_act := _resolve_action(name)
		if resolved_act != "":
			var sig = _exec_block_sync(_actions[resolved_act].get("body", {}), my)
			_last_result = sig.value if sig is ReturnSignal else null
			return _last_result
	if _builtins.has(low):
		var args: Array = []
		for a in arg_exprs:
			args.append(_eval(a, my))
		if low == "create" and arg_exprs.size() > 2:
			# 3rd arg is a bare ACTION name (compile-time symbol, e.g.
			# `create(<Photos.mdl>, my.x, Photos)`) -- not a runtime
			# variable read, unlike every other bare-identifier argument.
			var action_expr: Dictionary = arg_exprs[2]
			if action_expr.get("t") == "id":
				args[2] = str(action_expr.get("name", ""))
		if low == "create" and arg_exprs.size() > 1:
			# 2nd arg is conventionally written `entity.x` (Shiks:
			# `create(<Photos.mdl>, my.x, Photos)`; Range:
			# `create(<UziBul.mdl>, player.x, Spark)`) -- an Acknex idiom
			# for "spawn at THIS entity", not a real read of its numeric
			# X coordinate. The evaluated value (a bare float) throws away
			# *which* entity it came from, so _do_create() used to fall
			# back to spawning at `my`'s own position regardless -- wrong
			# whenever the position entity isn't the caller, confirmed
			# live (2026-08-01, Range): `CreateSpark()` runs via the
			# `on_mouse_left` global binding (`my == null`), so every
			# fired bullet spawned at Transform3D.IDENTITY's origin
			# instead of the player. Passed through as the RESOLVED
			# ENTITY (or null) in args[1]; _do_create() uses it directly
			# when present, `my` only as the pre-existing fallback.
			var pos_expr: Dictionary = arg_exprs[1]
			if pos_expr.get("t") == "field":
				args[1] = _resolve_entity(pos_expr.get("obj"), my)
			else:
				args[1] = null
		_last_result = _builtins[low].call(args, my)
		return _last_result
	_warn_once("builtin: " + name)
	return 0.0


func _call_user_function(fname: String, arg_exprs: Array, my) -> Variant:
	var fn: Dictionary = _functions[fname]
	var params: Array = fn.get("params", [])
	var saved: Dictionary = {}
	for i in params.size():
		var pname: String = params[i]
		saved[pname] = _globals.get(pname)
		var v = _eval(arg_exprs[i], my) if i < arg_exprs.size() else 0.0
		var had_key := _globals.has(pname)
		_globals[pname] = {"kind": "var", "init": null, "value": v}
		if not had_key:
			_index_global(pname)
	var sig = _exec_block_sync(fn.get("body", {}), my)
	for pname in saved:
		if saved[pname] == null:
			_globals.erase(pname)
			_deindex_global(pname)
		else:
			_globals[pname] = saved[pname]
	return sig.value if sig is ReturnSignal else null


## Real, awaitable counterpart to _call_user_function() -- used only for a
## bare top-level call statement (see exec_stmt()'s "expr_stmt" case),
## never for a call nested inside a larger expression (which still can't
## suspend mid-expression, matching real WDL: `wait()` only ever appears
## as its own statement).
##
## Some shared library functions (WDL/input.wdl's `perform_handle()`,
## WDL/movement.wdl's real `player_move()`/`player_move2()`) are written
## as `while(1){...wait(1);...}` loops meant to run for the rest of the
## level's lifetime, one iteration per real frame -- not "call, run to
## completion, return" helpers. `_call_user_function()`'s synchronous
## executor has no real per-frame yield (its own `wait()` handling is a
## one-time no-op warning, and its "while" loop's only safety valve is a
## flat 100000-iteration counter), so calling one of these synchronously
## burns through that entire budget in a single frame and returns having
## accomplished nothing -- any check inside that loop (a condition meant
## to be polled over real time) only ever got evaluated against
## whatever state existed in that first instant, never again.
##
## Confirmed live (2026-08-01, Plane2): `action player_walk2`'s tail
## statement is `player_move2();` -- and `player_move2()`'s own main loop
## is the ONLY place the real "all 4 side-quest goals done ->
## Run(Range.exe)" check lives (guarded by `_MOVEMODE`, itself only
## reachable at all after the 2026-08-01 DEFINE-constants fix). Even with
## that fix, the check never fired: player_move2() had already exhausted
## its 100000-iteration sync budget and returned within the first frame
## of the level loading, long before a real player could ever finish the
## side quests. This function gives it a genuine per-frame coroutine
## instead, so the check keeps being evaluated for as long as the level
## runs -- matching real WDL semantics for exactly this "long-running
## shared function called as an action's tail statement" shape, while
## every other function call in the corpus (the overwhelming majority --
## short helpers, called mid-expression, or never containing a real
## per-frame loop) is completely unaffected.
## 2026-08-09 continued (Desert): "some of the world backgrounds are not
## correct still" traced past both the earlier fixes (see docs/
## SESSION_LOG.md) to a real, deeper bug here. `Desert.wdl`'s own
## `main()` calls a weather helper (`let_it_rain()`, `WDL/Weather.wdl`)
## as a bare, NON-tail statement -- more statements (including the
## level's own `scene_map=...` lines) follow it in `main()`'s own body.
## `let_it_rain()` itself calls `rain_akt()`, a genuine `while(weather==
## weather_rain){...;WAITT(3);}` forever-loop explicitly meant to run as
## an independent background task driving the rain effect for the rest
## of the level. This function's own `await exec_block(...)` used to
## block THIS SAME CALLER (`main()`) at that exact statement forever,
## since `rain_akt()`'s loop never naturally returns -- so `scene_map`
## (and everything else later in `main()`) never got set at all,
## confirmed live via a temporary trace showing `WeatherSet` (set
## unconditionally right after the weather calls) also never left its
## own declared default.
##
## Real Acknex's own `wait()` yields to the engine's own cooperative
## scheduler, which resumes the ORIGINAL CALLER too, not just the
## callee that suspended -- the callee's own remaining body becomes an
## independent background task from that point on. This function now
## matches that: for a ZERO-PARAMETER callee, it calls `exec_block()`
## WITHOUT `await` (the same `_run_coroutine()`-style fire-and-forget
## already used to start every entity's own initial action) -- GDScript
## still runs it synchronously up to its own first real suspension, but
## does NOT block this caller past that point; whatever's left of the
## callee's own body keeps running independently once Godot resumes it.
##
## Scoped to zero-parameter callees specifically, not applied
## unconditionally: the param save/restore loop below assumes it's safe
## to restore the instant the call "returns" -- true when there's
## nothing to restore (empty `saved`), but NOT necessarily true for a
## callee that's still genuinely running in the background and might
## still need ITS OWN params. Verified this scoping doesn't regress the
## two existing, already-verified callers of this exact "long-running
## helper called as a bare statement" shape (2026-08-01, Plane2): traced
## live and confirmed `perform_handle()` never actually reaches this
## function at all (it's on `BRIDGE_OVER_SHARED_FUNCTIONS`, intercepted
## earlier as an intentional no-op -- this port's own native player
## controller handles input directly), and `player_move2()` -- an
## `ACTION`, not a `function`, so it goes through exec_stmt's own
## parallel action-invoked-as-function path, not this one, but the same
## reasoning applies -- is called in TRUE tail position (`action
## player_walk2`'s own literal last statement), where "block forever"
## and "detach and let the caller reach its own end anyway" are
## observably identical.
func _call_user_function_async(fname: String, arg_exprs: Array, my) -> Variant:
	var fn: Dictionary = _functions[fname]
	var params: Array = fn.get("params", [])
	var saved: Dictionary = {}
	for i in params.size():
		var pname: String = params[i]
		saved[pname] = _globals.get(pname)
		var v = _eval(arg_exprs[i], my) if i < arg_exprs.size() else 0.0
		var had_key := _globals.has(pname)
		_globals[pname] = {"kind": "var", "init": null, "value": v}
		if not had_key:
			_index_global(pname)
	var sig = null
	if params.is_empty():
		# GDScript's own compiler refuses to let a coroutine's return
		# value be captured without `await` at the call site (a real,
		# static check -- confirmed live, this failed to even compile
		# once written as `sig = exec_block(...)`) -- called as a bare
		# statement instead, discarding whatever it eventually returns,
		# same as `_run_coroutine()`'s own identical fire-and-forget call
		# just above. `sig` stays `null`, correctly producing a `null`
		# result below for this shape (matching real Acknex: nothing
		# meaningful to return from a call that hasn't necessarily
		# finished yet).
		exec_block(fn.get("body", {}), my)
	else:
		sig = await exec_block(fn.get("body", {}), my)
	for pname in saved:
		if saved[pname] == null:
			_globals.erase(pname)
			_deindex_global(pname)
		else:
			_globals[pname] = saved[pname]
	return sig.value if sig is ReturnSignal else null


## Synchronous statement execution for plain (non-coroutine) function calls
## reached from inside expression evaluation -- these cannot themselves
## `wait()` mid-body (that would require expressions to be awaitable,
## which real WDL doesn't need: `wait()` only ever appears as a bare
## statement, never inside an expression). A `wait()` hit here is treated
## as an immediate no-op and warned once, rather than blocking eval.
## Sync counterpart of exec_block()'s own `my`/`me` reassignment handling --
## see its docstring for the full story. Same corpus idiom, same scoping
## caveat (block-local, doesn't propagate out of a nested if/while).
func _exec_block_sync(block: Dictionary, my) -> Variant:
	var current_my = my
	for stmt in block.get("body", []):
		if str(stmt.get("t", "")) == "expr_stmt":
			var ex: Dictionary = stmt.get("expr", {})
			if str(ex.get("t", "")) == "assign" and str(ex.get("op", "")) == "=":
				var tgt: Dictionary = ex.get("target", {})
				if str(tgt.get("t", "")) == "id" and str(tgt.get("name", "")).to_lower() in ["my", "me"]:
					current_my = _eval(ex.get("value"), current_my)
					continue
		var sig = _exec_stmt_sync(stmt, current_my)
		if sig != null:
			return sig
	return null


func _exec_stmt_sync(stmt: Dictionary, my) -> Variant:
	match str(stmt.get("t", "")):
		"block":
			return _exec_block_sync(stmt, my)
		"expr_stmt":
			_eval(stmt.get("expr", {}), my)
			return null
		"local_decl":
			for decl in stmt.get("decls", []):
				var v = _eval_init(decl.get("init"), my, decl.get("kind", "var"))
				var dname: String = decl.get("name")
				_globals[dname] = {"kind": decl.get("kind", "var"), "init": null, "value": v}
				_index_global(dname)
			return null
		"if":
			if _truthy(_eval(stmt.get("cond"), my)):
				return _exec_stmt_sync(stmt.get("then"), my)
			elif stmt.get("else") != null:
				return _exec_stmt_sync(stmt.get("else"), my)
			return null
		"while":
			var guard := 0
			# Same GB-1 fresh-read fix as exec_stmt's async "while" case
			# above -- see its own comment.
			if my != null and _scan_for_calls(stmt.get("cond"), ["getposition"]):
				_voice_finished_consumed_by.erase(my)
			# Same _entity_alive() guard as exec_stmt's async "while" case
			# above and for the same reason: the loop body itself (or a
			# builtin it calls) can free `my` via remove(my), and the very
			# next condition re-check would otherwise crash the engine.
			while _entity_alive(my) and _truthy(_eval(stmt.get("cond"), my)) and guard < 100000:
				var sig = _exec_stmt_sync(stmt.get("body"), my)
				if sig is BreakSignal:
					break
				if sig is ReturnSignal:
					return sig
				guard += 1
			return null
		"return":
			var v = _eval(stmt.get("value"), my) if stmt.get("value") != null else null
			return ReturnSignal.new(v)
		"break":
			return BreakSignal.new()
		"wait", "waitt":
			_warn_once("wait() inside a function call (unsupported mid-expression)")
			return null
	return null


func _warn_once(what: String) -> void:
	if _warned_builtins.has(what):
		return
	_warned_builtins[what] = true
	push_warning("[wdl] unbridged: %s" % what)


func _register_builtins() -> void:
	_builtins = {
		"random": func(a, _my): return randf() * _to_num(a[0]) if a.size() > 0 else randf(),
		"int": func(a, _my): return float(int(_to_num(a[0]))) if a.size() > 0 else 0.0,
		"abs": func(a, _my): return absf(_to_num(a[0])) if a.size() > 0 else 0.0,
		"min": func(a, _my): return minf(_to_num(a[0]), _to_num(a[1])) if a.size() > 1 else 0.0,
		"max": func(a, _my): return maxf(_to_num(a[0]), _to_num(a[1])) if a.size() > 1 else 0.0,
		"str_cpy": func(a, _my): return str(a[1]) if a.size() > 1 else "",
		"str_cat": func(a, _my): return str(a[0]) + str(a[1]) if a.size() > 1 else "",
		"str_cmpi": func(a, _my): return 1.0 if a.size() > 1 and str(a[0]).to_lower() == str(a[1]).to_lower() else 0.0,
		# vec_set/vec_sub/vec_to_angle are NOT registered here -- they need
		# by-reference access to their first argument's raw AST node (which
		# named vector/field to write into), not an evaluated value like
		# every other builtin. Intercepted directly in _call() before the
		# generic args-evaluation loop; see _do_vector_call().
		"sqrt": func(a, _my): return sqrt(_to_num(a[0])) if a.size() > 0 else 0.0,
		# Acknex `ang(x)` -- normalizes an angle to (-180, 180]. Real,
		# genuinely portable builtin (no engine-internal dependency), unlike
		# most of its `WDL/actors.wdl` neighbors -- see
		# BRIDGE_OVER_SHARED_FUNCTIONS' "actor_move" comment for why
		# `actor_turnto` (which calls this) is deliberately NOT forced onto
		# this interpreter's own approximation.
		"ang": func(a, _my): return (
			fposmod(_to_num(a[0]) + 180.0, 360.0) - 180.0 if a.size() > 0 else 0.0
		),
		# `actor_move()`/`actor_turnto(angle)` -- the basic NPC walk-forward
		# idiom (`force=N; ...; actor_move();` inside a per-tick loop), used
		# in 30 level scripts, distinct from and much simpler than the
		# still-unbridged `ent_waypoint`/`scan_path`/`vec_to_angle` waypoint-
		# flying system (that one needs real by-reference VECTOR support,
		# `my_angle`, `ent_nextpoint` -- a bigger gap, still open). Found
		# blocking Shiks' Piposh2 (`while(1){ if(Scene==1){ ...
		# actor_move(); if (my.x > StandHerePoint) { Scene=2; ... } } }`) --
		# an unresolved-builtin no-op meant `my.x` never actually advanced,
		# so `Scene` never left 1 and the level never progressed past its
		# first line, reported live as "one correct vocal, then stuck in a
		# loop." Speed constants are a reasonable approximation, not a
		# measured value from the original engine -- re-tune if a real
		# playtest shows entities crawling or overshooting their mark.
		"actor_move": func(_a, my): return _do_actor_move(my),
		"actor_turnto": func(a, my): return _do_actor_turnto(a, my),
		# `load_level(<X.WMB>)` in the original engine is how a level's own
		# main() loaded its own map -- in this port WmbLevelLoader already
		# loads the level's geometry *before* the interpreter's main() ever
		# runs (see wdl_director.gd/_try_begin_interpreted_level()), so
		# calling it again must be a no-op, not another real level load.
		# Confirmed as the actual cause of a repeating scene reload
		# (sound loop / camera reset / frozen entities) -- see
		# docs/SESSION_LOG.md 2026-07-28.
		"load_level": func(_a, _my): return 0.0,
		# 2026-08-09 (Smash/Desert): "some of the world backgrounds are
		# not correct still." Root cause traced past the AcknexSky-level
		# fix (see level_runner.gd's own _apply_wdl_sky() docstring) to a
		# real, previously-unbridged subsystem: `file_open_write`/
		# `file_open_read`/`file_asc_write`/`file_asc_read`/`file_close`
		# were entirely absent (confirmed via corpus grep -- zero
		# matches anywhere in this file before this). `Map.wdl`'s own
		# `LocationGo(ID)` writes the chosen destination's ID to
		# "Arrive.dat" before `Run("Desert.exe")`; `Desert.wdl`'s own
		# `main()` reads it straight back into `Stage`, which then picks
		# BOTH the correct horizon texture (see the six `if(Stage==_X)
		# {scene_map=bmapBackN;}` branches) AND the correct music/weather
		# for wherever the player actually clicked -- with these unbridged,
		# `Stage` silently stayed at its own declared default (0),
		# matching none of the six branches, so `scene_map` (and music,
		# and weather) never changed AT ALL regardless of destination.
		# Scoped deliberately to the plain-number (`_asc_`) variant only,
		# not the by-reference string variant (`file_str_read(handle,
		# var)`, which writes directly into its own 2nd argument the same
		# way `vec_set` does and would need the same kind of special-
		# casing in `_call()` before generic arg evaluation) -- covers
		# this exact "hand a small number to the next level" idiom
		# (also used by Map.wdl's own "Depart.dat" and Start.wdl's own
		# "Movie.dat") without the added scope/risk of touching
		# `WDL/IO.wdl`'s own much larger sequential save/load-game system
		# (Piece[]/Village[]/Volcano[]/... arrays through the same
		# handle), which is a separate, bigger undertaking left
		# untouched. Real files under `user://` -- persist across level
		# loads within a run and across app restarts, matching what a
		# real saved-to-disk file would do.
		"file_open_write": func(a, _my): return _do_file_open(str(a[0]) if a.size() > 0 else "", true),
		"file_open_read": func(a, _my): return _do_file_open(str(a[0]) if a.size() > 0 else "", false),
		"file_asc_write": func(a, _my): return _do_file_asc_write(a),
		"file_asc_read": func(a, _my): return _do_file_asc_read(a),
		"file_close": func(a, _my): return _do_file_close(a),
		# GB-5 continued (2026-08-03, Range): the REAL corpus spelling is
		# `level_load(<X.WMB>)`, not `load_level` (the stub just above --
		# registered under the reversed name, so it never actually matched
		# any real call; left alone, harmless either way). Called by every
		# level's own main() at normal startup too (WmbLevelLoader already
		# loaded the level's geometry before main() ever runs, so a no-op
		# is correct there), but Range's `fRIP1` ("retry") re-invokes
		# main() a second time expecting a REAL reset -- and nothing else
		# does one: `Death` (gates Restart()'s own guard) is set to 0 only
		# once, at action CamTarget's initial coroutine start, never again,
		# so a second death never showed the RIP screen at all ("doesn't
		# let you die again even though you got fully hit"). Reset every
		# declared global back to its initial value, mirroring setup()'s
		# own one-time init loop exactly -- safe for the normal-startup
		# call too (main()'s own subsequent explicit assignments, e.g.
		# `Health=609;`, simply overwrite the same correct values again
		# right after). Entity-level state (target positions, Pop/Dying/
		# GoingUp flags) is NOT reset here -- a real fix for that is a
		# separate, larger piece; flagged in BUGS.md, not guessed at here.
		"level_load": func(_a, _my): return _do_level_load(),
		"remove": func(a, my): return _do_remove(a, my),
		"create": func(a, my): return _do_create(a, my),
		"morph": func(a, my): return _do_morph(a, my),
		"run": func(a, _my): return _do_run(a),
		# `scan_path`/`ent_nextpoint`/`ent_waypoint` -- the NPC path-following
		# library. First made a blind truthy stub (2026-07-30) to stop
		# `result = scan_path(...); if (result==0) { my._MOVEMODE = 0; }`
		# (corpus-wide idiom, Start/Shiks/Town/Plane/... 22 files) from
		# falsely gating unrelated logic coupled into the same
		# `while (my._MOVEMODE > 0) { ... }` loop (dialogue-scene
		# advancement, GetPosition(Voice) polling) -- that part was correct
		# and stays. But a blind "always succeeds, never actually binds a
		# path" stub broke a DIFFERENT case: Start.wmb has two `LookAtMe`
		# entities, and in the real engine only the one that actually finds
		# a path should be walking -- with every scan_path call succeeding
		# unconditionally, both ran their identical walk-toward-target logic
		# at once, both writing camera.x/y every tick, fighting for control
		# (reported live as "camera positions not updated correctly"). Worse,
		# `_TARGET_X`/`_TARGET_Y` (read via `MY._TARGET_X - MY.X` to compute
		# a walk direction) were never actually set to anything, so the
		# "direction" was always a stale (0,0) delta -- entities walked in
		# one fixed direction forever instead of toward a real waypoint,
		# explaining runaway movement and wrong facing.
		# Fixed with a real (if approximate) implementation: `scan_path`
		# finds the nearest point across every path in the level (loaded
		# from `_loader.last_level_data`, same source as
		# `WdlDirector._paths`) to `my`'s position, binds the entity to that
		# path + point index via node meta, and writes GS coordinates into
		# `_TARGET_X`/`_TARGET_Y`/`_TARGET_Z` (the generic custom-field
		# fallback -- see _get_field()/_set_field()) -- returns 0.0 only if
		# the level truly has no paths at all, so `_MOVEMODE`-gated
		# unrelated logic still isn't falsely blocked. `ent_nextpoint`
		# advances to the next bound point, rewriting the target fields the
		# same way. `ent_waypoint` stays a no-op -- redundant with what
		# scan_path already just set up, every call site invokes it
		# immediately after scan_path with the value scan_path itself wrote.
		"scan_path": func(_a, my): return _do_scan_path(my),
		"ent_nextpoint": func(_a, my): return _do_ent_nextpoint(my),
		"ent_waypoint": func(_a, _my): return 0.0,
		# `ShowDialog()` -- every dialogue-choice scene in the game
		# (`DoDialog(num) { DialogChoice=0; DialogIndex=num; ShowDialog();
		# ...}`) calls this, then the SAME coroutine's own already-written
		# per-tick loop polls `DialogChoice` to branch. Was completely
		# unbridged (generic 0.0 no-op fallback) -- the panel never showed,
		# so `DialogChoice` could never be set by a click, so every one of
		# those polling loops spun forever: "no text-choosing on screen"
		# and "after talking ends the game doesn't move on," reported live.
		# Fire-and-forget, not blocking -- matches the WDL call site shape
		# (never awaited, the calling loop already polls). Response half is
		# `_on_dialog_choice()`, wired to GameHud.dialog_choice in setup().
		"showdialog": func(_a, my): return _do_show_dialog(my),
		# See BRIDGE_OVER_SHARED_FUNCTIONS's "perform_handle" comment --
		# a real per-tick input poll this port's native player controller
		# makes meaningless, force-bridged to a harmless no-op so its own
		# real `while(1)` (which nothing here ever breaks) can't
		# permanently block whatever bare-statement call site it's
		# reached from.
		"perform_handle": func(_a, _my): return 0.0,
		# See BRIDGE_OVER_SHARED_FUNCTIONS' own comment: a real forever
		# loop for a save/load menu this port doesn't implement, called
		# unconditionally from the shared Initialize() every level's
		# main() runs near the top.
		"startsaveload": func(_a, _my): return 0.0,
		# See BRIDGE_OVER_SHARED_FUNCTIONS' own comment: the native
		# controller's Camera3D is the sole source of truth for the FP
		# camera in this port, so the WDL script's own per-tick
		# camera-attach logic has nothing useful left to do.
		"move_view_1st": func(_a, _my): return 0.0,
		"move_view_3rd": func(_a, _my): return 0.0,
		"move_view_3rd_2": func(_a, _my): return 0.0,
		"splay": func(a, my): return _do_play_sfx_logged(a, my),
		"vplay": func(a, my): return _do_play_sfx_logged(a, my),
		"play_sound": func(a, _my): return _do_play_sfx(a, 0, false),
		"play_entsound": func(a, _my): return _do_play_sfx(a, 1, false),
		# `stop_sound(handle)` -- same per-sound handle idiom as
		# `snd_playing`, corpus-wide (confirmed via grep, e.g. Start.wdl's
		# `stop_sound(my.skill40)` stopping a crowd-noise ambiance loop):
		# stops the SPECIFIC handle from a prior play_sound/play_entsound.
		# Ignoring the argument (an earlier version of this builtin) always
		# stopped the shared Voice channel instead -- a level's own
		# ambient-SFX stop call was silently cutting off unrelated dialogue
		# every time it ran.
		"stop_sound": func(a, _my): return _do_stop_sound(a),
		# `snd_playing(handle)` -- WDL's per-sound polling idiom, corpus-wide
		# (e.g. `if (snd_playing(SND)==0) { play_sound(...); SND=result; }`
		# for ambiance loops): checks the SPECIFIC handle returned by a prior
		# play_sound/play_entsound, never a global "is anything playing"
		# query -- confirmed via corpus grep, no call site ever passes Voice.
		# Ignoring the argument (an earlier version of this builtin) makes
		# `snd_playing(X) == 0` permanently true, so every ambiance loop
		# using this idiom retriggers its sound from the start every single
		# tick -- reported live as "background noises playing in loop with
		# bad sound." See autoload/audio_channels.gd's handle scheme.
		"snd_playing": func(a, _my): return (
			1.0 if a.size() > 0 and AudioChannels.is_sfx_handle_playing(_to_num(a[0])) else 0.0
		),
		"setvoice": func(_a, _my): return 0.0,
		"voiceinit": func(_a, _my): return 0.0,
		# "getposition" is deliberately NOT registered here -- it's
		# intercepted earlier, directly in _eval()'s "call" case, so it
		# can pass the call-site's own AST node through to
		# _do_get_voice_position() (see _call_site_id()'s comment for
		# why). Reaching _call()'s generic _builtins dispatch for this
		# name at all would mean that interception was bypassed somehow.
		"ent_frame": func(a, my): return _do_anim_frame(a, my),
		"ent_cycle": func(a, my): return _do_anim_cycle(a, my),
		"talk": func(_a, my): return _do_talk(my),
		"talk2": func(_a, my): return _do_talk_skins(my, true),
		"blink": func(_a, my): return _do_blink(my),
		"blink2": func(_a, my): return _do_blink(my),
	}


## Per-filename volume trims for entity/ambient SFX (case-insensitive).
## `play_entsound`'s 3rd argument is Acknex's audible-*range*/falloff
## distance (corpus-wide values run 66-5000, e.g. `play_entsound(my,
## sHammer,300)` -- see git history for the full survey), not a literal
## loudness scale -- this port has no distance-based 3D attenuation for
## entity sounds at all yet (a real fix, but far bigger in scope/risk
## than warranted by one report: it'd touch every play_entsound call
## site in the corpus with no way to verify the result by ear). So every
## entity sound currently plays at flat, un-attenuated volume regardless
## of range/distance -- reported live (2026-08-01, Plane2): "make the
## Hammer volume lower." SFX090.WAV (`sHammer`, Plane.wdl and Plane2.wdl
## both use it for Krupnik's hammer-hit) has one of the *shorter*
## authored ranges (300, well under the corpus' most common 500/1000) --
## clearly meant to be a close/quiet sound, not a loud one, which flat
## full-volume playback defeats. Narrow, per-filename trim instead of
## general attenuation, same precedent as the tuned dB values
## wdl_director.gd used to hardcode per-sound (SFX105/SFX089/SFX100,
## since removed as duplicate triggering, see 2026-08-01 fifth entry --
## the tuning concept wasn't the problem, the duplicate *call site* was).
const SFX_VOLUME_TRIM_DB := {
	"sfx090.wav": -12.0,  # sHammer (Plane/Plane2 Krupnik hammer-hit)
	# Range.wdl `Jet` -- background engine-idle ambiance, looped
	# continuously via `action PIP`/`action Handgun` for the entire level
	# (both the opening dialogue AND actual shooting-gallery gameplay).
	# Authored range 20-30 -- far smaller than the corpus' common
	# 500-1000, clearly meant to be a quiet backdrop, not something that
	# competes with the foreground voice lines. Reported live
	# (2026-08-01): "background sound for range is too high and we can
	# hear the character dialogue [over it]" -- flat, un-attenuated
	# playback (see SFX_VOLUME_TRIM_DB's own docstring above) made it
	# loud enough to mask PIP/KRP's voice lines during the intro dialogue.
	"sfx091.wav": -14.0,  # Jet (Range background engine ambiance)
	# Smash.wdl `action Traffic`: each spawned car has a flat 1%-per-tick
	# chance to honk (Honk1/2/3), and `action Dummy` keeps spawning new
	# traffic continuously via AddTraffic() -- with several cars alive at
	# once, their honks frequently overlap and mix at full, un-attenuated
	# volume each. Reported live (2026-08-09): "a very high volume of cars
	# honking that shouldn't be so loud." Individually authored at the
	# corpus' common 500-range, same as most other SFX, so this is a
	# stacking/overlap loudness issue rather than a mislabeled-range one
	# (unlike sHammer/Jet above) -- trimmed rather than left at full
	# volume, same mechanism either way.
	"sfx007.wav": -9.0,  # Honk1
	"sfx008.wav": -9.0,  # Honk2
	"sfx009.wav": -9.0,  # Honk3
}


## GB-1 investigation (2026-08-01, Shiks): a real session showed no
## VOICE_FINISHED for PIP017.WAV even after 30+s -- need to know whether
## sPlay() was ever actually called for it, or whether the caller's own
## coroutine never reached this statement at all.
func _do_play_sfx_logged(a: Array, my) -> float:
	if a.size() > 0:
		PiposhDebug.log_msg("dialog-choice", "SPLAY wav=%s by=%s" % [
			str(a[0]), (str(my.name) if (my != null and is_instance_valid(my)) else "<null>")
		])
	return _do_play_sfx(a, 0, true)


func _do_play_sfx(a: Array, wav_index: int, is_voice: bool) -> float:
	if a.size() <= wav_index:
		return -1.0
	var wav_name := str(a[wav_index])
	if is_voice:
		AudioChannels.play_voice(wav_name)
		return 0.0
	# Real handle, not a placeholder -- snd_playing(result) (the WDL "is my
	# ambiance loop still playing" idiom) needs it to identify this specific
	# playback, not just any playback. See _register_builtins()'s
	# "snd_playing" comment.
	var trim: float = SFX_VOLUME_TRIM_DB.get(wav_name.get_file().to_lower(), 0.0)
	return AudioChannels.play_sfx(wav_name, trim)


## Approximate speeds, not measured from the original engine -- see
## _register_builtins()'s "actor_move" comment.
const ACTOR_MOVE_BASE_SPEED := 3.0  # GS units per Acknex tick, per unit of `force`
const ACTOR_TURN_BASE_SPEED := 8.0  # degrees per Acknex tick, per unit of `force`


func _do_actor_move(my) -> float:
	if typeof(my) == TYPE_NIL or not is_instance_valid(my):
		return 0.0
	var force := _to_num(_get_var("force", my))
	if force <= 0.0:
		force = 1.0
	var t := _to_num(_get_var("time", my))
	var pan := deg_to_rad(float(my.get_meta("pan", 0.0)))
	# Same pan->forward convention as _apply_acknex_view()/WdlDirector's
	# entity-basis code (tilt=0, flat ground movement).
	var dir := Vector3(cos(pan), 0.0, -sin(pan))
	var step := force * ACTOR_MOVE_BASE_SPEED * t
	my.global_position += dir * step
	# See _seed_static_pose_if_never_animated()'s own comment: only set
	# for actions that call actor_move() but never ent_frame/ent_cycle
	# themselves. Phase accumulates with distance moved (matching every
	# other corpus idiom's own `skill1 = skill1 + N*time; ent_cycle
	# ("Walk", skill1);` pairing, just driven from here instead of the
	# WDL script) so the cycle actually advances instead of holding one
	# frame, and stops advancing the instant movement does.
	#
	# Wrapped via fmod, NOT left to grow unbounded: `MdlAnimator.play_cycle()`
	# does `_percent = clampf(percent, 0.0, 100.0)` -- a clamp, not a loop --
	# so an ever-growing phase value (as this was before) exceeds 100 after
	# only ~100 units of walking (a small fraction of a longer walk) and
	# then STAYS at exactly 100.0 forever: every subsequent call clamps to
	# the same value, freezing the render on the cycle's last frame for the
	# rest of the walk while `current_clip`/`playing` state still looks
	# perfectly normal (state-only checks miss this -- reported live via
	# Plane's PiposhWalk, 2026-08-02: walk animation "moves correctly but
	# ... no walking animation", confirmed via `[mdl-anim]` debug logging
	# showing `_percent` climbing straight past 100 without ever cycling
	# back down).
	# 2026-08-08 (Plane3): "piposh character's animation to move isn't
	# correct it looks like he's walking" during the vase-catch flight.
	# `action PipFall`'s own script calls `ent_frame("Fetch",...)` and
	# `actor_move()` in the SAME tick while flying toward the vase, so
	# this fallback's generic "Walk" cycle ran right after PipFall's own
	# "Fetch" pose and visibly stomped it. First attempt (suppress the
	# fallback whenever ANY real ent_frame/ent_cycle call already fired
	# this same tick, via a meta timestamp) broke Plane's own already-
	# verified PiposhWalk case (smoke_plane_walk_anim.gd): its `Blink()`
	# helper calls `ent_frame("Stand",0)` UNCONDITIONALLY, every tick,
	# before its own `actor_move()` call -- structurally the identical
	# "real anim call, then actor_move(), same tick" shape as PipFall's,
	# but there the walk cycle winning is the wanted outcome, so a plain
	# same-tick-ordering rule can't tell the two apart.
	#
	# The actual distinguishing signal turned out to be the CLIP NAME
	# itself, not ordering: a corpus-wide scan (`grep -B2 ent_frame
	# original/piposh3d/*.wdl`) found "Stand"/"stand" used as an
	# `ent_frame` target 105 times across the corpus -- by a wide margin
	# the single most common clip name, and every `Blink()`/`Blink2()`
	# variant that touches animation at all (Smash/Range/Olympic/etc.,
	# confirmed by direct comparison) uses exactly this name as its own
	# idle/default reset pose. "Stand" is semantically never a real
	# character POSE choice a script would deliberately want to hold
	# WHILE `actor_move()` is actively translating the entity -- standing
	# still and being actively moved are contradictory -- so treating a
	# same-tick "Stand" call as the low-priority default it actually is
	# (not a deliberate override) and letting the walk fallback win over
	# it, while still letting any OTHER named pose (PipFall's "Fetch",
	# "Fall", "Write", ...) win over the fallback, correctly separates
	# both cases without needing to touch the WDL source or guess at
	# call-site structure. Not a Plane3-only fix: every other
	# actor_move()-driven action found in the corpus that also animates
	# itself gets this same, more accurate resolution.
	if my.get_meta("wdl_auto_walk_anim", false) and int(my.get_meta("wdl_last_real_anim_frame", -1)) != _total_frames:
		var phase := fmod(float(my.get_meta("wdl_auto_walk_phase", 0.0)) + absf(step), 100.0)
		my.set_meta("wdl_auto_walk_phase", phase)
		_do_anim_cycle(["Walk", phase], my)
	return 0.0


func _do_actor_turnto(a: Array, my) -> float:
	if typeof(my) == TYPE_NIL or not is_instance_valid(my) or a.is_empty():
		return 0.0
	var target := _to_num(a[0])
	var force := _to_num(_get_var("force", my))
	if force <= 0.0:
		force = 1.0
	var t := _to_num(_get_var("time", my))
	var cur := float(my.get_meta("pan", 0.0))
	var max_step := force * ACTOR_TURN_BASE_SPEED * t
	var diff := fmod(target - cur + 540.0, 360.0) - 180.0  # shortest signed delta
	var step := clampf(diff, -max_step, max_step)
	_set_entity_pan(my, cur + step)
	return 0.0


func _do_show_dialog(my) -> float:
	PiposhDebug.log_msg("dialog-choice", "SHOWDIALOG by=%s DialogIndex=%s" % [
		(str(my.name) if (my != null and is_instance_valid(my)) else "<null>"),
		_get_var("DialogIndex", my)
	])
	_set_var("DialogChoice", 0.0, my)  # matches the real ShowDialog's first statement
	if _hud == null:
		return 0.0
	var idx := int(_to_num(_get_var("DialogIndex", my)))
	_hud.show_dialog(idx)
	PiposhDebug.log_msg("dialog-choice", "  -> after show_dialog(%d), is_dialog_open=%s" % [idx, _hud.is_dialog_open()])
	return 0.0


# ---------------------------------------------------------------------------
# VECTOR/ANGLE by-reference builtins (vec_set/vec_sub/vec_to_angle) and the
# NPC path-following pair (scan_path/ent_nextpoint) built on top of them.
# ---------------------------------------------------------------------------
func _vec_field_is_angle(field: String) -> bool:
	return field in ["pan", "tilt", "roll"]


## x/pan share slot 0, y/tilt share slot 1, z/roll share slot 2 -- Acknex's
## VECTOR and ANGLE types are the same 3-float struct with two field-naming
## conventions overlaid. -1 if `field` isn't one of these six.
func _vec_field_slot(field: String) -> int:
	match field:
		"x", "pan":
			return 0
		"y", "tilt":
			return 1
		"z", "roll":
			return 2
	return -1


## Resolves a vec_set/vec_sub/vec_to_angle argument -- a RAW AST node, not
## an evaluated value, since these need by-reference semantics -- to its
## current Vector3. Two shapes appear in this corpus: a bare scratch
## identifier (`temp`, `my_angle` -- own storage in `_vectors`) or
## `entity.x`/`entity.pan` (Acknex's "a position/angle field is also usable
## as a pointer to the entity's whole x/y/z or pan/tilt/roll triple" idiom
## -- only the field's IDENTITY, position vs. angle, matters here).
func _vec_get(expr: Variant, my) -> Vector3:
	if typeof(expr) != TYPE_DICTIONARY:
		return Vector3.ZERO
	var t := str(expr.get("t", ""))
	if t == "id":
		var name := str(expr.get("name", "")).to_lower()
		if name == "camera":
			return Vector3(_get_camera_field("x"), _get_camera_field("y"), _get_camera_field("z"))
		var node = _resolve_entity(expr, my)
		if node != null and is_instance_valid(node):
			var gs := _godot_to_gs(node.global_position)
			return Vector3(gs.x, gs.y, gs.z)
		if _vectors.has(name):
			return _vectors[name]
		# Acknex has two equally real spellings for a scratch 3-vector:
		# the `.x`/`.y`/`.z` field style (`temp.x = ...`, tracked in
		# `_vectors` above) and a plain 3-element ARRAY global
		# (`var abspeed[3]; abspeed[0] = ...;`), used corpus-wide (e.g.
		# WDL/war.wdl's `_gib_action` -- `MOVE ME,NULLSKILL,abspeed;`,
		# where `abspeed[0..2]` holds that tick's own computed velocity).
		# Only the field style was ever read here; a bare array-style
		# vector fell through to Vector3.ZERO regardless of what the
		# script had actually written into it. Confirmed live (2026-08-09,
		# Plane3): this is why `_gib(20)`'s own debris pieces never
		# visibly flew apart after the vase-catch fix landed -- each
		# gibbit's own per-tick `MOVE` call read a permanently-zero
		# velocity, so they sat motionless at the vase's exact position
		# instead of scattering, reading as "the vase just vanishes" with
		# no real explosion. `_get_var()` already resolves `abspeed` to
		# the real, live-mutated Array (index-assignment writes into it
		# in place); just needed to be checked here too.
		var v = _get_var(name, my)
		if v is Array and v.size() >= 3:
			return Vector3(_to_num(v[0]), _to_num(v[1]), _to_num(v[2]))
		return Vector3.ZERO
	if t == "field":
		var fname := str(expr.get("name", "")).to_lower()
		var is_angle := _vec_field_is_angle(fname)
		var obj_expr = expr.get("obj")
		var node = _resolve_entity(obj_expr, my)
		if node != null and is_instance_valid(node):
			if node == _camera:
				return (
					Vector3(_get_camera_field("pan"), _get_camera_field("tilt"), _get_camera_field("roll"))
					if is_angle else
					Vector3(_get_camera_field("x"), _get_camera_field("y"), _get_camera_field("z"))
				)
			if is_angle:
				return Vector3(
					float(node.get_meta("pan", 0.0)),
					float(node.get_meta("tilt", 0.0)),
					float(node.get_meta("roll", 0.0)),
				)
			var gs := _godot_to_gs(node.global_position)
			return Vector3(gs.x, gs.y, gs.z)
		if typeof(obj_expr) == TYPE_DICTIONARY and obj_expr.get("t") == "id":
			return _vectors.get(str(obj_expr.get("name", "")).to_lower(), Vector3.ZERO)
	return Vector3.ZERO


func _vec_put(expr: Variant, val: Vector3, my) -> void:
	if typeof(expr) != TYPE_DICTIONARY:
		return
	var t := str(expr.get("t", ""))
	if t == "id":
		var name := str(expr.get("name", "")).to_lower()
		if name == "camera":
			_set_camera_field("x", val.x, my)
			_set_camera_field("y", val.y, my)
			_set_camera_field("z", val.z, my)
			return
		var node = _resolve_entity(expr, my)
		if node != null and is_instance_valid(node):
			node.global_position = _gs_to_godot(val)
			return
		_vectors[name] = val
		return
	if t == "field":
		var fname := str(expr.get("name", "")).to_lower()
		var is_angle := _vec_field_is_angle(fname)
		var obj_expr = expr.get("obj")
		var node = _resolve_entity(obj_expr, my)
		if node != null and is_instance_valid(node):
			if node == _camera:
				if is_angle:
					_set_camera_field("pan", val.x, my)
					_set_camera_field("tilt", val.y, my)
					_set_camera_field("roll", val.z, my)
				else:
					_set_camera_field("x", val.x, my)
					_set_camera_field("y", val.y, my)
					_set_camera_field("z", val.z, my)
				return
			if is_angle:
				_set_entity_pan(node, val.x)
				_set_entity_tilt_roll(node, val.y, val.z)
			else:
				node.global_position = _gs_to_godot(val)
			return
		if typeof(obj_expr) == TYPE_DICTIONARY and obj_expr.get("t") == "id":
			_vectors[str(obj_expr.get("name", "")).to_lower()] = val


## Reported live (2026-08-09, Smash): "there's no animation of the pee
## when piposh pees" -- `action PipPee` calls Acknex's own particle
## builtin, `emit 2,temp.x,stream;`, entirely unbridged until now (zero
## matches for "emit" anywhere in this file). Real Acknex particles are a
## genuinely separate subsystem from ordinary WDL entities: `emit()`'s
## own 3rd argument names a "particle function" (e.g. `function stream()
## {...}`) that real Acknex re-invokes once PER PARTICLE PER FRAME, with
## a dedicated set of MY_-prefixed pseudo-fields (MY_AGE, MY_SPEED,
## MY_SIZE, MY_COLOR, MY_MAP, MY_ACTION, MY_FLARE, ...) that only make
## sense in that per-particle context -- correctly interpreting that
## function's own WDL body per-particle would need its own execution
## context (parallel to `my`), its own field-resolution rules (`MY_
## SPEED.X` is NOT the same thing as `my.x`), and a lifecycle model
## (`MY_ACTION = NULL;` to self-remove) layered on top of the ordinary
## entity/coroutine model this interpreter already has -- a genuinely
## new subsystem, not a bug fix. Also used by Smash's own Vespa (exhaust
## smoke) and PieceFall-adjacent dust effects, and almost certainly
## elsewhere in the corpus (any `particlefade()`-style function).
##
## Scoped down deliberately rather than left unbridged or rushed:
## renders a real, physically-reasonable particle burst (outward-and-up
## scatter, gravity, fade-to-nothing) at the emit position instead of
## genuinely interpreting the named particle function's own body -- the
## visible outcome the report is actually about (something happens where
## nothing did before) without the substantially larger, higher-risk
## scope of a byte-faithful per-particle WDL execution model. The
## specific per-particle physics constants below (speed/lifetime/gravity)
## are a reasonable approximation, not measured from the original.
const PARTICLE_LIFETIME_MIN := 0.5
const PARTICLE_LIFETIME_MAX := 1.1
const PARTICLE_SPEED_MIN := 20.0
const PARTICLE_SPEED_MAX := 55.0
const PARTICLE_GRAVITY := 200.0  # GS units/sec^2
const PARTICLE_MAX_QUANTITY := 40  # guard against a runaway/misread quantity arg
var _particles: Array[Dictionary] = []
var _particle_texture: Texture2D
var _particle_parent: Node3D
## particle-action name (lowercased) -> resolved Texture2D, or `null` once
## looked up and confirmed to have no real MY_MAP (falls back to the
## generic dot) -- see _get_particle_texture_for_action()'s own docstring.
var _particle_textures_by_action: Dictionary = {}


func _do_emit(quantity: float, pos_gs: Vector3, particle_action: String = "") -> void:
	if _loader == null:
		return
	if _particle_parent == null or not is_instance_valid(_particle_parent):
		_particle_parent = Node3D.new()
		_particle_parent.name = "WdlParticles"
		_loader.add_child(_particle_parent)
	var origin := _gs_to_godot(pos_gs)
	var n := clampi(int(quantity), 1, PARTICLE_MAX_QUANTITY)
	var tex := _get_particle_texture_for_action(particle_action)
	var real_tex: bool = tex != _get_particle_texture()
	# See _particle_base_dir_for_action()'s own docstring. A real,
	# evaluated direction (not the generic random-burst default) makes a
	# directional effect like `stream()` (pee) actually read as a STREAM
	# instead of an omnidirectional splash.
	var base_dir := _particle_base_dir_for_action(particle_action)
	var has_base_dir: bool = base_dir.length() > 0.001
	for i in n:
		var spr := Sprite3D.new()
		spr.texture = tex
		spr.pixel_size = 0.5
		spr.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		spr.shaded = false
		# A real MY_MAP texture (e.g. Pee.png) already carries its own
		# authored color -- tinting it blue-white (the generic dot's own
		# look) made every emit() effect in the corpus read as the same
		# bluish sparkle regardless of what it actually was. Only the
		# fallback dot still gets the neutral tint it was designed for.
		spr.modulate = Color(1, 1, 1, 0.95) if real_tex else Color(0.8, 0.87, 1.0, 0.85)
		_particle_parent.add_child(spr)
		spr.global_position = origin
		var jitter := Vector3(randf_range(-1.0, 1.0), randf_range(0.3, 1.0), randf_range(-1.0, 1.0))
		var dir: Vector3 = (base_dir + jitter * 0.35).normalized() if has_base_dir else jitter.normalized()
		_particles.append({
			"node": spr,
			"velocity": dir * randf_range(PARTICLE_SPEED_MIN, PARTICLE_SPEED_MAX),
			"age": 0.0,
			"lifetime": randf_range(PARTICLE_LIFETIME_MIN, PARTICLE_LIFETIME_MAX),
		})


## Reported live (2026-08-10): "the pee still isn't 'flowing' in the
## right angle." The particle system's own default direction (a generic
## random outward-and-up burst) is a reasonable approximation for a
## splash/scatter effect (blood, sparks, debris), but wrong for a
## genuinely DIRECTIONAL emitter -- Smash's own `function stream()`
## (`action PipPee`'s particle function) computes a real, non-random
## initial velocity for its "just born" particles: `MY_SPEED.X=-PeeStr+
## jitter; MY_SPEED.Y=PeeStr+jitter; MY_SPEED.Z=PeeStr+jitter;` -- every
## particle flies in roughly the SAME direction (scaled by `PeeStr`, a
## real WDL global), which is what makes it read as a coherent stream
## rather than a splash. Unlike `MY_MAP` (a static texture assignment,
## same session, same section), this can't be read as a literal off the
## AST -- `PeeStr` is a live global that changes over time (`PeeStr -=
## 0.03*time;` while peeing) -- so this actually EVALUATES the found
## expressions via `_eval()` at the moment `emit()` fires, using the
## interpreter's own real global state, not a byte-faithful continuous
## per-particle simulation (still out of scope, see this section's own
## top-level docstring) but a real one-time read of the SAME formula the
## original uses to seed each particle's own initial direction. Falls
## back to the existing random-burst behavior (Vector3.ZERO here) for any
## particle action with no MY_SPEED assignment found -- never a
## regression for smoke/lava/blood/debris-style effects that were already
## working as an omnidirectional scatter.
func _particle_base_dir_for_action(action_name: String) -> Vector3:
	if action_name == "":
		return Vector3.ZERO
	var resolved_fn := _resolve_function(action_name)
	if resolved_fn == "":
		return Vector3.ZERO
	var exprs := _find_my_speed_assignments(_functions[resolved_fn].get("body", {}))
	if exprs.is_empty():
		return Vector3.ZERO
	var vx := _to_num(_eval(exprs["x"], null)) if exprs.has("x") else 0.0
	var vy := _to_num(_eval(exprs["y"], null)) if exprs.has("y") else 0.0
	var vz := _to_num(_eval(exprs["z"], null)) if exprs.has("z") else 0.0
	var dir_gs := Vector3(vx, vy, vz)
	if dir_gs.length() < 0.001:
		return Vector3.ZERO
	return _gs_to_godot(dir_gs).normalized()


## Depth-first search for `MY_SPEED.X`/`.Y`/`.Z` assignments in a
## particle function's own body -- see _particle_base_dir_for_action().
## Returns a dict of whichever axes were found (`{"x": expr, ...}`), raw
## AST value-expression nodes (not evaluated here, by-reference like
## _find_my_map_assignment()'s own "id" case).
func _find_my_speed_assignments(node: Variant, into: Dictionary = {}) -> Dictionary:
	if typeof(node) != TYPE_DICTIONARY:
		return into
	var t := str(node.get("t", ""))
	if t == "expr_stmt":
		return _find_my_speed_assignments(node.get("expr"), into)
	if t == "assign" and str(node.get("op", "")) == "=":
		var target = node.get("target")
		if typeof(target) == TYPE_DICTIONARY and str(target.get("t", "")) == "field":
			var obj = target.get("obj")
			if typeof(obj) == TYPE_DICTIONARY and str(obj.get("t", "")) == "id" \
					and str(obj.get("name", "")).to_lower() == "my_speed":
				var axis := str(target.get("name", "")).to_lower()
				if axis in ["x", "y", "z"] and not into.has(axis):
					into[axis] = node.get("value")
		return into
	if t == "block":
		for stmt in node.get("body", []):
			_find_my_speed_assignments(stmt, into)
		return into
	if t == "if":
		_find_my_speed_assignments(node.get("then"), into)
		_find_my_speed_assignments(node.get("else"), into)
		return into
	return into


## Reported live (2026-08-10): "the pee animation is still not working
## right" -- the emit() bridge (see this section's own docstring) worked
## functionally but rendered EVERY particle effect corpus-wide with the
## same generic bluish soft-dot sprite, since genuinely interpreting the
## named particle function's own per-particle body is still out of scope
## (a real, separate execution model, not a bug fix -- see above). Most of
## that function's own body genuinely needs that (MY_SPEED/MY_AGE-driven
## physics), but its OTHER job -- picking a texture (`MY_MAP = bpee;`,
## Smash's own `stream()`) -- is a single static assignment, not runtime
## behavior, and can be read directly off the AST the same way
## `wdl_meta.json`'s own static sky_map/scene_map extraction already does
## elsewhere in this port. Scans the particle-action's own function body
## (bounded -- MY_MAP is always a top-level statement in this corpus, not
## behind a loop) for a literal `MY_MAP = <bmap id>;` assignment, resolves
## it through the SAME `_resolve_bmap_texture()` every panel/HUD bitmap
## already uses, and caches the result per action name. Falls back to the
## generic dot (unchanged) for any particle action with no MY_MAP
## assignment, or one this port can't resolve -- never a regression, only
## an upgrade when a real texture is actually found.
func _get_particle_texture_for_action(action_name: String) -> Texture2D:
	if action_name == "":
		return _get_particle_texture()
	var key := action_name.to_lower()
	if _particle_textures_by_action.has(key):
		var cached = _particle_textures_by_action[key]
		return cached if cached != null else _get_particle_texture()
	var resolved_fn := _resolve_function(action_name)
	var bmap_name := ""
	if resolved_fn != "":
		bmap_name = _find_my_map_assignment(_functions[resolved_fn].get("body", {}))
	var tex: Texture2D = _resolve_bmap_texture(bmap_name) if bmap_name != "" else null
	_particle_textures_by_action[key] = tex
	return tex if tex != null else _get_particle_texture()


## Depth-first search for the first `MY_MAP = <id>;` assignment in a
## particle function's own body -- see _get_particle_texture_for_action().
func _find_my_map_assignment(node: Variant) -> String:
	if typeof(node) != TYPE_DICTIONARY:
		return ""
	var t := str(node.get("t", ""))
	if t == "expr_stmt":
		return _find_my_map_assignment(node.get("expr"))
	if t == "assign" and str(node.get("op", "")) == "=":
		var target = node.get("target")
		if typeof(target) == TYPE_DICTIONARY and str(target.get("t", "")) == "id" \
				and str(target.get("name", "")).to_lower() == "my_map":
			var value = node.get("value")
			if typeof(value) == TYPE_DICTIONARY and str(value.get("t", "")) == "id":
				return str(value.get("name", ""))
		return ""
	if t == "block":
		for stmt in node.get("body", []):
			var found := _find_my_map_assignment(stmt)
			if found != "":
				return found
		return ""
	if t == "if":
		var found := _find_my_map_assignment(node.get("then"))
		if found != "":
			return found
		return _find_my_map_assignment(node.get("else"))
	return ""


func _update_particles(delta: float) -> void:
	var i := _particles.size() - 1
	while i >= 0:
		var p: Dictionary = _particles[i]
		var node: Sprite3D = p.get("node")
		if node == null or not is_instance_valid(node):
			_particles.remove_at(i)
			i -= 1
			continue
		var age: float = p["age"] + delta
		var lifetime: float = p["lifetime"]
		if age >= lifetime:
			node.queue_free()
			_particles.remove_at(i)
			i -= 1
			continue
		var vel: Vector3 = p["velocity"]
		vel.y -= PARTICLE_GRAVITY * delta
		node.global_position += vel * delta
		node.modulate.a = 0.85 * (1.0 - age / lifetime)
		p["velocity"] = vel
		p["age"] = age
		i -= 1


## Small soft-dot sprite, generated once and reused for every particle --
## real Acknex particles here are usually a small droplet/dust/smoke puff,
## not something that needs a hard edge or the emitting function's own
## specific texture (see this section's own docstring for why the named
## particle function isn't actually interpreted).
func _get_particle_texture() -> Texture2D:
	if _particle_texture != null:
		return _particle_texture
	var size := 16
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(size, size) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(x, y).distance_to(center) / (size * 0.5)
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a * a))
	_particle_texture = ImageTexture.create_from_image(img)
	return _particle_texture


func _do_vector_call(low: String, arg_exprs: Array, my) -> float:
	if arg_exprs.size() < 2:
		return 0.0
	match low:
		"vec_set":
			_vec_put(arg_exprs[0], _vec_get(arg_exprs[1], my), my)
			return 0.0
		"vec_sub":
			_vec_put(arg_exprs[0], _vec_get(arg_exprs[0], my) - _vec_get(arg_exprs[1], my), my)
			return 0.0
		"vec_to_angle":
			# Acknex vec_to_angle(angle_out, dir_in): writes pan/tilt derived
			# from dir_in into angle_out BY REFERENCE, and returns dir_in's
			# length -- callers use the return value as a distance check
			# (`result = vec_to_angle(...); if (result < 25) { ... arrived
			# ... }`), not the angle itself. Same GS pan/tilt convention as
			# WdlDirector._apply_acknex_view()'s inverse (pan=0 -> +X).
			var dir := _vec_get(arg_exprs[1], my)
			var dist := dir.length()
			var pan := 0.0
			var tilt := 0.0
			if dist > 0.001:
				pan = rad_to_deg(atan2(dir.y, dir.x))
				tilt = rad_to_deg(atan2(dir.z, Vector2(dir.x, dir.y).length()))
			_vec_put(arg_exprs[0], Vector3(pan, tilt, 0.0), my)
			return dist
	return 0.0


## `move(entity, angle_delta, dist_delta)` -- a real Acknex engine builtin
## (WDL/move.wdl's own `function move` wraps lower-level primitives this
## port doesn't have; not in BRIDGE_OVER_SHARED_FUNCTIONS because no WDL
## script in the corpus actually redefines `move` itself, confirmed via
## `grep -n "^function move"` across the whole corpus -- nothing to shadow).
## `dist_delta` needs `_vec_get()`, not the generic per-arg `_eval()` every
## other builtin's arguments go through in `_call()` -- a bare vector-typed
## identifier like `fireball_speed` isn't a declared WDL global, so
## `_eval()`'s normal "id" path (`_get_var`) would silently read it as 0.0,
## same class of bug `vec_set`/`vec_sub`/`vec_to_angle` above are already
## special-cased for. Confirmed live (2026-08-01, Range): `action Spark`'s
## entire bullet-travel logic is `move(ME, nullskill, fireball_speed)`
## every tick -- without this, every fired shot stayed frozen at its spawn
## point forever, `enable_impact` proximity never had anything to detect.
## `angle_delta` is accepted but not applied: the one real corpus usage
## always passes a zero vector (`nullskill`), and `fireball_speed` is
## already a fully-rotated world/GS-space vector by the time it gets here
## (CreateSpark() rotates the base shot vector by the player's own pan/
## tilt/roll via vec_rotate() before create()), so there is nothing left
## for `move` itself to rotate in the only case that exists to verify
## against.
## `vec_rotate(vec, angle)` -- rotates `vec` (GS-space, by-reference like
## every other vec_* op) by `angle.pan/tilt/roll`, writing the result back
## into `vec`. Confirmed missing (2026-08-01, Range): `function
## CreateSpark()`'s entire aiming logic is `vec_rotate(shot_speed,
## my_angle)` after copying the player's own pan/tilt/roll into
## `my_angle` -- unimplemented, this was a silent no-op, so every fired
## shot kept the same fixed (200,0,0) GS direction regardless of where the
## player was actually aiming.
##
## Reuses `_acknex_entity_basis()` (already the one true pan/tilt/roll ->
## Godot-space-basis conversion in this file, used for entity transforms)
## rather than inventing a second rotation formula: converts `vec` to
## Godot space, applies the basis (its own local +X is "forward" at
## pan=tilt=roll=0, matching a GS `(N,0,0)` "N units forward" vector
## converted through `_gs_to_godot()` unchanged), converts back to GS.
func _do_vec_rotate(arg_exprs: Array, my) -> void:
	if arg_exprs.size() < 2:
		return
	var v_gs := _vec_get(arg_exprs[0], my)
	var angle_gs := _vec_get(arg_exprs[1], my)
	var basis := _acknex_entity_basis(angle_gs.x, angle_gs.y, angle_gs.z)
	var rotated := basis * _gs_to_godot(v_gs)
	_vec_put(arg_exprs[0], _godot_to_gs(rotated), my)


## Reported live (2026-08-10, Town): "there are no running cars." Traced
## past the earlier `_MOVEMODE` fix (Town's `SportCar` now correctly
## enters its own `while(my._MOVEMODE>0){...actor_move2();wait(1);}`
## walk loop) to a second, independent bug here: real Acknex's `move(ENT,
## dist, absdist)` takes TWO distinct vectors -- `dist` is relative to the
## entity's OWN current facing (pan/tilt/roll), `absdist` is a world-space
## delta (used for gravity/jump/external forces, already resolved to
## world axes by the caller) -- and applies BOTH. This only ever applied
## `absdist` (arg_exprs[2]), silently dropping `dist` (arg_exprs[1])
## entirely. That happened to be harmless for the corpus's other `move()`
## idiom (`move(ME,nullskill,fireball_speed)` -- projectiles, where the
## relative arg really is always zero) but breaks every ground-actor
## caller of the real `dist,absdist` pattern (Town's SportCar,
## WDL/actors.wdl-style `move_gravity2()` in Fight/Mount/Mine/Race/
## WDL/Cards.wdl/WDL/PWF.wdl): their entire forward speed is accumulated
## into `dist` (from `MY._SPEED_X`/`_SPEED_Y`, themselves driven by the
## `force` the script sets), while `absdist` stays ~0 for anything not
## jumping/falling -- so the entity's `global_position` never actually
## moved. Confirmed via a headless trace: a spawned TownCar sat frozen at
## its exact spawn point for 120+ frames even after the _MOVEMODE fix.
## Fixed by rotating `dist` into world space using the entity's own
## current pan/tilt/roll (the same `_acknex_entity_basis()` helper
## `_do_vec_rotate()` already uses for the identical local-to-world
## conversion) and adding both vectors, matching real Acknex's own
## contract instead of a partial approximation of it.
func _do_move_call(arg_exprs: Array, my) -> float:
	if arg_exprs.size() < 3:
		return 0.0
	var entity = _resolve_entity(arg_exprs[0], my)
	if entity == null or not is_instance_valid(entity):
		return 0.0
	var dist_gs := _vec_get(arg_exprs[1], my)
	var absdist_gs := _vec_get(arg_exprs[2], my)
	var pan := float(entity.get_meta("pan", 0.0))
	var tilt := float(entity.get_meta("tilt", 0.0))
	var roll := float(entity.get_meta("roll", 0.0))
	var basis := _acknex_entity_basis(pan, tilt, roll)
	var rel := basis * _gs_to_godot(dist_gs)
	entity.global_position += rel + _gs_to_godot(absdist_gs)
	return 0.0


func _ensure_paths_loaded() -> void:
	if _paths_loaded:
		return
	_paths_loaded = true
	if _loader == null:
		return
	for p in _loader.last_level_data.get("paths", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var pts: Array = p.get("points", [])
		var arr := PackedVector3Array()
		for pt in pts:
			if pt is Array and pt.size() >= 3:
				arr.append(Vector3(float(pt[0]), float(pt[1]), float(pt[2])))
		if arr.size() > 0:
			_paths_cache.append(arr)


func _set_target_from_path_point(my, godot_pt: Vector3) -> void:
	var gs := _godot_to_gs(godot_pt)
	my.set_meta("wdl_custom__target_x", gs.x)
	my.set_meta("wdl_custom__target_y", gs.y)
	my.set_meta("wdl_custom__target_z", gs.z)


## Binds `my` to the nearest point on the nearest path in the level and
## seeds `_TARGET_X`/`_TARGET_Y`/`_TARGET_Z` from it -- see the
## "scan_path"/"ent_nextpoint" comment in _register_builtins() for why a
## blind truthy stub wasn't enough. Returns 0.0 only if the level truly has
## no paths at all (still correctly gates `_MOVEMODE`-dependent logic in
## that genuine case).
func _do_scan_path(my) -> float:
	_ensure_paths_loaded()
	if typeof(my) == TYPE_NIL or not is_instance_valid(my) or _paths_cache.is_empty():
		return 0.0
	var pos: Vector3 = my.global_position
	var best_pts := PackedVector3Array()
	var best_idx := 0
	var best_d := INF
	for pts in _paths_cache:
		for i in pts.size():
			var d := pos.distance_to(pts[i])
			if d < best_d:
				best_d = d
				best_pts = pts
				best_idx = i
	if best_pts.is_empty():
		return 0.0
	my.set_meta("wdl_path_points", best_pts)
	my.set_meta("wdl_path_index", best_idx)
	_set_target_from_path_point(my, best_pts[best_idx])
	# Reported live (2026-08-10, Town): "there are no running cars" --
	# traced to Town.wdl's own `action SportCar` (the runtime-`create()`d
	# traffic car actor), whose `while (my._MOVEMODE > 0) { ...
	# actor_move2(); }` walk loop never ran at all: `_MOVEMODE` was never
	# written to a positive value anywhere in the script (only ever set
	# to 0 on the `result==0` "no path found" failure branch). Confirmed
	# via headless trace: cars spawn correctly via create(), but sit at
	# their spawn point for 120+ frames with zero movement. Compared
	# against the same `result=scan_path(...); if(result==0){my._MOVEMODE
	# =0;}` idiom in the 21 other corpus files that call scan_path
	# (Start/Fight/Race/AsyAct1/... ) -- every one of THOSE explicitly
	# writes `my._movemode = 1;` immediately BEFORE its own scan_path
	# call, which is what actually made them work; SportCar is the one
	# script in the corpus that omits it, relying on real Acknex's own
	# scan_path() to set _MOVEMODE on success as a side effect (a genuine
	# engine behavior this port's own scan_path stub never replicated).
	# Setting it here matches that real contract and is a strict superset
	# of the existing explicit-set convention -- every other caller
	# already sets the same value 1 itself first, so this is a no-op for
	# them and the missing piece for SportCar specifically.
	my.set_meta("wdl_custom__movemode", 1.0)
	return 1.0


func _do_ent_nextpoint(my) -> float:
	if typeof(my) == TYPE_NIL or not is_instance_valid(my):
		return 0.0
	var pts: PackedVector3Array = my.get_meta("wdl_path_points", PackedVector3Array())
	if pts.is_empty():
		return 0.0
	var idx := (int(my.get_meta("wdl_path_index", 0)) + 1) % pts.size()
	my.set_meta("wdl_path_index", idx)
	_set_target_from_path_point(my, pts[idx])
	return 0.0


func _do_stop_sound(a: Array) -> float:
	if a.size() > 0:
		AudioChannels.stop_sfx_handle(_to_num(a[0]))
	return 0.0


## caller (the `my` that called GetPosition(Voice), or the literal `null`
## key for calls with no entity, e.g. from `main()`) -> {site_id ->
## generation that (caller, call site) has already observed as
## "finished"}. See _do_get_voice_position() and _call_site_id().
var _voice_finished_consumed_by: Dictionary = {}
## Assigns each distinct `GetPosition(...)` call SITE in the parsed AST
## a stable integer id, stamped directly onto that call node's own
## dictionary (`_site_id`) the first time it's evaluated -- the AST is
## parsed once and never recreated, so every future `_eval()` of the
## exact same node sees the same stamp. See _do_get_voice_position()'s
## own comment for why one caller can have MULTIPLE independent sites.
var _next_call_site_id := 0


func _call_site_id(node: Dictionary) -> int:
	if not node.has("_site_id"):
		node["_site_id"] = _next_call_site_id
		_next_call_site_id += 1
	return int(node["_site_id"])
## GB-1 investigation heartbeat -- see _do_get_voice_position()'s own comment.
var _voice_poll_heartbeat: Dictionary = {}
## GB-1 investigation heartbeat -- see _get_field()'s "Dialog"/"visible" comment.
var _dialog_visible_read_heartbeat: Dictionary = {}


## Per-CALLER, per-GENERATION debounce of `GetPosition(Voice)`'s "finished"
## reading -- NOT a single frame-global flag (that was tried 2026-07-30 and
## caused a worse bug, see the 2026-07-31 correction below). Two different
## WDL idioms share this one value and need different things from it:
##   A) `while (GetPosition(Voice) < 1000000) { wait(1); }` -- a blocking
##      wait for exactly one specific line. Works fine with the value
##      staying "finished" for as long as it takes the caller to notice.
##   B) `if (GetPosition(Voice) >= 1000000) { Scene = Scene + 1; SetVoice();
##      }` inside a perpetual `while(1){...wait(1);}` -- a one-shot poll
##      that must fire (at most) once per real completion, since once
##      `SetVoice()` runs out of Scene values to handle it becomes a no-op
##      that never starts a new line, so an un-debounced read would re-fire
##      this every single subsequent frame forever.
## 2026-07-30 (Start, LookAtMe): two entities both running idiom B on the
## same completion, in the same frame, both got "finished" and both
## incremented Scene -- fixed then with a single frame-global "only the
## first caller this frame wins" flag.
## 2026-07-31 correction (Studio, ShikKlik/Naknik): that frame-global flag
## has a fatal flaw once a THIRD, always-polling-every-frame caller
## (Naknik's own idiom-B poll, running from level start) is competing with
## a LATER-started caller (ShikKlik's idiom-A wait, started on click) --
## Naknik is structurally always resumed first each frame, so it always
## wins the single global slot, and ShikKlik's own wait loop NEVER once
## sees "finished", forever. Confirmed live via tools/smoke_studio_shikklik.gd:
## `Talking` stuck at 3.0 and `Run("Shiks.exe")` never fired for 40+ real
## seconds. Fixed by keying consumption per (caller, generation) instead of
## per frame: each caller gets its own independent "have I seen THIS
## specific line's completion yet" state, so a late-starting caller is
## never starved by an earlier, more eager one, while a single caller that
## keeps polling after already consuming a generation still only acts once
## per real completion (idiom B stays correctly single-shot; idiom A exits
## the moment it sees its own first "yes", which is still guaranteed since
## nothing else can consume vs it -- consumption is per-caller, not shared).
## 2026-08-08 correction (Plane3, GB-15): "getting stuck mid flight...
## the game is stuck." `action Dome`'s own perpetual Scene-progression
## poll (`if (Scene > -1) { if (GetPosition(Voice) >= 1000000) {
## Scene = Scene + 1; SetVoice(); } }`, runs unconditionally every tick)
## and its OWN dialogue-choice resolution (`if (DialogIndex == 6) {
## ...; while (GetPosition(Voice) < 1000000) { wait(1); } ...}`) are TWO
## textually-distinct `GetPosition(Voice)` call sites -- but BOTH run on
## the SAME entity (`my` = the Dome node), so the per-CALLER debounce
## above still let them collide: once a NEW voice line (e.g. a picked
## dialogue choice's own line) finished, whichever of the two happened
## to be evaluated first that tick "consumed" the generation for BOTH,
## permanently starving the other -- confirmed live via a headless
## trace: `Dude` (only ever set once the second dialogue's own two-line
## choice branch runs to completion) never changed from its default 3.0
## across 70 simulated seconds, well past how long those two real voice
## lines take to finish. Not Plane3-specific: any single entity with
## more than one independent GetPosition(Voice) poll in its own
## coroutine has the same exposure. Fixed by keying consumption per
## (caller, call SITE, generation) -- see _call_site_id() -- instead of
## per (caller, generation) alone, so two unrelated polls sharing a
## caller no longer compete for the same single slot.
func _do_get_voice_position(my, site_id: int) -> float:
	var progress := AudioChannels.get_voice_progress()
	# GB-1 heartbeat: once every ~60 calls (roughly 1/sec at 60fps) per
	# (caller, site), so a real session shows whether this is even being
	# polled, and whether progress is climbing, frozen, or stuck at the
	# already-consumed 999999 sentinel -- without flooding the log every
	# single tick.
	var who_hb := str(my.name) if (my != null and is_instance_valid(my)) else "<null>"
	var hb_key := "%s#%d" % [who_hb, site_id]
	var hb_count := int(_voice_poll_heartbeat.get(hb_key, 0)) + 1
	_voice_poll_heartbeat[hb_key] = hb_count
	if hb_count % 60 == 1:
		PiposhDebug.log_msg("dialog-choice", "VOICE_POLL by=%s site=%d progress=%.4f is_playing=%s generation=%d" % [
			who_hb, site_id, progress, AudioChannels.is_voice_playing(), AudioChannels.get_voice_generation()
		])
	if progress >= 1.0:
		var gen: int = AudioChannels.get_voice_generation()
		var sites: Dictionary = _voice_finished_consumed_by.get(my, {})
		if sites.get(site_id, -1) == gen:
			return 999999.0
		sites[site_id] = gen
		_voice_finished_consumed_by[my] = sites
		PiposhDebug.log_msg("dialog-choice", "VOICE_FINISHED first-seen-by=%s site=%d generation=%d" % [who_hb, site_id, gen])
	return progress * 1000000.0


func _resolve_arg_entity(a: Array, idx: int, my):
	# Untyped return + is_instance_valid() before the `is Node3D` check --
	# same reason as _entity_alive(): `a[idx]` can be a dangling reference
	# (e.g. `remove(my)` evaluates its `my` argument to the same entity a
	# sibling coroutine is mid-removing), and both a typed return value and
	# the `is` operator's left-hand side can themselves throw ("previously
	# freed instance") on one, confirmed via tools/smoke_remove_race.gd.
	if idx < a.size() and is_instance_valid(a[idx]) and a[idx] is Node3D:
		return a[idx]
	return my


## See _do_actor_move()'s own "wdl_auto_walk_anim" comment for the full
## story: "Stand" is excluded here because it's the corpus-wide idle/
## default reset pose (Blink()'s own unconditional per-tick call), not a
## deliberate override -- everything else stamps a per-tick marker so
## actor_move()'s generic walk fallback knows a real, specific pose
## already won this exact tick and shouldn't be stomped.
func _do_anim_frame(a: Array, my) -> float:
	if a.size() < 2 or not is_instance_valid(my):
		return 0.0
	var anim := my.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.play_frame(str(a[0]), _to_num(a[1]))
		if str(a[0]).to_lower() != "stand":
			my.set_meta("wdl_last_real_anim_frame", _total_frames)
	return 0.0


func _do_anim_cycle(a: Array, my) -> float:
	if a.size() < 1 or not is_instance_valid(my):
		return 0.0
	var anim := my.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.play_cycle(str(a[0]), _to_num(a[1]) if a.size() > 1 else 0.0)
		if str(a[0]).to_lower() != "stand":
			my.set_meta("wdl_last_real_anim_frame", _total_frames)
	return 0.0


func _do_talk(my) -> float:
	if not is_instance_valid(my):
		return 0.0
	var anim := my.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.play_talk()
	return 0.0


func _do_talk_skins(my, enabled: bool) -> float:
	if not is_instance_valid(my):
		return 0.0
	var anim := my.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.enable_talk_skins(enabled)
	return 0.0


func _do_blink(my) -> float:
	if not is_instance_valid(my):
		return 0.0
	var anim := my.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.play_blink()
	return 0.0


func _do_morph(a: Array, my) -> float:
	if a.size() < 1:
		return 0.0
	var target = _resolve_arg_entity(a, 1, my)
	if target == null:
		return 0.0
	var anim := target.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim == null:
		return 0.0
	anim.morph_to(String(a[0]).get_basename())
	return 0.0


func _do_remove(a: Array, my) -> float:
	var target = _resolve_arg_entity(a, 0, my)
	if target == null or not is_instance_valid(target):
		return 0.0
	if target.has_meta("wdl_removed"):
		# Idempotency guard -- root cause reproduced 2026-07-30
		# (docs/SESSION_LOG.md, tools/smoke_remove_race.gd): the standard
		# WDL shape `action X { while(1){ if(cond){remove(my);} wait(1); } }`
		# plus a click-triggered handler that *also* removes the same
		# entity (e.g. WDL/Afgan.wdl's AFG_Card checking `AFG[my.skill1]`
		# and AFG_Take setting that same flag right before its own
		# `remove(my)`) means `remove()` can legitimately be called *twice*
		# on one entity within the same synchronous burst -- once from the
		# click handler, once from the persistent coroutine's own next
		# iteration re-observing the flag it just set. The second
		# queue_free() on an already-queued node is what actually corrupts
		# it into a state where is_instance_valid()/is_inside_tree() both
		# still read true, yet passing that same reference into any other
		# Node3D-typed parameter (e.g. _eval()) crashes the engine outright.
		# Making removal a no-op past the first call is the real fix;
		# _entity_alive()'s meta check remains as defense for the ordinary
		# (non-reentrant, already-fully-freed) case.
		return 0.0
	target.set_meta("wdl_removed", true)
	target.queue_free()
	return 0.0


## Reported live (2026-08-10): "there's an animation that should run on
## a big screen in the smash WDL that's just a single picture now" --
## traced to Smash.wdl's own wart mini-game (`DialogChoice==3` inside
## `DialogIndex==8`): its "wart counter" panel (`pWart.bmap=...`, a real
## 2D overlay) already updates correctly through the existing panel-bmap
## bridge (confirmed directly: calling `_set_panel_field` with each of
## Wart1..Wart7 in turn genuinely swaps the rendered texture) -- the
## actual missing piece is the wart CREATURES themselves, spawned via
## `create(<Wart.pcx>,camera.x,Warty);` inside the same loop. `create()`
## only ever resolved its 1st argument against `assets/converted/mdl/
## {stem}.glb` -- a `.pcx`/bitmap argument (Acknex's own "spawn a sprite,
## not a full 3D model" idiom, confirmed corpus-wide: `WDL/doors.wdl`'s
## arrow marker, `WDL/venture.wdl`'s blood splats/fireballs, `WDL/war.wdl`'s
## target-loc arrow all use the identical shape) silently failed to
## resolve and returned null every time -- so the whole "screen" (really
## the special `wartcamx` camera view this scene cuts to) showed nothing
## moving at all except the counter icon, reading as "just a single
## picture" instead of the intended animated wart-critter scene.
func _do_create(a: Array, my) -> Node3D:
	if a.size() < 1 or _loader == null:
		return null
	var stem := String(a[0]).get_basename()
	var path := "res://assets/converted/mdl/%s.glb" % stem
	var inst: Node3D = null
	var is_sprite := false
	if ResourceLoader.exists(path):
		var packed := load(path)
		if not (packed is PackedScene):
			return null
		inst = (packed as PackedScene).instantiate() as Node3D
	else:
		var sprite_tex := _resolve_gfx_texture_by_stem(stem)
		if sprite_tex == null:
			return null
		is_sprite = true
		var spr := Sprite3D.new()
		spr.name = "Sprite"
		spr.texture = sprite_tex
		# Acknex's own bitmap-`create()` entities are always billboard
		# sprites (real per-instance "facing" props like Smash's own
		# Warty, WDL/venture.wdl's blood splats) -- there's no 3D geometry
		# to orient any other way.
		spr.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		spr.shaded = false
		spr.pixel_size = 0.5
		inst = spr
	if inst == null:
		return null
	var parent: Node = (my.get_parent() if my else null)
	if parent == null:
		parent = _loader.get_node_or_null("Entities")
	if parent == null:
		return null
	parent.add_child(inst)
	# a[1] is the entity `create()`'s 2nd argument named (see _call()'s
	# "create" 2nd-arg comment) -- spawn there when resolvable, `my` only
	# as the pre-existing fallback (bare `create(<X.mdl>, my.x, Action)`
	# calls still resolve a[1] to `my` itself, so this is a strict
	# superset of the old behavior, not a narrowing).
	var pos_source: Node3D = (a[1] if a.size() > 1 and a[1] is Node3D and is_instance_valid(a[1]) else my)
	inst.global_transform = pos_source.global_transform if pos_source else Transform3D.IDENTITY
	# See `_reset_entity_to_spawn()`'s own comment -- WmbLevelLoader sets
	# this for every level-placed entity, but a runtime `create()`'d one
	# never goes through that spawn path at all. Without it, a retry
	# reset would have nothing to put a runtime-created entity back to.
	inst.set_meta("wdl_spawn_position", inst.global_position)
	if not is_sprite:
		var anim := MdlAnimator.new()
		anim.name = "MdlAnimator"
		inst.add_child(anim)
		anim.setup_from_stem(stem, inst)
	inst.set_meta("action", str(a[2]) if a.size() > 2 else "")
	inst.set_meta("wdl_skills", [])
	var action := str(inst.get_meta("action", ""))
	# GB-8 continued (2026-08-07, Range): "can we remove the bullets and
	# just check if the mouse clicked on the target or not?" Replaces
	# Range/Final/Shooter/InShrine's shared physical-bullet-travel model
	# (`ACTION Spark`: `move()` every tick + this port's own approximate
	# impact-zone proximity check, the whole thing this session's other
	# GB-8 rounds spent so long making merely reliable) with a single,
	# instant raycast along the exact direction `CreateSpark()` already
	# computed. Reads the `shot_speed` global vector directly -- every
	# one of those four levels' own `CreateSpark()` rotates it via
	# `vec_rotate()` immediately before calling `create()`, so this needs
	# no per-level knowledge (Shooter's own extra crossbow-delay/
	# animation logic all runs BEFORE `create()` and is untouched; only
	# what happens once a "Spark" actually exists changes). Uses Godot's
	# own real physics raycast against the same real mesh collision
	# shapes `_add_mesh_collision()` already builds for every solid
	# entity and wall -- pixel-precise against the actual model, not an
	# approximation, so it's naturally immune to every collision-
	# precision issue this session chased (self-kill at spawn, non-
	# physical markers, ignored height, radius sizing). The bullet
	# entity itself is never kept around -- no coroutine, no visible
	# presence, matching the request literally.
	if action.to_lower() == "spark":
		_do_spark_hitscan(inst)
		inst.queue_free()
		return null
	# GB-15 continued (2026-08-08, Plane3): "getting stuck mid flight
	# where the vase is." Traced past the earlier GetPosition(Voice)
	# debounce fix to a second, independent bug in the SAME "bird catches
	# the vase" sequence: `action BadBird`'s own resolution calls
	# `_gib(20);` (WDL/war.wdl's shared, portable gib-debris helper --
	# `function _gib(numberOfParts) { ...; create(<gibbit.mdl>, MY.POS,
	# _gib_action); ... }`), passing `_gib_action` -- ALSO declared via
	# `function`, not `action` -- as create()'s own 3rd argument. Only
	# `_resolve_action()` was ever tried here, so a function used this
	# way (a real, portable WDL idiom -- Acknex has no separate
	# "action" vs. "callable" concept, either kind of named block can be
	# create()'s own initial-action argument, matching how exec_stmt()'s
	# own "expr_stmt" case already treats an ACTION invoked like a bare
	# function call as equally valid the other way around) resolved to
	# nothing, so the entity got no coroutine started at all -- not a
	# crash, just a silently inert prop with an `action` meta pointing
	# at nothing that ever ran. Confirmed this doesn't crash or block
	# `_gib(20)`'s own calling coroutine on its own (BadBird's while
	# loop's own `create()` calls all still return normally) -- but see
	# `docs/SESSION_LOG.md` for why fixing this (alongside the earlier
	# debounce fix) was needed before the whole sequence could reach
	# `Run("Smash.exe")` at all.
	var resolved_action := _resolve_action(action) if action != "" else ""
	if resolved_action != "":
		_run_coroutine(_actions[resolved_action].get("body", {}), inst)
	elif action != "":
		var resolved_fn := _resolve_function(action)
		if resolved_fn != "":
			_run_coroutine(_functions[resolved_fn].get("body", {}), inst)
	return inst


## See `_do_create()`'s own "Spark" comment.
func _do_spark_hitscan(inst: Node3D) -> void:
	var dir_gs: Vector3 = _vec_get({"t": "id", "name": "shot_speed"}, null)
	var dir: Vector3 = _gs_to_godot(dir_gs)
	var origin: Vector3 = inst.global_position
	PiposhDebug.log_msg("range-shot", "FIRED pos=%s" % origin)
	if dir.length() < 0.01 or inst.get_world_3d() == null:
		PiposhDebug.log_msg("range-shot", "MISS (no aim direction)")
		return
	dir = dir.normalized()
	var space_state := inst.get_world_3d().direct_space_state
	# GB-8 continued (2026-08-07, Range): confirmed live via
	# smoke_range_hitscan_check.gd that a bare raycast from the shooter's
	# own position immediately hits `action Handgun` -- the first-person
	# weapon view-model, which (like any ordinary MDL entity) gets a real
	# collision shape from `_add_mesh_collision()`, but was never meant
	# to physically block its own gunfire (the same class of problem the
	# old bullet-travel model's own pre-seed fix solved for "whatever is
	# already touching the shot at its own origin"). Generic fix, not
	# Handgun-specific: an entity that never called `enable_impact` (no
	# `wdl_event`) never opted into interacting with impacts at all --
	# skip past it and keep tracing.
	#
	# Also confirmed live: even past the Handgun, several real (non-
	# clamped-tilt) far targets still came back "HIT geometry (no
	# entity)" partway there -- the old `move()`-based bullet never
	# checked wall/brush collision AT ALL (`_do_move_call()` is a bare
	# position add, see its own comment), so nothing in Range's own
	# shooting booth (the counter/rail the player looks out over) ever
	# blocked a shot before, even though it's real, solid level geometry.
	# Switching to a real raycast made that geometry suddenly solid for
	# gunfire for the first time -- not a bug in the raycast itself, but
	# a real behavior change from the system it replaced, and one that
	# would make FAR targets specifically harder to hit again (a shallow-
	# angle shot toward a far target stays close to the counter's own
	# height for longer than a steep shot toward a near one). Skip past
	# pure geometry too, matching the old system's own permissiveness,
	# so only an actual impact-enabled entity (or running out of range)
	# ever stops a shot -- same reasoning as skipping non-event entities
	# above, just extended to non-entity colliders too. Capped iteration
	# count as a safety net against a pathological chain of skippable
	# colliders either way.
	var exclude: Array[RID] = []
	for _i in 20:
		var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * 5000.0)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		query.exclude = exclude
		var result := space_state.intersect_ray(query)
		if result.is_empty():
			PiposhDebug.log_msg("range-shot", "MISS (no collision)")
			return
		var entity := _find_entity_ancestor(result.get("collider") as Node)
		var dist: float = origin.distance_to(result.get("position"))
		if entity == null:
			PiposhDebug.log_msg("range-shot", "geometry at %s dist=%.1f (not solid for gunfire, skipping past)" % [
				result.get("position"), dist,
			])
			exclude.append(result.get("rid"))
			continue
		var event_name := str(entity.get_meta("wdl_event", ""))
		if event_name == "":
			exclude.append(result.get("rid"))
			continue
		if _entity_alive(entity):
			PiposhDebug.log_msg("range-shot", "HIT entity=%s event=%s dist=%.1f" % [entity.name, event_name, dist])
			invoke_event(entity, event_name)
		else:
			PiposhDebug.log_msg("range-shot", "HIT entity=%s (not alive) dist=%.1f" % [entity.name, dist])
		return
	PiposhDebug.log_msg("range-shot", "MISS (too many non-impact colliders in the way)")


## See `_do_spark_hitscan()`'s own comment. Walks up from a raycast
## collider (a `_add_mesh_collision()`-built `StaticBody3D`, nested
## under the mesh, under the entity root) to the entity root itself --
## the node every other part of this file already keys off of, marked
## by carrying `action` meta (see `WmbLevelLoader._spawn_entity()`).
func _find_entity_ancestor(node: Node) -> Node3D:
	var n := node
	while n != null:
		if n is Node3D and n.has_meta("action"):
			return n as Node3D
		n = n.get_parent()
	return null


func _do_run(a: Array) -> float:
	if a.size() < 1:
		return 0.0
	var target := String(a[0]).get_basename()
	LevelRouter.goto_level(target)
	# Real Acknex's Run() unloads the current level immediately -- this
	# level's own script must stop running right away, not keep executing
	# for however many frames the actual scene swap takes to land.
	# _running is the same flag _exit_tree() sets (every exec_stmt() checks
	# it before each statement); without setting it here too, other still-
	# suspended coroutines on this level keep running in that gap. Found
	# via a real "scene doesn't move to the next one, loops forever"
	# report on Start (2026-07-30): two `LookAtMe` coroutines both poll
	# the same Voice-finished state, and once Scene passed the values
	# `SetVoice()` handles, GetPosition(Voice) stayed permanently
	# "finished" -- both kept incrementing Scene once per frame forever,
	# racing straight past the `if (Scene==6) { Run("Menu.exe"); }` check
	# meant to catch it (Scene never rested on exactly 6 long enough for
	# either coroutine's own check to see it) because Run() hadn't
	# actually stopped anything yet when it was first (correctly) called.
	_running = false
	return 0.0


## See _register_builtins()'s own "file_open_write" comment for the full
## story. `_file_handles` isn't cleared on level teardown -- a handle is
## just a float key into a small Dictionary of `FileAccess` objects, and
## a leftover entry after a level ends is harmless (nothing will ever
## reuse that exact handle number once `_next_file_handle` has moved
## past it, and the interpreter instance itself is freed with its own
## level anyway).
var _file_handles: Dictionary = {}
var _next_file_handle := 1.0


func _do_file_open(filename: String, write: bool) -> float:
	if filename == "":
		return 0.0
	# Acknex paths are corpus-authored with backslashes (`"Prefs\\Flag.txt"`)
	# -- real on this port's own target platforms (Windows/Android/etc)
	# too, but `user://` always wants forward slashes.
	var rel := filename.replace("\\", "/")
	var path := "user://" + rel
	if write:
		var dir_path := path.get_base_dir()
		if dir_path != "user:/" and dir_path != "user://":
			DirAccess.make_dir_recursive_absolute(dir_path)
	var f := FileAccess.open(path, FileAccess.WRITE if write else FileAccess.READ)
	if f == null:
		return 0.0
	var handle := _next_file_handle
	_next_file_handle += 1.0
	_file_handles[handle] = f
	return handle


func _do_file_asc_write(a: Array) -> float:
	if a.size() < 2 or not _file_handles.has(a[0]):
		return 0.0
	var f: FileAccess = _file_handles[a[0]]
	f.store_line(str(_to_num(a[1])))
	return 0.0


func _do_file_asc_read(a: Array) -> float:
	if a.size() < 1 or not _file_handles.has(a[0]):
		return 0.0
	var f: FileAccess = _file_handles[a[0]]
	if f.eof_reached():
		return 0.0
	var line := f.get_line().strip_edges()
	return float(line) if line.is_valid_float() else 0.0


func _do_file_close(a: Array) -> float:
	if a.size() < 1 or not _file_handles.has(a[0]):
		return 0.0
	var f: FileAccess = _file_handles[a[0]]
	f.close()
	_file_handles.erase(a[0])
	return 0.0


## See _register_builtins()'s "level_load" comment. Every level's own
## main() calls this near its top as a "(re)load my map" step;
## WmbLevelLoader already loaded the level once before main() ever runs,
## so for a genuinely fresh level start this is correctly a no-op.
##
## GB-5 (2026-08-03, Range): `Death` (gates `Restart()`'s own guard) was
## only ever reset once, at `action CamTarget`'s initial coroutine start
## -- never again -- so a second death never showed RIP again. Reset it
## alone, narrowly -- an earlier attempt at this reset EVERY declared
## global back to its initial value (mirroring setup()'s own init loop)
## and was confirmed live as too broad: `var MoviePlaying = 1;` is
## Range's own declared default, only ever set to 0 once the intro
## dialogue finishes, so a blanket reset re-triggered the ENTIRE intro
## dialogue on every retry, rendered on top of the still-running
## shooting-gallery view underneath (action CamTarget's own coroutine,
## started once at level load, is never stopped or restarted by a second
## main() call, so it keeps driving camera.pan/tilt throughout). Real
## Acknex script globals are process-persistent across a level_load() by
## design -- no shipped game would replay its own intro on every retry.
##
## GB-7 continued (2026-08-04, Range): tried also resetting the camera's
## spawn pan/tilt/roll here (this call sits inside `main()`, right where
## the ORIGINAL WDL's own `level_load("Range.wmb");` line sits) -- wrong
## call site for that specifically: `main()` reaches this only AFTER its
## own opening `wait(3);`, but `action CamTarget` resumes ticking (once
## unfrozen -- see _set_panel_field()'s "visible" case) well BEFORE that
## wait clears, so the camera reset landing here still left a stale/live
## gap where CamTarget kept responding to live mouse input on the
## pre-death orientation, then SNAPPED once this finally landed. Moved
## camera-pose reset to `_reset_camera_spawn_pose()`, called synchronously
## at the SAME moment `pRIP` hides (no gap, no snap) -- `Death` has to
## stay HERE, deferred, though, for the opposite reason: resetting it that
## early raced against `Health` (only reset by main()'s OWN subsequent
## `Health = 609;` statement, further still behind the same wait(3) gap)
## -- with `Death` reset back to 0 early but `Health` still <= 0`,
## `action CamTarget`'s own `updatepanel()` -> `Restart()` call
## (`if (Death==0) { Death=1; ShowRIP(); }`) would fire again immediately,
## re-showing RIP right after the player had just retried. Keeping `Death`
## reset in the same synchronous burst as `Health = 609;` (both inside
## main()'s own single, non-yielding run of statements, no wait() between
## them) is what makes the original WDL script itself race-free here --
## reproducing that ordering natively is what keeps this port race-free
## too.
func _do_level_load() -> float:
	if _globals.has("Death"):
		_globals["Death"]["value"] = 0.0
	return 0.0


## GB-7 continued (2026-08-04, Range): "on retry we should restart the
## position of the cursor as well... [and] messes with the view." Called
## synchronously the instant `pRIP` transitions from visible to hidden
## (see _set_panel_field()'s "visible" case, and `_do_level_load()`'s own
## comment for why `Death`'s reset has to stay separate/deferred instead
## of also living here). The `player` global is bound to whichever entity
## is driving the scripted camera (Range's own `action CamTarget`:
## `player = my;`, its own first line) -- reset its live pan/tilt/roll
## back to their WED-authored spawn values (`_spawn_entity()`'s own
## `wdl_spawn_pan/tilt/roll` meta, preserved separately from the live,
## per-tick-accumulated `pan/tilt/roll` meta). Resolved generically
## through `player`, not by Range's own action name, so this applies to
## any level using the same scripted-camera-aiming idiom. Goes through
## `_set_entity_tilt_roll()`/`_set_entity_pan()` themselves (not a direct
## `set_meta()` poke) so the node's actual `global_transform` snaps to the
## spawn pose immediately, rather than staying stale until CamTarget's
## own next `my.pan = ...` tick happens to rebuild it.
func _reset_camera_spawn_pose() -> void:
	var p = _get_var("player", null)
	if p != null and is_instance_valid(p) and p is Node3D:
		var spawn_pan: float = float(p.get_meta("wdl_spawn_pan", p.get_meta("pan", 0.0)))
		var spawn_tilt: float = float(p.get_meta("wdl_spawn_tilt", p.get_meta("tilt", 0.0)))
		var spawn_roll: float = float(p.get_meta("wdl_spawn_roll", p.get_meta("roll", 0.0)))
		_set_entity_tilt_roll(p, spawn_tilt, spawn_roll)
		_set_entity_pan(p, spawn_pan)


## GB-7 continued (2026-08-07, Range): "restarting the stage after dying
## should reset the enemies on screen as well." Real Acknex's own
## `level_load()` genuinely respawns every entity fresh; this port's own
## `level_load()` is a no-op (the level's already loaded, see
## `_do_level_load()`'s own comment) and nothing else ever restarted an
## already-popped-up Terrorist/Civilian's own `Pop`/`Dying`/`GoingUp`/
## `OriginalZ` state or its live position -- once hit or mid-animation
## at the moment of death, it stayed exactly that way through a retry.
## Called alongside `_reset_camera_spawn_pose()` (same trigger, same
## synchronous burst -- see `_set_panel_field()`'s "visible" case) for
## every OTHER entity in the level (the `player`/camera entity keeps
## going through its own dedicated reset above, not this one, so it
## isn't double-handled). Generic, not Terrorist/Civilian-specific --
## see `_reset_entity_to_spawn()`'s own comment for what actually gets
## reset and why.
func _reset_all_entities_to_spawn() -> void:
	if _loader == null:
		return
	var entities: Node = _loader.get_node_or_null("Entities")
	if entities == null:
		return
	var p = _get_var("player", null)
	for node in entities.get_children():
		if not (node is Node3D) or node == p or not is_instance_valid(node):
			continue
		_reset_entity_to_spawn(node)


## See `_reset_all_entities_to_spawn()`'s own comment. First implementation
## of this only reset `wdl_skills` (this file's storage for direct numeric
## `my.skillN` access) and was confirmed live (via a real Terrorist forced
## into a hit state, then retried) to do NOTHING for `Pop`/`Dying`/
## `GoingUp`/`Type`/`OriginalZ` at all: `define Pop,skill20;` (Range.wdl's
## own top, one line per named field) is Acknex's real compile-time
## alias-macro convention, but this port's own parser (`tools/
## parse_wdl.py`'s "define" case) treats every `define NAME,VALUE;` as an
## ordinary GLOBAL VARIABLE declaration instead of an alias table --
## reasonable for the one case that motivated it (`WDL/movement.wdl`'s
## `_MODE_WALKING`/`_MODE_STILL`, genuine constants), wrong for this one.
## Since no alias resolution happens at parse time, `my.Pop` never
## becomes `my.skill20` in the AST -- it stays a field access literally
## named "Pop", which `_get_field()`/`_set_field()`'s generic fallback
## (see their own "Generic custom-field fallback" comments) stores as its
## own independent `wdl_custom_pop` meta key, completely disconnected
## from the `skills`/`wdl_skills` array.
##
## Second implementation blanket-ERASED every `wdl_custom_*` key instead
## of restoring a snapshot, and was ALSO confirmed live as wrong, in the
## opposite direction: "after the first reset, the character heads are
## not moving up... as they were." `action Terrorist`'s own body sets
## `my.OriginalZ = my.z;` (its resting height, read back by both the
## "pop up" and "duck back down" branches every tick) as a genuine ONE-
## TIME init, executed once, synchronously, before its first `wait()` --
## the coroutine itself is never restarted on retry (only `main()` is),
## so nothing ever runs that line again. Erasing `wdl_custom_originalz`
## left it permanently reading back as the generic `0.0` default after
## the first retry, so `if (my.z > my.OriginalZ+60)` / `if (my.z <
## my.OriginalZ)` -- the pop-up/duck-down thresholds -- silently broke
## for good. Fixed by capturing a real snapshot instead of guessing at
## "erased == freshly spawned": `begin_level()` now records EVERY
## `wdl_custom_*` key (and `wdl_skills`) right after `_run_coroutine()`
## returns for each entity -- since coroutines run synchronously up to
## their first real `wait()`, that snapshot reflects exactly what the
## action's own one-time init already computed (`OriginalZ` included),
## not a blind guess at what "reset" should mean. Reset now restores
## from that snapshot; still generic, not Terrorist/Civilian-specific.
func _reset_entity_to_spawn(node: Node3D) -> void:
	if node.has_meta("wdl_spawn_position"):
		node.global_position = node.get_meta("wdl_spawn_position")
	# GB-9 continued (2026-08-08, Range): "after retry... we see the gun
	# and the hand in front of us instead of first person POV like before
	# the retry." This reset puts the entity's position back at its raw,
	# un-pulled WMB spawn point (the line above) -- correct for every
	# OTHER entity, but for a `near`-flagged weapon view-model that spawn
	# point is deliberately wrong, only ever meant to be a STARTING point
	# for `_near_weapon_adjusted_position()`'s own one-time pull. That
	# pull is guarded by `wdl_near_applied` so it can't reapply itself
	# every tick (see its own comment for why) -- but nothing ever
	# cleared the guard on retry, so the pull didn't get a chance to
	# reapply either: the reset undid the pull, and the guard then
	# permanently blocked redoing it, leaving the weapon stuck at its
	# far/full-view spawn position for the rest of that playthrough.
	# Clearing both here re-arms it exactly like a fresh level load --
	# `action Handgun`'s own still-running `while(1)` loop writes
	# `my.pan`/`my.roll` every tick regardless of retry (its coroutine is
	# never restarted, only unfrozen), so `_set_entity_pan()`/
	# `_set_entity_tilt_roll()` will pull it close again on the very next
	# tick.
	if node.has_meta("wdl_near"):
		node.set_meta("wdl_near_applied", false)
		node.set_meta("wdl_near_activated_frame", Engine.get_process_frames())
	var spawn_pan: float = float(node.get_meta("wdl_spawn_pan", node.get_meta("pan", 0.0)))
	var spawn_tilt: float = float(node.get_meta("wdl_spawn_tilt", node.get_meta("tilt", 0.0)))
	var spawn_roll: float = float(node.get_meta("wdl_spawn_roll", node.get_meta("roll", 0.0)))
	_set_entity_tilt_roll(node, spawn_tilt, spawn_roll)
	_set_entity_pan(node, spawn_pan)
	if node.has_meta("wdl_spawn_skills"):
		node.set_meta("wdl_skills", (node.get_meta("wdl_spawn_skills", []) as Array).duplicate())
	for key in node.get_meta_list():
		if String(key).begins_with("wdl_custom_"):
			node.remove_meta(key)
	var snapshot: Dictionary = node.get_meta("wdl_spawn_custom_fields", {})
	for key in snapshot:
		node.set_meta(key, snapshot[key])
	# `skin` (Range's own hit-reaction skin swap, `my.skin = my.base + 2;`)
	# is its OWN dedicated meta key too, not a `wdl_custom_*` one -- see
	# _get_field()/_set_field()'s own "skin" case. No level in the corpus
	# gives an entity a real spawn-time skin override (grepped: `skin` is
	# only ever WRITTEN by scripts at runtime, never read from WED spawn
	# data), so erasing it back to unset (reads back as the same `1.0`
	# default every entity starts at) is the correct "as if freshly
	# spawned" value, not just a guess.
	if node.has_meta("skin"):
		node.remove_meta("skin")


## See `_reset_entity_to_spawn()`'s own comment for why/when this is
## captured. `{key: value}` for every `wdl_custom_*` meta currently on
## `node` -- a generic, name-agnostic snapshot, not a Range-specific
## field list.
func _snapshot_custom_fields(node: Node3D) -> Dictionary:
	var snapshot := {}
	for key in node.get_meta_list():
		if String(key).begins_with("wdl_custom_"):
			snapshot[key] = node.get_meta(key)
	return snapshot


## See _set_panel_field()'s "visible" case and recenter_aim()'s own
## comment for the two callers. `Input.warp_mouse()` expects window-local
## pixel coordinates, not design-space -- unlike every panel's own
## pos_x/pos_y, which is why this doesn't go through GameHud.DESIGN.
## Also arms `_mouse_delta_suppress_frames` -- see its own comment for
## why a warp needs a multi-frame guard, not just a same-frame clear.
func _warp_mouse_to_center() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	Input.warp_mouse(vp.get_visible_rect().size / 2.0)
	_mouse_delta_suppress_frames = 3
	_mouse_delta = Vector2.ZERO
	_vectors["mickey"] = Vector3.ZERO


## QOL (2026-08-04, Range): "adding a button - space - that resets the
## cursor to the middle of the screen." A player who's turned all the way
## around chasing a target has no way back to a known-good orientation
## short of dying and retrying (which already resets it -- see
## `_reset_camera_spawn_pose()`) -- exposed the same reset as an explicit,
## anytime action instead. Public (no leading underscore, unlike this
## file's internal helpers) since `level_runner.gd` calls it directly from
## its own `_unhandled_input()`, the same way it already calls the public
## `uses_mickey_aiming()` to decide whether Space should do anything here
## at all -- only levels using the scripted-camera mouse-look idiom have a
## meaningful "spawn pose" to recenter to. Also re-warps and clears any
## in-flight mouse delta, same reasoning as the post-retry reset in
## _set_panel_field()'s "visible" case: without clearing `mickey` too, a
## Space press mid-mouse-motion would recenter the pose only to have it
## immediately nudged again by whatever delta was still in flight that
## same tick.
func recenter_aim() -> void:
	_reset_camera_spawn_pose()
	_mouse_delta = Vector2.ZERO
	_vectors["mickey"] = Vector3.ZERO
	if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		_warp_mouse_to_center()
