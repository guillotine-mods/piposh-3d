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
var _sounds: Dictionary = {}
var _loader: WmbLevelLoader
var _camera: Camera3D
var _running := true
var _total_frames := 0
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


func setup(level_stem: String, loader: WmbLevelLoader, camera: Camera3D) -> bool:
	_loader = loader
	_camera = camera
	_register_builtins()
	var ast := _load_ast(level_stem)
	if ast.is_empty():
		return false
	_merge_ast(ast, {})
	_merge_includes_recursive(ast.get("includes", []), {level_stem.to_lower(): true})
	for g in _globals.values():
		g["value"] = _eval_init(g.get("init"), null, g.get("kind", "var"))
	return true


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
func _eval_init(init_val: Variant, my: Node3D, kind: String) -> Variant:
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
			_functions_lower[String(fname).to_lower()] = fname
	for aname in ast.get("actions", {}):
		if not _actions.has(aname):
			_actions[aname] = ast["actions"][aname]
	for decl in ast.get("globals", []):
		var name: String = decl.get("name", "")
		if name != "" and not _globals.has(name):
			_globals[name] = {"kind": decl.get("kind", "var"), "init": decl.get("init"), "value": null}
			_index_global(name)
	for k in ast.get("sounds", {}):
		if not _sounds.has(k):
			_sounds[k] = ast["sounds"][k]


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
		if _actions.has(action):
			node.set_meta("wdl_skills", (node.get_meta("skills", []) as Array).duplicate())
			_run_coroutine(_actions[action].get("body", {}), node)
			started += 1
		else:
			unmatched[action] = unmatched.get(action, 0) + 1
	print(
		"[wdl] begin_level: main=%s entities=%d action_coroutines_started=%d unmatched_actions=%s"
		% [_functions.has("main"), total, started, unmatched]
	)


func _run_coroutine(body: Dictionary, entity: Node3D) -> void:
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


func exec_block(block: Dictionary, my: Node3D) -> Variant:
	for stmt in block.get("body", []):
		var sig = await exec_stmt(stmt, my)
		if sig != null:
			return sig
	return null


func exec_stmt(stmt: Dictionary, my: Node3D) -> Variant:
	if not _running or (my != null and not is_instance_valid(my)):
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
			while _truthy(_eval(stmt.get("cond"), my)):
				var sig = await exec_stmt(stmt.get("body"), my)
				if sig is BreakSignal:
					break
				if sig is ReturnSignal:
					return sig
				guard += 1
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
func _eval(e: Variant, my: Node3D) -> Variant:
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


func _binop(op: String, ln: Variant, rn: Variant, my: Node3D) -> Variant:
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
	# _to_num()).
	if l == null or r == null or l is Node3D or r is Node3D:
		return l == r
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
func _get_var(name: String, my: Node3D) -> Variant:
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
	if _globals.has(name):
		return _globals[name].get("value")
	var canonical = _globals_lower.get(low)
	if canonical != null and _globals.has(canonical):
		return _globals[canonical].get("value")
	return 0.0


func _set_var(name: String, value: Variant, my: Node3D) -> void:
	if not _globals.has(name):
		var canonical = _globals_lower.get(name.to_lower())
		if canonical != null and _globals.has(canonical):
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
	_globals_lower[name.to_lower()] = name


func _deindex_global(name: String) -> void:
	var low := name.to_lower()
	if _globals_lower.get(low) == name:
		_globals_lower.erase(low)


func _resolve_entity(obj: Variant, my: Node3D) -> Node3D:
	if obj == null:
		return my
	if obj is Dictionary and obj.get("t") == "id" and str(obj.get("name", "")).to_lower() == "my":
		return my
	if obj is Dictionary and obj.get("t") == "id" and str(obj.get("name", "")).to_lower() == "camera":
		return _camera
	var v = _eval(obj, my)
	return v if v is Node3D else my


func _get_field(obj_expr: Variant, field: String, my: Node3D) -> Variant:
	var node := _resolve_entity(obj_expr, my)
	var low := field.to_lower()
	if node == null or not is_instance_valid(node):
		return 0.0
	if node == _camera:
		return _get_camera_field(low)
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
			return 0.0


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


func _set_field(obj_expr: Variant, field: String, value: Variant, my: Node3D) -> void:
	var node := _resolve_entity(obj_expr, my)
	if node == null or not is_instance_valid(node):
		return
	var low := field.to_lower()
	if node == _camera:
		_set_camera_field(low, value)
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
		_:
			if low.begins_with("skill"):
				var idx := int(low.substr(5)) - 1
				var arr: Array = node.get_meta("wdl_skills", [])
				while arr.size() <= idx:
					arr.append(0.0)
				if idx >= 0:
					arr[idx] = value
				node.set_meta("wdl_skills", arr)


