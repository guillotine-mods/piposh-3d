extends SceneTree
## Engine-level oracle for the runtime MDL reader wired into the level loader.
##
## This asks a DIFFERENT question from tools/smoke_mdl_reader.gd. That one
## proves `reader == Python` at the byte level (648/648 geometry, 648/648 skins,
## 213M texels): the numbers coming out of `MdlFile` are identical to what
## `tools/convert_mdl.py` wrote into `assets/converted/mdl/*.glb`. It says
## nothing about what the ENGINE then does with those numbers, and nothing at
## all about the two ANIMATION sidecars (`.mdlanim`, `.skins`), which it never
## reads.
##
## This one proves `engine-fed-by-reader == engine-fed-by-GLB+sidecars`: the
## same `WmbLevelLoader` builds each level twice in one process -- once with
## `use_runtime_mdl = false` (glb + `.mdlanim` + `.skins`, exactly what ships
## today) and once with `use_runtime_mdl = true` (`MdlFile` reading
## `original/piposh3d/MDL/*.MDL`) -- and the two resulting SCENES are compared:
##
##   * number of spawned entity nodes under Entities/
##   * their names, in order, and their classes
##   * their global transforms (basis + origin), which is where a feet-snap
##     difference would show up, since _snap_mesh_feet_to_origin() measures the
##     spawned mesh's own AABB
##   * per-entity MeshInstance3D count, vertex total and index total, which is
##     what catches a real model silently degrading into an `_add_marker` sphere
##   * per-entity ANIMATION: whether an MdlAnimator attached at all, its clip
##     table (every clip name with its frame count), the frame count, the anim
##     vertex count, the skin count, the clip it settled on and whether it is
##     cycling or holding
##   * per-entity animation DATA: `_positions` compared element by element --
##     frame_count * anim_verts * 3 float32s, the actual morph targets. This is
##     the real test of the clip work; matching clip NAMES with different vertex
##     data would be a silent lie.
##
## Lights (`_spawn_light`) are children of Entities/ too but are added unnamed,
## so Godot assigns them a process-global "@OmniLight3D@NN" counter that
## necessarily differs between the first and second build in the same process.
## They are compared by class + transform under a synthetic "<OmniLight3D>"
## label instead; that is a property of Godot's node naming, not a difference
## between the two paths.
##
##   godot --path . --headless -s res://tools/smoke_mdl_integration.gd
##   godot --path . --headless -s res://tools/smoke_mdl_integration.gd -- --only=Studio
##   godot --path . --headless -s res://tools/smoke_mdl_integration.gd -- --all
##   godot --path . --headless -s res://tools/smoke_mdl_integration.gd -- --all --start=0 --count=40
##
## Same memory caveat as tools/smoke_wmb_integration.gd: `--all` builds 2 scenes
## per level and every GLB/texture/skin it touches stays in Godot's resource
## cache for the life of the process, so the whole corpus in one run can exhaust
## memory partway through. `--start`/`--count` sweep it in chunks.

## NOT a preload. `wmb_level_loader.gd` references the `PiposhDebug` autoload,
## and under `--headless -s <script>` Godot registers autoloads as global
## identifiers only AFTER the script main loop has been instantiated -- so any
## `preload()` of it fails to compile with "Identifier not found: PiposhDebug"
## before `_init()` ever runs. `load()` from inside the deferred `_run()`
## happens after that registration.
var WmbLevelLoader: GDScript = null

## The five the task names: levels dense in animated characters and props.
const LEVELS := ["Start", "Town", "Shiks", "Studio", "Plane3"]

## Transforms are float32 all the way through on both paths, so an exact match
## is the expectation and anything non-zero gets printed. This is only the
## PASS/FAIL threshold.
const XF_EPS := 1.0e-4

