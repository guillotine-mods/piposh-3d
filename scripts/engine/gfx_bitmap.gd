extends RefCounted
## Runtime reader for the original A5 GFX bitmaps (PCX / BMP).
##
## This is the GDScript counterpart of `tools/convert_gfx.py`, and the first
## step of moving conversion out of the offline Python pipeline and into the
## game itself (the "read the original files" model already used by the
## Director player). It reads `original/piposh3d/GFX/*.pcx|*.bmp` and returns a
## Godot `Image` directly — no intermediate PNG, no `.import` sidecar.
##
## Deliberately NO `class_name`: a global class inside a mounted `.pck` never
## resolves (see commit 5c0adfa). Use it via `const GfxBitmap = preload(...)`.
##
## Corpus measurement (2026-08-10) over the 456 PCX files actually shipped —
## the reader handles exactly what is present, and refuses anything else rather
## than guessing:
##   * 438 files: version 5, RLE, 8 bits/plane, 3 planes  -> 24-bit truecolour
##   *  17 files: version 5, RLE, 8 bits/plane, 1 plane   -> paletted, 768-byte
##                trailing palette introduced by a 0x0C marker
##   *  86 further files are .bmp, handled by Godot's built-in BMP loader
##
## `bytes_per_line` is used EXACTLY as declared. The PCX spec requires an even
## stride, but this corpus violates it (cross.pcx=15, Opt1.pcx=593, glf1-3=431,
## Pause=167 ...). Rounding the stride up to even silently shears those images.

## Bitmaps drawn by a panel WITHOUT the `overlay` flag: they must render opaque,
## black background included. Every other bitmap gets pure black color-keyed to
## transparent, matching Acknex `overlay` semantics.
##
## This set is a corpus measurement copied verbatim from `tools/convert_gfx.py`
## (regenerate with `tools/gen_overlay_bmap_list.py`), NOT a judgement call:
## every `panel NAME { ... }` block in every original .wdl was parsed for its
## bmap and whether `overlay` appears in its flags. No filename appeared both
## ways, so the split is unambiguous.
const NON_OVERLAY_BMAPS := {
	"2min": true, "a5": true, "ami": true, "credits": true, "cube": true,
	"fin": true, "fatass1": true, "fight": true, "gir1": true, "glf1": true,
	"lastlev": true, "loading01": true, "loading02": true, "loading03": true,
	"loading04": true, "loading05": true, "loading06": true, "loading07": true,
	"loading08": true, "loading09": true, "loading10": true, "loading11": true,
	"loading12": true, "loading13": true, "loading14": true, "loading15": true,
	"loading16": true, "loading17": true, "loading18": true, "loading19": true,
	"loading20": true, "loading21": true, "loading22": true, "loading23": true,
	"mov1": true, "n2": true, "nvision": true, "nomap": true, "nosave": true,
	"piposh1": true, "save": true, "shkufit": true, "shkufit1": true,
	"skuf": true, "someover": true, "somewher": true, "stage": true,
	"wart1": true, "zimimbk": true, "afri1": true, "afri2": true,
	"icn_vol1": true, "icn_vol2": true, "icn_vol3": true, "icn_vol4": true,
	"icn_vol5": true, "mod1": true, "mod2": true, "pigs": true,
	"temple": true, "txt1": true, "txt7": true,
}

## Last error, set when a load_* call returns null.
static var last_error: String = ""


# ---------------------------------------------------------------------------
# The single texture seam (0-py migration)
# ---------------------------------------------------------------------------

## Offline pipeline output — `tools/convert_gfx.py` writes every source here as
## `<stem>.png`.
const CONVERTED_DIR := "res://assets/converted/gfx/"
## The original game data, read byte-for-byte by `load_gfx()` on the runtime
## path. Same directory the byte-level oracle (tools/smoke_gfx_reader.gd) reads.
const SRC_DIR := "res://original/piposh3d/GFX/"

