extends RefCounted
## Runtime MDL reader (Conitec MDL2-5): the GDScript counterpart of the
## `parse_conitec_mdl` half of `tools/convert_mdl.py`.
##
## Fifth reader of the 0-py migration. `tools/smoke_mdl_reader.gd` validates it
## against the committed `assets/converted/mdl/*.glb`.
##
## Deliberately NO `class_name` (see commit 5c0adfa). Use via `preload`.
##
## SCOPE: Conitec MDL2/3/4/5 and Quake IDPO (`parse_quake_mdl`, including its
## winding flip and the `_idpo_to_godot` det+1 map). The two families share a
## convention but not a layout, so they have separate entry points.
##
## Skins are always TRAVERSED even when not decoded: the UV and triangle blocks
## follow them in the byte stream, and skin width/height feed the UV half-texel
## offset. Getting the skin stride wrong silently corrupts the geometry that
## comes after it, which is far worse than a wrong-looking texture.
##
## All five skin encodings decode: 8-bit palette (through the embedded game
## palette, see GAME_PALETTE_B64), RGB565, RGBA4444, BGR888 and BGRA8888.

## `extra_yaw_deg` from tools/mdl_yaw_allowlist.json, the ONLY sanctioned
## per-model exception mechanism (CONTRACT.md #2). Every row must be a
## human-confirmed measurement, never a heuristic's opinion.
const YAW_ALLOWLIST_PATH := "res://tools/mdl_yaw_allowlist.json"

## The game's 256x3 RGB palette, base64 of `tools/game_palette.raw`
## (768 bytes, sha256 5d548a3a3f14b87236079891bf5aab06b5dd2e70f388af14a112304801350afc).
##
## EMBEDDED, not loaded from disk, because export_presets.cfg excludes
## `tools/*` (and `original/*`) from every preset: neither
## `res://tools/game_palette.raw` nor the `original/piposh3d/GFX/palette.pcx`
## that `convert_mdl.py::_game_palette` falls back to exists in an exported
## build, so a file read would silently degrade every 8-bit skin to the
## grayscale fallback in shipped builds only. Regenerate with:
##   python -c "import base64;print(base64.b64encode(open('tools/game_palette.raw','rb').read()).decode())"
##
## NOTE: `tools/quake_palette.py` is NOT the source. It is stale and broken --
## its table holds 864 bytes (its own `assert len(PALETTE) == 768` fails on
## import), it differs from game_palette.raw in 54 of the first 768 bytes, and
## nothing in convert_mdl.py imports it. The oracle uses game_palette.raw.
const GAME_PALETTE_B64 := \
	"AAAADw8PHx8fLy8vPz8/S0tLW1tba2tre3t7i4uLm5ubq6uru7u7y8vL29vb6+vrDwsHFw8LHxcLJxsPLyMTNysXPy8XSzcb" + \
	"UzsbW0MfY0sfa1Mfc1cfe18jg2cjj28jCwsPExMbGxsnJyczLy8/NzdLPz9XR0dnT09zW1t/Y2OLa2uXc3Oje3uvg4O7i4vL" + \
	"AAAABwcACwsAExMAGxsAIyMAKysHLy8HNzcHPz8HR0cHS0sLU1MLW1sLY2MLa2sPBwAADwAAFwAAHwAAJwAALwAANwAAPwAA" + \
	"RwAATwAAVwAAXwAAZwAAbwAAdwAAfwAAExMAGxsAIyMALysANy8AQzcASzsHV0MHX0cHa0sLd1MPg1cTi1sTl18bo2Mfr2cj" + \
	"IxMHLxcLOx8PSyMTVysXYy8fczcjfzsrj0Mzn08zr2Mvv3cvz48r36sn78sf//MbCwcAGxMAKyMPNysTRzMbUzcjYz8rb0cz" + \
	"f1M/i19Hm2tTp3tft4drw5N706OL47OXq4ujn3+Xk3OHi2d7f1tvd1Nja0tXXz9LVzdDSy83QycvNx8jKxcbIxMTFwsLDwcH" + \
	"u3Ofr2uPo1+Dl1d3i09rf0tfc0NTaztLXzM/Uys3RyMrOx8jLxcbIxMTFwsLDwcH28O7y7Onv6Obr5eLo4d7l3tvh29fe2NT" + \
	"a1dHX0s7Uz8zQzMnNysfJx8XGxMPDwsHb4N7Z3tvX3NnV2tfT2NXR1tPP1NHN0s/L0M3KzsvIzMnHysfFyMXDxsTCxMLBwsH" + \
	"//Mb798X28sTy7cPu6cPq5cLm4MHi3MHe2MHa1MAW0cASzcAOysAKx8AGw8ACwcAAAD/CwvvExPfGxvPIyO/KyuvLy+fLy+P" + \
	"Ly9/Ly9vLy9fKytPIyM/GxsvExMfCwsPKwAAOwAASwcAXwcAbw8AfxcHkx8HoycLtzMPw0sbz2Mr238745dP56tf779399OL" + \
	"p3s7t5s3x8M35+NXf7//q+f/1///ZwAAiwAAswAA1wAA/wAA//OT//fH/v7+////"

