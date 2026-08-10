extends SceneTree
## Oracle test for the runtime MDL reader (Conitec MDL2-5).
##
## `MdlFile.read_mdl_bytes()` must reproduce `tools/convert_mdl.py`. The
## committed `assets/converted/mdl/*.glb` are ground truth: their glTF chunks
## are parsed DIRECTLY from the binary -- never via `load()`, which returns an
## imported, VRAM-compressed resource (docs/BUGS.md GB-19) -- and every vertex
## position, UV and index is compared.
##
## SKINS are compared too. The GLB embeds skin 0 as a PNG in a bufferView; it
## is decoded with `Image.load_png_from_buffer` on those raw bytes, for exactly
## the same GB-19 reason, and compared to `read_mdl_bytes(...)["skins"][0]`
## dimension-for-dimension and byte-for-byte.
##
## IDPO models are counted separately but no longer skipped -- both parsers are
## ported.
##
## Floats compare at float32 precision, for the reason documented in
## smoke_wmb_reader.gd: the data IS float32 and the reference has been through a
## lossy round trip that the reader has not.
##
##   godot --path . --headless -s res://tools/smoke_mdl_reader.gd
##   godot --path . --headless -s res://tools/smoke_mdl_reader.gd -- --only=Ami

const MdlFile = preload("res://scripts/engine/mdl_file.gd")

const SRC := "res://original/piposh3d/MDL"
const REF := "res://assets/converted/mdl"

## sha256 of `tools/game_palette.raw`, the palette `convert_mdl.py::_game_palette`
## actually loads. The reader has to embed a copy (tools/* is excluded from
## export_presets.cfg), so this pins the copy to the original.
const GAME_PALETTE_SHA256 := \
	"5d548a3a3f14b87236079891bf5aab06b5dd2e70f388af14a112304801350afc"

## A hand-built IDPO with one group-0 skin and one group-1 (2-frame) group skin,
## 4x2 texels, 3 verts, 1 tri, 1 frame. The 649-model corpus contains ONLY
## group-2 (RGB565) IDPO skins, so nothing in it reaches the 8-bit palette
## branches or their strides; this buffer is the only coverage they get. Every
## expectation below was produced by running `convert_mdl.parse_quake_mdl` on
## these exact bytes.
const SYNTH_IDPO_B64 := \
	"SURQTwYAAAAAAIA/AAAAQAAAQEAAACBBAACgQQAA8EEAAAAAAAAAAAAAAAAAAAAAAgAAAAQAAAACAAAAAwAAAAEAAAABAAAA" + \
	"AAAAAAAAAAAAAAAAAAAAAAABDy+AyP7/AQAAAAIAAADNzMw9zcxMPv/+yIAvDwEABwcHBwcHBwcAAAAAAQAAAAAAAAABAAAA" + \
	"AgAAAAEAAAAAAAAAAwAAAAEAAAAAAAAAAAAAAAEAAAACAAAAAAAAAAAAAAAAAAAAc3ludGgAAAAAAAAAAAAAAAoUHgAoMjwA" + \
	"RlBaAA=="


