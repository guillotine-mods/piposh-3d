extends Node
class_name WdlInterpreter
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

const AST_DIR := "res://assets/converted/wdl_ast/"

var _globals: Dictionary = {}
var _globals_lower: Dictionary = {}  # lowercase name -> canonical name, kept in sync with _globals -- see _index_global()
var _functions: Dictionary = {}
var _functions_lower: Dictionary = {}  # same O(1)-fallback idea as _globals_lower, for _call()
var _actions: Dictionary = {}
var _actions_lower: Dictionary = {}  # lowercase name -> canonical name, see _resolve_action()
var _sounds: Dictionary = {}
var _sounds_lower: Dictionary = {}  # lowercase name -> canonical name, same pattern as _actions_lower
var _loader: WmbLevelLoader
var _camera: Camera3D
var _hud: GameHud
## Set once in setup(). Used only to scope the small number of hand-wired
## HUD hooks below (_seed_subtitle_crawl()) to the exact level/action pair
## they were built for -- some action names (e.g. "Ami") are reused across
## levels for an unrelated, ordinary talk/blink loop.
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


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
func _exit_tree() -> void:
	# Every spawned action/main() coroutine checks this each statement (see
	# exec_stmt) so they wind down cleanly instead of touching a freed node
	# when a level ends/reloads mid-script.
	_running = false


func _process(_delta: float) -> void:
	_total_frames += 1


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
	return true


## `ShowDialog()`'s corresponding response half: GameHud's dialog panel
## emits this when the player clicks an option button (1/2/3). Sets the
## `DialogChoice` global directly -- the script's own already-written
## per-tick polling loop (`while (DialogIndex==X) { if (DialogChoice==1)
## {...} ...}`, present in every level that calls ShowDialog) picks it up
## naturally on its next `wait(1)` iteration. See _do_show_dialog().
func _on_dialog_choice(choice: int) -> void:
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
			_seed_subtitle_crawl(action)
			_run_coroutine(_actions[resolved_action].get("body", {}), node)
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


## GameHud's `setup_start_subtitles()`/`setup_studio_subtitles()` (the
## sliding-in bitmap "subtitle" panel -- `pSom`/`pOvr` in the original WDL,
## a pre-rendered green-on-black bitmap TEXT graphic, not a live font) were
## built with the exact slide/blink timings and thresholds these two real
## actions use (`_update_crawl()`'s `stop_x` is -200 for Start, -310 for
## Studio, matching `POvr.pos_x > -200`/`> -310` in the WDL source
## byte-for-byte) but were never actually wired to anything -- confirmed
## via `git log -S` showing zero commits ever called either function.
## `pSom`/`pOvr` are WDL `panel` objects, which this interpreter has no
## generic support for (docs/CONTRACT.md #4.1 known gap), so the
## `pOvr.visible = on; pSom.visible = on;` statements that open both
## actions silently no-op instead of ever reaching GameHud -- reported
## 2026-07-31 as "green text... not showing" in Studio. Fixed with a
## one-time hook at the exact two (level, action) pairs GameHud was built
## for, since "action Ami"/"action DefineYachdel" are reused in OTHER
## levels for an ordinary, unrelated talk/blink loop (confirmed via corpus
## grep) -- this must not fire for those.
func _seed_subtitle_crawl(action: String) -> void:
	if _hud == null:
		return
	var low := action.to_lower()
	var level_low := _level_stem.to_lower()
	if level_low == "start" and low == "defineyachdel":
		_hud.setup_start_subtitles()
	elif level_low == "studio" and low == "ami":
		_hud.setup_studio_subtitles()


func _seed_look_at_me_flag1(node: Node3D, action: String) -> void:
	if action.to_lower() != "lookatme":
		return
	if node.has_meta("wdl_custom_flag1"):
		return  # already set (e.g. re-entrant setup) -- don't clobber a runtime write
	var pan := float(node.get_meta("pan", 0.0))
	var diff := absf(fposmod(pan - LOOK_AT_ME_FLAG1_ON_PAN + 180.0, 360.0) - 180.0)
	node.set_meta("wdl_custom_flag1", 1.0 if diff <= LOOK_AT_ME_FLAG1_PAN_TOLERANCE else 0.0)


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