static var _yaw_cache: Dictionary

## Decoded GAME_PALETTE_B64, 768 bytes. Lazily built once per run.
static var _palette_cache: PackedByteArray

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
		return _read_idpo(data, stem, decode_skins)
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
		# Python: Image.new("RGBA", (4, 4), (180, 180, 180, 255)).
		skins.append({
			"w": 4, "h": 4,
			"image": _solid_skin(4, 4, 180, 180, 180, 255) if decode_skins else null,
		})

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


# ---------------------------------------------------------------------------
# Quake IDPO
# ---------------------------------------------------------------------------
#
# Port of `parse_quake_mdl`. This game stores Conitec-style skin types (RGB565,
# RGBA4444) under an IDPO header as well as classic Quake 8-bit palette skins,
# so the skin loop handles both. `orient_mesh_face_plus_x` is NOT ported: it
# returns immediately because FACE_ORIENT is False, i.e. it is dead code that
# deliberately relies on WED pan rather than skin-pixel guessing.

static func _read_idpo(data: PackedByteArray, stem: String, decode_skins: bool) -> Dictionary:
	if data.size() < 84:
		return {"error": "truncated IDPO header"}

	# Header "<4si10f9i": ident, version, scale[3], offset[3], radius, eye[3],
	# then the nine counts.
	var scale := [data.decode_float(8), data.decode_float(12), data.decode_float(16)]
	var origin := [data.decode_float(20), data.decode_float(24), data.decode_float(28)]
	var numskins := data.decode_s32(48)
	var sw := data.decode_s32(52)
	var sh := data.decode_s32(56)
	var numverts := data.decode_s32(60)
	var numtris := data.decode_s32(64)
	var numframes := data.decode_s32(68)

	if numverts <= 0 or numtris <= 0:
		return {"error": "degenerate IDPO verts=%d tris=%d" % [numverts, numtris]}

	var o := 84
	var skins: Array = []
	for _s in numskins:
		if o + 4 > data.size():
			break
		var group := data.decode_s32(o)
		o += 4
		var img: Image = null
		match group:
			0:
				# Classic Quake 8-bit palette skin.
				if decode_skins:
					img = _apply_quake_palette(data, o, sw, sh)
				o += sw * sh
			1:
				# Group skin: N animation frames sharing one size. The oracle
				# keeps only the FIRST frame (`raw[: skinwidth * skinheight]`).
				var nb := data.decode_s32(o)
				o += 4
				o += 4 * nb          # frame times
				if decode_skins:
					img = _apply_quake_palette(data, o, sw, sh)
				o += sw * sh * nb    # the frames themselves
			2, 10:
				if decode_skins:
					img = _decode_skin(data, o, sw, sh, 2)
				o += sw * sh * 2
				if group == 10:
					for div in [2, 4, 8]:
						o += 2 * maxi(int(sw / div), 1) * maxi(int(sh / div), 1)
			3, 11:
				if decode_skins:
					img = _decode_skin(data, o, sw, sh, 3)
				o += sw * sh * 2
				if group == 11:
					for div in [2, 4, 8]:
						o += 2 * maxi(int(sw / div), 1) * maxi(int(sh / div), 1)
			_:
				# Unknown: skip one 8-bit skin's worth to stay aligned. The
				# oracle shows these raw indices as grayscale (index 0 clear),
				# NOT through the game palette -- see _palette_skin.
				if decode_skins:
					img = _palette_skin(data, o, sw, sh)
					if img == null:
						img = _solid_skin(sw if sw != 0 else 4,
								sh if sh != 0 else 4, 180, 180, 180, 255)
				o += sw * sh
		skins.append({"w": sw, "h": sh, "image": img})
	if skins.is_empty():
		# Python: Image.new("RGBA", (skinwidth or 4, skinheight or 4),
		# (180, 180, 180, 255)) -- `or 4` substitutes only for ZERO, so this is
		# not maxi(sw, 4).
		var fw := sw if sw != 0 else 4
		var fh := sh if sh != 0 else 4
		skins.append({
			"w": fw, "h": fh,
			"image": _solid_skin(fw, fh, 180, 180, 180, 255) if decode_skins else null,
		})

	# stverts: onseam, s, t (int32 each)
	if o + numverts * 12 > data.size():
		return {"error": "truncated IDPO stvert block"}
	var st_off := o
	o += numverts * 12

	# triangles: facesfront, v0, v1, v2 (int32 each)
	if o + numtris * 16 > data.size():
		return {"error": "truncated IDPO triangle block"}
	var tri_off := o
	o += numtris * 16

	# frames
	var frames: Array = []
	for _fi in numframes:
		if o + 4 > data.size():
			break
		var typ := data.decode_s32(o)
		o += 4
		if typ == 0:
			o += 8  # bbox min/max (2 x trivertx)
			var name := _c_str(data, o, 16)
			o += 16
			if o + 4 * numverts > data.size():
				break
			frames.append([name, _idpo_frame(data, o, numverts, scale, origin)])
			o += 4 * numverts
		else:
			var n := data.decode_s32(o)
			o += 4
			o += 8       # group min/max
			o += 4 * n   # times
			for gi in n:
				if o + 8 + 16 + 4 * numverts > data.size():
					break
				o += 8
				var nm := _c_str(data, o, 16)
				o += 16
				frames.append([nm, _idpo_frame(data, o, numverts, scale, origin)])
				o += 4 * numverts

	if frames.is_empty():
		return {"error": "IDPO has no frames"}

	# --- corners ------------------------------------------------------------
	var corner_map := {}
	var indices := PackedInt32Array()
	var pos_idx_list := PackedInt32Array()
	var uv_list: Array = []

	for t in numtris:
		var tb := tri_off + t * 16
		var facesfront := data.decode_s32(tb)
		var v0 := data.decode_s32(tb + 4)
		var v1 := data.decode_s32(tb + 8)
		var v2 := data.decode_s32(tb + 12)
		# The legacy (det -1) map was a reflection, so authored winding already
		# read correct after mirroring. FIX_IDPO uses a proper rotation
		# (det +1), so winding must flip exactly once to keep faces outward.
		for vi_v in [v0, v2, v1]:
			# Explicitly typed: iterating an untyped Array literal yields
			# Variant, and `:=` cannot infer from it.
			var vi: int = vi_v
			if vi < 0 or vi >= numverts:
				continue
			var sb := st_off + vi * 12
			var onseam := data.decode_s32(sb)
			var ss := data.decode_s32(sb + 4)
			var tt := data.decode_s32(sb + 8)
			if onseam != 0 and facesfront == 0:
				ss += int(sw / 2)
			var key := "%d:%d:%d:%d" % [vi, ss, tt, facesfront]
			if not corner_map.has(key):
				corner_map[key] = pos_idx_list.size()
				pos_idx_list.append(vi)
				uv_list.append([
					(float(ss) + 0.5) / float(maxi(sw, 1)),
					(float(tt) + 0.5) / float(maxi(sh, 1)),
				])
			indices.append(corner_map[key])

	if indices.is_empty():
		return {"error": "no valid IDPO triangles"}

	var base: Array = frames[0][1]
	var positions: Array = []
	for i in pos_idx_list:
		positions.append(base[i])

	# Unlike the Conitec path, every frame is remapped with no length filter.
	var remapped: Array = []
	for fr in frames:
		var p: Array = fr[1]
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


