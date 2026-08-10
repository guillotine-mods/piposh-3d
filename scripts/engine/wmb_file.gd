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

## Raw list table for the BRUSH path. Deliberately different from _read_lists:
## extract_wmb_mesh.py reads 16 lists and performs NO bounds validation, while
## extract_wmb_full.py reads 20 WITH validation and stops early on a bad entry.
## Using either one for both paths changes which lists are visible on malformed
## files, so both behaviours are reproduced separately.
static func _read_lists_raw(data: PackedByteArray, n: int = 16) -> Array:
	var lists: Array = []
	var off := 4
	for _i in n:
		if off + 8 > data.size():
			break
		lists.append([data.decode_u32(off), data.decode_u32(off + 4)])
		off += 8
	return lists


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
# Brush / BSP geometry
# ---------------------------------------------------------------------------
#
# WMB5 list layout (Acknex A5):
#   L2  textures (RGB565 + mipmaps, type 40)
#   L3  vertices (float3, GS Z-up)
#   L6  texinfo (64 bytes: s/t vec4 + texture index)
#   L7  faces (24 bytes: ..., firstedge, numedges, texinfo, ...)
#   L12 edges (8-byte header, then uint32 v0,v1 pairs)
#   L13 surfedges (int32, Quake-style signed edge refs)
#
# NOTE for Phase 2: face records are 24 bytes and only bytes 4-11 are read here,
# matching the Python. Bytes 0-3 (plane index -> authored NORMAL, free) and
# 12-23 (light styles + lightmap offset) are still unread. Recovering them is
# the whole point of doing this in-engine, but it must not happen in the same
# change that establishes parity -- the oracle can only prove equivalence while
# this reproduces the Python exactly.


## Extract brush geometry. Returns {} when the file has no usable brush data,
## matching the Python's `return None`.
##
## `decode_textures` controls whether texture PIXELS are decoded. Dimensions are
## always read, because UVs are divided by them. The runtime needs the pixels;
## the parity test does not, and skipping them keeps it geometry-focused.
static func read_brush(data: PackedByteArray, decode_textures: bool = true) -> Dictionary:
	var magic := ""
	for i in mini(4, data.size()):
		magic += char(data[i])
	if not ["WMB4", "WMB5", "WMB6"].has(magic):
		return {}

	var lists := _read_lists_raw(data, 16)
	if lists.size() < 14:
		return {}
	if lists[3][1] < 12 or lists[7][1] < 24 or lists[12][1] < 16 or lists[13][1] < 4:
		return {}

	# Vertices (GS Z-up, float3).
	var v_off: int = lists[3][0]
	var nv: int = int(lists[3][1] / 12)
	if nv == 0:
		return {}

	# Edges: 8-byte header, then uint32 pairs.
	var e_off: int = lists[12][0]
	var e_len: int = lists[12][1]
	var n_edges: int = int((e_len - 8) / 8)

	# Surfedges: signed int32.
	var s_off: int = lists[13][0]
	var n_surf: int = int(lists[13][1] / 4)

	var textures := _read_texture_headers(data, lists, decode_textures)
	if textures.is_empty():
		textures = [{"name": "_default", "w": 8, "h": 8, "image": null}]

	# Texinfo: s vec4, t vec4, texture index.
	var t_off: int = lists[6][0]
	var t_len: int = lists[6][1]
	var n_texinfo: int = int(t_len / 64) if t_len >= 64 else 0
	var texinfos: Array = []
	for i in n_texinfo:
		var b := t_off + i * 64
		var s := [data.decode_float(b), data.decode_float(b + 4),
				  data.decode_float(b + 8), data.decode_float(b + 12)]
		var t := [data.decode_float(b + 16), data.decode_float(b + 20),
				  data.decode_float(b + 24), data.decode_float(b + 28)]
		var ti := data.decode_s32(b + 32)
		if ti < 0 or ti >= textures.size():
			ti = 0
		texinfos.append([s, t, ti])

	var f_off: int = lists[7][0]
	var n_faces: int = int(lists[7][1] / 24)
	var buckets := {}
	var skipped := 0

	for fi in n_faces:
		var b := f_off + fi * 24
		var first := data.decode_s32(b + 4)
		var num := data.decode_s16(b + 8)
		var ti := data.decode_s16(b + 10)

		var poly := _poly_verts(data, s_off, n_surf, e_off, n_edges, nv, first, num)
		if poly.is_empty():
			skipped += 1
			continue

		var s_vec: Array
		var t_vec: Array
		var tex_idx: int
		if ti >= 0 and ti < texinfos.size():
			s_vec = texinfos[ti][0]
			t_vec = texinfos[ti][1]
			tex_idx = texinfos[ti][2]
		else:
			s_vec = [1.0, 0.0, 0.0, 0.0]
			t_vec = [0.0, 1.0, 0.0, 0.0]
			tex_idx = 0

		var tex: Dictionary = textures[tex_idx]
		var tw: int = tex["w"]
		var th: int = tex["h"]

		if not buckets.has(tex_idx):
			buckets[tex_idx] = {"pos": [], "uv": [], "idx": [], "name": tex["name"]}
		var bucket: Dictionary = buckets[tex_idx]
		var base_idx: int = (bucket["pos"] as Array).size()

		for vi in poly:
			var p := _vec3(data, v_off + vi * 12)
			bucket["pos"].append(_pos_to_godot(p))
			# UVs are computed from the UNREMAPPED GS vertex, then divided by
			# the texture size to reach 0..1. Using the Godot-space position
			# here would shear every texture.
			# Explicitly typed: element access on an untyped Array yields
			# Variant, which `:=` cannot infer from.
			var u: float = p[0] * s_vec[0] + p[1] * s_vec[1] + p[2] * s_vec[2] + s_vec[3]
			var v: float = p[0] * t_vec[0] + p[1] * t_vec[1] + p[2] * t_vec[2] + t_vec[3]
			if tw > 0:
				u /= float(tw)
			if th > 0:
				v /= float(th)
			bucket["uv"].append([u, v])

		# Fan triangulate, winding flipped for right-handed Godot after the
		# axis remap.
		for k in range(1, poly.size() - 1):
			bucket["idx"].append_array([base_idx, base_idx + k + 1, base_idx + k])

	if buckets.is_empty():
		return {}

	return {
		"buckets": buckets,
		"textures": textures,
		"faces": n_faces,
		"skipped": skipped,
		"verts": nv,
	}


