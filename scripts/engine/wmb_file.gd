extends RefCounted
## Runtime WMB reader: entities, lights, positions, paths, bounds, spawn.
##
## Third step of the 0-py migration, and the GDScript counterpart of
## `tools/extract_wmb_full.py`. Reads `original/piposh3d/WMB/*.WMB` directly and
## returns the same structure that tool writes to
## `assets/converted/levels/<Name>.json`. `tools/smoke_wmb_reader.gd` asserts
## that against all 134 committed level JSONs.
##
## Deliberately NO `class_name` (see commit 5c0adfa). Use via `preload`.
##
## Only the object/entity half is here. Brush geometry (extract_wmb_mesh.py) is
## the separate, larger piece and is where normals and lightmaps live.
##
## Transform rules come from `tools/gs_math.py` and CONTRACT.md, and are ported
## verbatim -- Acknex A5/WED is right-handed Z-up, so position (x,y,z) -> (x,z,-y)
## and scale (sx,sy,sz) -> (sx,sz,sy). Note this path contains NO trigonometry:
## `angle_deg` is the legacy approximate euler (accurate for pure pan only) and
## runtime orientation is supposed to come from `angle_gs` via ang_to_matrix, so
## the output here should be bit-exact against the Python, not merely close.

const OBJECTS_LIST := 15
const NUM_LISTS := 20


## Read a .WMB and return the level dictionary. Returns {} with `error` set on
## a file that has no objects list, matching the Python's ValueError path.
static func read_level(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"error": "cannot open %s" % path}
	var data := f.get_buffer(f.get_length())
	f.close()
	return read_level_bytes(data, path.get_file())


static func read_level_bytes(data: PackedByteArray, source_name: String) -> Dictionary:
	var magic := ""
	for i in mini(4, data.size()):
		magic += char(data[i])

	var lists := _read_lists(data)
	if lists.size() <= OBJECTS_LIST or int(lists[OBJECTS_LIST][1]) == 0:
		return {"error": "no objects list"}

	var base: int = lists[OBJECTS_LIST][0]
	var length: int = lists[OBJECTS_LIST][1]
	var chunk := data.slice(base, base + length)

	var objects: Array = []
	var paths: Array = []
	var info := {}

	var count := chunk.decode_u32(0)
	var offsets: Array = []
	for i in count:
		if 4 + i * 4 + 4 > chunk.size():
			break
		offsets.append(chunk.decode_u32(4 + i * 4))

	for rel in offsets:
		var o: int = rel
		if o + 4 > chunk.size():
			continue
		var typ := chunk.decode_u32(o)
		o += 4

		if typ == 5:
			info = {"type": "info"}
			continue

		if typ == 1:  # POSITION
			var origin := _vec3(chunk, o)
			o += 12
			var angle := _vec3(chunk, o)
			o += 20
			objects.append({
				"type": "position",
				"name": _c_str(chunk, o, 20),
				"origin_gs": origin,
				"origin": _pos_to_godot(origin),
				"angle_gs": angle,
				"angle_deg": _euler_to_godot_deg(angle),
			})
			continue

		if typ == 2:  # LIGHT
			var origin := _vec3(chunk, o)
			o += 12
			var r := chunk.decode_float(o)
			var g := chunk.decode_float(o + 4)
			var b := chunk.decode_float(o + 8)
			var rng := chunk.decode_float(o + 12)
			objects.append({
				"type": "light",
				"origin_gs": origin,
				"origin": _pos_to_godot(origin),
				"color": [r / 100.0, g / 100.0, b / 100.0],
				"range": rng,
			})
			continue

		if typ == 6:  # PATH
			_read_path(chunk, o, paths)
			continue

		if typ == 3:  # OLD ENTITY
			var origin := _vec3(chunk, o)
			o += 12
			var angle := _vec3(chunk, o)
			o += 12
			var scale := _vec3(chunk, o)
			o += 12
			var name := _c_str(chunk, o, 20)
			o += 20
			var filename := _c_str(chunk, o, 13)
			o += 13
			var action := _c_str(chunk, o, 20)
			o += 20
			# 3 pad bytes float-align skills (WED/A5 OLD ENTITY layout). Easy to
			# lose, and losing them yields plausible-but-wrong skills.
			o += 3
			var skills: Array = []
			for i in 8:
				skills.append(chunk.decode_float(o + i * 4))
			o += 32
			var flags := chunk.decode_u32(o) if o + 4 <= chunk.size() else 0
			objects.append({
				"type": "entity",
				"old": true,
				"name": name,
				"file": filename,
				"action": action,
				"origin_gs": origin,
				"origin": _pos_to_godot(origin),
				"angle_gs": angle,
				"angle_deg": _euler_to_godot_deg(angle),
				"scale_gs": scale,
				"scale": _scale_to_godot(scale),
				"skills": skills,
				"flags": flags,
			})
			continue

		if typ == 7:  # NEW ENTITY
			var origin := _vec3(chunk, o)
			o += 12
			var angle := _vec3(chunk, o)
			o += 12
			var scale := _vec3(chunk, o)
			o += 12
			var name := _c_str(chunk, o, 33)
			o += 33
			var filename := _c_str(chunk, o, 33)
			o += 33
			var action := _c_str(chunk, o, 33)
			o += 34
			var skills: Array = []
			for i in 20:
				skills.append(chunk.decode_float(o + i * 4))
			o += 80
			var flags := chunk.decode_u32(o)
			o += 4
			var ambient := chunk.decode_float(o)
			o += 4
			var albedo := chunk.decode_float(o)
			o += 4
			var path_idx := chunk.decode_s32(o)
			o += 4
			var ent2 := chunk.decode_u32(o)
			objects.append({
				"type": "entity",
				"old": false,
				"name": name,
				"file": filename,
				"action": action,
				"origin_gs": origin,
				"origin": _pos_to_godot(origin),
				"angle_gs": angle,
				"angle_deg": _euler_to_godot_deg(angle),
				"scale_gs": scale,
				"scale": _scale_to_godot(scale),
				"skills": skills,
				"flags": flags,
				"ambient": ambient,
				"albedo": albedo,
				"path": path_idx,
				"attached": ent2,
			})
			continue

	var bs := _bounds_and_spawn(objects)

	return {
		"source": source_name,
		"magic": magic,
		"script": source_name.get_basename() + ".wdl",
		"coord_space": "godot_y_up_from_acknex_z_up",
		"info": info,
		"bounds": bs["bounds"],
		"spawn": bs["spawn"],
		"paths": paths,
		"objects": objects,
	}