## One IDPO frame: uint8 xyz (4th byte is the normal index), scaled and offset
## in float32, then remapped (x, y, z) -> (x, z, -y). That map is det +1, which
## is why the triangle winding is flipped above.
static func _idpo_frame(data: PackedByteArray, off: int, numverts: int,
		scale: Array, origin: Array) -> Array:
	var pos: Array = []
	for v in numverts:
		var vb := off + v * 4
		var wx := _f32(_f32(float(data[vb]) * float(scale[0])) + float(origin[0]))
		var wy := _f32(_f32(float(data[vb + 1]) * float(scale[1])) + float(origin[1]))
		var wz := _f32(_f32(float(data[vb + 2]) * float(scale[2])) + float(origin[2]))
		pos.append([wx, wz, -wy])
	return pos


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
		0:  # 8-bit palette index
			return _apply_quake_palette(data, off, w, h)
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
			# Python: Image.new("RGBA", (max(w,1), max(h,1)), (200,200,200,255)).
			return _solid_skin(w, h, 200, 200, 200, 255)
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)


# ---------------------------------------------------------------------------
# 8-bit palette skins
# ---------------------------------------------------------------------------

## Decode GAME_PALETTE_B64 once. 768 bytes = 256 RGB triples.
static func _game_palette() -> PackedByteArray:
	if _palette_cache.size() != 768:
		_palette_cache = Marshalls.base64_to_raw(GAME_PALETTE_B64)
	return _palette_cache


