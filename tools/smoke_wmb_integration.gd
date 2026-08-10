extends SceneTree
## Engine-level oracle for the runtime WMB reader wired into the level loader.
##
## This asks a DIFFERENT question from tools/smoke_wmb_reader.gd and
## tools/smoke_wmb_mesh.gd. Those two prove `reader == Python` at the byte level
## (134/134 each): the numbers coming out of `WmbFile` are bit-identical to what
## `tools/extract_wmb_full.py` / `tools/extract_wmb_mesh.py` wrote to
## `assets/converted/levels/`. They say nothing about what the ENGINE then does
## with those numbers.
##
## This one proves `engine-fed-by-reader == engine-fed-by-GLB`: the same
## `WmbLevelLoader` builds each level twice in one process -- once with
## `use_runtime_wmb = false` (JSON + `_brush.glb`, exactly what ships today) and
## once with `use_runtime_wmb = true` (`WmbFile` reading
## `original/piposh3d/WMB/*.WMB`) -- and the two resulting SCENES are compared:
##
##   * number of spawned entity nodes under Entities/
##   * their names, in order
##   * their global transforms (basis + origin)
##   * per-entity mesh presence (MeshInstance3D count + vertex total), which is
##     what catches a real model silently degrading into an `_add_marker` sphere
##   * the brush mesh's per-surface vertex and triangle counts, plus surface
##     names and order
##
## Lights (`_spawn_light`) are children of Entities/ too but are added unnamed,
## so Godot assigns them a process-global "@OmniLight3D@NN" counter that
## necessarily differs between the first and second build in the same process.
## They are compared by class + transform under a synthetic "<OmniLight3D>"
## label instead; that is a property of Godot's node naming, not a difference
## between the two paths.
##
##   godot --path . --headless -s res://tools/smoke_wmb_integration.gd
##   godot --path . --headless -s res://tools/smoke_wmb_integration.gd -- --only=Town
##   godot --path . --headless -s res://tools/smoke_wmb_integration.gd -- --all
##   godot --path . --headless -s res://tools/smoke_wmb_integration.gd -- --all --start=0 --count=40
##
## `--all` builds 2 scenes per level and every GLB/texture it touches stays in
## Godot's resource cache for the life of the process, so the whole 134-level
## corpus in one run exhausts memory partway through (observed: hard process
## death around level 59, no error printed). `--start`/`--count` sweep it in
## chunks instead; that is a limit of one process's cache, not of either path.

## NOT a preload. `wmb_level_loader.gd` references the `PiposhDebug` autoload,
## and under `--headless -s <script>` Godot registers autoloads as global
## identifiers only AFTER the script main loop has been instantiated -- so any
## `preload()` of it fails to compile with "Identifier not found: PiposhDebug"
## before `_init()` ever runs. (Pre-existing: `tools/smoke_anim.gd`,
## `smoke_dispatch.gd` and `smoke_screenshot.gd` all fail this way today.)
## `load()` from inside the deferred `_run()` happens after that registration.
var WmbLevelLoader: GDScript = null

## At least the six the task names. `--all` widens this to every level JSON on
## disk, which is the real corpus-wide question.
const LEVELS := ["Menu", "Studio", "Town", "Start", "Shiks", "Plane2"]