## FEATURE FLAG — DEFAULTS OFF.
##
## false (default): `get_texture()` loads `assets/converted/gfx/<stem>.png`,
## i.e. the offline Python pipeline's committed output. Behaviour is exactly
## what it has always been; none of the runtime-decode code is reached.
##
## true: the same texture is produced in-engine by `load_gfx()` straight out of
## `original/piposh3d/GFX/*.pcx|*.bmp` — no PNG, no `.import` sidecar.
## `load_gfx()` is already proven pixel-identical to `tools/convert_gfx.py`
## (tools/smoke_gfx_reader.gd: 507 pixel-exact, 0 mismatched); what this flag
## adds is the *engine* question — does a call site fed by the reader get the
## same texture as one fed by the PNG — which tools/smoke_gfx_integration.gd
## answers.
##
## Mirrors `wmb_level_loader.gd`'s own `USE_RUNTIME_WMB` seam: produce the
## resource two ways, then run the identical shared tail.
const USE_RUNTIME_GFX := false
## Process-wide override of the const above, so both paths can be exercised in
## one process. Nothing in the game writes this; it defaults to the const, which
## is false. `tools/smoke_gfx_integration.gd` does not write it either — it calls
## `get_texture_from()` with an explicit flag instead.
static var use_runtime_gfx: bool = USE_RUNTIME_GFX

## Which source extension the runtime resolver picks for a stem that exists as
## BOTH `.bmp` and `.pcx` in `original/piposh3d/GFX` (NB-7 in docs/BUGS.md:
## `convert_gfx.py` writes both to the same `<stem>.png`, so one silently
## overwrites the other). This table exists so the choice is DELIBERATE rather
## than a side effect of filename sort order.
##
## It is a corpus measurement, not a guess. Every `.wdl` under
## `original/piposh3d` (top level + `WDL/`, excluding the stale `_backup_wdl/`
## copies) was scanned for `bmap` declarations — the corpus uses four spellings,
## `bmap N = <f.ext>;`, `BMAP N = (<f.ext>,x,y,w,h);`, `BMAP N, <f.ext>;` and
## `BMAP N <f.ext>,...;` — and the declared filename ALWAYS carries an explicit
## extension (549 file-referencing declarations: 496 `.pcx`, 53 `.bmp`, 0
## anything else). For each colliding stem, the extension the original engine
## actually loaded is therefore directly readable out of the source:
##
##   * 10 stems are declared ONLY as .pcx  — asybar1, asybar2, asypnl, caseoff,
##     caseon, large, pass, pnl1, pnl2, vs (AsyAct1/2/3.wdl, Range.wdl,
##     Fight.wdl).
##   *  1 stem is declared ONLY as .bmp    — pokrpnl1 (Cardgame.wdl:3,
##     `bmap bPoker1 = <PokrPNL1.bmp>;`). This is the ONE stem where the
##     original engine and today's converter genuinely disagree: the converter
##     kept `PokrPNL1.PCX` (350x250) and threw away `PokrPNL1.bmp` (57x250).
##   *  3 stems are declared BOTH ways, with genuinely different images —
##     credits (Credits.wdl:8 `<Credits.bmp>` 320x480 vs VilEnd.wdl:25
##     `<credits.pcx>` 640x750), drop (Mount/Olympic/Temple `<drop.bmp>`, a
##     70-byte 2x2 "no visible raindrop" stub, vs Mansion.wdl / WDL/Weather.wdl
##     `<drop.pcx>` 40x40) and sky (IO.wdl:130 + WDL/IO.wdl:94 `<sky.bmp>`
##     320x320 vs WDL/Weather.wdl:57 `<sky.pcx>` 256x256). For these there is no
##     correct per-STEM answer — only a correct per-CALL-SITE one, which is why
##     `_resolve_source_path()` honours an explicitly-named extension verbatim
##     before ever consulting this table. The value here is only the fallback
##     for a caller that supplies no extension (e.g. `AcknexSky` asks for
##     "sky.png", because `wdl_meta.json`'s static extraction already dropped
##     the extension); it keeps today's converted-PNG behaviour so a bare-stem
##     lookup changes nothing.
##   *  3 stems are declared NEITHER way — clouds, panel, star. No WDL evidence
##     exists (they are level/WMB textures or leftover art), so these also keep
##     today's converted-PNG behaviour.
##
## "Today's converted-PNG behaviour" was measured, not assumed: all 17 committed
## `<stem>.png` files were compared pixel-for-pixel against both of their
## sources, and the .PCX variant is what survived in every one of the 17 (on
## Windows, `pathlib` sorts case-insensitively, so `.bmp` always precedes `.pcx`
## and the .pcx write always lands last). NB-7's own example — "CLOUDS.PCX loses
## to Clouds.bmp" — is what pure ASCII ordering would do; it is not what the
## committed files actually contain. Five of the 17 (asybar1, asybar2, asypnl,
## pass, star) are byte-identical between the two formats anyway.
const COLLIDING_STEM_EXT := {
	# Declared only as .pcx by the WDL corpus (== today's converter output).
	"asybar1": "pcx", "asybar2": "pcx", "asypnl": "pcx",
	"caseoff": "pcx", "caseon": "pcx", "large": "pcx", "pass": "pcx",
	"pnl1": "pcx", "pnl2": "pcx", "vs": "pcx",
	# Declared only as .bmp by the WDL corpus. DIFFERS from today's converter,
	# deliberately — Cardgame.wdl names PokrPNL1.bmp and nothing names the .PCX.
	"pokrpnl1": "bmp",
	# Declared BOTH ways — fallback only; an explicit extension wins first.
	"credits": "pcx", "drop": "pcx", "sky": "pcx",
	# Declared neither way — no evidence, keep the converter's choice.
	"clouds": "pcx", "panel": "pcx", "star": "pcx",
}

