extends SceneTree
## Oracle test for the runtime WMB brush-geometry reader.
##
## `WmbFile.read_brush()` must reproduce `tools/extract_wmb_mesh.py`. The
## committed brush GLBs are ground truth: parse each one's glTF chunks DIRECTLY
## out of the binary (never via `load()`, which would hand back an imported,
## possibly VRAM-compressed resource) and compare every vertex position, UV and
## index against what the reader produces.
##
## Primitive order in those files is sorted texture index, one primitive per
## non-empty bucket, with POSITION/TEXCOORD_0 as float32 and indices as uint32 --
## so the comparison walks our buckets in the same sorted order.
##
## Floats compare at float32 precision, for the same reason as
## smoke_wmb_reader.gd: the data IS float32, and the reference has been through
## a lossy float64/decimal round trip that the reader has not.
##
##   godot --path . --headless -s res://tools/smoke_wmb_mesh.gd
##   godot --path . --headless -s res://tools/smoke_wmb_mesh.gd -- --only=Town

const WmbFile = preload("res://scripts/engine/wmb_file.gd")

const SRC := "res://original/piposh3d/WMB"
const LEVELS := "res://assets/converted/levels"
const WMB := "res://assets/converted/wmb"


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
		if not d.current_is_dir() and n.get_extension().to_lower() == "wmb":
			files.append(n)
		n = d.get_next()
	d.list_dir_end()
	files.sort()

	var exact := 0
	var differ := 0
	var no_ref := 0
	var verts_compared := 0
	var tris_compared := 0
	var detail: Array[String] = []
	var read_usec := 0

	for fname in files:
		var stem: String = fname.get_basename()
		if only != "" and stem.to_lower() != only:
			continue

		# Level geometry goes to levels/<stem>_brush.glb; prop/sub-model WMBs go
		# to wmb/<stem>.glb. Try both.
		var ref_bytes := _read_file("%s/%s_brush.glb" % [LEVELS, stem])
		if ref_bytes.is_empty():
			ref_bytes = _read_file("%s/%s.glb" % [WMB, stem])
		if ref_bytes.is_empty():
			no_ref += 1
			continue

		var src_bytes := _read_file("%s/%s" % [SRC, fname])
		if src_bytes.is_empty():
			no_ref += 1
			continue

		var r0 := Time.get_ticks_usec()
		var brush := WmbFile.read_brush(src_bytes, false)
		read_usec += Time.get_ticks_usec() - r0

		var ref_prims := _glb_primitives(ref_bytes)
		if ref_prims.is_empty():
			no_ref += 1
			continue

		var why := _compare(brush, ref_prims)
		if why == "":
			exact += 1
			for p in ref_prims:
				verts_compared += (p["pos"] as PackedFloat32Array).size() / 3
				tris_compared += (p["idx"] as PackedInt32Array).size() / 3
		else:
			differ += 1
			if detail.size() < 15:
				detail.append("%s: %s" % [fname, why])

	print("")
	print("=== WMB brush geometry vs Python oracle ===")
	print("levels           : %d" % (exact + differ))
	print("EXACT MATCH      : %d" % exact)
	print("differ           : %d" % differ)
	print("no reference GLB : %d" % no_ref)
	print("vertices compared: %d" % verts_compared)
	print("triangles        : %d" % tris_compared)
	print("read time        : %.1f ms" % (read_usec / 1000.0))
	for x in detail:
		print("  DIFF %s" % x)

	print("")
	print("smoke_wmb_mesh: %s" % ("PASS" if differ == 0 else "%d level(s) differ" % differ))
	quit(0 if differ == 0 else 1)


func _read_file(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var b := f.get_buffer(f.get_length())
	f.close()
	return b


## Decode a GLB's primitives straight from its chunks: [{pos, uv, idx}, ...] in
## file order, which is the writer's sorted-texture order.
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
			var txt := data.slice(off, off + clen).get_string_from_utf8()
			var parsed = JSON.parse_string(txt.strip_edges())
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


func _view_span(views: Array, accessors: Array, ai: int) -> Array:
	if ai < 0 or ai >= accessors.size():
		return []
	var acc: Dictionary = accessors[ai]
	var bv: Dictionary = views[int(acc.get("bufferView", 0))]
	var start := int(bv.get("byteOffset", 0)) + int(acc.get("byteOffset", 0))
	return [start, int(acc.get("count", 0))]


func _f32(bin: PackedByteArray, views: Array, accessors: Array, ai: int) -> PackedFloat32Array:
	var span := _view_span(views, accessors, ai)
	if span.is_empty():
		return PackedFloat32Array()
	var acc: Dictionary = accessors[ai]
	var per := 3 if str(acc.get("type", "VEC3")) == "VEC3" else 2
	var total: int = span[1] * per
	var out := PackedFloat32Array()
	out.resize(total)
	for i in total:
		out[i] = bin.decode_float(span[0] + i * 4)
	return out


func _u32(bin: PackedByteArray, views: Array, accessors: Array, ai: int) -> PackedInt32Array:
	var span := _view_span(views, accessors, ai)
	if span.is_empty():
		return PackedInt32Array()
	var out := PackedInt32Array()
	out.resize(span[1])
	for i in span[1]:
		out[i] = bin.decode_u32(span[0] + i * 4)
	return out


static func _to_f32(v: float) -> float:
	var p := PackedFloat32Array([v])
	return p[0]


func _compare(brush: Dictionary, ref_prims: Array) -> String:
	if brush.is_empty():
		return "reader produced no brush geometry, reference has %d primitive(s)" % ref_prims.size()

	var keys: Array = brush["buckets"].keys()
	keys.sort()
	# The writer skips buckets with no indices, so ours must too.
	var ours: Array = []
	for k in keys:
		var b: Dictionary = brush["buckets"][k]
		if not (b["idx"] as Array).is_empty():
			ours.append(b)

	if ours.size() != ref_prims.size():
		return "primitive count %d vs %d" % [ref_prims.size(), ours.size()]

	for pi in ours.size():
		var b: Dictionary = ours[pi]
		var r: Dictionary = ref_prims[pi]
		var rpos: PackedFloat32Array = r["pos"]
		var ruv: PackedFloat32Array = r["uv"]
		var ridx: PackedInt32Array = r["idx"]
		var opos: Array = b["pos"]
		var ouv: Array = b["uv"]
		var oidx: Array = b["idx"]

		if rpos.size() != opos.size() * 3:
			return "prim %d: vertex count %d vs %d" % [pi, rpos.size() / 3, opos.size()]
		if ridx.size() != oidx.size():
			return "prim %d: index count %d vs %d" % [pi, ridx.size(), oidx.size()]

		for i in opos.size():
			for c in 3:
				if _to_f32(opos[i][c]) != rpos[i * 3 + c]:
					return "prim %d vert %d comp %d: ref=%s ours=%s" % [
						pi, i, c, rpos[i * 3 + c], opos[i][c]]
		for i in ouv.size():
			for c in 2:
				if _to_f32(ouv[i][c]) != ruv[i * 2 + c]:
					return "prim %d uv %d comp %d: ref=%s ours=%s" % [
						pi, i, c, ruv[i * 2 + c], ouv[i][c]]
		for i in oidx.size():
			if int(oidx[i]) != ridx[i]:
				return "prim %d index %d: ref=%d ours=%d" % [pi, i, ridx[i], oidx[i]]

	return ""