## Port of `convert_mdl.py::_apply_quake_palette`: 8-bit indices through the
## real game palette, FULLY OPAQUE.
##
## Index 0 in this game's palette is plain black (0,0,0), the start of an
## ordinary grayscale shading ramp -- NOT a colorkey sentinel. Treating it as
## transparent punched real holes in character skins wherever the artist used
## that ramp for eyebrows, pupils and hairlines ("heads are transparent",
## docs/SESSION_LOG.md 2026-07-31). Only the degraded `_palette_skin`
## fallback, which has no real colour data to trust, still keys index 0.
static func _apply_quake_palette(data: PackedByteArray, off: int, w: int, h: int) -> Image:
	if w <= 0 or h <= 0 or off < 0 or off + w * h > data.size():
		return null
	var pal := _game_palette()
	if pal.size() < 768:
		return _palette_skin(data, off, w, h)
	var px := PackedByteArray()
	px.resize(w * h * 4)
	for i in w * h:
		var p := int(data[off + i]) * 3
		px[i * 4] = pal[p]
		px[i * 4 + 1] = pal[p + 1]
		px[i * 4 + 2] = pal[p + 2]
		px[i * 4 + 3] = 255
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)


## Port of `convert_mdl.py::_palette_skin`: the no-real-palette fallback.
## Index used directly as grayscale, index 0 transparent.
static func _palette_skin(data: PackedByteArray, off: int, w: int, h: int) -> Image:
	if w <= 0 or h <= 0 or off < 0 or off + w * h > data.size():
		return null
	var px := PackedByteArray()
	px.resize(w * h * 4)
	for i in w * h:
		var v := data[off + i]
		px[i * 4] = v
		px[i * 4 + 1] = v
		px[i * 4 + 2] = v
		px[i * 4 + 3] = 0 if v == 0 else 255
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)


## Flat placeholder, matching the oracle's `Image.new("RGBA", ..., colour)`.
static func _solid_skin(w: int, h: int, r: int, g: int, b: int, a: int) -> Image:
	var iw := maxi(w, 1)
	var ih := maxi(h, 1)
	var px := PackedByteArray()
	px.resize(iw * ih * 4)
	for i in iw * ih:
		px[i * 4] = r
		px[i * 4 + 1] = g
		px[i * 4 + 2] = b
		px[i * 4 + 3] = a
	return Image.create_from_data(iw, ih, false, Image.FORMAT_RGBA8, px)


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
