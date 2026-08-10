extends Node3D
## Instantiates entities from converted WMB JSON + MDL glb assets.
## Transforms are pre-baked Acknex(Z-up) → Godot(Y-up) in the JSON.

const MdlAnimator = preload("res://scripts/engine/mdl_animator.gd")
## Runtime .WMB reader (0-py migration). Deliberately NO `class_name` anywhere
## in this project (commit 5c0adfa: a global class inside a mounted .pck never
## resolves), so it is reached by preload only.
const WmbFile = preload("res://scripts/engine/wmb_file.gd")

signal entity_triggered(action: String, skills: Array, node: Node3D)
signal level_loaded(level_name: String, ok: bool)

const MDL_DIR := "res://assets/converted/mdl/"
const WMB_DIR := "res://assets/converted/wmb/"
const LEVEL_DIR := "res://assets/converted/levels/"
## Original game data, read byte-for-byte by `WmbFile` when the runtime path is
## enabled. Same directory the byte-level oracles (tools/smoke_wmb_reader.gd,
## tools/smoke_wmb_mesh.gd) read.
const WMB_SRC_DIR := "res://original/piposh3d/WMB/"

## FEATURE FLAG — DEFAULTS OFF.
##
## false (default): level object data comes from `assets/converted/levels/
## <Name>.json` and brush geometry from `<Name>_brush.glb` / `wmb/<Stem>.glb`,
## i.e. the offline Python pipeline's output. Behaviour is byte-for-byte what it
## has always been; none of the runtime-WMB code below is reached.
##
## true: the same two things are produced in-engine by `WmbFile` straight out of
## `original/piposh3d/WMB/*.WMB` — no converted JSON, no GLB. `WmbFile` is
## already proven byte-identical to the Python converters
## (tools/smoke_wmb_reader.gd 134/134, tools/smoke_wmb_mesh.gd 134/134); what
## this flag adds is the *engine* question — does a scene fed by the reader
## equal a scene fed by the GLB — which tools/smoke_wmb_integration.gd answers.
const USE_RUNTIME_WMB := false
## Per-instance override of the const above, so both paths can be built in one
## process and compared (tools/smoke_wmb_integration.gd). Nothing in the game
## writes this; it defaults to the const, which is false.
var use_runtime_wmb: bool = USE_RUNTIME_WMB
## Island.MDL uses scale 20; allow generous but reject skybox junk.
## Reported live (2026-08-08): Plane3 "loads but nothing ever
## progresses" -- its own `action Dome` (`BackDome.MDL`, scale 95.36)
## is the ONLY entity that polls `GetPosition(Voice)` and advances
## `Scene`, the variable every camera cut/dialogue/character state in
## the whole level gates on. At the old 64.0 cap this entity was
## silently rejected by _spawn_entity()'s own scale check before ever
## spawning -- no node, no coroutine, nothing to advance Scene, so the
## level sat frozen on its very first line forever, matching the report
## exactly. A corpus-wide survey of every level's own entity scales
## (see docs/SESSION_LOG.md) found only one other placement above the
## old cap -- Mount's own BackDome at 197.82, `action=null` (purely
## decorative, no script depends on it existing) -- so raising this to
## 100.0 picks up Plane3's real, functionally-required dome without
## changing Mount's (already-excluded, unused-by-any-action) one at all.
const MAX_UNIFORM_SCALE := 100.0
## CamPlane / far scenery can sit tens of thousands of quants out.
const MAX_ORIGIN_DIST := 80000.0

var level_name: String = ""
var spawn_position := Vector3(0, 2, 8)
var level_bounds := AABB(Vector3(-20, 0, -20), Vector3(40, 10, 40))
var floor_y := 0.0
var last_level_data: Dictionary = {}
## Set when WMB has player_walk* / player_stand — first-person spawn (Plane2…).
var first_person_spawn: Dictionary = {}  # origin, pan, action, node_name

var _entities_root: Node3D
var _geometry_root: Node3D
var _glb_index: Dictionary = {}
var _wmb_index: Dictionary = {}
## lowercased stem -> "res://original/piposh3d/WMB/<file>", with the file's real
## on-disk casing. Built lazily, only on the runtime path.
var _wmb_src_index: Dictionary = {}


func _ready() -> void:
	_geometry_root = Node3D.new()
	_geometry_root.name = "Geometry"
	add_child(_geometry_root)
	_entities_root = Node3D.new()
	_entities_root.name = "Entities"
	add_child(_entities_root)
	_build_glb_index()


func has_first_person() -> bool:
	return not first_person_spawn.is_empty()


func load_level(p_level_name: String) -> bool:
	level_name = p_level_name
	first_person_spawn = {}
	_clear_children(_geometry_root)
	_clear_children(_entities_root)

	# SEAM 1 — level object data. Both branches must yield the same dictionary
	# shape; `WmbFile.read_level()` returns exactly what
	# `tools/extract_wmb_full.py` writes to <Name>.json (proven 134/134 by
	# tools/smoke_wmb_reader.gd), so everything downstream is untouched.
	var data
	if use_runtime_wmb:
		var wmb_path := _resolve_wmb_source(p_level_name)
		if wmb_path == "":
			push_warning("No level WMB: %s" % p_level_name)
			_spawn_ground(Vector3.ZERO, Vector3(40, 1, 40))
			spawn_position = Vector3(0, 2, 8)
			level_loaded.emit(level_name, false)
			return false
		data = WmbFile.read_level(wmb_path)
		# read_level() reports its "no objects list" ValueError path as {"error": …},
		# which is the runtime equivalent of an unreadable/!Dictionary JSON below.
		if typeof(data) != TYPE_DICTIONARY or data.has("error"):
			level_loaded.emit(level_name, false)
			return false
	else:
		var path := _resolve_level_json(p_level_name)
		if path == "":
			push_warning("No level JSON: %s" % p_level_name)
			_spawn_ground(Vector3.ZERO, Vector3(40, 1, 40))
			spawn_position = Vector3(0, 2, 8)
			level_loaded.emit(level_name, false)
			return false

		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			level_loaded.emit(level_name, false)
			return false
		data = JSON.parse_string(f.get_as_text())
		if typeof(data) != TYPE_DICTIONARY:
			level_loaded.emit(level_name, false)
			return false
	last_level_data = data

	var bounds: Dictionary = data.get("bounds", {})
	var center := _vec3(bounds.get("center", [0, 0, 0]), Vector3.ZERO)
	var size := _vec3(bounds.get("size", [40, 5, 40]), Vector3(40, 5, 40))
	floor_y = float(bounds.get("floor_y", center.y))
	level_bounds = AABB(center - size * 0.5, size)
	spawn_position = _vec3(data.get("spawn", [center.x, floor_y + 2.0, center.z]), Vector3(0, 2, 8))

	var has_brush := _spawn_brush_geometry(p_level_name)
	if not has_brush:
		# Fallback pad when WMB brush mesh was not extracted.
		var ground_size := Vector3(
			minf(maxf(size.x + 80.0, 80.0), 4000.0),
			1.0,
			minf(maxf(size.z + 80.0, 80.0), 4000.0)
		)
		_spawn_ground(Vector3(center.x, floor_y - 0.5, center.z), ground_size)

	var objects: Array = data.get("objects", [])
	var spawned := 0
	var skipped := 0
	for obj in objects:
		if typeof(obj) != TYPE_DICTIONARY:
			continue
		match str(obj.get("type", "")):
			"entity":
				# WED set-piece MDLs that duplicate extracted brush geometry
				# (e.g. StudioL) sit ~4u below the brush floor and z-fight.
				if has_brush and _is_brush_duplicate_entity(obj):
					skipped += 1
					continue
				if _spawn_entity(obj):
					spawned += 1
				else:
					skipped += 1
			"light":
				_spawn_light(obj)
	if level_name == "Plane":
		_snap_piposh_walk_to_pip()
	print(
		"WmbLevelLoader: %s spawned=%d skipped=%d brush=%s floor_y=%.1f spawn=%s"
		% [level_name, spawned, skipped, has_brush, floor_y, spawn_position]
	)
	level_loaded.emit(level_name, true)
	return true


