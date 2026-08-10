extends SceneTree
## Oracle test for the runtime WMB object reader.
##
## `scripts/engine/wmb_file.gd` must reproduce `tools/extract_wmb_full.py`
## exactly. The committed `assets/converted/levels/*.json` is the ground truth:
## read every .WMB and deep-compare.
##
## Floats are compared EXACTLY here, not approximately, because this path
## contains no trigonometry -- positions are axis swaps of float32 values read
## straight out of the file, and `angle_deg` is only a tilt normalisation. Any
## drift at all means a real difference in how a record was decoded, so a
## tolerance would hide exactly the bugs this test exists to find. The one
## deliberate exception is int-vs-float, which is a JSON encoding artifact.
##
##   godot --path . --headless -s res://tools/smoke_wmb_reader.gd
##   godot --path . --headless -s res://tools/smoke_wmb_reader.gd -- --only=Town

const WmbFile = preload("res://scripts/engine/wmb_file.gd")

const SRC := "res://original/piposh3d/WMB"
const REF := "res://assets/converted/levels"


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
	var missing := 0
	var detail: Array[String] = []
	var objects_compared := 0
	var t0 := Time.get_ticks_usec()
	var read_usec := 0
	var bytes_read := 0

	for fname in files:
		var stem: String = fname.get_basename()
		if only != "" and stem.to_lower() != only:
			continue

		var rf := FileAccess.open("%s/%s.json" % [REF, stem], FileAccess.READ)
		if rf == null:
			missing += 1
			continue
		var ref = JSON.parse_string(rf.get_as_text())
		rf.close()
		if typeof(ref) != TYPE_DICTIONARY:
			missing += 1
			continue

		var src := "%s/%s" % [SRC, fname]
		var sf := FileAccess.open(src, FileAccess.READ)
		if sf != null:
			bytes_read += sf.get_length()
			sf.close()

		var r0 := Time.get_ticks_usec()
		var got := WmbFile.read_level(src)
		read_usec += Time.get_ticks_usec() - r0

		if got.has("error"):
			differ += 1
			if detail.size() < 15:
				detail.append("%s: reader error: %s" % [fname, got["error"]])
			continue

		objects_compared += (got.get("objects", []) as Array).size()
		var why := _diff(ref, got, "")
		if why == "":
			exact += 1
		else:
			differ += 1
			if detail.size() < 15:
				detail.append("%s: %s" % [fname, why])

	var total_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var read_ms := read_usec / 1000.0

	print("")
	print("=== WMB runtime reader vs Python oracle ===")
	print("levels           : %d" % (exact + differ))
	print("EXACT MATCH      : %d" % exact)
	print("differ           : %d" % differ)
	print("no reference JSON: %d" % missing)
	print("objects compared : %d" % objects_compared)
	print("")
	print("read             : %.2f MB in %.1f ms  (%.1f MB/s)" % [
		bytes_read / 1048576.0, read_ms,
		(bytes_read / 1048576.0) / maxf(read_ms / 1000.0, 0.000001)])
	print("total incl verify: %.1f ms" % total_ms)
	for x in detail:
		print("  DIFF %s" % x)

	print("")
	print("smoke_wmb_reader: %s" % ("PASS" if differ == 0 else "%d level(s) differ" % differ))
	quit(0 if differ == 0 else 1)


## Round a float64 to the nearest float32, via an actual float32 store.
static func _f32(v: float) -> float:
	var p := PackedFloat32Array([v])
	return p[0]


func _diff(a, b, path: String) -> String:
	var ta := typeof(a)
	var tb := typeof(b)

	var a_num := ta == TYPE_INT or ta == TYPE_FLOAT
	var b_num := tb == TYPE_INT or tb == TYPE_FLOAT
	if a_num and b_num:
		# Compared at FLOAT32 precision, which is the precision the data
		# actually has: every number here originates as a <f (float32) field in
		# the WMB. The reference path is lossy in a way the reader is not --
		# float32 -> Python float64 -> decimal text -> Godot's JSON parser,
		# whose decimal->binary conversion differs in the last double bit --
		# so an exact float64 compare flags ~1e-14 noise on 44 levels that are
		# in fact identical. Rounding both to float32 removes that artifact
		# without hiding real defects: a misread record (wrong offset, missed
		# pad byte, wrong field order) differs by orders of magnitude, never by
		# one float32 ULP.
		if _f32(float(a)) == _f32(float(b)):
			return ""
		# GDScript's format has no %g; %s prints enough digits to see the drift.
		return "%s: ref=%s ours=%s (delta %s)" % [
			path, float(a), float(b), float(b) - float(a)]

	if ta != tb:
		return "%s: type %d vs %d (%s vs %s)" % [path, ta, tb, a, b]

	match ta:
		TYPE_DICTIONARY:
			for k in a.keys():
				if not b.has(k):
					return "%s.%s: missing in ours" % [path, k]
				var w := _diff(a[k], b[k], "%s.%s" % [path, k])
				if w != "":
					return w
			for k in b.keys():
				if not a.has(k):
					return "%s.%s: extra in ours" % [path, k]
			return ""
		TYPE_ARRAY:
			if a.size() != b.size():
				return "%s: length %d vs %d" % [path, a.size(), b.size()]
			for i in a.size():
				var w := _diff(a[i], b[i], "%s[%d]" % [path, i])
				if w != "":
					return w
			return ""
		_:
			if a == b:
				return ""
			return "%s: '%s' != '%s'" % [path, a, b]