func _init() -> void:
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only"):
			var parts := a.split("=")
			if parts.size() > 1:
				only = parts[1].to_lower()

	var files: Array = []
	var d := DirAccess.open(SRC)
	if d == null:
		push_error("cannot open " + SRC)
		quit(2)
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not d.current_is_dir() and n.get_extension().to_lower() == "mdl":
			files.append(n)
		n = d.get_next()
	d.list_dir_end()
	files.sort()

	var exact := 0
	var differ := 0
	var idpo := 0
	var no_ref := 0
	var reader_err := 0
	var verts := 0
	var detail: Array[String] = []
	var err_detail: Array[String] = []
	var read_usec := 0
	var skin_exact := 0
	var skin_differ := 0
	var skin_no_ref := 0
	var skin_pixels := 0
	var skin_detail: Array[String] = []

	for fname in files:
		var stem: String = fname.get_basename()
		if only != "" and stem.to_lower() != only:
			continue

		var src := _read("%s/%s" % [SRC, fname])
		if src.is_empty():
			no_ref += 1
			continue
		var magic := ""
		for i in mini(4, src.size()):
			magic += char(src[i])
		if magic == "IDPO":
			idpo += 1

		var ref_bytes := _read("%s/%s.glb" % [REF, stem])
		if ref_bytes.is_empty():
			no_ref += 1
			continue

		var t0 := Time.get_ticks_usec()
		# decode_skins = true: skin pixels are part of what is being verified.
		var m := MdlFile.read_mdl_bytes(src, stem, true)
		read_usec += Time.get_ticks_usec() - t0

		if m.has("error"):
			reader_err += 1
			if err_detail.size() < 10:
				err_detail.append("%s: %s" % [fname, m["error"]])
			continue

		var chunks := _glb_chunks(ref_bytes)
		if chunks.is_empty():
			no_ref += 1
			continue
		var js: Dictionary = chunks["json"]
		var bin: PackedByteArray = chunks["bin"]

		var prims := _glb_primitives(js, bin)
		if prims.is_empty():
			no_ref += 1
			continue

		var why := _compare(m, prims)
		if why == "":
			exact += 1
			verts += (m["positions"] as Array).size()
		else:
			differ += 1
			if detail.size() < 15:
				detail.append("%s: %s" % [fname, why])

		# --- skin 0 pixels -------------------------------------------------
		var ref_png := _glb_skin_png(js, bin)
		if ref_png.is_empty():
			skin_no_ref += 1
		else:
			var ref_img := Image.new()
			var perr := ref_img.load_png_from_buffer(ref_png)
			if perr != OK:
				skin_no_ref += 1
				if skin_detail.size() < 15:
					skin_detail.append("%s: reference PNG failed to decode (%d)"
							% [fname, perr])
			else:
				var swhy := _compare_skin(m, ref_img)
				if swhy == "":
					skin_exact += 1
					skin_pixels += ref_img.get_width() * ref_img.get_height()
				else:
					skin_differ += 1
					if skin_detail.size() < 15:
						skin_detail.append("%s: %s" % [fname, swhy])

	print("")
	print("=== MDL runtime reader vs Python oracle ===")
	print("models compared  : %d" % (exact + differ + reader_err))
	print("EXACT MATCH      : %d" % exact)
	print("differ           : %d" % differ)
	print("reader error     : %d" % reader_err)
	print("  of which IDPO  : %d" % idpo)
	print("no reference GLB : %d" % no_ref)
	print("vertices compared: %d" % verts)
	print("read time        : %.1f ms" % (read_usec / 1000.0))
	print("--- skin 0 pixels vs GLB-embedded PNG ---")
	print("SKIN EXACT       : %d" % skin_exact)
	print("skin differ      : %d" % skin_differ)
	print("skin no reference: %d" % skin_no_ref)
	print("texels compared  : %d" % skin_pixels)
	for x in detail:
		print("  DIFF  %s" % x)
	for x in err_detail:
		print("  ERR   %s" % x)
	for x in skin_detail:
		print("  SKIN  %s" % x)

	var synth: Array[String] = _check_idpo_palette_paths()
	print("--- IDPO 8-bit palette self-check (not reachable from the corpus) ---")
	print("synthetic checks : %s" % ("PASS" if synth.is_empty() else "%d FAILED" % synth.size()))
	for x in synth:
		print("  SYNTH %s" % x)

	var bad := differ + reader_err + skin_differ + synth.size()
	# A run that compared nothing is not a pass. Without this guard a compile
	# error in the reader reports PASS with 0 models, which is exactly how this
	# test first lied about a broken build.
	if exact + differ + reader_err == 0:
		print("")
		print("smoke_mdl_reader: NO MODELS COMPARED — treating as failure")
		quit(2)
		return
	print("")
	print("smoke_mdl_reader: %s" % ("PASS" if bad == 0 else "%d problem(s)" % bad))
	quit(0 if bad == 0 else 1)