## See _spawn_entity()'s own PiposhWalk comment. Runs once, after every
## entity has actually finished spawning (feet-snap/scale/basis already
## applied).
##
## Originally matched PiposhWalk's height to Krupnik's real, final
## `global_position.y` instead -- confirmed live 2026-08-01 as visually
## correct at spawn ("should be the same height as Krupnik"). But a later
## report (2026-08-02) found Piposh's feet visibly sunk under the cabin
## floor throughout the whole walk and at the final stop too, even though
## he numerically never left that Krupnik-matched height (no drift --
## `tools/smoke_plane_walk_height.gd`). Root cause, found via the
## `[feet-snap]` debug log (`_snap_mesh_feet_to_origin()`'s own per-entity
## output): Krupnik's model (Krup2.MDL / Krupnik.MDL) and Piposh's own
## model (Piposh.MDL) get very different feet-to-origin corrections --
## Krupnik's ~-33.4 to -33.6, Piposh's own ~-58.2 to -58.4 -- so matching
## Piposh's height to a DIFFERENT model's feet-snap result leaves him
## ~24 units short of where his OWN model's geometry says his feet
## should be for that same floor. Confirmed directly with a same-model
## comparison: `action Pip` (Plane.wdl) is a second Piposh.MDL placement
## in the same area (raw WED Y=34, essentially the same floor as
## Krupnik's raw Y=35 -- it's the stand-in shown during the DialogChoice
## ==3 cockpit-camera cutscene, toggled by `Pip2`), and its own
## independently-computed feet-snap height is 92.161, not 68.55 --
## exactly the size of the model-to-model correction gap. Matching
## PiposhWalk to `Pip` instead of Krupnik keeps the fix on the same
## model throughout, sidestepping the cross-model mismatch entirely.
func _snap_piposh_walk_to_pip() -> void:
	var piposh: Node3D = null
	var pip: Node3D = null
	for node in _entities_root.get_children():
		if not (node is Node3D):
			continue
		var action := str(node.get_meta("action", ""))
		if action == "PiposhWalk":
			piposh = node
		elif action == "Pip":
			pip = node
	if piposh == null or pip == null:
		return
	var pos := piposh.global_position
	pos.y = pip.global_position.y
	piposh.global_position = pos


func _resolve_level_json(p_level_name: String) -> String:
	# Android PCK: prefer ResourceLoader / direct paths — DirAccess listing is unreliable.
	var json_names: Array[String] = [
		p_level_name, p_level_name.to_lower(), p_level_name.capitalize()
	]
	for name in json_names:
		var direct: String = LEVEL_DIR + name + ".json"
		if _file_ok(direct):
			return direct
	var dir := DirAccess.open(LEVEL_DIR)
	if dir == null:
		return ""
	var want := p_level_name.to_lower() + ".json"
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir() and fn.to_lower() == want:
			return LEVEL_DIR + fn
		fn = dir.get_next()
	return ""


func _file_ok(path: String) -> bool:
	return ResourceLoader.exists(path) or FileAccess.file_exists(path)


