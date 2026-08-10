extends SceneTree
## Oracle test for the first-run AST cache (scripts/engine/wdl_cache.gd).
##
## Three things have to hold before wdl_interpreter.gd's USE_RUNTIME_WDL may
## ever be flipped on:
##
##   (a) IDENTITY -- the AST the cache serves is deep-equal to the committed
##       assets/converted/wdl_ast/<Stem>.json for every script. Checked twice,
##       on the cold pass (fresh parse) and again on the warm pass (read back
##       out of user://), because the warm pass is the one that also proves the
##       JSON round-trip through the envelope loses nothing -- the corpus is
##       latin-1 Hebrew text and a lossy round-trip would show up here.
##   (b) CACHE HIT -- the second pass must not reparse. Asserted from
##       WdlCache.stats, i.e. from the code path actually taken, not from a
##       stopwatch that could be fooled by a warm OS file cache.
##   (c) COST -- report cold parse vs warm load, since the whole reason the
##       cache exists is that the first number is ~10x the second.
##
##   godot --path . --headless -s res://tools/smoke_wdl_cache.gd
##   godot --path . --headless -s res://tools/smoke_wdl_cache.gd -- --keep-cache
##
## `--keep-cache` skips the wipe, so running it once plain and once with the
## flag proves the cache survives across PROCESSES, not just across two passes
## inside one.

const WdlCache = preload("res://scripts/engine/wdl_cache.gd")

const AST := "res://assets/converted/wdl_ast"


func _init() -> void:
	var keep_cache := false
	for a in OS.get_cmdline_user_args():
		if a == "--keep-cache":
			keep_cache = true

	var stems: Array = WdlCache.list_stems()
	print("")
	print("=== WDL first-run AST cache ===")
	print("cache dir        : %s" % ProjectSettings.globalize_path(WdlCache.CACHE_DIR))
	print("sources found    : %d" % stems.size())

	var removed := 0
	if keep_cache:
		print("mode             : --keep-cache (existing user:// cache reused)")
	else:
		removed = WdlCache.clear_disk_cache()
		print("mode             : cold start (%d stale cache file(s) removed)" % removed)

	# Reference ASTs are loaded (and timed) up front so neither pass pays for
	# them, and so the JSON-load baseline below measures the same work the
	# shipping res:// path does today.
	var refs := {}
	var no_ref: Array[String] = []
	var ref_bytes := 0
	var t_ref := Time.get_ticks_usec()
	for stem in stems:
		var p := "%s/%s.json" % [AST, stem]
		var f := FileAccess.open(p, FileAccess.READ)
		if f == null:
			no_ref.append(stem)
			continue
		ref_bytes += f.get_length()
		var data = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(data) != TYPE_DICTIONARY:
			no_ref.append(stem)
			continue
		refs[stem] = data
	var ref_ms := (Time.get_ticks_usec() - t_ref) / 1000.0

	var src_bytes := 0
	for stem in stems:
		var sf := FileAccess.open(WdlCache.source_path(stem), FileAccess.READ)
		if sf:
			src_bytes += sf.get_length()
			sf.close()

	var cold := _pass(stems, refs, "cold")
	var warm := _pass(stems, refs, "warm")

	var cached_files := _count_cache_files()
	var invalidation := _check_invalidation(stems)

	print("")
	print("--- pass 1 (cold) ---")
	print("parsed           : %d" % cold["parsed"])
	print("cache hits       : %d" % cold["hit"])
	print("write failures   : %d" % cold["write_failed"])
	print("time             : %.1f ms" % cold["ms"])
	print("")
	print("--- pass 2 (warm) ---")
	print("parsed           : %d" % warm["parsed"])
	print("cache hits       : %d" % warm["hit"])
	print("time             : %.1f ms" % warm["ms"])
	print("")
	print("--- cost ---")
	print("source           : %.2f MB across %d file(s)" % [src_bytes / 1048576.0, stems.size()])
	print("cold  parse+store: %.1f ms" % cold["ms"])
	print("warm  cache load : %.1f ms" % warm["ms"])
	print("speedup          : %.1fx" % (cold["ms"] / maxf(warm["ms"], 0.001)))
	print("(baseline) committed res:// AST load: %.1f ms for %.2f MB" % [
		ref_ms, ref_bytes / 1048576.0])
	print("")
	print("--- identity vs assets/converted/wdl_ast ---")
	print("compared         : %d" % refs.size())
	print("cold  IDENTICAL  : %d   differ: %d" % [cold["same"], cold["differ"]])
	print("warm  IDENTICAL  : %d   differ: %d" % [warm["same"], warm["differ"]])
	print("no reference AST : %d%s" % [
		no_ref.size(), "" if no_ref.is_empty() else " " + str(no_ref)])
	print("empty AST        : cold %d, warm %d" % [cold["empty"], warm["empty"]])
	print("cache files      : %d" % cached_files)
	print("")
	print("--- invalidation ---")
	print("%s" % invalidation["report"])
	for d in cold["detail"]:
		print("  COLD DIFF %s" % d)
	for d in warm["detail"]:
		print("  WARM DIFF %s" % d)

	# The warm pass must be a pure cache read. On a --keep-cache run the cold
	# pass is warm too, so only assert "no parses in pass 2".
	var fails: Array[String] = []
	if cold["differ"] > 0 or warm["differ"] > 0:
		fails.append("AST differs from the committed oracle")
	if warm["parsed"] > 0:
		fails.append("pass 2 reparsed %d file(s) instead of hitting the cache" % warm["parsed"])
	if warm["hit"] != refs.size() + no_ref.size():
		fails.append("pass 2 hit %d of %d" % [warm["hit"], stems.size()])
	if cold["write_failed"] > 0:
		fails.append("%d cache write(s) failed" % cold["write_failed"])
	if not keep_cache and cold["parsed"] != stems.size():
		fails.append("cold pass parsed %d of %d" % [cold["parsed"], stems.size()])
	if refs.size() == 0:
		fails.append("no reference ASTs loaded -- nothing was actually compared")
	if not invalidation["ok"]:
		fails.append("stale cache entry was served: %s" % invalidation["report"])

	print("")
	for f in fails:
		print("  FAIL %s" % f)
	print("smoke_wdl_cache: %s" % ("PASS" if fails.is_empty() else "FAIL"))
	quit(0 if fails.is_empty() else 1)


