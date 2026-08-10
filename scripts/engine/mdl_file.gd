extends RefCounted
## Runtime MDL reader (Conitec MDL2-5): the GDScript counterpart of the
## `parse_conitec_mdl` half of `tools/convert_mdl.py`.
##
## Fifth reader of the 0-py migration. `tools/smoke_mdl_reader.gd` validates it
## against the committed `assets/converted/mdl/*.glb`.
##
## Deliberately NO `class_name` (see commit 5c0adfa). Use via `preload`.
##
## SCOPE: Conitec MDL2/3/4/5 only. Quake IDPO (`parse_quake_mdl`, plus its
## winding flip and the `_idpo_to_godot` det+1 map) is NOT ported yet and
## `read_mdl` refuses it explicitly rather than mis-decoding it. The two
## families share a convention but not a layout.
##
## Skins are always TRAVERSED even when not decoded: the UV and triangle blocks
## follow them in the byte stream, and skin width/height feed the UV half-texel
## offset. Getting the skin stride wrong silently corrupts the geometry that
## comes after it, which is far worse than a wrong-looking texture.

## `extra_yaw_deg` from tools/mdl_yaw_allowlist.json, the ONLY sanctioned
## per-model exception mechanism (CONTRACT.md #2). Every row must be a
## human-confirmed measurement, never a heuristic's opinion.
const YAW_ALLOWLIST_PATH := "res://tools/mdl_yaw_allowlist.json"

static var _yaw_cache: Dictionary

## Reusable 1-element buffer for float32 rounding. A fresh PackedFloat32Array
## per call would allocate millions of times across the corpus.
static var _f32buf := PackedFloat32Array([0.0])


## Round a float64 to the nearest float32, via a real float32 store.
static func _f32(v: float) -> float:
	_f32buf[0] = v
	return _f32buf[0]


static func read_mdl(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"error": "cannot open %s" % path}
	var data := f.get_buffer(f.get_length())
	f.close()
	return read_mdl_bytes(data, path.get_file().get_basename(), false)


