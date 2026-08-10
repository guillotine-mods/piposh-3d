extends SceneTree
## Oracle test for the runtime MDL reader (Conitec MDL2-5).
##
## `MdlFile.read_mdl_bytes()` must reproduce the `parse_conitec_mdl` half of
## `tools/convert_mdl.py`. The committed `assets/converted/mdl/*.glb` are ground
## truth: their glTF chunks are parsed DIRECTLY from the binary -- never via
## `load()`, which returns an imported, VRAM-compressed resource -- and every
## vertex position, UV and index is compared.
##
## Quake IDPO models are counted separately and skipped: that parser is not
## ported yet, and the reader refuses them explicitly rather than guessing.
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
		var m := MdlFile.read_mdl_bytes(src, stem, false)
		read_usec += Time.get_ticks_usec() - t0

		if m.has("error"):
			reader_err += 1
			if err_detail.size() < 10:
				err_detail.append("%s: %s" % [fname, m["error"]])
			continue

		var prims := _glb_primitives(ref_bytes)
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
	for x in detail:
		print("  DIFF  %s" % x)
	for x in err_detail:
		print("  ERR   %s" % x)

	var bad := differ + reader_err
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


func _glb_primitives(data: PackedByteArray) -> Array:
	if data.size() < 12:
		return []
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
		return []

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