## Morph target positions: both paths are float32. The sidecar path stores them
## as float32 bytes and reads them back; the runtime path hands over floats
## MdlFile already rounded to float32 at each arithmetic step. Exact equality is
## the expectation.
const POS_EPS := 1.0e-6


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
	print("=== engine scene: runtime MDL reader vs converted GLB + sidecars ===")
	print("levels: %s" % ", ".join(PackedStringArray(levels)))

	var diff_levels := 0
	var ok_levels := 0
	var failed_levels := 0
	var report: Array[String] = []

	for level in levels:
		var glb_snap := await _build(str(level), false)
		var mdl_snap := await _build(str(level), true)

		if not bool(glb_snap["loaded"]) or not bool(mdl_snap["loaded"]):
			failed_levels += 1
			print("")
			print("--- %s" % level)
			print("  LOAD FAILED  glb_path_ok=%s runtime_path_ok=%s"
				% [glb_snap["loaded"], mdl_snap["loaded"]])
			continue

		var diffs := _compare(glb_snap, mdl_snap)
		print("")
		print("--- %s" % level)
		print("  entities    : glb=%d  mdl=%d" % [
			(glb_snap["entities"] as Array).size(),
			(mdl_snap["entities"] as Array).size()])
		print("  meshed ents : glb=%d/%dv  mdl=%d/%dv" % [
			glb_snap["meshed"], glb_snap["verts"],
			mdl_snap["meshed"], mdl_snap["verts"]])
		print("  animators   : glb=%d (%d with clips)  mdl=%d (%d with clips)" % [
			glb_snap["animators"], glb_snap["clipped"],
			mdl_snap["animators"], mdl_snap["clipped"]])
		print("  anim frames : glb=%d  mdl=%d   anim verts: glb=%d  mdl=%d" % [
			glb_snap["frames"], mdl_snap["frames"],
			glb_snap["anim_verts"], mdl_snap["anim_verts"]])
		print("  skins       : glb=%d  mdl=%d   (real skin digests compared: glb=%d mdl=%d)" % [
			glb_snap["skins"], mdl_snap["skins"],
			glb_snap["skin_pixels"], mdl_snap["skin_pixels"]])
		# NOT a pass/fail field. The GLB path may need a real remap because
		# Godot's glTF import can reorder/weld vertices relative to the
		# `.mdlanim` order; the runtime path takes its mesh and its frames from
		# the same `pos_idx_list`, so identity is the expected answer there.
		# Either way the morph result is compared directly above.
		print("  vert remap  : glb identity=%d remapped=%d   mdl identity=%d remapped=%d" % [
			glb_snap["identity"], glb_snap["remapped"],
			mdl_snap["identity"], mdl_snap["remapped"]])
		print("  max |dXf|   : origin %.9f  basis %.9f" % [
			_max_origin_delta(glb_snap, mdl_snap),
			_max_basis_delta(glb_snap, mdl_snap)])
		print("  max |dPos|  : %.9f  (over %d compared float32s)" % [
			_max_pos_delta(glb_snap, mdl_snap), _pos_compared(glb_snap, mdl_snap)])
		print("  spawn/floor : glb=%s %.3f   mdl=%s %.3f" % [
			glb_snap["spawn"], glb_snap["floor_y"],
			mdl_snap["spawn"], mdl_snap["floor_y"]])

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
	print("smoke_mdl_integration: %s" % ("PASS" if pass_all else "FAIL"))
	quit(0 if pass_all else 1)


# ---------------------------------------------------------------------------
# Build + snapshot
# ---------------------------------------------------------------------------


func _build(level: String, runtime: bool) -> Dictionary:
	var host := Node3D.new()
	host.name = "Host_%s_%s" % [level, "mdl" if runtime else "glb"]
	root.add_child(host)
	var loader: Node3D = WmbLevelLoader.new()
	loader.use_runtime_mdl = runtime
	host.add_child(loader)
	await process_frame
	var ok: bool = loader.load_level(level)
	# One frame so MdlAnimator._process() has run at least once on both paths.
	await process_frame
	var snap := _snapshot(loader)
	snap["loaded"] = ok
	host.queue_free()
	await process_frame
	return snap