## `decode_skins` controls pixel decoding only; skins are traversed regardless.
static func read_mdl_bytes(data: PackedByteArray, stem: String,
		decode_skins: bool = true) -> Dictionary:
	if data.size() < 84:
		return {"error": "truncated header"}
	var magic := ""
	for i in 4:
		magic += char(data[i])
	if magic == "IDPO":
		return {"error": "IDPO (Quake) not supported by this reader yet"}
	if not ["MDL2", "MDL3", "MDL4", "MDL5"].has(magic):
		return {"error": "unsupported MDL magic %s" % magic}

	# Header layout "<4si6fi3f8i": magic, ver, scale[3], offset[3], u2,
	# emit[3], then the eight counts.
	var scale := [data.decode_float(8), data.decode_float(12), data.decode_float(16)]
	var origin := [data.decode_float(20), data.decode_float(24), data.decode_float(28)]
	var numskins := data.decode_s32(48)
	var skinwidth := data.decode_s32(52)
	var skinheight := data.decode_s32(56)
	var numverts := data.decode_s32(60)
	var numtris := data.decode_s32(64)
	var numframes := data.decode_s32(68)
	var numskinverts := data.decode_s32(72)

	var is_mdl5 := magic == "MDL5"
	var o := 84

	# --- skins -------------------------------------------------------------
	var skins: Array = []
	for _s in numskins:
		if o + 4 > data.size():
			break
		var skintype := data.decode_s32(o)
		o += 4
		var w := skinwidth
		var h := skinheight
		if is_mdl5:
			if o + 8 > data.size():
				break
			w = data.decode_s32(o)
			h = data.decode_s32(o + 4)
			o += 8
		var base := skintype & 7
		var has_mips := bool(skintype & 8)
		var bpp := 2
		match base:
			0: bpp = 1
			2, 3: bpp = 2
			4: bpp = 3
			5: bpp = 4
			_: bpp = 2
		var nbytes := bpp * w * h
		var img: Image = null
		if decode_skins:
			img = _decode_skin(data, o, w, h, base)
		skins.append({"w": w, "h": h, "image": img})
		o += nbytes
		if has_mips:
			for div in [2, 4, 8]:
				o += bpp * maxi(int(w / div), 1) * maxi(int(h / div), 1)

	if skins.is_empty():
		skins.append({"w": 4, "h": 4, "image": null})

	var skin_w: int = skins[0]["w"]
	var skin_h: int = skins[0]["h"]

	if numskinverts <= 0 or numtris <= 0 or numverts <= 0:
		return {"error": "degenerate mesh verts=%d tris=%d uvs=%d" % [
			numverts, numtris, numskinverts]}

	# --- UVs (int16 pairs) and triangles (6 x int16) ------------------------
	if o + numskinverts * 4 > data.size():
		return {"error": "truncated UV block"}
	var uv_off := o
	o += numskinverts * 4

	if o + numtris * 12 > data.size():
		return {"error": "truncated triangle block"}
	var tri_off := o
	o += numtris * 12

	# --- expand to unique (position index, uv index) corners ----------------
	var corner_map := {}
	var indices := PackedInt32Array()
	var pos_idx_list := PackedInt32Array()
	var uv_list: Array = []

	for t in numtris:
		var tb := tri_off + t * 12
		for k in 3:
			var pi := data.decode_s16(tb + k * 2)
			var ui := data.decode_s16(tb + (k + 3) * 2)
			if pi < 0 or pi >= numverts or ui < 0 or ui >= numskinverts:
				continue
			var key := pi * numskinverts + ui
			if not corner_map.has(key):
				corner_map[key] = pos_idx_list.size()
				pos_idx_list.append(pi)
				var su := float(data.decode_s16(uv_off + ui * 4))
				var sv := float(data.decode_s16(uv_off + ui * 4 + 2))
				uv_list.append([
					(su + 0.5) / float(maxi(skin_w, 1)),
					(sv + 0.5) / float(maxi(skin_h, 1)),
				])
			indices.append(corner_map[key])

	if indices.is_empty():
		return {"error": "no valid triangles after index clamp"}

	# --- frames -------------------------------------------------------------
	var frames: Array = []
	var base_positions: Array = []
	for fi in maxi(numframes, 1):
		if numframes <= 0:
			break
		if o + 4 > data.size():
			break
		var ftype := data.decode_s32(o)
		o += 4
		var vsize := 8 if ftype == 2 else 4
		o += vsize * 2  # bbox min/max
		var name := _c_str(data, o, 16)
		o += 16
		if o + vsize * numverts > data.size() or numverts <= 0:
			break
		var pos: Array = []
		for v in numverts:
			var vb := o + v * vsize
			var px: float
			var py: float
			var pz: float
			if ftype == 2:
				px = float(data.decode_u16(vb))
				py = float(data.decode_u16(vb + 2))
				pz = float(data.decode_u16(vb + 4))
			else:
				px = float(data[vb])
				py = float(data[vb + 1])
				pz = float(data[vb + 2])
			# Acknex Z-up -> Godot Y-up via rotateX(-90): (X, Z, -Y). det +1.
			#
			# The rounding here is not incidental. numpy evaluates
			# `packed * scale + offset` on float32 arrays, so it rounds to
			# float32 after the multiply AND again after the add. GDScript works
			# in float64 and would round only once at the end, which lands ~2
			# float32 ULP away -- enough to fail an exact comparison on 269 of
			# 273 models. Rounding at each step reproduces numpy exactly.
			var wx := _f32(_f32(px * float(scale[0])) + float(origin[0]))
			var wy := _f32(_f32(py * float(scale[1])) + float(origin[1]))
			var wz := _f32(_f32(pz * float(scale[2])) + float(origin[2]))
			pos.append([wx, wz, -wy])
		o += vsize * numverts
		frames.append([name if name != "" else "frame_%d" % fi, pos])
		if base_positions.is_empty():
			base_positions = pos

	if base_positions.is_empty():
		# Degenerate model: emit the same placeholder triangle the Python does.
		base_positions = [[0, 0, 0], [1, 0, 0], [0, 1, 0]]
		indices = PackedInt32Array([0, 1, 2])
		pos_idx_list = PackedInt32Array([0, 1, 2])
		uv_list = [[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]]
		frames = [["frame_0", base_positions]]

	var positions: Array = []
	var max_idx := 0
	for i in pos_idx_list:
		if i > max_idx:
			max_idx = i
	for i in pos_idx_list:
		positions.append(base_positions[i])

	# A frame is kept only when it actually covers the remap indices, matching
	# the Python's `if len(pos) > idx_arr.max()`.
	var remapped: Array = []
	for fr in frames:
		var p: Array = fr[1]
		if p.size() > max_idx:
			var rp: Array = []
			for i in pos_idx_list:
				rp.append(p[i])
			remapped.append([fr[0], rp])

	var out := {
		"positions": positions,
		"uvs": uv_list,
		"indices": indices,
		"frames": remapped,
		"skins": skins,
	}
	_apply_yaw_allowlist(out, stem)
	return out