# ---------------------------------------------------------------------------
# Records
# ---------------------------------------------------------------------------

static func _read_lists(data: PackedByteArray) -> Array:
	var lists: Array = []
	var off := 4
	for _i in NUM_LISTS:
		if off + 8 > data.size():
			break
		var lo := data.decode_u32(off)
		var ln := data.decode_u32(off + 4)
		off += 8
		if ln == 0 and lo == 0:
			lists.append([lo, ln])
			continue
		if lo >= data.size() or lo + ln > data.size():
			break
		lists.append([lo, ln])
	return lists


## WMB5 often stores the point count in num_edges with fNumPoints=0.
static func _read_path(chunk: PackedByteArray, start: int, paths: Array) -> void:
	var o := start
	if o + 40 > chunk.size():
		return
	var name := _c_str(chunk, o, 20)
	o += 20
	var fnum := chunk.decode_float(o)
	o += 4
	o += 12  # unused[3]
	var num_edges := chunk.decode_u32(o)
	o += 4
	var npoints := int(fnum) if fnum >= 1.0 else int(num_edges)

	var points: Array = []
	for _i in maxi(npoints, 0):
		if o + 12 > chunk.size():
			break
		points.append(_pos_to_godot(_vec3(chunk, o)))
		o += 12

	var edges: Array = []
	var skills: Array = []
	if fnum >= 1.0:
		# WMB7-style per-point skills then edges.
		for _i in npoints:
			if o + 24 > chunk.size():
				break
			var s: Array = []
			for j in 6:
				s.append(chunk.decode_float(o + j * 4))
			skills.append(s)
			o += 24
		for _i in num_edges:
			if o + 24 > chunk.size():
				break
			edges.append({
				"a": int(chunk.decode_float(o)) - 1,
				"b": int(chunk.decode_float(o + 4)) - 1,
				"length": chunk.decode_float(o + 8),
				"bezier": chunk.decode_float(o + 12),
				"weight": chunk.decode_float(o + 16),
				"skill": chunk.decode_float(o + 20),
			})
			o += 24
	else:
		# Sequential loop path (Town's traffic cars): i -> i+1 -> 0.
		for i in points.size():
			edges.append({"a": i, "b": (i + 1) % points.size(), "length": 0.0})

	# Start.wmb has two paths both named path_001; keep keys unique so each
	# LookAtMe can bind to the nearest path.
	var base_name := name if name != "" else "path_%03d" % (paths.size() + 1)
	var unique := base_name
	var suffix := 2
	var existing := {}
	for p in paths:
		existing[p["name"]] = true
	while existing.has(unique):
		unique = "%s_%d" % [base_name, suffix]
		suffix += 1

	paths.append({"name": unique, "points": points, "skills": skills, "edges": edges})


# ---------------------------------------------------------------------------
# Bounds / spawn
# ---------------------------------------------------------------------------