func exec_block(block: Dictionary, my) -> Variant:
	for stmt in block.get("body", []):
		var sig = await exec_stmt(stmt, my)
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
			_eval(stmt.get("expr", {}), my)
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
	if low == "my":
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
	return 0.0


func _set_var(name: String, value: Variant, my) -> void:
	var canonical := _resolve_symbol(_globals, _globals_lower, name)
	if canonical != "":
		name = canonical
	if not _globals.has(name):
		_globals[name] = {"kind": "var", "init": null, "value": null}
		_index_global(name)
	_globals[name]["value"] = value


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
	if obj is Dictionary and obj.get("t") == "id" and str(obj.get("name", "")).to_lower() == "my":
		return my
	if obj is Dictionary and obj.get("t") == "id" and str(obj.get("name", "")).to_lower() == "camera":
		return _camera
	if obj is Dictionary and obj.get("t") == "id" and str(obj.get("name", "")).to_lower() == "dialog" and _hud != null:
		return _hud
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
		return 1.0 if (low == "visible" and _hud.is_dialog_open()) else 0.0
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
			node.visible = not _truthy(value)
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
## _set_field(). Detects the player's own CharacterBody3D (added to group
## "player" by player_controller.gd) entering the entity's space and fires
## its `.event`, the same dispatch `invoke_event()` already provides for
## clicks. `body_entered` only fires once per approach (not continuously
## while overlapping), matching a real walk-into-it collision, not a
## per-frame poll.
func _ensure_impact_area(node: Node3D) -> void:
	if node.has_meta("wdl_impact_area"):
		return
	var area := Area3D.new()
	area.collision_layer = 0
	area.collision_mask = 1  # Player's CharacterBody3D default layer.
	area.monitoring = true
	var cs := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 28.0
	cs.shape = shape
	cs.position = _clickable_center_offset(node)
	area.add_child(cs)
	node.add_child(area)
	node.set_meta("wdl_impact_area", true)
	area.body_entered.connect(_on_impact_body_entered.bind(node))


func _on_impact_body_entered(body: Node3D, node: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	if not _entity_alive(node):
		return
	invoke_event(node, str(node.get_meta("wdl_event", "")))


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


func _set_entity_pan(node: Node3D, pan_deg: float) -> void:
	var scl := node.transform.basis.get_scale()
	if scl.x <= 0.001 or scl.y <= 0.001 or scl.z <= 0.001:
		scl = Vector3.ONE
	var pos := node.global_position
	node.global_transform = Transform3D(_acknex_entity_basis(pan_deg, 0.0, 0.0) * Basis.from_scale(scl.abs()), pos)
	node.set_meta("pan", pan_deg)
	node.set_meta("tilt", 0.0)
	node.set_meta("roll", 0.0)


func _set_entity_tilt_roll(node: Node3D, tilt_deg: float, roll_deg: float) -> void:
	var scl := node.transform.basis.get_scale()
	if scl.x <= 0.001 or scl.y <= 0.001 or scl.z <= 0.001:
		scl = Vector3.ONE
	var pan := float(node.get_meta("pan", 0.0))
	var pos := node.global_position
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
const BRIDGE_OVER_SHARED_FUNCTIONS: Array[String] = [
	"splay", "vplay", "play_sound", "play_entsound", "stop_sound",
	"snd_playing", "getposition", "actor_move", "showdialog", "run",
]


func _call(name: String, arg_exprs: Array, my) -> Variant:
	var low := name.to_lower()
	if low == "vec_set" or low == "vec_sub" or low == "vec_to_angle":
		_last_result = _do_vector_call(low, arg_exprs, my)
		return _last_result
	if not (low in BRIDGE_OVER_SHARED_FUNCTIONS):
		# User-defined function call (not a builtin) -- run synchronously to
		# completion this frame (no `wait()` support inside nested function
		# calls yet; real usage here is almost entirely simple helpers).
		var resolved_fn := _resolve_function(name)
		if resolved_fn != "":
			_last_result = _call_user_function(resolved_fn, arg_exprs, my)
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


## Synchronous statement execution for plain (non-coroutine) function calls
## reached from inside expression evaluation -- these cannot themselves
## `wait()` mid-body (that would require expressions to be awaitable,
## which real WDL doesn't need: `wait()` only ever appears as a bare
## statement, never inside an expression). A `wait()` hit here is treated
## as an immediate no-op and warned once, rather than blocking eval.
func _exec_block_sync(block: Dictionary, my) -> Variant:
	for stmt in block.get("body", []):
		var sig = _exec_stmt_sync(stmt, my)
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
		"splay": func(a, _my): return _do_play_sfx(a, 0, true),
		"vplay": func(a, _my): return _do_play_sfx(a, 0, true),
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
		"getposition": func(_a, my): return _do_get_voice_position(my),
		"ent_frame": func(a, my): return _do_anim_frame(a, my),
		"ent_cycle": func(a, my): return _do_anim_cycle(a, my),
		"talk": func(_a, my): return _do_talk(my),
		"talk2": func(_a, my): return _do_talk_skins(my, true),
		"blink": func(_a, my): return _do_blink(my),
		"blink2": func(_a, my): return _do_blink(my),
	}