func _set_camera_field(low: String, value: Variant) -> void:
	if _camera == null:
		return
	match low:
		"x", "y", "z":
			var gs := _godot_to_gs(_camera.global_position)
			if low == "x":
				gs.x = _to_num(value)
			elif low == "y":
				gs.y = _to_num(value)
			else:
				gs.z = _to_num(value)
			_camera.global_position = _gs_to_godot(gs)
		"pan", "tilt", "roll":
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
func _assign(op: String, target: Dictionary, value_expr: Variant, my: Node3D) -> Variant:
	var new_val = _eval(value_expr, my)
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
func _call(name: String, arg_exprs: Array, my: Node3D) -> Variant:
	var low := name.to_lower()
	# User-defined function call (not a builtin) -- run synchronously to
	# completion this frame (no `wait()` support inside nested function
	# calls yet; real usage here is almost entirely simple helpers).
	if _functions.has(name):
		return _call_user_function(name, arg_exprs, my)
	var canonical_fn = _functions_lower.get(low)
	if canonical_fn != null and _functions.has(canonical_fn):
		return _call_user_function(canonical_fn, arg_exprs, my)
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
		return _builtins[low].call(args, my)
	_warn_once("builtin: " + name)
	return 0.0


func _call_user_function(fname: String, arg_exprs: Array, my: Node3D) -> Variant:
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
func _exec_block_sync(block: Dictionary, my: Node3D) -> Variant:
	for stmt in block.get("body", []):
		var sig = _exec_stmt_sync(stmt, my)
		if sig != null:
			return sig
	return null


func _exec_stmt_sync(stmt: Dictionary, my: Node3D) -> Variant:
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
			while _truthy(_eval(stmt.get("cond"), my)) and guard < 100000:
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
		"vec_set": func(a, _my): return 0.0,
		"vec_sub": func(a, _my): return 0.0,
		"vec_to_angle": func(a, _my): return 0.0,
		"sqrt": func(a, _my): return sqrt(_to_num(a[0])) if a.size() > 0 else 0.0,
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
		"splay": func(a, _my): return _do_play_sfx(a, 0),
		"vplay": func(a, _my): return _do_play_sfx(a, 0),
		"play_sound": func(a, _my): return _do_play_sfx(a, 0),
		"play_entsound": func(a, _my): return _do_play_sfx(a, 1),
		"stop_sound": func(_a, _my): return _do_stop_sound(),
		"snd_playing": func(_a, _my): return 1.0 if AudioBus.is_voice_playing() else 0.0,
		"setvoice": func(_a, _my): return 0.0,
		"voiceinit": func(_a, _my): return 0.0,
		"getposition": func(_a, _my): return AudioBus.get_voice_progress() * 1000000.0,
		"ent_frame": func(a, my): return _do_anim_frame(a, my),
		"ent_cycle": func(a, my): return _do_anim_cycle(a, my),
		"talk": func(_a, my): return _do_talk(my),
		"talk2": func(_a, my): return _do_talk_skins(my, true),
		"blink": func(_a, my): return _do_blink(my),
		"blink2": func(_a, my): return _do_blink(my),
	}


func _do_play_sfx(a: Array, wav_index: int) -> float:
	if a.size() > wav_index:
		AudioBus.play_sfx(str(a[wav_index]))
	return 0.0


func _do_stop_sound() -> float:
	AudioBus.stop_sfx()
	return 0.0


func _resolve_arg_entity(a: Array, idx: int, my: Node3D) -> Node3D:
	if idx < a.size() and a[idx] is Node3D:
		return a[idx]
	return my


func _do_anim_frame(a: Array, my: Node3D) -> float:
	if a.size() < 2 or my == null:
		return 0.0
	var anim := my.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.play_frame(str(a[0]), _to_num(a[1]))
	return 0.0


func _do_anim_cycle(a: Array, my: Node3D) -> float:
	if a.size() < 1 or my == null:
		return 0.0
	var anim := my.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.play_cycle(str(a[0]), _to_num(a[1]) if a.size() > 1 else 0.0)
	return 0.0


func _do_talk(my: Node3D) -> float:
	if my == null:
		return 0.0
	var anim := my.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.play_talk()
	return 0.0


func _do_talk_skins(my: Node3D, enabled: bool) -> float:
	if my == null:
		return 0.0
	var anim := my.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.enable_talk_skins(enabled)
	return 0.0


func _do_blink(my: Node3D) -> float:
	if my == null:
		return 0.0
	var anim := my.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.play_blink()
	return 0.0


func _do_morph(a: Array, my: Node3D) -> float:
	if a.size() < 1:
		return 0.0
	var target := _resolve_arg_entity(a, 1, my)
	if target == null:
		return 0.0
	var anim := target.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim == null:
		return 0.0
	anim.morph_to(String(a[0]).get_basename())
	return 0.0


func _do_remove(a: Array, my: Node3D) -> float:
	var target := _resolve_arg_entity(a, 0, my)
	if target and is_instance_valid(target):
		target.queue_free()
	return 0.0


func _do_create(a: Array, my: Node3D) -> Node3D:
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
	if action != "" and _actions.has(action):
		_run_coroutine(_actions[action].get("body", {}), inst)
	return inst


func _do_run(a: Array) -> float:
	if a.size() < 1:
		return 0.0
	var target := String(a[0]).get_basename()
	LevelRouter.goto_level(target)
	return 0.0