## Transforms are float32 all the way through on both paths, so an exact match
## is the expectation and anything non-zero gets printed. This is only the
## PASS/FAIL threshold.
const XF_EPS := 1.0e-4


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	WmbLevelLoader = load("res://scripts/engine/wmb_level_loader.gd")
	if WmbLevelLoader == null:
		push_error("cannot load res://scripts/engine/wmb_level_loader.gd")
		quit(2)
		return

	var only := ""
	var all := false
	var start := 0
	var count := -1
	for a in OS.get_cmdline_user_args():
		var parts := a.split("=")
		var val := parts[1] if parts.size() > 1 else ""
		if a.begins_with("--only"):
			only = val.to_lower()
		elif a == "--all":
			all = true
		elif a.begins_with("--start"):
			start = int(val)
		elif a.begins_with("--count"):
			count = int(val)

	var levels: Array = LEVELS.duplicate()
	if all:
		levels = _all_level_names()
		if start > 0 or count >= 0:
			var stop: int = levels.size() if count < 0 else mini(start + count, levels.size())
			levels = levels.slice(mini(start, levels.size()), stop)
	if only != "":
		levels = []
		for n in _all_level_names():
			if str(n).to_lower() == only:
				levels = [n]
				break
		if levels.is_empty():
			levels = [only]

	print("")
	print("=== engine scene: runtime WMB reader vs converted GLB/JSON ===")
	print("levels: %s" % ", ".join(PackedStringArray(levels)))

	var diff_levels := 0
	var ok_levels := 0
	var failed_levels := 0
	var report: Array[String] = []

	for level in levels:
		var glb_snap := await _build(str(level), false)
		var wmb_snap := await _build(str(level), true)

		if not bool(glb_snap["loaded"]) or not bool(wmb_snap["loaded"]):
			failed_levels += 1
			print("")
			print("--- %s" % level)
			print("  LOAD FAILED  glb_path_ok=%s runtime_path_ok=%s"
				% [glb_snap["loaded"], wmb_snap["loaded"]])
			continue

		var diffs := _compare(glb_snap, wmb_snap)
		print("")
		print("--- %s" % level)
		print("  entities   : glb=%d  wmb=%d" % [
			(glb_snap["entities"] as Array).size(),
			(wmb_snap["entities"] as Array).size()])
		print("  brush       : glb has_brush=%s surfaces=%d verts=%d tris=%d" % [
			glb_snap["has_brush"], (glb_snap["surfaces"] as Array).size(),
			glb_snap["total_verts"], glb_snap["total_tris"]])
		print("  brush       : wmb has_brush=%s surfaces=%d verts=%d tris=%d" % [
			wmb_snap["has_brush"], (wmb_snap["surfaces"] as Array).size(),
			wmb_snap["total_verts"], wmb_snap["total_tris"]])
		print("  spawn/floor : glb=%s %.3f   wmb=%s %.3f" % [
			glb_snap["spawn"], glb_snap["floor_y"],
			wmb_snap["spawn"], wmb_snap["floor_y"]])
		print("  max |dXf|   : origin %.9f  basis %.9f" % [
			_max_origin_delta(glb_snap, wmb_snap),
			_max_basis_delta(glb_snap, wmb_snap)])
		print("  normals     : glb=%s wmb=%s" % [
			glb_snap["surface_normals"], wmb_snap["surface_normals"]])

		if diffs.is_empty():
			ok_levels += 1
			print("  MATCH")
		else:
			diff_levels += 1
			print("  DIFFER (%d)" % diffs.size())
			for i in mini(diffs.size(), 25):
				print("    %s" % diffs[i])
			if diffs.size() > 25:
				print("    ... %d more" % (diffs.size() - 25))
			report.append("%s: %d difference(s); first: %s" % [level, diffs.size(), diffs[0]])

	print("")
	print("=== summary ===")
	print("levels compared : %d" % (ok_levels + diff_levels))
	print("identical scenes: %d" % ok_levels)
	print("differing scenes: %d" % diff_levels)
	print("load failures   : %d" % failed_levels)
	for r in report:
		print("  %s" % r)
	print("")
	var pass_all := diff_levels == 0 and failed_levels == 0
	print("smoke_wmb_integration: %s" % ("PASS" if pass_all else "FAIL"))
	quit(0 if pass_all else 1)


# ---------------------------------------------------------------------------
# Build + snapshot
# ---------------------------------------------------------------------------


func _build(level: String, runtime: bool) -> Dictionary:
	var host := Node3D.new()
	host.name = "Host_%s_%s" % [level, "wmb" if runtime else "glb"]
	root.add_child(host)
	var loader: Node3D = WmbLevelLoader.new()
	loader.use_runtime_wmb = runtime
	host.add_child(loader)
	await process_frame
	var ok: bool = loader.load_level(level)
	var snap := _snapshot(loader)
	snap["loaded"] = ok
	host.queue_free()
	await process_frame
	return snap