func _do_play_sfx(a: Array, wav_index: int, is_voice: bool) -> float:
	if a.size() <= wav_index:
		return -1.0
	if is_voice:
		AudioChannels.play_voice(str(a[wav_index]))
		return 0.0
	# Real handle, not a placeholder -- snd_playing(result) (the WDL "is my
	# ambiance loop still playing" idiom) needs it to identify this specific
	# playback, not just any playback. See _register_builtins()'s
	# "snd_playing" comment.
	return AudioChannels.play_sfx(str(a[wav_index]))


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
	my.global_position += dir * (force * ACTOR_MOVE_BASE_SPEED * t)
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
	_set_var("DialogChoice", 0.0, my)  # matches the real ShowDialog's first statement
	if _hud == null:
		return 0.0
	var idx := int(_to_num(_get_var("DialogIndex", my)))
	_hud.show_dialog(idx)
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
		return _vectors.get(name, Vector3.ZERO)
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
## key for calls with no entity, e.g. from `main()`) -> the voice
## generation (AudioChannels.get_voice_generation()) that caller has
## already observed as "finished". See _do_get_voice_position().
var _voice_finished_consumed_by: Dictionary = {}


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
func _do_get_voice_position(my) -> float:
	var progress := AudioChannels.get_voice_progress()
	if progress >= 1.0:
		var gen: int = AudioChannels.get_voice_generation()
		if _voice_finished_consumed_by.get(my, -1) == gen:
			return 999999.0
		_voice_finished_consumed_by[my] = gen
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


func _do_anim_frame(a: Array, my) -> float:
	if a.size() < 2 or not is_instance_valid(my):
		return 0.0
	var anim := my.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.play_frame(str(a[0]), _to_num(a[1]))
	return 0.0


func _do_anim_cycle(a: Array, my) -> float:
	if a.size() < 1 or not is_instance_valid(my):
		return 0.0
	var anim := my.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.play_cycle(str(a[0]), _to_num(a[1]) if a.size() > 1 else 0.0)
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


func _do_create(a: Array, my) -> Node3D:
	if a.size() < 1 or _loader == null:
		return null
	var stem := String(a[0]).get_basename()
	var path := "res://assets/converted/mdl/%s.glb" % stem
	if not ResourceLoader.exists(path):
		return null
	var packed := load(path)
	if not (packed is PackedScene):
		return null
	var inst := (packed as PackedScene).instantiate() as Node3D
	if inst == null:
		return null
	var parent: Node = (my.get_parent() if my else null)
	if parent == null:
		parent = _loader.get_node_or_null("Entities")
	if parent == null:
		return null
	parent.add_child(inst)
	inst.global_transform = my.global_transform if my else Transform3D.IDENTITY
	var anim := MdlAnimator.new()
	anim.name = "MdlAnimator"
	inst.add_child(anim)
	anim.setup_from_stem(stem, inst)
	inst.set_meta("action", str(a[2]) if a.size() > 2 else "")
	inst.set_meta("wdl_skills", [])
	var action := str(inst.get_meta("action", ""))
	var resolved_action := _resolve_action(action) if action != "" else ""
	if resolved_action != "":
		_run_coroutine(_actions[resolved_action].get("body", {}), inst)
	return inst


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
