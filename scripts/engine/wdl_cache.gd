extends RefCounted
## First-run AST cache for the runtime WDL parser.
##
## Third step of moving conversion into the game (after `wdl_parser.gd`).
## Given a level stem it returns the same AST the committed
## `assets/converted/wdl_ast/<Stem>.json` holds, but produced from the
## ORIGINAL `original/piposh3d/**.wdl` at runtime: parsed once with
## `wdl_parser.gd` and written to `user://wdl_cache/<stem>.json`, then read
## back from there on every later run.
##
## The cache is the design, not an optimisation. `wdl_parser.gd` is GDScript
## and Godot's JSON reader is C++, so parsing the 1.57 MB corpus costs ~3.7 s
## against ~0.3 s to load the equivalent JSON -- roughly an order of
## magnitude. Nothing may pay that cost more than once per install.
##
## Deliberately NO `class_name` (see commit 5c0adfa). Use via `preload`.
##
## INVALIDATION: MD5 of the source file, not size+modified-time.
## `FileAccess.get_modified_time()` returns 0 for any file inside an exported
## .pck (PackedData stores no timestamps), so a size+mtime key silently
## degrades to size-only in a shipped build -- and a shipped build is exactly
## where the user:// cache outlives the source it was built from. An edit that
## keeps the byte count (a renamed action, a changed constant) would then be
## served stale forever. MD5 is computed in C++ over at most ~200 KB per file;
## that is noise next to the GDScript parse it is guarding, and it behaves
## identically in the editor and in an export. The parser's own fingerprint is
## folded into the same key so changing `wdl_parser.gd` invalidates every
## entry (see `_fingerprint()`).

const WdlParser = preload("res://scripts/engine/wdl_parser.gd")

const CACHE_DIR := "user://wdl_cache/"
## Bumped by hand only when the ENVELOPE layout below changes. A change to the
## parser itself is caught by `_fingerprint()` instead.
const CACHE_VERSION := 1

## Source roots, in `tools/parse_wdl.py` main()'s order: Conitec's shared
## WDL/ library first, then the game's own top-level scripts, which overwrite
## it on a stem collision (IO and Menu both exist in each). Getting this
## backwards makes the real game's Menu.wdl lose to the unused SDK template.
const SRC_DIRS: Array[String] = [
	"res://original/piposh3d/WDL",
	"res://original/piposh3d",
]

## Result of the most recent get_ast(): "hit" (read from user://),
## "parsed" (source parsed and cached), "missing" (no .wdl for that stem)
## or "" (nothing called yet). Purely observational -- tools/smoke_wdl_cache.gd
## reads it to prove the second run does not reparse.
static var last_status := ""
static var stats := {"hit": 0, "parsed": 0, "missing": 0, "write_failed": 0}

## lowercase stem -> res:// path of its .wdl. Built once per process.
static var _index: Dictionary = {}
static var _index_built := false
static var _fingerprint_cached := ""


## The AST for `stem`, from the disk cache when it is valid, else parsed from
## the original .wdl and cached. `{}` when no source file exists for that stem
## (callers already treat an empty AST as "nothing to merge" -- see
## wdl_interpreter.gd's _load_ast()/_merge_includes_recursive()).
##
## No in-memory memoisation here on purpose: wdl_interpreter.gd already keeps a
## process-lifetime `_ast_cache`, and leaving this layer purely disk-backed is
## what lets the smoke test observe hit vs. parse honestly.
static func get_ast(stem: String) -> Dictionary:
	var src := source_path(stem)
	if src == "":
		last_status = "missing"
		stats["missing"] += 1
		return {}

	var src_md5 := FileAccess.get_md5(src)
	var cache_path := cache_path_for(stem)
	var cached := _read_cache(cache_path, src_md5)
	if not cached.is_empty():
		last_status = "hit"
		stats["hit"] += 1
		return cached

	var ast := WdlParser.parse_file(src, src.get_file())
	last_status = "parsed"
	stats["parsed"] += 1
	if not ast.is_empty():
		if not _write_cache(cache_path, src, src_md5, ast):
			stats["write_failed"] += 1
	return ast