func _clear_children(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.free()


## SEAM 2 — level brush geometry. Everything after the `inst` is produced is
## shared by both branches, so material treatment (sky transparency, filtering)
## and collision are applied identically either way.
func _spawn_brush_geometry(p_level_name: String) -> bool:
	var inst: Node = null
	if use_runtime_wmb:
		inst = _build_runtime_wmb_node(p_level_name)
		if inst == null:
			return false
	else:
		var path := _resolve_brush_glb(p_level_name)
		if path == "":
			return false
		var packed := load(path)
		if packed == null or not (packed is PackedScene):
			push_warning("Brush GLB failed to load: %s" % path)
			return false
		inst = (packed as PackedScene).instantiate()
	inst.name = "Brush"
	_force_unshaded_if_needed(inst, true)
	# Static collision from visual meshes (coarse but keeps player on floors).
	_add_mesh_collision(inst)
	_geometry_root.add_child(inst)
	return true


## Build the same node an extracted `_brush.glb` / `wmb/<stem>.glb` would
## instantiate to, but straight from the original .WMB via `WmbFile`.
##
## Shape mirrors the offline pipeline's glTF: ONE MeshInstance3D whose ArrayMesh
## carries one surface per non-empty texture bucket, in sorted texture-index
## order (`WmbFile.build_mesh()`), wrapped in a Node3D at identity — which is
## what the exporter writes and therefore what `PackedScene.instantiate()`
## yields. Returns null wherever the GLB path would have returned "" / failed to
## load, so the caller's ground-pad fallback is reached the same way.
func _build_runtime_wmb_node(stem: String) -> Node3D:
	var src := _resolve_wmb_source(stem)
	if src == "":
		return null
	var f := FileAccess.open(src, FileAccess.READ)
	if f == null:
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	if bytes.is_empty():
		return null
	var brush := WmbFile.read_brush(bytes, true)
	if brush.is_empty():
		return null
	var mesh := WmbFile.build_mesh(brush)
	if mesh.get_surface_count() == 0:
		return null
	_apply_runtime_brush_materials(mesh, brush)
	var mi := MeshInstance3D.new()
	mi.name = "BrushMesh"
	mi.mesh = mesh
	var holder := Node3D.new()
	holder.name = stem
	holder.add_child(mi)
	return holder


## Attach one StandardMaterial3D per surface carrying the Acknex texture NAME
## and decoded pixels.
##
## The name matters as much as the pixels: `_force_unshaded_if_needed()` keys
## its sky/backdrop transparency rule off `mat.resource_name` (see its own
## comment — the glTF exporter carries the original Acknex texture name through
## as the glTF material name, which is the only place it survives). Setting
## `resource_name` here is what makes that rule fire identically on this path.
func _apply_runtime_brush_materials(mesh: ArrayMesh, brush: Dictionary) -> void:
	var textures: Array = brush.get("textures", [])
	var keys: Array = brush["buckets"].keys()
	keys.sort()
	var si := 0
	for tex_idx in keys:
		var b: Dictionary = brush["buckets"][tex_idx]
		# build_mesh() skips empty buckets; walk in lockstep with it.
		if (b["idx"] as Array).is_empty():
			continue
		if si >= mesh.get_surface_count():
			break
		var mat := StandardMaterial3D.new()
		mat.resource_name = str(b["name"])
		var ti := int(tex_idx)
		if ti >= 0 and ti < textures.size():
			var img: Image = textures[ti].get("image")
			if img != null:
				# LINEAR_WITH_MIPMAPS is what brush surfaces get below; without
				# mips that filter silently degrades to plain linear.
				if not img.has_mipmaps():
					img.generate_mipmaps()
				mat.albedo_texture = ImageTexture.create_from_image(img)
		mesh.surface_set_material(si, mat)
		si += 1


## Locate the original .WMB for a level or prop stem.
##
## Unlike `_resolve_level_json` / `_direct_glb`, this prefers a cached DirAccess
## listing over direct-path probes, and deliberately so: the corpus mixes `.wmb`
## and `.WMB` (and `Menu.WMB` vs `Town.wmb` casing on the stem too), so a probe
## loop on a case-INsensitive filesystem happily opens `DRoad1.wmb` when asked
## for `DRoad1.WMB` and Godot logs "Case mismatch opening requested file … will
## not open when exported to other case-sensitive platforms" for every one. The
## listing gives the real on-disk name, so the path handed to FileAccess is
## always exact. The direct-probe fallback is kept for the PCK/Android case
## where DirAccess listing of res:// is unreliable (CONTRACT §6).
func _resolve_wmb_source(stem: String) -> String:
	if stem == "":
		return ""
	if _wmb_src_index.is_empty():
		_build_wmb_src_index()
	var hit := str(_wmb_src_index.get(stem.to_lower(), ""))
	if hit != "":
		return hit
	var casings: Array[String] = [stem, stem.to_lower()]
	casings.append(stem.substr(0, 1).to_upper() + stem.substr(1).to_lower())
	for s in casings:
		for ext in [".WMB", ".wmb"]:
			var p: String = WMB_SRC_DIR + s + ext
			if FileAccess.file_exists(p):
				return p
	return ""


func _build_wmb_src_index() -> void:
	var dir := DirAccess.open(WMB_SRC_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir() and fn.get_extension().to_lower() == "wmb":
			_wmb_src_index[fn.get_basename().to_lower()] = WMB_SRC_DIR + fn
		fn = dir.get_next()
	dir.list_dir_end()


func _resolve_brush_glb(p_level_name: String) -> String:
	var names: Array[String] = [p_level_name, p_level_name.to_lower()]
	for name in names:
		var candidates := [
			LEVEL_DIR + name + "_brush.glb",
			LEVEL_DIR + name + ".glb",
			WMB_DIR + name + ".glb",
			WMB_DIR + name + "_brush.glb",
		]
		for c in candidates:
			if _file_ok(c):
				return c
	for base in [LEVEL_DIR, WMB_DIR]:
		var dir := DirAccess.open(base)
		if dir == null:
			continue
		var want_a := p_level_name.to_lower() + "_brush.glb"
		var want_b := p_level_name.to_lower() + ".glb"
		dir.list_dir_begin()
		var fn := dir.get_next()
		while fn != "":
			if not dir.current_is_dir():
				var low := fn.to_lower()
				if low == want_a or low == want_b:
					return base + fn
			fn = dir.get_next()
	return ""


func _add_mesh_collision(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			var body := StaticBody3D.new()
			body.name = "Col"
			var col := CollisionShape3D.new()
			col.shape = mi.mesh.create_trimesh_shape()
			body.add_child(col)
			mi.add_child(body)
	for c in node.get_children():
		_add_mesh_collision(c)


func _spawn_ground(center: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = "Ground"
	body.position = center
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh_instance.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.18, 0.22, 0.16)
	mesh_instance.material_override = mat
	body.add_child(mesh_instance)
	_geometry_root.add_child(body)


func _is_brush_duplicate_entity(obj: Dictionary) -> bool:
	var stem := str(obj.get("file", "")).get_file().get_basename().to_lower()
	# Town/desert shells duplicate brush floors. StudioL is set dressing
	# (light frames) that the brush does NOT include — keep spawning it.
	return stem in ["townl", "desertl", "mansionl", "innl"]


func _snap_mesh_feet_to_origin(root: Node3D, _scale_y: float = 1.0) -> void:
	## Put the lowest mesh point on the WED origin plane (world +Y).
	## Uses root basis (scale+pan) so we do not double-scale local AABB.
	var aabb := _mesh_aabb_local(root, Transform3D.IDENTITY, true)
	if aabb.size.y <= 0.001:
		return
	var b := root.transform.basis
	var min_y := INF
	for i in 8:
		var corner := Vector3(
			aabb.position.x if (i & 1) == 0 else aabb.position.x + aabb.size.x,
			aabb.position.y if (i & 2) == 0 else aabb.position.y + aabb.size.y,
			aabb.position.z if (i & 4) == 0 else aabb.position.z + aabb.size.z
		)
		min_y = minf(min_y, (b * corner).y)
	if min_y == INF or absf(min_y) < 0.001:
		return
	var y_before := root.position.y
	# Lift root so lowest transformed point sits at origin Y.
	root.position.y -= min_y
	var anim := root.get_node_or_null("MdlAnimator")
	var clip := str(anim.get("_current_clip")) if anim else "(no MdlAnimator)"
	PiposhDebug.log_msg(
		"feet-snap",
		(
			"level=%s node=%s action=%s clip=%s local_aabb_size=%s min_y=%.3f "
			+ "y_before=%.3f y_after=%.3f"
		)
		% [
			level_name, root.name, str(root.get_meta("action", "")), clip,
			str(aabb.size), min_y, y_before, root.position.y,
		]
	)


func _mesh_aabb_local(node: Node, parent_xf: Transform3D, skip_node_xf: bool) -> AABB:
	var xf := parent_xf
	if node is Node3D and not skip_node_xf:
		xf = parent_xf * (node as Node3D).transform
	var acc := AABB()
	var has := false
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			acc = xf * mi.mesh.get_aabb()
			has = true
	for c in node.get_children():
		var ca := _mesh_aabb_local(c, xf, false)
		if ca.size.x <= 0.0 and ca.size.y <= 0.0 and ca.size.z <= 0.0:
			continue
		if not has:
			acc = ca
			has = true
		else:
			acc = acc.merge(ca)
	return acc if has else AABB()


func _spawn_entity(obj: Dictionary) -> bool:
	var file: String = str(obj.get("file", ""))
	var action: String = str(obj.get("action", ""))
	var pos := _vec3(obj.get("origin", [0, 0, 0]), Vector3.ZERO)
	if pos.length() > MAX_ORIGIN_DIST:
		return false

	# Plane.wdl's `action PiposhWalk` (Piposh's walk-in at level start) is
	# WED-authored ~73 units below the cabin's real floor -- Godot Y=-39,
	# while the surrounding cabin (Pip Y=34, Krup Y=35, Dummy Y=49, raw
	# JSON origins) sits at the correct height. No WDL script anywhere
	# manages the height axis directly around actor_move() -- the
	# original engine's own actor_move() floor-snaps for free every
	# tick, so this port's straight-line X/Z-only _do_actor_move() just
	# leaves him pinned at spawn height forever. A real per-tick raycast
	# floor-snap (matching the original engine) was tried and reverted:
	# on this exact mesh it locked onto the wrong collision surface (an
	# upper-deck/ceiling hit above the ray's rising start point) and
	# climbed away instead of settling -- too fragile to ship without
	# visual verification, and touching every actor_move() call site in
	# the corpus for one report is out of proportion anyway.
	#
	# An in-line raw-Y snap was tried here first (this level's own
	# `floor_y`, then Pip's raw origin.y=34) and reverted both times: a
	# raw JSON Y isn't comparable to `pos.y` at this point in the
	# pipeline, since feet-snap/scale/basis transforms haven't been
	# applied yet -- `floor_y` overshot Krupnik's real spawned height by
	# ~24 Godot units even after matching Pip's own raw origin (reported
	# live 2026-08-01 twice: first "lower than he should be", then, after
	# the floor_y fix, "too high... should be the same height as
	# Krupnik"). That ~24-unit figure turned out to be the real clue:
	# matching Krupnik's own post-feet-snap height fixed the spawn report
	# but a later one (2026-08-02) found Piposh still visibly sunk under
	# the floor throughout the walk and at the stop, confirmed via the
	# `[feet-snap]` debug log that Krupnik's model (Krup2.MDL/Krupnik.MDL)
	# and Piposh's own model (Piposh.MDL) get very different feet-to-
	# origin corrections (~-33.4 to -33.6 vs ~-58.2 to -58.4) -- matching
	# a DIFFERENT model's feet-snap result left him exactly that ~24
	# units short. See `_snap_piposh_walk_to_pip()` (called once after
	# every entity has actually finished spawning, at the very end of
	# `load_level()`): copies `action Pip`'s real, already-transformed
	# `global_position.y` onto Piposh instead -- `Pip` is the SAME
	# Piposh.MDL model (a second placement used as the cockpit-cutscene
	# stand-in, toggled by `Pip2`), sitting at essentially the same floor
	# height as Krupnik (raw Y=34 vs 35), so this keeps the match on the
	# same model throughout instead of borrowing a different one's
	# geometry-dependent correction.

	var scl := _vec3(obj.get("scale", [1, 1, 1]), Vector3.ONE)
	# Preserve authored scales (Island=20). Only reject insane non-uniform junk.
	if scl.x <= 0.0 or scl.y <= 0.0 or scl.z <= 0.0:
		scl = Vector3.ONE
	if maxf(scl.x, maxf(scl.y, scl.z)) > MAX_UNIFORM_SCALE:
		return false

	var root := Node3D.new()
	root.name = str(obj.get("name", file)).replace(".", "_")
	root.set_meta("action", action)
	root.set_meta("skills", obj.get("skills", []))
	root.set_meta("file", file)
	if obj.has("origin_gs"):
		root.set_meta("origin_gs", obj.get("origin_gs"))
	# Acknex pan/tilt/roll via Conitec ang_to_matrix → Godot basis.
	# Euler (tilt,±pan,roll) is wrong when tilt/roll ≠ 0 (Glass, Cam2, …).
	var pan_a := 0.0
	var tilt_a := 0.0
	var roll_a := 0.0
	if obj.has("angle_gs"):
		var ag: Variant = obj.get("angle_gs")
		if ag is Array and ag.size() >= 2:
			pan_a = float(ag[0])
			tilt_a = float(ag[1])
			roll_a = float(ag[2]) if ag.size() > 2 else 0.0
			root.set_meta("angle_gs", ag)
		else:
			var legacy := _legacy_pan_tilt_roll(obj)
			pan_a = legacy.x
			tilt_a = legacy.y
			roll_a = legacy.z
	else:
		var legacy2 := _legacy_pan_tilt_roll(obj)
		pan_a = legacy2.x
		tilt_a = legacy2.y
		roll_a = legacy2.z
	root.set_meta("pan", pan_a)
	root.set_meta("tilt", tilt_a)
	root.set_meta("roll", roll_a)
	# GB-7 continued (2026-08-04, Range): "on retry we should restart the
	# position of the cursor as well." `pan`/`tilt`/`roll` above are the
	# LIVE, mutable per-tick values (Range's own `action CamTarget`
	# accumulates into them every frame, `my.pan = my.pan - mickey.x/
	# SEN;`) -- once that coroutine's spawn-time value is overwritten,
	# the WED-authored starting orientation is gone. Its own coroutine
	# never restarts on a WDL-level "retry" (only `main()` gets called
	# again, not every entity's own action), so nothing else ever
	# reset the player's look direction back to where the level actually
	# started them facing. Preserved separately, immutable, so
	# WdlInterpreter._do_level_load() (or anything else wanting a real
	# "reset to spawn facing") has a real value to reset to.
	root.set_meta("wdl_spawn_pan", pan_a)
	root.set_meta("wdl_spawn_tilt", tilt_a)
	root.set_meta("wdl_spawn_roll", roll_a)
	# WED origin + local scale, then ang_to_matrix orientation (1:1 with A5).
	root.transform = Transform3D(
		_acknex_entity_basis(pan_a, tilt_a, roll_a) * Basis.from_scale(scl),
		pos
	)
	var flags := int(obj.get("flags", 0))
	root.set_meta("flags", flags)
	# A5 WED: bit0 = INVISIBLE, bit10 (0x400) = passable/non-solid prop.
	var flag_invisible := (flags & 0x1) != 0
	var flag_passable := (flags & 0x400) != 0
	root.set_meta("invisible", flag_invisible)
	root.set_meta("passable", flag_passable)

	var stem := file.get_file().get_basename()
	var is_wmb := file.to_lower().ends_with(".wmb")
	# SEAM 3 — per-entity visual. Only .wmb-backed props change source; .mdl
	# props keep going through _find_glb() either way (MDL is a separate reader
	# and a separate migration step). Everything after `inst` is shared.
	var inst: Node = null
	if use_runtime_wmb and is_wmb:
		inst = _build_runtime_wmb_node(stem)
	else:
		var glb_path := _find_wmb_glb(stem) if is_wmb else _find_glb(stem)
		if glb_path != "":
			var packed := load(glb_path)
			if packed is PackedScene:
				inst = (packed as PackedScene).instantiate()

	if inst != null:
		_force_unshaded_if_needed(inst, is_wmb)
		root.add_child(inst)
		if not is_wmb:
			_attach_animator(root, stem, action)
		# Opt-in feet-snap for floor actors only (see CONTRACT).
		if _should_feet_snap(action, stem):
			_snap_mesh_feet_to_origin(root, scl.y)
		if stem.to_lower() in ["shiknote", "afg"]:
			_mount_wall_card(root, stem.to_lower())
		# FP levels need solid props; skip passable / cameras / FP body.
		if (
			not is_wmb
			and not flag_passable
			and not _is_camera_action(action)
			and not _is_first_person_action(action)
			and stem.to_lower() != "cam"
		):
			_add_mesh_collision(inst)
	else:
		_add_marker(root, action, is_wmb)

	# Camera placeholders should not render Cam.MDL blobs. `action Dummy`
	# is the same shape of problem: a corpus-wide convention (checked every
	# `action Dummy` definition across the original .wdl corpus -- AsyAct1,
	# AsyAct3, Credits, Dutyfree, HitUFO, Inn, Intro2, MOI, Shiks, Studio)
	# for a pure logic/sound-position marker, never a real gameplay visual
	# -- AsyAct3's own copy even explicitly does `my.invisible = on;`
	# itself. `Dummy.MDL`'s real (small, roughly spherical, unremarkable)
	# geometry was apparently unobtrusive enough in the original low-res
	# game to go unnoticed; in this port it renders as a plainly visible
	# stray sphere. Reported live in Studio (2026-07-31): "black balls...
	# shouldn't appear visually or at all... don't know how it reached the
	# Ami level" -- it's not level-specific, `action Dummy` is used the
	# same way everywhere.
	if _is_camera_action(action) or stem.to_lower() == "cam" or flag_invisible or action.to_lower() == "dummy":
		_hide_meshes(root)
		# GB-8 continued (2026-08-07, Range): "none of my shots were
		# triggered even when they were accurate." A `Cam.MDL`-stem
		# placeholder with action "CameraEngine" (unmatched -- no such
		# action is declared anywhere Range.wdl includes, so it runs no
		# script and just sits there) turned out to be positioned close
		# enough to the shooter's own line of fire to catch a fired
		# bullet within its first frame or two of travel almost every
		# time, well before it ever reached a real target --
		# `WdlInterpreter._check_impact_proximity()`'s own generic
		# entity-vs-entity distance check has no notion of "this thing
		# isn't really here," so an invisible camera-rig marker was just
		# as solid an obstacle as any real target. Every marker hidden
		# right here for the exact same reason (a pure logic/position
		# helper, never meant to be a physical presence in the game
		# world) gets flagged so that check can skip it too.
		root.set_meta("wdl_non_physical", true)

	if _is_trigger_action(action) or (is_wmb and action.to_lower().contains("door")):
		var area := Area3D.new()
		area.monitoring = true
		area.collision_layer = 0
		area.collision_mask = 1
		var cs := CollisionShape3D.new()
		var shape := SphereShape3D.new()
		shape.radius = 2.5
		cs.shape = shape
		area.add_child(cs)
		area.body_entered.connect(_on_trigger.bind(root))
		root.add_child(area)

	_entities_root.add_child(root)
	# GB-7 continued (2026-08-07, Range): "restarting the stage after
	# dying should reset the enemies on screen as well." Mirrors
	# `wdl_spawn_pan/tilt/roll`'s own preservation (see that meta's own
	# comment) but for position -- captured only now, after `add_child()`,
	# so `global_position` reflects every adjustment already applied
	# (feet-snap included, `_snap_mesh_feet_to_origin()` above), not the
	# raw pre-adjustment WED origin. `WdlInterpreter._reset_entity_to_spawn()`
	# uses this (alongside the pan/tilt/roll meta and a fresh copy of the
	# entity's own pristine `skills` array) to put an entity back to
	# exactly how it looked the moment the level first began.
	root.set_meta("wdl_spawn_position", root.global_position)

	# First-person player proxy (Plane2 player_walk2, Inn, Mansion, …).
	# Record after feet-snap + enter tree so origin matches the standing pose.
	if _is_first_person_action(action) and first_person_spawn.is_empty():
		first_person_spawn = {
			"origin": root.global_position,
			"pan": pan_a,
			"tilt": tilt_a,
			"action": action,
			"node": root,
		}
		spawn_position = root.global_position
		# move_view_1st GENIUS — don't draw the player body in FP.
		_hide_meshes(root)
	return true


func _is_first_person_action(action: String) -> bool:
	var a := action.to_lower()
	return (
		a.begins_with("player_walk")
		or a in ["player_stand", "player_fly", "player_walkinn", "player_walktravel"]
	)


func _should_feet_snap(action: String, stem: String) -> bool:
	## Opt-OUT: snap by default. WED origin is the floor/attachment point and
	## MDL geometry commonly hangs below it — without this, curtains, fans,
	## and light-rig props (StudioL) sink under the floor. A prior rewrite
	## inverted this to opt-in (floor actors only), which silently stopped
	## snapping every non-whitelisted prop — regression found via a user
	## playtest report ("fans, lights and curtains a bit down under the
	## floor" in Studio); see docs/SESSION_LOG.md. Only exclude entities
	## whose origin is deliberately NOT a floor/feet reference.
	if _is_camera_action(action) or stem.to_lower() == "cam":
		return false
	var a := action.to_lower()
	var s := stem.to_lower()
	if s in ["afg", "shiknote"]:
		return false
	if a == "window":
		return false
	# Every remaining stem exclusion below is a measured verdict (GLB local-Y
	# AABB vs. WED origin + a grep of the entity's real WDL `action` body for
	# runtime position control), not a carried-over guess — see
	# docs/CONTRACT.md §3.5 for the full method and numbers. "tv", "hanger",
	# and "towerw" used to be in this list too; measurement showed the same
	# bug shape as Cockpit (mesh hangs mostly below its own origin, no WDL
	# action ever moves them) and they were removed 2026-07-28.
	if s in [
		"glass",   # 6.7% of mesh below origin (Dutyfree-shaped) — already sits at its own floor.
		"b747",    # `action B747` (Plane2.wdl) assigns my.z directly during takeoff — runtime vehicle, not a floor prop.
		"island",  # `action Land` (Plane3.wdl) assigns my.y/my.z at runtime (descends, then slides) — a runtime-animated prop, not a floor prop; also sits ~387 units below floor_y in both Plane3 and Town.
		"headphon",
		"biplane", "biplane2",  # `action Fly` (Intro4.wdl) does my.x += .. ; my.z += .. — a real runtime-moving vehicle, same class as b747.
		"dutyfree",  # mesh spans [0.44, 224.93] local Y — origin already sits at the mesh's own bottom.
	]:
		return false
	# "cockpit" was excluded here on the assumption it's fixed attachment
	# scenery like a ceiling light, needing no feet/origin correction.
	# Measured directly from Cockpit.glb: local Y spans -165.66..+76.83 (the
	# mesh hangs mostly BELOW its own origin, same shape of bug as StudioL's
	# light rigs) — so it needs the opt-out default like everything else,
	# not an exclusion. User screenshot confirmed the console rendering
	# mostly below floor level in Plane/Plane2 (docs/SESSION_LOG.md).
	if a in ["headphone", "land", "wind", "ent_rotate", "item_pickup"]:
		return false
	return true


func _acknex_entity_basis(pan_deg: float, tilt_deg: float, roll_deg: float) -> Basis:
	## Conitec ang_to_matrix (DirectX) conjugated by S=diag(1,1,-1) → Godot RH.
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
	# Rows of ang_to_matrix = entity axes in DirectX Y-up.
	var x_dx := Vector3(ct * cp, st, ct * sp)
	var y_dx := Vector3(-cr * st * cp + sr * sp, cr * ct, -cr * st * sp - sr * cp)
	var z_dx := Vector3(-sr * st * cp - cr * sp, sr * ct, cr * cp - sr * st * sp)
	# R_g = S * R_dx * S with S=diag(1,1,-1): flip Z on X/Y axes, flip X/Y on Z.
	var x_g := Vector3(x_dx.x, x_dx.y, -x_dx.z)
	var y_g := Vector3(y_dx.x, y_dx.y, -y_dx.z)
	var z_g := Vector3(-z_dx.x, -z_dx.y, z_dx.z)
	return Basis(x_g, y_g, z_g)


func _legacy_pan_tilt_roll(obj: Dictionary) -> Vector3:
	# Early extractors stored Godot euler as [tilt, -pan, roll].
	# Returns (pan, tilt, roll) in Acknex order.
	var ad: Variant = obj.get("angle_deg", [0, 0, 0])
	if ad is Array and ad.size() >= 2:
		var tilt_a := float(ad[0])
		var pan_a := -float(ad[1])
		var roll_a := float(ad[2]) if ad.size() > 2 else 0.0
		return Vector3(pan_a, tilt_a, roll_a)
	return Vector3.ZERO


func _mount_wall_card(root: Node3D, stem: String) -> void:
	# Pull off the far wall so the card is not buried in brush z-fighting.
	# Keep WED pan/tilt/roll (angle_gs) — do not invent facing overrides.
	root.position.z -= 6.0
	if stem == "shiknote":
		# Extracted brush is an edge-on slab; poster uses WED pan (usually 180).
		_hide_meshes(root)
		var mi := MeshInstance3D.new()
		mi.name = "ShikNotePoster"
		var quad := QuadMesh.new()
		quad.size = Vector2(58.0, 72.0)
		mi.mesh = quad
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.05
		var tex_path := "res://assets/converted/wmb/ShikNote_modaa1.png"
		if ResourceLoader.exists(tex_path):
			mat.albedo_texture = load(tex_path) as Texture2D
		else:
			mat.albedo_color = Color(0.85, 0.75, 0.45)
		mi.material_override = mat
		# The quad is centered on the entity's raw WED origin, which isn't
		# guaranteed to be the poster's own intended visual center (this
		# whole quad is a hand-placed replacement for a brush the original
		# extraction couldn't render sensibly -- see above -- not a
		# measured position). Reported live as sitting visibly low
		# (2026-07-31); nudged up by a fixed fraction of the quad's own
		# height rather than a raw unit guess. Unconfirmed pending
		# playtest -- adjust or revert if still off.
		mi.position.y += quad.size.y * 0.12
		# Quad faces +Z; WED pan orients the card (flatten authored tilt/roll).
		var pan := float(root.get_meta("pan", 180.0))
		root.transform = Transform3D(_acknex_entity_basis(pan, 0.0, 0.0), root.position)
		root.add_child(mi)
	elif stem == "afg":
		# WED already authored roll≈89 / tilt≈6 — only fix tiny scale.
		if root.scale.x < 0.9:
			root.scale *= 1.8


func _attach_animator(root: Node3D, stem: String, action: String) -> void:
	if root.get_node_or_null("MdlAnimator") != null:
		return
	var anim := MdlAnimator.new()
	anim.name = "MdlAnimator"
	anim.autoplay_clip = _default_anim_clip(action, stem)
	root.add_child(anim)
	if not anim.setup_from_stem(stem, root):
		anim.queue_free()


func _default_anim_clip(action: String, stem: String) -> String:
	var a := action.to_lower()
	var s := stem.to_lower()
	if a in ["patrolcity", "sportcar"] or s.contains("car"):
		return "Walk"
	if a in ["cow", "cow2", "arrow1", "arrow2", "crowd", "ship", "falling", "pisafall", "thebeam"]:
		return "Frame"
	# Studio ceiling fan / smoke props
	if s in ["sfan", "shtomba"]:
		return "Frame"
	if a in ["ami", "naknik", "kazale", "dummy"] or s in ["ami", "piposh", "piposh2", "fpiposh", "pipdog"]:
		return "Stand"
	if a == "defineyachdel" or s.contains("yach"):
		return "Speech"
	if a == "drawbridge":
		return "Closed"
	return "Stand"


func _force_unshaded_if_needed(node: Node, repeat_textures: bool = false) -> void:
	# Was SHADING_MODE_UNSHADED under the assumption "match mdl-texture-editor
	# / A5: unlit textured meshes" -- that assumption is contradicted by a
	# real original .exe screenshot (Start level, Yachdal/crowd scene):
	# models are visibly shaded/lit, not flat-colored. This function runs on
	# every brush wall/floor and every non-animated prop in every level, so
	# it was the dominant reason the whole port looked flat -- WMB light
	# entities were already being spawned as real OmniLight3D nodes
	# (_spawn_light) but had nothing that could receive them. Switched to lit
	# so those lights (plus the level's ambient) actually show up. Name kept
	# for now despite no longer forcing unshaded — rename is a follow-up, not
	# urgent. (docs/SESSION_LOG.md 2026-07-27)
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		# Imported LODs destroy seam UVs on low-poly MDL skins — stay on LOD0.
		mi.lod_bias = 128.0
		if mi.mesh:
			for i in mi.mesh.get_surface_count():
				var mat := mi.get_active_material(i)
				if mat == null and mi.mesh.surface_get_material(i) != null:
					mat = mi.mesh.surface_get_material(i)
				if mat is BaseMaterial3D:
					# Reported live (2026-08-10): "the Smash level still has
					# the weird cloud artifacts" -- traced via direct
					# isolation (hiding AcknexSky's own cylinder AND forcing
					# a flat BG_COLOR background both left the pattern fully
					# intact) to something entirely outside AcknexSky: real
					# WMB BRUSH GEOMETRY. A genuine, corpus-wide Acknex/
					# Quake-family convention -- confirmed via a plain
					# filename scan across every converted level -- surface
					# textures literally named "sky*" (`skywhite.png`/
					# `skyblue.png`, 18 levels including Town/Smash) mark
					# polygons the REAL engine renders as an infinite-
					# distance backdrop (same idea as this port's own
					# AcknexSky), not literal tiled wall/ceiling geometry.
					# This port's own WMB extraction (`tools/extract_wmb_
					# mesh.py`) has no such special case at all -- it just
					# emits these faces as ordinary textured triangles, so
					# they render as a real, static, densely-repeating
					# cloud-pattern surface hanging above the level instead
					# of the (already-correct) procedural sky showing
					# through. Fixed here rather than in the offline
					# conversion pipeline (narrower blast radius, no
					# regeneration of 18 levels' own GLBs needed): any
					# surface whose own texture file is named "sky*" is
					# made fully transparent instead of getting the normal
					# lit material, letting AcknexSky's own sky dome show
					# through in its place.
					# NOTE: brush materials/textures are loaded at runtime straight
					# out of "{Level}_brush.glb" (see _resolve_brush_glb below), so
					# Texture2D.resource_path is an internal glTF-packed path like
					# "Town_brush.glb::ImageTexture_bkbhm" -- it never contains the
					# original texture's name. The glTF material *name* does,
					# though (confirmed live via tools/diag_town_brush_mats.gd:
					# mat.resource_name == "skywhite" for exactly this surface),
					# since the exporter carries the original Acknex texture name
					# through as the glTF material name. Check that instead of the
					# texture path.
					#
					# Reported live again after the "sky"-substring fix (2026-08-10,
					# Town): the cloud wallpaper was gone but the sky itself still
					# rendered as a flat, featureless wall of color instead of the
					# real starry AcknexSky gradient. Traced via a physics raycast
					# fanned out from the live camera (every pitch from 0 to 89
					# degrees hit real collision geometry, never "no hit") to a
					# SEPARATE brush surface: a flat ceiling polygon capping the
					# entire level at its own bounding box's top, using a texture
					# whose name is a literal empty string in the source WMB data
					# (`tools/extract_wmb_mesh.py`'s `_load_textures()` reads a raw
					# 16-byte name field straight from the WMB texture lump --
					# Godot's own glTF importer then labels the resulting anonymous
					# material "#default"). A corpus scan (multiple levels' own
					# `_brush.glb` files) found this exact blank-name pattern is not
					# Town-specific -- Desert and MOI have it too, always as a face
					# sealing the level from above/outside -- and also turned up a
					# SECOND sky-naming convention this corpus uses beyond "sky*"/
					# "zSKYNEW": French "ciel" ("sky"/"ceiling") -- Mansion's
					# mansion_ciel/mansion_ciel2/mansion_roomcie, MOI's CIEL, and
					# Shiks's CIELIN/shiks_ciel are all real, named backdrop-type
					# surfaces in the actual source data, not a guess. Both new
					# signals are genuine properties of the original WMB/WED data
					# (a designer-left-blank texture name, or a French synonym for
					# "sky"), not heuristics invented from this port's own geometry.
					var mat_name := mat.resource_name.to_lower()
					if mat_name.contains("sky") or mat_name.contains("ciel") or mat_name == "" or mat_name == "#default":
						var invis := StandardMaterial3D.new()
						invis.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
						invis.albedo_color = Color(1, 1, 1, 0)
						mi.set_surface_override_material(i, invis)
						continue
					# Duplicate so we don't mutate the shared imported resource.
					var bm := (mat as BaseMaterial3D).duplicate() as BaseMaterial3D
					bm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
					# Reported live (2026-08-10), confirmed via a real non-
					# headless capture of this port's own Town level: ground/
					# terrain brush geometry rendered as visibly blocky,
					# stair-stepped color bands instead of the original's
					# smooth gradient slope. `repeat_textures` (true only for
					# `_spawn_brush_geometry()`'s own WMB level geometry --
					# terrain/walls/floors -- false for MDL character/prop
					# skins) already exists as exactly this distinction, just
					# not applied to filtering: NEAREST was chosen (with the
					# comment below) specifically to keep hard, crisp edges on
					# alpha-scissor CHARACTER skins, but the same reasoning
					# doesn't apply to solid, non-cutout brush textures like
					# terrain -- there smooth filtering is what actually
					# matches "a gradient", not blocky texel edges. Nearest
					# stays for props/characters (repeat_textures=false); brush
					# geometry now gets real mipmapped linear filtering.
					if repeat_textures:
						bm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
					else:
						# No mipmaps here: they blur + darken alpha-scissor pixel skins.
						bm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
					bm.cull_mode = BaseMaterial3D.CULL_DISABLED
					# Color-key cutout (RGB565 0 / palette index 0).
					bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
					bm.alpha_scissor_threshold = 0.1
					bm.texture_repeat = repeat_textures
					bm.metallic = 0.0
					bm.roughness = 1.0
					bm.disable_receive_shadows = true
					bm.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
					bm.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
					mi.set_surface_override_material(i, bm)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in node.get_children():
		_force_unshaded_if_needed(c, repeat_textures)


func _add_marker(root: Node3D, action: String, is_wmb: bool) -> void:
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.5 if is_wmb else 0.35
	mi.mesh = sphere
	var mat := StandardMaterial3D.new()
	if action.to_lower().contains("door"):
		mat.albedo_color = Color(0.9, 0.45, 0.15)
	elif is_wmb:
		mat.albedo_color = Color(0.55, 0.35, 0.8)
	else:
		mat.albedo_color = Color(0.35, 0.65, 0.95)
	mi.material_override = mat
	root.add_child(mi)


func _spawn_light(obj: Dictionary) -> void:
	var pos := _vec3(obj.get("origin", [0, 0, 0]), Vector3.ZERO)
	if pos.length() > MAX_ORIGIN_DIST:
		return
	var color: Array = obj.get("color", [1, 1, 1])
	var light := OmniLight3D.new()
	light.position = pos
	light.light_color = Color(
		clampf(float(color[0]), 0.0, 1.0),
		clampf(float(color[1]), 0.0, 1.0),
		clampf(float(color[2]), 0.0, 1.0)
	)
	var rng := float(obj.get("range", 300.0))
	light.omni_range = clampf(rng * 0.05, 4.0, 120.0)
	light.light_energy = 1.1
	_entities_root.add_child(light)


func _build_glb_index() -> void:
	_glb_index.clear()
	_wmb_index.clear()
	_index_glb_dir(MDL_DIR, _glb_index)
	_index_glb_dir(WMB_DIR, _wmb_index)


func _index_glb_dir(dir_path: String, into: Dictionary) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir() and fn.to_lower().ends_with(".glb"):
			into[fn.get_basename().to_lower()] = dir_path + fn
		fn = dir.get_next()


func _direct_glb(dir_path: String, stem: String) -> String:
	## Packed Android builds often can't DirAccess-list res:// — probe known paths.
	var casings: Array[String] = [stem, stem.to_lower()]
	if stem.length() > 0:
		casings.append(stem.substr(0, 1).to_upper() + stem.substr(1).to_lower())
	for s in casings:
		var path: String = dir_path + s + ".glb"
		if ResourceLoader.exists(path):
			return path
	return ""


func _find_glb(stem: String) -> String:
	var direct := _direct_glb(MDL_DIR, stem)
	if direct != "":
		return direct
	if _glb_index.is_empty():
		_build_glb_index()
	var key := stem.to_lower()
	if _glb_index.has(key):
		var indexed := str(_glb_index[key])
		if ResourceLoader.exists(indexed) or FileAccess.file_exists(indexed):
			return indexed
	if key.length() >= 6:
		for k in _glb_index.keys():
			if str(k).begins_with(key) or key.begins_with(str(k)):
				var path2 := str(_glb_index[k])
				if ResourceLoader.exists(path2) or FileAccess.file_exists(path2):
					return path2
	return ""


func _find_wmb_glb(stem: String) -> String:
	var direct := _direct_glb(WMB_DIR, stem)
	if direct != "":
		return direct
	if _wmb_index.is_empty():
		_build_glb_index()
	var key := stem.to_lower()
	if _wmb_index.has(key):
		var indexed := str(_wmb_index[key])
		if ResourceLoader.exists(indexed) or FileAccess.file_exists(indexed):
			return indexed
	# Also allow level-style brush names if a prop was exported there.
	var brush_stems: Array[String] = [stem, stem.to_lower()]
	for s in brush_stems:
		var brush: String = LEVEL_DIR + s + "_brush.glb"
		if _file_ok(brush):
			return brush
	return ""


func _is_camera_action(action: String) -> bool:
	var a := action.to_lower()
	return a in [
		"cam", "thecam", "thecam2", "farcam", "scam", "cammy", "lookatme",
		"mycamera", "pipicam",
	]


func _hide_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).visible = false
	for c in node.get_children():
		_hide_meshes(c)


func _is_trigger_action(action: String) -> bool:
	var a := action.to_lower()
	return a.contains("door") or a.begins_with("menu") or a == "gotodoor" or a == "menudoor"


func _on_trigger(body: Node3D, entity: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	entity_triggered.emit(str(entity.get_meta("action", "")), entity.get_meta("skills", []), entity)


func _vec3(v: Variant, fallback: Vector3) -> Vector3:
	if v is Array and v.size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return fallback