## Walk a face's surfedges into an ordered vertex ring. Returns [] when the ring
## does not close, matching the Python's `return None` (the caller counts it as
## a skipped face rather than emitting broken geometry).
static func _poly_verts(data: PackedByteArray, s_off: int, n_surf: int,
		e_off: int, n_edges: int, nv: int, first: int, num: int) -> Array:
	if num < 3 or first < 0 or first + num > n_surf:
		return []

	var pair := _edge_verts(data, e_off, n_edges, data.decode_s32(s_off + first * 4))
	var vs: Array = [pair[0]]
	var cur: int = pair[1]

	for i in range(1, num):
		var ei := data.decode_s32(s_off + (first + i) * 4)
		var e := _edge_verts(data, e_off, n_edges, ei)
		var a: int = e[0]
		var b: int = e[1]
		if a == cur:
			vs.append(a)
			cur = b
		elif b == cur:
			vs.append(b)
			cur = a
		else:
			return []

	if cur != vs[0] or vs.size() != num:
		return []
	for v in vs:
		if v < 0 or v >= nv:
			return []
	return vs


## Quake-style signed edge reference: positive uses the edge forward, anything
## else uses it reversed. Index 0 takes the `else` branch and resolves to
## edges[-1] -- Python's negative indexing, i.e. the LAST edge, not the first.
## Reproducing that literally matters: treating it as edge 0 changes the ring.
static func _edge_verts(data: PackedByteArray, e_off: int, n_edges: int, ei: int) -> Array:
	var base := e_off + 8
	if ei > 0:
		var j := ei - 1
		if j >= n_edges:
			return [-1, -1]
		return [data.decode_u32(base + j * 8), data.decode_u32(base + j * 8 + 4)]
	var j := -ei - 1
	if j < 0:
		j += n_edges
	if j < 0 or j >= n_edges:
		return [-1, -1]
	return [data.decode_u32(base + j * 8 + 4), data.decode_u32(base + j * 8)]


## Texture table. Dimensions follow the Python's fallbacks exactly, because UVs
## are divided by them: an invalid size yields a 4x4 placeholder, and an absent
## texture list yields a single 8x8 "_default".
static func _read_texture_headers(data: PackedByteArray, lists: Array, decode_pixels: bool) -> Array:
	var o: int = lists[2][0]
	var ln: int = lists[2][1]
	if ln < 8:
		return []
	var count := data.decode_u32(o)
	if count == 0 or count > 4096:
		return []
	var out: Array = []
	for i in count:
		var rel := data.decode_u32(o + 4 + i * 4)
		var to := o + rel
		if to + 40 > data.size():
			break
		var name := _c_str(data, to, 16)
		var w := data.decode_s32(to + 16)
		var h := data.decode_s32(to + 20)
		var typ := data.decode_s32(to + 24)
		if w <= 0 or h <= 0 or w > 4096 or h > 4096:
			out.append({"name": name, "w": 4, "h": 4, "image": null})
			continue

		# Type 40 (0x28) is used for BOTH RGB565 and 8-bit palettized textures,
		# so the type alone cannot distinguish them -- and decoding an 8-bit
		# texture as RGB565 reads ~1.5x past its payload into unrelated file
		# data, which renders as dense RGB static. Measured over all 134 WMBs:
		# 984 textures, 978 fit RGB565 exactly, 6 fit 8-bit exactly, 0 fit
		# neither, so the payload SIZE decides unambiguously.
		var next_off: int = (o + data.decode_u32(o + 4 + (i + 1) * 4)) if i + 1 < count else (o + ln)
		var avail := next_off - (to + 40)
		var fits_565 := avail == w * h * 2 or avail == w * h * 2 + _mip_bytes(w, h, 2)
		var fits_8bit := avail == w * h or avail == w * h + _mip_bytes(w, h, 1)

		var img: Image = null
		if decode_pixels:
			if fits_8bit and not fits_565:
				img = _decode_palette8(data, to + 40, w, h)
			else:
				img = _decode_texture(data, to + 40, w, h, typ)
		out.append({"name": name, "w": w, "h": h, "image": img})
	return out