func _snapshot(loader: Node) -> Dictionary:
	var entities: Array = []
	var ents: Node = loader.get_node_or_null("Entities")
	if ents != null:
		for n in ents.get_children():
			entities.append(_entity_row(n))

	var surfaces: Array = []
	var total_verts := 0
	var total_tris := 0
	var has_brush := false
	var brush_xf := Transform3D.IDENTITY
	var normals := "n/a"
	var geo: Node = loader.get_node_or_null("Geometry")
	if geo != null:
		var brush: Node = geo.get_node_or_null("Brush")
		if brush != null:
			has_brush = true
			var meshes: Array = []
			_collect_meshes(brush, meshes)
			var norm_flags: Array[String] = []
			for mi in meshes:
				var m: MeshInstance3D = mi
				brush_xf = m.global_transform
				var mesh: Mesh = m.mesh
				if mesh == null:
					continue
				for i in mesh.get_surface_count():
					var arrays: Array = mesh.surface_get_arrays(i)
					var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
					var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
					var nrm = arrays[Mesh.ARRAY_NORMAL]
					var nv := pos.size()
					var nt := int(idx.size() / 3) if idx.size() > 0 else int(nv / 3)
					surfaces.append({
						"name": mesh.surface_get_name(i),
						"verts": nv,
						"tris": nt,
					})
					total_verts += nv
					total_tris += nt
					norm_flags.append("y" if (nrm != null and (nrm as PackedVector3Array).size() > 0) else "n")
			normals = "".join(norm_flags) if not norm_flags.is_empty() else "n/a"

	return {
		"entities": entities,
		"surfaces": surfaces,
		"total_verts": total_verts,
		"total_tris": total_tris,
		"has_brush": has_brush,
		"brush_xf": brush_xf,
		"surface_normals": normals,
		"spawn": loader.get("spawn_position"),
		"floor_y": float(loader.get("floor_y")),
	}


func _entity_row(n: Node) -> Dictionary:
	var label := str(n.name)
	# Auto-generated ("@OmniLight3D@37") names carry a process-global counter and
	# cannot be equal across two builds in one process. Compare by class instead.
	if label.begins_with("@"):
		label = "<%s>" % n.get_class()
	var xf := Transform3D.IDENTITY
	if n is Node3D:
		xf = (n as Node3D).global_transform
	var meshes: Array = []
	_collect_meshes(n, meshes)
	var mverts := 0
	for mi in meshes:
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(i)
			mverts += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return {
		"label": label,
		"class": n.get_class(),
		"xf": xf,
		"action": str(n.get_meta("action", "")) if n.has_meta("action") else "",
		"file": str(n.get_meta("file", "")) if n.has_meta("file") else "",
		"meshes": meshes.size(),
		"mverts": mverts,
	}


func _collect_meshes(n: Node, into: Array) -> void:
	if n is MeshInstance3D:
		into.append(n)
	for c in n.get_children():
		_collect_meshes(c, into)


# ---------------------------------------------------------------------------
# Compare
# ---------------------------------------------------------------------------