## Decoding a PCX in GDScript runs at roughly 3.4 Mpx/s, so re-decoding the same
## bitmap on every request (a HUD panel rebuild, a per-frame `_load_tex`) would
## be catastrophic. Keyed by path+flag; a null result is cached too, so a missing
## file is not re-probed on every call either.
static var _tex_cache: Dictionary = {}
## lowercased stem -> {"pcx": "res://...", "bmp": "res://..."}, with each file's
## real on-disk casing. The corpus mixes `.pcx`/`.PCX` and `.bmp`/`.BMP` (and
## `CaseOff.bmp` vs `caseoff.pcx` on the stem too), so a direct-path probe on a
## case-INsensitive filesystem happily opens the wrong casing and makes Godot log
## "Case mismatch opening requested file". The listing gives the real name.
static var _src_index: Dictionary = {}
static var _src_index_built := false
## lowercased filename -> "res://assets/converted/gfx/<real name>". Same reason,
## for the converted side (`Con_Load.png`, `SHKUFIT.png`, ...).
static var _png_index: Dictionary = {}
static var _png_index_built := false


## THE SEAM. Every GFX texture the engine draws should come through here.
##
## `name` is whatever the call site has: a converted PNG name ("A5.png"), a bare
## stem, or a real WDL-declared filename with its original extension
## ("Horizon1.pcx", "sky.bmp" — this is what `WdlInterpreter._bmaps` holds and
## what `LevelRunner._live_bmap_file()` hands to `AcknexSky`). All three resolve
## on both sides of the flag.
static func get_texture(name: String) -> Texture2D:
	return get_texture_from(name, use_runtime_gfx)


## Same resolver with the flag supplied explicitly, so one process can build
## both and compare them (tools/smoke_gfx_integration.gd). The game never calls
## this; `get_texture()` is the real entry point.
static func get_texture_from(name: String, runtime: bool) -> Texture2D:
	if name == "":
		return null
	var key := ("r|" if runtime else "c|") + name.to_lower()
	if _tex_cache.has(key):
		var cached: Texture2D = _tex_cache[key]
		return cached
	var tex: Texture2D = null
	if runtime:
		var src := resolve_source_path(name)
		if src != "":
			var img := load_gfx(src)
			if img != null:
				tex = ImageTexture.create_from_image(img)
	else:
		var png := resolve_converted_path(name)
		if png != "":
			tex = load(png) as Texture2D
	_tex_cache[key] = tex
	return tex