static func _mip_bytes(w: int, h: int, bpp: int) -> int:
	var t := 0
	for d in [2, 4, 8]:
		t += bpp * maxi(int(w / d), 1) * maxi(int(h / d), 1)
	return t


## 8-bit palettized, using the same tools/game_palette.raw the converters use.
## NOTE: tools/ is excluded from the export preset, so if this reader is ever
## wired into the shipping game the palette must move somewhere included.
static func _decode_palette8(data: PackedByteArray, off: int, w: int, h: int) -> Image:
	if off + w * h > data.size():
		return null
	var pf := FileAccess.open("res://tools/game_palette.raw", FileAccess.READ)
	if pf == null:
		return null
	var pal := pf.get_buffer(768)
	pf.close()
	if pal.size() < 768:
		return null
	var px := PackedByteArray()
	px.resize(w * h * 4)
	for i in w * h:
		var idx := data[off + i]
		px[i * 4] = pal[idx * 3]
		px[i * 4 + 1] = pal[idx * 3 + 1]
		px[i * 4 + 2] = pal[idx * 3 + 2]
		# Index 0 transparent, matching the RGB565 path's colour-0 convention.
		px[i * 4 + 3] = 0 if idx == 0 else 255
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)


## A5 WMB usually stores RGB565+mips as type 40 (0x28). Colour index 0 is
## transparent, matching the Python's `a = where(arr == 0, 0, 255)`.
static func _decode_texture(data: PackedByteArray, off: int, w: int, h: int, typ: int) -> Image:
	var base := typ & 7
	var px := PackedByteArray()
	px.resize(w * h * 4)

	if base == 4:
		if off + w * h * 3 > data.size():
			return _flat_image(w, h, Color8(160, 80, 80, 255))
		for i in w * h:
			px[i * 4] = data[off + i * 3]
			px[i * 4 + 1] = data[off + i * 3 + 1]
			px[i * 4 + 2] = data[off + i * 3 + 2]
			px[i * 4 + 3] = 255
		return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)

	if base == 5:
		if off + w * h * 4 > data.size():
			return _flat_image(w, h, Color8(160, 80, 80, 255))
		return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8,
			data.slice(off, off + w * h * 4))

	# RGB565 for base 2/0 and the type 10/40/42 forms, and as the fallback.
	if off + w * h * 2 > data.size():
		return _flat_image(w, h, Color8(160, 80, 80, 255))
	for i in w * h:
		var c := data.decode_u16(off + i * 2)
		px[i * 4] = ((c >> 11) & 0x1F) * 255 / 31
		px[i * 4 + 1] = ((c >> 5) & 0x3F) * 255 / 63
		px[i * 4 + 2] = (c & 0x1F) * 255 / 31
		px[i * 4 + 3] = 0 if c == 0 else 255
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)


static func _flat_image(w: int, h: int, c: Color) -> Image:
	var img := Image.create(maxi(w, 1), maxi(h, 1), false, Image.FORMAT_RGBA8)
	img.fill(c)
	return img


## Build a renderable ArrayMesh from read_brush() output -- one surface per
## texture bucket, in sorted texture order to match the glTF the offline
## pipeline emits.
static func build_mesh(brush: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if brush.is_empty():
		return mesh
	var keys: Array = brush["buckets"].keys()
	keys.sort()
	for tex_idx in keys:
		var b: Dictionary = brush["buckets"][tex_idx]
		if (b["idx"] as Array).is_empty():
			continue
		var pos := PackedVector3Array()
		for p in b["pos"]:
			pos.append(Vector3(p[0], p[1], p[2]))
		var uv := PackedVector2Array()
		for t in b["uv"]:
			uv.append(Vector2(t[0], t[1]))
		var idx := PackedInt32Array(b["idx"])
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_INDEX] = idx
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_name(mesh.get_surface_count() - 1, str(b["name"]))
	return mesh


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