## res:// path of the .wdl a stem comes from, "" when there is none.
## Case-insensitive: the corpus spells the same file `DIalog`, `Dialog` and
## `DIALOG` in different `include` lines.
static func source_path(stem: String) -> String:
	_build_index()
	return String(_index.get(stem.to_lower(), ""))


## Every stem the cache can serve, sorted -- the roster tools/smoke_wdl_cache.gd
## walks.
static func list_stems() -> Array:
	_build_index()
	var out: Array = []
	for path in _index.values():
		out.append(String(path).get_file().get_basename())
	out.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	return out


static func cache_path_for(stem: String) -> String:
	# Lowercased: the index is keyed lowercase, and a case-preserving name
	# would let a case-insensitive filesystem serve `IO` from `Io.json`
	# while a case-sensitive one wrote a second file.
	return CACHE_DIR + stem.to_lower() + ".json"


## Deletes every cached AST. Returns how many files were removed. Only used by
## the smoke test to force a cold run; nothing in the game calls it.
static func clear_disk_cache() -> int:
	var removed := 0
	var d := DirAccess.open(CACHE_DIR)
	if d == null:
		return 0
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not d.current_is_dir() and n.get_extension().to_lower() == "json":
			if d.remove(n) == OK:
				removed += 1
		n = d.get_next()
	d.list_dir_end()
	return removed


static func reset_stats() -> void:
	last_status = ""
	stats = {"hit": 0, "parsed": 0, "missing": 0, "write_failed": 0}


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

## Envelope layout (v1):
##   { "cache_version": int, "fingerprint": String, "source": String,
##     "source_md5": String, "ast": Dictionary }
## The AST is nested rather than stored bare so the validity key travels with
## it in one file -- a sidecar index would have to be kept consistent with N
## separate writes.
static func _read_cache(cache_path: String, src_md5: String) -> Dictionary:
	if not FileAccess.file_exists(cache_path):
		return {}
	var f := FileAccess.open(cache_path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var data = JSON.parse_string(txt)
	# A half-written file (killed mid-store_string) parses as null. Treat any
	# malformed or stale envelope as a plain miss and reparse over it.
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	if int(data.get("cache_version", -1)) != CACHE_VERSION:
		return {}
	if String(data.get("fingerprint", "")) != _fingerprint():
		return {}
	if String(data.get("source_md5", "")) != src_md5:
		return {}
	var ast = data.get("ast")
	if typeof(ast) != TYPE_DICTIONARY:
		return {}
	return ast


static func _write_cache(cache_path: String, src: String, src_md5: String, ast: Dictionary) -> bool:
	if not DirAccess.dir_exists_absolute(CACHE_DIR):
		if DirAccess.make_dir_recursive_absolute(CACHE_DIR) != OK:
			return false
	var f := FileAccess.open(cache_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({
		"cache_version": CACHE_VERSION,
		"fingerprint": _fingerprint(),
		"source": src,
		"source_md5": src_md5,
		"ast": ast,
	}))
	f.close()
	return true


## Identifies the code that produced a cached AST, so an entry written by an
## older parser is never reused. The parser's source MD5 is the honest answer
## and needs no discipline to maintain, but a .gd file is compiled away in an
## exported build and may not be present to hash -- hence the CACHE_VERSION
## fallback, which does need a manual bump if the parser ever changes in a way
## that must invalidate exported installs.
static func _fingerprint() -> String:
	if _fingerprint_cached != "":
		return _fingerprint_cached
	var parser_md5 := FileAccess.get_md5("res://scripts/engine/wdl_parser.gd")
	if parser_md5 == "":
		parser_md5 = "unhashable"
	_fingerprint_cached = "v%d/%s" % [CACHE_VERSION, parser_md5]
	return _fingerprint_cached


static func _build_index() -> void:
	if _index_built:
		return
	_index_built = true
	for dir_path in SRC_DIRS:
		for f in _list_wdl(dir_path):
			_index[f.get_file().get_basename().to_lower()] = f


static func _list_wdl(dir_path: String) -> Array:
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