func _snapshot(loader: Node) -> Dictionary:
	var entities: Array = []
	var meshed := 0
	var verts := 0
	var animators := 0
	var clipped := 0
	var frames := 0
	var anim_verts := 0
	var skins := 0
	var identity := 0
	var skin_pixels := 0
	var remapped := 0
	var ents: Node = loader.get_node_or_null("Entities")
	if ents != null:
		for n in ents.get_children():
			var row := _entity_row(n)
			entities.append(row)
			if int(row["meshes"]) > 0:
				meshed += 1
			verts += int(row["mverts"])
			if str(row["remap"]).begins_with("identity"):
				identity += 1
			elif str(row["remap"]).begins_with("remapped"):
				remapped += 1
			if bool(row["has_anim"]):
				animators += 1
				if str(row["clips"]) != "":
					clipped += 1
				frames += int(row["frames"])
				anim_verts += int(row["anim_verts"])
				skins += int(row["skins"])
				# Guard against the check passing having compared nothing: a
				# digest of "null"/"noimg" on BOTH sides would match happily.
				for part in str(row["skin_sig"]).split(",", false):
					if str(part) != "" and str(part) != "null" and str(part) != "noimg":
						skin_pixels += 1

	return {
		"entities": entities,
		"meshed": meshed,
		"verts": verts,
		"animators": animators,
		"clipped": clipped,
		"frames": frames,
		"anim_verts": anim_verts,
		"skins": skins,
		"skin_pixels": skin_pixels,
		"identity": identity,
		"remapped": remapped,
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
	var midx := 0
	var normals := 0
	for mi in meshes:
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(i)
			mverts += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			midx += idx.size()
			var nrm = arrays[Mesh.ARRAY_NORMAL]
			if nrm != null and (nrm as PackedVector3Array).size() > 0:
				normals += 1

	var row := {
		"label": label,
		"class": n.get_class(),
		"xf": xf,
		"action": str(n.get_meta("action", "")) if n.has_meta("action") else "",
		"file": str(n.get_meta("file", "")) if n.has_meta("file") else "",
		"meshes": meshes.size(),
		"mverts": mverts,
		"midx": midx,
		"normals": normals,
		"has_anim": false,
		"clips": "",
		"frames": 0,
		"anim_verts": 0,
		"mesh_verts": 0,
		"skins": 0,
		"skin_sig": "",
		"clip": "",
		"playing": false,
		"remap": "",
		"positions": PackedFloat32Array(),
	}

	var anim: Node = n.get_node_or_null("MdlAnimator")
	if anim != null:
		row["has_anim"] = true
		row["clips"] = _clip_signature(anim.get("_clips"))
		row["frames"] = int(anim.get("_frame_count"))
		row["anim_verts"] = int(anim.get("_anim_verts"))
		row["mesh_verts"] = int(anim.get("_mesh_verts"))
		row["skins"] = int(anim.call("skin_count"))
		row["skin_sig"] = _skin_signature(anim.get("_skin_textures"))
		row["clip"] = str(anim.get("_current_clip"))
		row["playing"] = bool(anim.get("_playing"))
		row["remap"] = _remap_shape(anim.get("_remap"))
		# Packed arrays are copy-on-write, so this retains the buffer without
		# duplicating it -- the loader can be freed before the comparison.
		row["positions"] = anim.get("_positions")
	return row


## "Frame=6,Stand=2,Walk=8" -- every clip with its frame count, sorted so the
## comparison does not depend on dictionary insertion order (which is first-seen
## frame order on both paths, but is not what the engine keys off).
func _clip_signature(clips_v: Variant) -> String:
	if typeof(clips_v) != TYPE_DICTIONARY:
		return ""
	var clips: Dictionary = clips_v
	var keys: Array = clips.keys()
	keys.sort()
	var parts: Array[String] = []
	for k in keys:
		var key := str(k)
		var idxs: PackedInt32Array = clips[key]
		parts.append("%s=%d" % [key, idxs.size()])
	return ",".join(PackedStringArray(parts))


## Every skin the animator ended up holding, as "WxH/format/hash-of-pixels".
##
## This is the ONE part of the runtime path no existing oracle covers.
## tools/smoke_mdl_reader.gd compares skin 0 only (the single PNG `write_glb`
## embeds in the glTF); skins 1..N-1 live solely in the `.skins` sidecar, and
## they are what `my.skin` / Acknex Talk() / Blink() actually switch between.
##
## Both sides are fair to compare: the sidecar textures are decoded at RUNTIME
## from PNG bytes (`Image.load_png_from_buffer`) and never go through Godot's
## import pipeline, so neither side is VRAM-compressed (docs/BUGS.md GB-19 --
## which is exactly why the mesh's own imported albedo texture is deliberately
## NOT compared here).
func _skin_signature(textures_v: Variant) -> String:
	if typeof(textures_v) != TYPE_ARRAY:
		return ""
	var textures: Array = textures_v
	if textures.is_empty():
		return ""
	var parts: Array[String] = []
	for t in textures:
		var tex: Texture2D = t
		if tex == null:
			parts.append("null")
			continue
		var img: Image = tex.get_image()
		if img == null:
			parts.append("noimg")
			continue
		parts.append("%dx%d/%d/%d" % [
			img.get_width(), img.get_height(), img.get_format(), hash(img.get_data())])
	return ",".join(PackedStringArray(parts))


## The vertex remap MdlAnimator builds from the imported mesh onto the anim
## vertex order. "identity/N" means the mesh and the frame data are already in
## the same order (expected on the runtime path, where both come from the same
## `pos_idx_list`); "remapped/N" means Godot's glTF import reordered or welded
## vertices and the nearest-bind-pose match had to fix it up.
func _remap_shape(remap_v: Variant) -> String:
	if typeof(remap_v) != TYPE_PACKED_INT32_ARRAY:
		return "none"
	var remap: PackedInt32Array = remap_v
	if remap.is_empty():
		return "none"
	for i in remap.size():
		if remap[i] != i:
			return "remapped/%d" % remap.size()
	return "identity/%d" % remap.size()


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
		out.append("entity count: glb=%d mdl=%d" % [ea.size(), eb.size()])
	for i in mini(ea.size(), eb.size()):
		var x: Dictionary = ea[i]
		var y: Dictionary = eb[i]
		if x["label"] != y["label"]:
			out.append("entity[%d] name: glb=%s mdl=%s" % [i, x["label"], y["label"]])
			continue
		var who := "entity[%d] %s (action=%s file=%s)" % [i, x["label"], x["action"], x["file"]]
		if x["class"] != y["class"]:
			out.append("%s class: glb=%s mdl=%s" % [who, x["class"], y["class"]])
		var d := _xf_delta(x["xf"], y["xf"])
		if d > XF_EPS:
			out.append("%s transform delta=%.6f\n      glb=%s\n      mdl=%s"
				% [who, d, x["xf"], y["xf"]])
		if x["meshes"] != y["meshes"] or x["mverts"] != y["mverts"] or x["midx"] != y["midx"]:
			out.append("%s meshes glb=%d/%dv/%di mdl=%d/%dv/%di"
				% [who, x["meshes"], x["mverts"], x["midx"],
					y["meshes"], y["mverts"], y["midx"]])
		if bool(x["has_anim"]) != bool(y["has_anim"]):
			out.append("%s animator: glb=%s mdl=%s" % [who, x["has_anim"], y["has_anim"]])
			continue
		if not bool(x["has_anim"]):
			continue
		if str(x["clips"]) != str(y["clips"]):
			out.append("%s clips:\n      glb=%s\n      mdl=%s" % [who, x["clips"], y["clips"]])
		if int(x["frames"]) != int(y["frames"]) or int(x["anim_verts"]) != int(y["anim_verts"]):
			out.append("%s anim shape: glb=%df/%dv mdl=%df/%dv"
				% [who, x["frames"], x["anim_verts"], y["frames"], y["anim_verts"]])
		if int(x["skins"]) != int(y["skins"]):
			out.append("%s skins: glb=%d mdl=%d" % [who, x["skins"], y["skins"]])
		elif str(x["skin_sig"]) != str(y["skin_sig"]):
			out.append("%s skin pixels:\n      glb=%s\n      mdl=%s"
				% [who, x["skin_sig"], y["skin_sig"]])
		if str(x["clip"]) != str(y["clip"]) or bool(x["playing"]) != bool(y["playing"]):
			out.append("%s pose: glb=%s/playing=%s mdl=%s/playing=%s"
				% [who, x["clip"], x["playing"], y["clip"], y["playing"]])
		var pa: PackedFloat32Array = x["positions"]
		var pb: PackedFloat32Array = y["positions"]
		if pa.size() != pb.size():
			out.append("%s morph data size: glb=%d mdl=%d" % [who, pa.size(), pb.size()])
		else:
			var worst := 0.0
			var at := -1
			for j in pa.size():
				var dd := absf(pa[j] - pb[j])
				if dd > worst:
					worst = dd
					at = j
			if worst > POS_EPS:
				out.append("%s morph data: max |delta|=%.9f at float %d/%d (glb=%f mdl=%f)"
					% [who, worst, at, pa.size(), pa[at], pb[at]])

	if _v3_delta(a["spawn"], b["spawn"]) > XF_EPS:
		out.append("spawn_position: glb=%s mdl=%s" % [a["spawn"], b["spawn"]])
	if absf(float(a["floor_y"]) - float(b["floor_y"])) > XF_EPS:
		out.append("floor_y: glb=%f mdl=%f" % [a["floor_y"], b["floor_y"]])

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


func _max_pos_delta(a: Dictionary, b: Dictionary) -> float:
	var ea: Array = a["entities"]
	var eb: Array = b["entities"]
	var m := 0.0
	for i in mini(ea.size(), eb.size()):
		var pa: PackedFloat32Array = ea[i]["positions"]
		var pb: PackedFloat32Array = eb[i]["positions"]
		if pa.size() != pb.size():
			continue
		for j in pa.size():
			m = maxf(m, absf(pa[j] - pb[j]))
	return m


func _pos_compared(a: Dictionary, b: Dictionary) -> int:
	var ea: Array = a["entities"]
	var eb: Array = b["entities"]
	var n := 0
	for i in mini(ea.size(), eb.size()):
		var pa: PackedFloat32Array = ea[i]["positions"]
		var pb: PackedFloat32Array = eb[i]["positions"]
		if pa.size() == pb.size():
			n += pa.size()
	return n


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