## The only sanctioned per-model correction. Applied to the base positions and
## every frame, exactly as the Python does.
static func _apply_yaw_allowlist(mesh: Dictionary, stem: String) -> void:
	var deg := _yaw_for(stem)
	if absf(deg) < 1e-6:
		return
	mesh["positions"] = _yaw_rotate_y(mesh["positions"], deg)
	var fr: Array = []
	for f in mesh["frames"]:
		fr.append([f[0], _yaw_rotate_y(f[1], deg)])
	mesh["frames"] = fr


static func _yaw_for(stem: String) -> float:
	if _yaw_cache.is_empty():
		_yaw_cache = {"_loaded": true}
		var f := FileAccess.open(YAW_ALLOWLIST_PATH, FileAccess.READ)
		if f != null:
			var d = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(d) == TYPE_DICTIONARY:
				for k in d.get("extra_yaw_deg", {}).keys():
					_yaw_cache[str(k).to_lower()] = float(d["extra_yaw_deg"][k])
	return float(_yaw_cache.get(stem.to_lower(), 0.0))


static func _yaw_rotate_y(pos: Array, yaw_deg: float) -> Array:
	var a := deg_to_rad(yaw_deg)
	var c := cos(a)
	var s := sin(a)
	var out: Array = []
	for p in pos:
		var x: float = p[0]
		var z: float = p[2]
		out.append([x * c + z * s, p[1], -x * s + z * c])
	return out


static func _decode_skin(data: PackedByteArray, off: int, w: int, h: int, base: int) -> Image:
	if w <= 0 or h <= 0:
		return null
	var px := PackedByteArray()
	px.resize(w * h * 4)
	match base:
		2:  # RGB565
			if off + w * h * 2 > data.size():
				return null
			for i in w * h:
				var c := data.decode_u16(off + i * 2)
				px[i * 4] = ((c >> 11) & 0x1F) * 255 / 31
				px[i * 4 + 1] = ((c >> 5) & 0x3F) * 255 / 63
				px[i * 4 + 2] = (c & 0x1F) * 255 / 31
				px[i * 4 + 3] = 255
		3:  # RGBA4444
			if off + w * h * 2 > data.size():
				return null
			for i in w * h:
				var c := data.decode_u16(off + i * 2)
				px[i * 4] = ((c >> 8) & 0xF) * 17
				px[i * 4 + 1] = ((c >> 4) & 0xF) * 17
				px[i * 4 + 2] = (c & 0xF) * 17
				px[i * 4 + 3] = ((c >> 12) & 0xF) * 17
		4:  # BGR888
			if off + w * h * 3 > data.size():
				return null
			for i in w * h:
				px[i * 4] = data[off + i * 3 + 2]
				px[i * 4 + 1] = data[off + i * 3 + 1]
				px[i * 4 + 2] = data[off + i * 3]
				px[i * 4 + 3] = 255
		5:  # BGRA8888
			if off + w * h * 4 > data.size():
				return null
			for i in w * h:
				px[i * 4] = data[off + i * 4 + 2]
				px[i * 4 + 1] = data[off + i * 4 + 1]
				px[i * 4 + 2] = data[off + i * 4]
				px[i * 4 + 3] = data[off + i * 4 + 3]
		_:
			return null
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)


static func _c_str(b: PackedByteArray, o: int, n: int) -> String:
	var out := ""
	for i in n:
		var j := o + i
		if j >= b.size():
			break
		if b[j] == 0:
			break
		out += char(b[j])
	return out


## Build a renderable ArrayMesh from read_mdl() output (base frame).
static func build_mesh(m: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if m.is_empty() or m.has("error"):
		return mesh
	var pos := PackedVector3Array()
	for p in m["positions"]:
		pos.append(Vector3(p[0], p[1], p[2]))
	var uv := PackedVector2Array()
	for t in m["uvs"]:
		uv.append(Vector2(t[0], t[1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array(m["indices"])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