func _read(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var b := f.get_buffer(f.get_length())
	f.close()
	return b


## Split a GLB into its JSON and BIN chunks. Raw bytes only -- never `load()`.
func _glb_chunks(data: PackedByteArray) -> Dictionary:
	if data.size() < 12:
		return {}
	var off := 12
	var js: Dictionary = {}
	var bin := PackedByteArray()
	while off + 8 <= data.size():
		var clen := data.decode_u32(off)
		var ctype := data.decode_u32(off + 4)
		off += 8
		if off + clen > data.size():
			break
		if ctype == 0x4E4F534A:
			var parsed = JSON.parse_string(
				data.slice(off, off + clen).get_string_from_utf8().strip_edges())
			if typeof(parsed) == TYPE_DICTIONARY:
				js = parsed
		elif ctype == 0x004E4942:
			bin = data.slice(off, off + clen)
		off += clen
	if js.is_empty() or bin.is_empty():
		return {}
	return {"json": js, "bin": bin}


## Raw PNG bytes of the GLB's first image (the model's skin 0). Returned as
## bytes and decoded by the caller with `Image.load_png_from_buffer`; going
## through `load()` on the .glb would hand back an imported, possibly
## VRAM-compressed texture instead of the authored pixels (docs/BUGS.md GB-19).
func _glb_skin_png(js: Dictionary, bin: PackedByteArray) -> PackedByteArray:
	var images: Array = js.get("images", [])
	if images.is_empty():
		return PackedByteArray()
	var img0: Dictionary = images[0]
	if not img0.has("bufferView"):
		return PackedByteArray()
	var views: Array = js.get("bufferViews", [])
	var bvi := int(img0["bufferView"])
	if bvi < 0 or bvi >= views.size():
		return PackedByteArray()
	var bv: Dictionary = views[bvi]
	var start := int(bv.get("byteOffset", 0))
	var length := int(bv.get("byteLength", 0))
	if length <= 0 or start < 0 or start + length > bin.size():
		return PackedByteArray()
	return bin.slice(start, start + length)


func _glb_primitives(js: Dictionary, bin: PackedByteArray) -> Array:
	var accessors: Array = js.get("accessors", [])
	var views: Array = js.get("bufferViews", [])
	var out: Array = []
	for mesh in js.get("meshes", []):
		for prim in mesh.get("primitives", []):
			var attrs: Dictionary = prim.get("attributes", {})
			out.append({
				"pos": _f32(bin, views, accessors, attrs.get("POSITION", -1)),
				"uv": _f32(bin, views, accessors, attrs.get("TEXCOORD_0", -1)),
				"idx": _u32(bin, views, accessors, prim.get("indices", -1)),
			})
	return out


func _span(views: Array, accessors: Array, ai: int) -> Array:
	if ai < 0 or ai >= accessors.size():
		return []
	var acc: Dictionary = accessors[ai]
	var bv: Dictionary = views[int(acc.get("bufferView", 0))]
	return [int(bv.get("byteOffset", 0)) + int(acc.get("byteOffset", 0)),
			int(acc.get("count", 0))]


func _f32(bin: PackedByteArray, views: Array, accessors: Array, ai: int) -> PackedFloat32Array:
	var s := _span(views, accessors, ai)
	if s.is_empty():
		return PackedFloat32Array()
	var acc: Dictionary = accessors[ai]
	var per := 3 if str(acc.get("type", "VEC3")) == "VEC3" else 2
	var out := PackedFloat32Array()
	out.resize(s[1] * per)
	for i in out.size():
		out[i] = bin.decode_float(s[0] + i * 4)
	return out


func _u32(bin: PackedByteArray, views: Array, accessors: Array, ai: int) -> PackedInt32Array:
	var s := _span(views, accessors, ai)
	if s.is_empty():
		return PackedInt32Array()
	var out := PackedInt32Array()
	out.resize(s[1])
	for i in s[1]:
		out[i] = bin.decode_u32(s[0] + i * 4)
	return out


static func _to_f32(v: float) -> float:
	var p := PackedFloat32Array([v])
	return p[0]


func _compare(m: Dictionary, prims: Array) -> String:
	if prims.size() != 1:
		return "expected 1 primitive, reference has %d" % prims.size()
	var r: Dictionary = prims[0]
	var rpos: PackedFloat32Array = r["pos"]
	var ruv: PackedFloat32Array = r["uv"]
	var ridx: PackedInt32Array = r["idx"]
	var opos: Array = m["positions"]
	var ouv: Array = m["uvs"]
	var oidx: PackedInt32Array = m["indices"]

	if rpos.size() != opos.size() * 3:
		return "vertex count %d vs %d" % [rpos.size() / 3, opos.size()]
	if ridx.size() != oidx.size():
		return "index count %d vs %d" % [ridx.size(), oidx.size()]

	for i in opos.size():
		for c in 3:
			if _to_f32(opos[i][c]) != rpos[i * 3 + c]:
				return "vert %d comp %d: ref=%s ours=%s" % [i, c, rpos[i * 3 + c], opos[i][c]]
	for i in ouv.size():
		for c in 2:
			if _to_f32(ouv[i][c]) != ruv[i * 2 + c]:
				return "uv %d comp %d: ref=%s ours=%s" % [i, c, ruv[i * 2 + c], ouv[i][c]]
	for i in oidx.size():
		if oidx[i] != ridx[i]:
			return "index %d: ref=%d ours=%d" % [i, ridx[i], oidx[i]]
	return ""


## Compare our decoded skin 0 with the GLB's embedded PNG, texel for texel.
func _compare_skin(m: Dictionary, ref_img: Image) -> String:
	var skins: Array = m.get("skins", [])
	if skins.is_empty():
		return "reader produced no skins (reference is %dx%d)" % [
			ref_img.get_width(), ref_img.get_height()]
	var s0: Dictionary = skins[0]
	var img: Image = s0.get("image")
	if img == null:
		return "reader skin 0 not decoded (null); reference is %dx%d" % [
			ref_img.get_width(), ref_img.get_height()]
	if img.get_width() != ref_img.get_width() or img.get_height() != ref_img.get_height():
		return "size %dx%d vs ref %dx%d" % [img.get_width(), img.get_height(),
			ref_img.get_width(), ref_img.get_height()]
	# The oracle always writes an RGBA PNG; convert defensively so a reference
	# that ever lands in RGB8 still compares by value rather than failing on
	# a stride mismatch.
	var ref_rgba := ref_img
	if ref_rgba.get_format() != Image.FORMAT_RGBA8:
		ref_rgba = ref_img.duplicate()
		ref_rgba.convert(Image.FORMAT_RGBA8)
	if img.get_format() != Image.FORMAT_RGBA8:
		return "reader format %d, expected FORMAT_RGBA8" % img.get_format()
	var a := img.get_data()
	var b := ref_rgba.get_data()
	if a.size() != b.size():
		return "pixel byte count %d vs ref %d" % [a.size(), b.size()]
	if a == b:
		return ""
	var w := img.get_width()
	var bad := 0
	var first := ""
	for i in a.size() / 4:
		var d := false
		for c in 4:
			if a[i * 4 + c] != b[i * 4 + c]:
				d = true
		if d:
			bad += 1
			if first == "":
				first = "(%d,%d) ref=%d,%d,%d,%d ours=%d,%d,%d,%d" % [
					i % w, i / w,
					b[i * 4], b[i * 4 + 1], b[i * 4 + 2], b[i * 4 + 3],
					a[i * 4], a[i * 4 + 1], a[i * 4 + 2], a[i * 4 + 3]]
	return "%d/%d texels differ, first at %s" % [bad, a.size() / 4, first]


## Cover what the corpus cannot: the embedded palette table, and the IDPO
## group-0 / group-1 skin branches (pixels AND stride). Returns failures.
func _check_idpo_palette_paths() -> Array[String]:
	var fail: Array[String] = []

	# 1. The embedded palette must be tools/game_palette.raw, byte for byte.
	var pal: PackedByteArray = MdlFile._game_palette()
	if pal.size() != 768:
		fail.append("embedded palette is %d bytes, expected 768" % pal.size())
	else:
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		ctx.update(pal)
		var got := ctx.finish().hex_encode()
		if got != GAME_PALETTE_SHA256:
			fail.append("embedded palette sha256 %s, expected %s" % [got, GAME_PALETTE_SHA256])

	# 2. Parse the synthetic IDPO and compare against convert_mdl.py's output.
	var m := MdlFile.read_mdl_bytes(Marshalls.base64_to_raw(SYNTH_IDPO_B64), "synth_idpo", true)
	if m.has("error"):
		fail.append("synthetic IDPO failed to parse: %s" % m["error"])
		return fail

	# Palette RGB for indices 0,1,15,47,128,200,254,255 -- fully opaque, index 0
	# black rather than transparent, exactly as _apply_quake_palette specifies.
	var want_skin0: Array = [
		[0, 0, 0, 255], [15, 15, 15, 255], [235, 235, 235, 255], [139, 139, 203, 255],
		[171, 139, 163, 255], [123, 99, 7, 255], [254, 254, 254, 255], [255, 255, 255, 255],
	]
	var want_skin1: Array = []
	for i in range(want_skin0.size() - 1, -1, -1):
		want_skin1.append(want_skin0[i])

	var skins: Array = m.get("skins", [])
	if skins.size() != 2:
		fail.append("synthetic IDPO: %d skins, expected 2" % skins.size())
	else:
		# Explicitly typed: indexing an untyped Array yields Variant.
		var s0: Dictionary = skins[0]
		var s1: Dictionary = skins[1]
		fail.append_array(_check_synth_skin(s0, "group0", want_skin0))
		# Group skins hold N frames; the oracle keeps only the FIRST.
		fail.append_array(_check_synth_skin(s1, "group1", want_skin1))

	# Geometry after the two skin blocks: proves both strides land correctly.
	var want_pos: Array = [[20.0, 120.0, -60.0], [80.0, 300.0, -180.0], [50.0, 210.0, -120.0]]
	var want_uv: Array = [[0.375, 0.25], [0.875, 0.75], [1.125, 0.75]]
	var pos: Array = m["positions"]
	var uvs: Array = m["uvs"]
	var idx: PackedInt32Array = m["indices"]
	if pos.size() != 3 or uvs.size() != 3 or idx.size() != 3:
		fail.append("synthetic IDPO geometry sizes %d/%d/%d, expected 3/3/3" % [
			pos.size(), uvs.size(), idx.size()])
	else:
		for i in 3:
			for c in 3:
				if float(pos[i][c]) != float(want_pos[i][c]):
					fail.append("synthetic IDPO vert %d comp %d: want %s got %s" % [
						i, c, want_pos[i][c], pos[i][c]])
			for c in 2:
				if float(uvs[i][c]) != float(want_uv[i][c]):
					fail.append("synthetic IDPO uv %d comp %d: want %s got %s" % [
						i, c, want_uv[i][c], uvs[i][c]])
			if idx[i] != i:
				fail.append("synthetic IDPO index %d: want %d got %d" % [i, i, idx[i]])
	return fail


func _check_synth_skin(entry: Dictionary, label: String, want: Array) -> Array[String]:
	var fail: Array[String] = []
	var img: Image = entry.get("image")
	if img == null:
		fail.append("synthetic IDPO %s skin not decoded (null)" % label)
		return fail
	if img.get_width() != 4 or img.get_height() != 2:
		fail.append("synthetic IDPO %s skin is %dx%d, expected 4x2" % [
			label, img.get_width(), img.get_height()])
		return fail
	var px: PackedByteArray = img.get_data()
	if px.size() != want.size() * 4:
		fail.append("synthetic IDPO %s skin has %d bytes, expected %d" % [
			label, px.size(), want.size() * 4])
		return fail
	for i in want.size():
		var w: Array = want[i]
		for c in 4:
			if px[i * 4 + c] != int(w[c]):
				fail.append("synthetic IDPO %s texel %d comp %d: want %d got %d" % [
					label, i, c, int(w[c]), px[i * 4 + c]])
	return fail