static func _in_play(o: Array) -> bool:
	for v in o:
		if absf(v) > 20000:
			return false
	return true


static func _bounds_and_spawn(objects: Array) -> Dictionary:
	var pts: Array = []
	for o in objects:
		var t = o.get("type")
		if (t == "entity" or t == "light" or t == "position") and _in_play(o.get("origin", [0, 0, 0])):
			pts.append(o["origin"])

	var mn: Array
	var mx: Array
	var center: Array
	var size: Array
	var floor_y: float

	if pts.size() > 0:
		var ys: Array = []
		for p in pts:
			ys.append(p[1])
		ys.sort()
		var med_y := _median(ys)
		var band := maxf(80.0, (ys[ys.size() - 1] - ys[0]) * 0.05)
		var cluster: Array = []
		for p in pts:
			if absf(p[1] - med_y) <= band:
				cluster.append(p)
		if cluster.is_empty():
			cluster = pts
		var xs: Array = []
		var ys_c: Array = []
		var zs: Array = []
		for p in cluster:
			xs.append(p[0])
			ys_c.append(p[1])
			zs.append(p[2])
		mn = [_min_of(xs), _min_of(ys_c), _min_of(zs)]
		mx = [_max_of(xs), _max_of(ys_c), _max_of(zs)]
		center = [(mn[0] + mx[0]) * 0.5, (mn[1] + mx[1]) * 0.5, (mn[2] + mx[2]) * 0.5]
		size = [
			maxf(mx[0] - mn[0], 4.0),
			maxf(mx[1] - mn[1], 4.0),
			maxf(mx[2] - mn[2], 4.0),
		]
		# statistics.median sorts internally; ys_c is NOT pre-sorted here.
		floor_y = _median(ys_c)
	else:
		mn = [-20, 0, -20]
		mx = [20, 5, 20]
		center = [0, 1, 0]
		size = [40, 5, 40]
		floor_y = 0.0

	var spawn := [center[0], floor_y + 2.0, center[2] + 8.0]

	# Prefer Cam entities for spawn; skill1 is often the view index, so the one
	# nearest 1 wins. Python's sort is STABLE and GDScript's is not, so the
	# original index is used as an explicit tie-breaker -- without it, ties
	# resolve arbitrarily and a different camera can win.
	var cams: Array = []
	for i in objects.size():
		var e = objects[i]
		if e.get("type") == "entity" and str(e.get("action", "")).to_lower() == "cam":
			var sk = e.get("skills")
			var key: float = float(sk[0]) if (sk is Array and not sk.is_empty()) else 1.0
			cams.append([absf(key - 1.0), i, e])
	if not cams.is_empty():
		cams.sort_custom(func(a, b):
			if a[0] == b[0]:
				return a[1] < b[1]
			return a[0] < b[0])
		var c = cams[0][2]["origin"]
		spawn = [c[0], c[1], c[2]]

	return {
		"bounds": {"min": mn, "max": mx, "center": center, "size": size, "floor_y": floor_y},
		"spawn": spawn,
	}


## Matches Python's statistics.median: sorts, and averages the two middle
## values for an even-length sequence.
static func _median(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var v := values.duplicate()
	v.sort()
	var n := v.size()
	if n % 2 == 1:
		return float(v[(n - 1) / 2])
	return (float(v[n / 2 - 1]) + float(v[n / 2])) / 2.0


static func _min_of(a: Array) -> float:
	var m: float = a[0]
	for v in a:
		if v < m:
			m = v
	return m


static func _max_of(a: Array) -> float:
	var m: float = a[0]
	for v in a:
		if v > m:
			m = v
	return m


# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------

static func _vec3(b: PackedByteArray, o: int) -> Array:
	return [b.decode_float(o), b.decode_float(o + 4), b.decode_float(o + 8)]


## NUL-terminated, latin-1. Must not be UTF-8: entity names carry high bytes.
static func _c_str(b: PackedByteArray, o: int, n: int) -> String:
	var out := ""
	for i in n:
		var j := o + i
		if j >= b.size():
			break
		var c := b[j]
		if c == 0:
			break
		out += char(c)
	return out


static func _pos_to_godot(v: Array) -> Array:
	return [v[0], v[2], -v[1]]


static func _scale_to_godot(v: Array) -> Array:
	return [v[0], v[2], v[1]]


static func _norm_tilt(t: float) -> float:
	if t > 180.0:
		return t - 360.0
	elif t < -180.0:
		return t + 360.0
	return t


## Legacy approximate euler for the JSON dump, accurate for pure pan only.
## Runtime orientation must use angle_gs via ang_to_matrix, not this.
static func _euler_to_godot_deg(a: Array) -> Array:
	return [_norm_tilt(a[1]), a[0], a[2]]