func _compare(a: Dictionary, b: Dictionary) -> Array[String]:
	var out: Array[String] = []

	var ea: Array = a["entities"]
	var eb: Array = b["entities"]
	if ea.size() != eb.size():
		out.append("entity count: glb=%d wmb=%d" % [ea.size(), eb.size()])
	for i in mini(ea.size(), eb.size()):
		var x: Dictionary = ea[i]
		var y: Dictionary = eb[i]
		if x["label"] != y["label"]:
			out.append("entity[%d] name: glb=%s wmb=%s" % [i, x["label"], y["label"]])
			continue
		if x["class"] != y["class"]:
			out.append("entity[%d] %s class: glb=%s wmb=%s" % [i, x["label"], x["class"], y["class"]])
		var d := _xf_delta(x["xf"], y["xf"])
		if d > XF_EPS:
			out.append("entity[%d] %s (action=%s file=%s) transform delta=%.6f\n      glb=%s\n      wmb=%s"
				% [i, x["label"], x["action"], x["file"], d, x["xf"], y["xf"]])
		if x["meshes"] != y["meshes"] or x["mverts"] != y["mverts"]:
			out.append("entity[%d] %s (file=%s) meshes glb=%d/%dv wmb=%d/%dv"
				% [i, x["label"], x["file"], x["meshes"], x["mverts"], y["meshes"], y["mverts"]])

	if bool(a["has_brush"]) != bool(b["has_brush"]):
		out.append("has_brush: glb=%s wmb=%s" % [a["has_brush"], b["has_brush"]])
	var sa: Array = a["surfaces"]
	var sb: Array = b["surfaces"]
	if sa.size() != sb.size():
		out.append("brush surface count: glb=%d wmb=%d" % [sa.size(), sb.size()])
	for i in mini(sa.size(), sb.size()):
		var p: Dictionary = sa[i]
		var q: Dictionary = sb[i]
		if p["verts"] != q["verts"] or p["tris"] != q["tris"]:
			out.append("brush surface[%d] '%s'/'%s': glb=%dv/%dt wmb=%dv/%dt"
				% [i, p["name"], q["name"], p["verts"], p["tris"], q["verts"], q["tris"]])
		elif str(p["name"]).to_lower() != str(q["name"]).to_lower():
			out.append("brush surface[%d] name: glb='%s' wmb='%s' (counts equal: %dv/%dt)"
				% [i, p["name"], q["name"], p["verts"], p["tris"]])
	if int(a["total_verts"]) != int(b["total_verts"]) or int(a["total_tris"]) != int(b["total_tris"]):
		out.append("brush totals: glb=%dv/%dt wmb=%dv/%dt"
			% [a["total_verts"], a["total_tris"], b["total_verts"], b["total_tris"]])
	var bd := _xf_delta(a["brush_xf"], b["brush_xf"])
	if bd > XF_EPS:
		out.append("brush node transform delta=%.6f glb=%s wmb=%s" % [bd, a["brush_xf"], b["brush_xf"]])

	if _v3_delta(a["spawn"], b["spawn"]) > XF_EPS:
		out.append("spawn_position: glb=%s wmb=%s" % [a["spawn"], b["spawn"]])
	if absf(float(a["floor_y"]) - float(b["floor_y"])) > XF_EPS:
		out.append("floor_y: glb=%f wmb=%f" % [a["floor_y"], b["floor_y"]])

	return out


func _xf_delta(a: Transform3D, b: Transform3D) -> float:
	var d := _v3_delta(a.origin, b.origin)
	d = maxf(d, _v3_delta(a.basis.x, b.basis.x))
	d = maxf(d, _v3_delta(a.basis.y, b.basis.y))
	d = maxf(d, _v3_delta(a.basis.z, b.basis.z))
	return d


func _v3_delta(a: Vector3, b: Vector3) -> float:
	return maxf(absf(a.x - b.x), maxf(absf(a.y - b.y), absf(a.z - b.z)))


func _max_origin_delta(a: Dictionary, b: Dictionary) -> float:
	var ea: Array = a["entities"]
	var eb: Array = b["entities"]
	var m := 0.0
	for i in mini(ea.size(), eb.size()):
		m = maxf(m, _v3_delta((ea[i]["xf"] as Transform3D).origin, (eb[i]["xf"] as Transform3D).origin))
	return m


func _max_basis_delta(a: Dictionary, b: Dictionary) -> float:
	var ea: Array = a["entities"]
	var eb: Array = b["entities"]
	var m := 0.0
	for i in mini(ea.size(), eb.size()):
		var x: Transform3D = ea[i]["xf"]
		var y: Transform3D = eb[i]["xf"]
		m = maxf(m, _v3_delta(x.basis.x, y.basis.x))
		m = maxf(m, _v3_delta(x.basis.y, y.basis.y))
		m = maxf(m, _v3_delta(x.basis.z, y.basis.z))
	return m


func _all_level_names() -> Array:
	var out: Array = []
	var d := DirAccess.open("res://assets/converted/levels")
	if d == null:
		return LEVELS.duplicate()
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not d.current_is_dir() and n.get_extension().to_lower() == "json":
			out.append(n.get_basename())
		n = d.get_next()
	d.list_dir_end()
	out.sort()
	return out