func _pass(stems: Array, refs: Dictionary, label: String) -> Dictionary:
	WdlCache.reset_stats()
	var same := 0
	var differ := 0
	var empty := 0
	var detail: Array[String] = []
	var got := {}

	# Timed loop does the fetching only -- the deep compare is this test's
	# cost, not the cache's, and folding it in would make the reported
	# cold/warm numbers meaningless.
	var t0 := Time.get_ticks_usec()
	for stem in stems:
		got[stem] = WdlCache.get_ast(stem)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0

	for stem in stems:
		var ast: Dictionary = got[stem]
		if ast.is_empty():
			empty += 1
		if not refs.has(stem):
			continue
		var why := _diff(refs[stem], ast, "")
		if why == "":
			same += 1
		else:
			differ += 1
			if detail.size() < 15:
				detail.append("%s: %s" % [stem, why])

	return {
		"label": label, "ms": ms, "same": same, "differ": differ, "empty": empty,
		"detail": detail,
		"parsed": int(WdlCache.stats["parsed"]),
		"hit": int(WdlCache.stats["hit"]),
		"missing": int(WdlCache.stats["missing"]),
		"write_failed": int(WdlCache.stats["write_failed"]),
	}


## A cache nobody can invalidate is worse than no cache: an edited .wdl would
## be shadowed forever by a stale user:// entry. Rather than mutate a source
## file under the other agents working in this tree, rewrite ONE cache entry's
## recorded source MD5 -- the exact state "the source changed since this was
## written" produces -- and require that the next fetch reparses, and the one
## after that hits again. Uses the smallest source so the reparse costs
## milliseconds.
func _check_invalidation(stems: Array) -> Dictionary:
	var victim := ""
	var smallest := 1 << 30
	for stem in stems:
		var f := FileAccess.open(WdlCache.source_path(stem), FileAccess.READ)
		if f == null:
			continue
		var n := f.get_length()
		f.close()
		if n > 0 and n < smallest and FileAccess.file_exists(WdlCache.cache_path_for(stem)):
			smallest = n
			victim = stem
	if victim == "":
		return {"ok": false, "report": "no cache entry available to tamper with"}

	var cache_path := WdlCache.cache_path_for(victim)
	var rf := FileAccess.open(cache_path, FileAccess.READ)
	var env = JSON.parse_string(rf.get_as_text())
	rf.close()
	if typeof(env) != TYPE_DICTIONARY:
		return {"ok": false, "report": "cache entry for %s is not a readable envelope" % victim}
	env["source_md5"] = "0000stale0000"
	var wf := FileAccess.open(cache_path, FileAccess.WRITE)
	wf.store_string(JSON.stringify(env))
	wf.close()

	WdlCache.reset_stats()
	var after_tamper: Dictionary = WdlCache.get_ast(victim)
	var status_1 := WdlCache.last_status
	WdlCache.get_ast(victim)
	var status_2 := WdlCache.last_status

	var ok := status_1 == "parsed" and status_2 == "hit" and not after_tamper.is_empty()
	return {
		"ok": ok,
		"report": "tampered source_md5 on %s (%d B): next fetch = %s, one after = %s%s" % [
			victim, smallest, status_1, status_2,
			"" if ok else "  <-- expected parsed then hit"],
	}


func _count_cache_files() -> int:
	var n := 0
	var d := DirAccess.open(WdlCache.CACHE_DIR)
	if d == null:
		return 0
	d.list_dir_begin()
	var e := d.get_next()
	while e != "":
		if not d.current_is_dir() and e.get_extension().to_lower() == "json":
			n += 1
		e = d.get_next()
	d.list_dir_end()
	return n


## Deep structural compare, identical in rule to tools/smoke_wdl_parser.gd's:
## returns "" when equal, else the path + description of the FIRST difference.
## int and float compare numerically because JSON round-tripping makes that
## distinction an artifact of the encoder (Python writes 3.0, Godot may read it
## back as either) rather than a property of the parse.
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