## FLAG FALSE side: the converted PNG under `assets/converted/gfx/`.
##
## The candidate list is the union of what the four call sites used to do
## individually (exact name; lowercased; basename + ".png" when the caller named
## a non-PNG extension; then a cached case-insensitive directory listing), so
## routing them all through one resolver cannot make anything that resolved
## before stop resolving.
static func resolve_converted_path(name: String) -> String:
	var cands: Array[String] = [name, name.to_lower()]
	if name.get_extension().to_lower() != "png":
		cands.append(name.get_basename() + ".png")
		cands.append(name.get_basename().to_lower() + ".png")
	for c in cands:
		var p: String = CONVERTED_DIR + c
		if ResourceLoader.exists(p):
			return p
	# Packed Android builds cannot reliably DirAccess-list res:// (CONTRACT §6),
	# hence the direct probes above first; this is the desktop fallback.
	_ensure_png_index()
	for c in cands:
		var hit: String = str(_png_index.get(c.to_lower(), ""))
		if hit != "":
			return hit
	return ""


## FLAG TRUE side: the original .pcx/.bmp under `original/piposh3d/GFX/`.
##
## An extension the caller actually named wins outright — a WDL `bmap`
## declaration names the extension explicitly, so when that filename reaches us
## it IS the original engine's own answer and no table can improve on it. Only a
## caller with no extension (or a `.png` one, i.e. a converted name) falls
## through to `COLLIDING_STEM_EXT`.
static func resolve_source_path(name: String) -> String:
	if name == "":
		return ""
	_ensure_src_index()
	var stem := name.get_file().get_basename().to_lower()
	var entry: Dictionary = _src_index.get(stem, {})
	if entry.is_empty():
		return ""
	var ext := name.get_extension().to_lower()
	if (ext == "pcx" or ext == "bmp") and entry.has(ext):
		return str(entry[ext])
	var want: String = str(COLLIDING_STEM_EXT.get(stem, ""))
	if want != "" and entry.has(want):
		return str(entry[want])
	if entry.has("pcx"):
		return str(entry["pcx"])
	if entry.has("bmp"):
		return str(entry["bmp"])
	return ""


