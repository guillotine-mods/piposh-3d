extends SceneTree
## Oracle test for the runtime WDL parser.
##
## `scripts/engine/wdl_parser.gd` must reproduce `tools/parse_wdl.py` exactly.
## The committed `assets/converted/wdl_ast/*.json` is the ground truth: parse
## every .wdl with the GDScript parser and deep-compare the resulting AST
## against the JSON the Python produced. Any structural difference is a bug in
## the GDScript parser, including a difference in the recorded `skipped`
## messages -- those encode where each parser gave up and resynced, so if they
## diverge the two are not walking the same token stream.
##
##   godot --path . --headless -s res://tools/smoke_wdl_parser.gd
##   godot --path . --headless -s res://tools/smoke_wdl_parser.gd -- --only=Range

const WdlParser = preload("res://scripts/engine/wdl_parser.gd")

const SRC := "res://original/piposh3d"
const AST := "res://assets/converted/wdl_ast"


func _init() -> void:
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only"):
			var parts := a.split("=")
			if parts.size() > 1:
				only = parts[1].to_lower()

	# File selection must match parse_wdl.py's main() exactly: WDL/ (Conitec's
	# shared library) is inserted FIRST, then the top-level per-level scripts
	# overwrite on stem collision -- otherwise the real game's Menu.wdl loses
	# to the unused SDK template WDL/menu.wdl.
	var by_stem := {}
	for f in _list(SRC + "/WDL"):
		by_stem[f.get_file().get_basename().to_lower()] = f
	for f in _list(SRC):
		by_stem[f.get_file().get_basename().to_lower()] = f

	var files: Array = by_stem.values()
	files.sort_custom(func(a, b): return a.get_file() < b.get_file())

	var exact := 0
	var differ := 0
	var missing := 0
	var detail: Array[String] = []
	var t0 := Time.get_ticks_usec()
	var parse_usec := 0
	var bytes_parsed := 0

	for path in files:
		var stem: String = path.get_file().get_basename()
		if only != "" and stem.to_lower() != only:
			continue

		var ref_path := "%s/%s.json" % [AST, stem]
		var rf := FileAccess.open(ref_path, FileAccess.READ)
		if rf == null:
			missing += 1
			continue
		var ref_txt := rf.get_as_text()
		rf.close()
		var ref = JSON.parse_string(ref_txt)
		if typeof(ref) != TYPE_DICTIONARY:
			missing += 1
			continue

		var sf := FileAccess.open(path, FileAccess.READ)
		if sf == null:
			missing += 1
			continue
		bytes_parsed += sf.get_length()
		sf.close()

		var p0 := Time.get_ticks_usec()
		var got := WdlParser.parse_file(path, path.get_file())
		parse_usec += Time.get_ticks_usec() - p0

		var why := _diff(ref, got, "")
		if why == "":
			exact += 1
		else:
			differ += 1
			if detail.size() < 15:
				detail.append("%s: %s" % [path.get_file(), why])

	var total_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var parse_ms := parse_usec / 1000.0

	print("")
	print("=== WDL runtime parser vs Python oracle ===")
	print("files            : %d" % (exact + differ))
	print("AST-IDENTICAL    : %d" % exact)
	print("differ           : %d" % differ)
	print("no reference AST : %d" % missing)
	print("")
	print("source parsed    : %.2f MB" % (bytes_parsed / 1048576.0))
	print("parse time       : %.1f ms  (%.2f MB/s)" % [
		parse_ms, (bytes_parsed / 1048576.0) / maxf(parse_ms / 1000.0, 0.000001)])
	print("total incl verify: %.1f ms" % total_ms)
	for d in detail:
		print("  DIFF %s" % d)

	print("")
	print("smoke_wdl_parser: %s" % ("PASS" if differ == 0 else "%d file(s) differ" % differ))
	quit(0 if differ == 0 else 1)


func _list(dir_path: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not d.current_is_dir() and n.get_extension().to_lower() == "wdl":
			out.append(dir_path + "/" + n)
		n = d.get_next()
	d.list_dir_end()
	out.sort()
	return out


## Deep structural compare. Returns "" when equal, else a path + description of
## the FIRST difference — a bare "not equal" is useless across an 85-file corpus.
##
## int and float compare numerically: JSON round-tripping makes the distinction
## an artifact of the encoder, not of the parse (Python writes 3.0, Godot may
## read it back as either), and treating that as a failure would bury real
## differences under hundreds of false ones.
func _diff(a, b, path: String) -> String:
	var ta := typeof(a)
	var tb := typeof(b)

	var a_num := ta == TYPE_INT or ta == TYPE_FLOAT
	var b_num := tb == TYPE_INT or tb == TYPE_FLOAT
	if a_num and b_num:
		if is_equal_approx(float(a), float(b)):
			return ""
		return "%s: %s != %s" % [path, a, b]

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
			return "%s: %s != %s" % [path, a, b]