static func _ensure_src_index() -> void:
	if _src_index_built:
		return
	_src_index_built = true
	var dir := DirAccess.open(SRC_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir():
			var e := fn.get_extension().to_lower()
			if e == "pcx" or e == "bmp":
				var stem := fn.get_basename().to_lower()
				var entry: Dictionary = _src_index.get(stem, {})
				entry[e] = SRC_DIR + fn
				_src_index[stem] = entry
		fn = dir.get_next()
	dir.list_dir_end()


static func _ensure_png_index() -> void:
	if _png_index_built:
		return
	_png_index_built = true
	var dir := DirAccess.open(CONVERTED_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir() and fn.get_extension().to_lower() == "png":
			_png_index[fn.to_lower()] = CONVERTED_DIR + fn
		fn = dir.get_next()
	dir.list_dir_end()


## Load a GFX bitmap by absolute/res path, applying the same overlay colour-key
## rule as the offline converter. Returns null and sets `last_error` on failure.
static func load_gfx(path: String) -> Image:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		last_error = "cannot open %s (err %d)" % [path, FileAccess.get_open_error()]
		return null
	var data := f.get_buffer(f.get_length())
	f.close()

	var stem := path.get_file().get_basename().to_lower()
	var ext := path.get_extension().to_lower()

	var img: Image
	if ext == "pcx":
		img = decode_pcx(data)
	elif ext == "bmp":
		img = Image.new()
		if img.load_bmp_from_buffer(data) != OK:
			last_error = "%s: Godot BMP loader rejected the buffer" % path.get_file()
			return null
	else:
		last_error = "%s: unsupported extension '%s'" % [path.get_file(), ext]
		return null

	if img == null:
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if not NON_OVERLAY_BMAPS.has(stem):
		_color_key_black(img)
	return img


## Decode a PCX buffer to an RGBA8 Image. Returns null and sets `last_error`
## for anything this corpus does not actually contain.
static func decode_pcx(data: PackedByteArray) -> Image:
	if data.size() < 128:
		last_error = "PCX too small (%d bytes)" % data.size()
		return null
	if data[0] != 0x0A:
		last_error = "not a PCX: magic 0x%02X" % data[0]
		return null

	var encoding := data[2]
	var bpp := data[3]
	var xmin := data.decode_u16(4)
	var ymin := data.decode_u16(6)
	var xmax := data.decode_u16(8)
	var ymax := data.decode_u16(10)
	var planes := data[65]
	var bpl := data.decode_u16(66)          # per plane, used AS DECLARED

	if encoding != 1:
		last_error = "PCX encoding %d unsupported (only RLE=1 is present)" % encoding
		return null
	if bpp != 8 or (planes != 1 and planes != 3):
		last_error = "PCX bpp=%d planes=%d unsupported" % [bpp, planes]
		return null

	var w := int(xmax) - int(xmin) + 1
	var h := int(ymax) - int(ymin) + 1
	if w <= 0 or h <= 0 or bpl <= 0:
		last_error = "PCX bad geometry %dx%d bpl=%d" % [w, h, bpl]
		return null

	var row_bytes := bpl * planes
	var scanlines := _rle_decode(data, 128, row_bytes * h)
	if scanlines.is_empty():
		last_error = "PCX RLE stream ended early"
		return null

	var out := PackedByteArray()
	out.resize(w * h * 4)

	if planes == 3:
		for y in h:
			var base := y * row_bytes
			var o := y * w * 4
			for x in w:
				out[o] = scanlines[base + x]                 # R plane
				out[o + 1] = scanlines[base + bpl + x]       # G plane
				out[o + 2] = scanlines[base + bpl * 2 + x]   # B plane
				out[o + 3] = 255
				o += 4
	else:
		var pal := _pcx_palette(data)
		if pal.is_empty():
			last_error = "PCX 8-bit paletted but no trailing 0x0C palette"
			return null
		for y in h:
			var base := y * row_bytes
			var o := y * w * 4
			for x in w:
				var idx := int(scanlines[base + x]) * 3
				out[o] = pal[idx]
				out[o + 1] = pal[idx + 1]
				out[o + 2] = pal[idx + 2]
				out[o + 3] = 255
				o += 4

	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, out)


## PCX run-length decoder. Stops once `expected` bytes are produced; a stream
## that ends early yields an empty array rather than a half-built image.
static func _rle_decode(data: PackedByteArray, start: int, expected: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(expected)
	var n := data.size()
	var i := start
	var o := 0
	while o < expected and i < n:
		var b := data[i]
		i += 1
		if (b & 0xC0) == 0xC0:
			var count := b & 0x3F
			if i >= n:
				break
			var value := data[i]
			i += 1
			var end := mini(o + count, expected)
			while o < end:
				out[o] = value
				o += 1
		else:
			out[o] = b
			o += 1
	if o < expected:
		return PackedByteArray()
	return out


## The 256-colour palette is the last 769 bytes, introduced by a 0x0C marker.
static func _pcx_palette(data: PackedByteArray) -> PackedByteArray:
	var n := data.size()
	if n < 769 or data[n - 769] != 0x0C:
		return PackedByteArray()
	return data.slice(n - 768, n)


## Acknex `overlay`: pure black becomes fully transparent.
static func _color_key_black(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var d := img.get_data()
	var i := 0
	var total := w * h * 4
	while i < total:
		if d[i] == 0 and d[i + 1] == 0 and d[i + 2] == 0:
			d[i + 3] = 0
		i += 4
	# Rebuild rather than set_pixel per pixel — one C++ call instead of w*h.
	var rebuilt := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, d)
	img.copy_from(rebuilt)
