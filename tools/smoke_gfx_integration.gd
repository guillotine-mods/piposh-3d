extends SceneTree
## Engine-level oracle for the runtime GFX reader wired into the five call sites.
##
## This asks a DIFFERENT question from tools/smoke_gfx_reader.gd. That one proves
## `reader == Python` at the pixel level (507 exact, 0 mismatched): the bytes
## coming out of `GfxBitmap.load_gfx()` are identical to what
## `tools/convert_gfx.py` wrote to `assets/converted/gfx/`. It says nothing about
## what the ENGINE then asks for, or which of two same-stem source files a
## request resolves to.
##
## This one proves `engine-fed-by-reader == engine-fed-by-PNG` for exactly the
## names the engine really requests. Every bitmap is resolved TWICE through the
## one seam -- `GfxBitmap.get_texture_from(name, false)` (converted PNG, what
## ships today) and `GfxBitmap.get_texture_from(name, true)` (original PCX/BMP
## decoded in-engine) -- and the two textures are compared by dimensions and
## pixel data.
##
## The request set is not invented here; it is the union of
##   * every literal GFX filename in the five call sites that were routed
##     through the seam (scenes/boot.gd, scenes/main_menu.gd,
##     scripts/ui/game_hud.gd, scripts/engine/acknex_sky.gd), and
##   * every `sky_map` / `cloud_map` / `scene_map` value in
##     `assets/converted/wdl_meta.json` (defaults + every level), which is
##     literally what `AcknexSky.apply()` reads.
## `AcknexSky` can also be handed a LIVE bmap filename at runtime
## (`LevelRunner._live_bmap_file()` -> `WdlInterpreter._bmaps`, e.g.
## "Horizon1.pcx" / "sky.bmp"); those carry an explicit extension, so a second
## section below exercises that shape directly on the 17 colliding stems.
##
## Three verdicts are reported separately, because they are three different
## things:
##   MATCH        - byte-identical RGBA8.
##   ALPHA-BORDER - the alpha channel is identical everywhere and the RGB is
##                  identical on every pixel that is not fully transparent; only
##                  the RGB hidden UNDER alpha=0 differs. That is Godot's own
##                  texture importer (`process/fix_alpha_border=true` in every
##                  assets/converted/gfx/*.png.import), which bleeds edge colour
##                  into transparent texels so bilinear filtering does not pull
##                  black in. It is a property of the PNG import step, not of the
##                  reader, and it is invisible on screen.
##   EXT-CHOICE   - the two paths deliberately resolved DIFFERENT source files,
##                  because `GfxBitmap.COLLIDING_STEM_EXT` picked the extension
##                  the original `.wdl` `bmap` declarations name instead of the
##                  one `convert_gfx.py` happened to write last (NB-7).
##   MISMATCH     - anything else. A real defect.
##
##   godot --path . --headless -s res://tools/smoke_gfx_integration.gd

const GfxBitmap = preload("res://scripts/engine/gfx_bitmap.gd")

const META_PATH := "res://assets/converted/wdl_meta.json"

## Literal GFX names requested by the five routed call sites.
const CALL_SITE_NAMES := [
	# scenes/boot.gd
	"A5.png",
	# scenes/main_menu.gd
	"mainmsg.png", "ShowMov1.png", "ShowMov2.png", "ShowMov3.png",
	# scripts/ui/game_hud.gd
	"SHKUFIT.png", "BIO.png", "cursor1.png", "Steel.png", "Opt1.png", "Opt2.png",
]

## The 17 stems that exist as both .bmp and .pcx (NB-7). Exercised twice: once as
## the bare converted name a static call site uses, once as each of the two real
## WDL-declared filenames a live `bmap` value would carry.
const COLLIDING_STEMS := [
	"AsyBar1", "AsyBar2", "AsyPNL", "CaseOff", "CaseOn", "Clouds", "Credits",
	"Drop", "Large", "Panel", "pass", "PNL1", "PNL2", "PokrPNL1", "sky",
	"Star", "VS",
]


func _init() -> void:
	print("")
	print("=== engine texture: runtime GFX reader vs converted PNG ===")
	print("flag default: GfxBitmap.USE_RUNTIME_GFX = %s" % GfxBitmap.USE_RUNTIME_GFX)

	var names := _requested_names()
	print("bitmaps the engine actually requests: %d" % names.size())

	var totals := {"match": 0, "alpha": 0, "ext": 0, "bad": 0, "missing": 0}
	var rows: Array[String] = []
	print("")
	print("--- requested by the engine ---")
	for n in names:
		rows.append(_check(str(n), totals))
	for r in rows:
		print(r)

	# The colliding stems, resolved the way a static call site asks (bare name,
	# no extension evidence) -- this is where COLLIDING_STEM_EXT actually decides.
	var ctotals := {"match": 0, "alpha": 0, "ext": 0, "bad": 0, "missing": 0}
	var crows: Array[String] = []
	print("")
	print("--- the 17 .bmp/.pcx colliding stems, asked for as '<Stem>.png' ---")
	for s in COLLIDING_STEMS:
		crows.append(_check("%s.png" % s, ctotals))
	for r in crows:
		print(r)

	# The same stems asked for the way a LIVE WDL `bmap` value arrives: with the
	# original declared extension. The seam must honour it verbatim, so the
	# runtime path must land on exactly that file every time.
	print("")
	print("--- explicit-extension requests (live `bmap` shape) ---")
	var verbatim_ok := 0
	var verbatim_bad := 0
	for s in COLLIDING_STEMS:
		for ext in ["pcx", "bmp"]:
			var req := "%s.%s" % [s, ext]
			var got := GfxBitmap.resolve_source_path(req)
			if got == "":
				continue
			if got.get_extension().to_lower() == ext:
				verbatim_ok += 1
			else:
				verbatim_bad += 1
				print("  VERBATIM FAIL %s -> %s" % [req, got])
	print("  explicit extension honoured: %d/%d" % [verbatim_ok, verbatim_ok + verbatim_bad])

	# Requirement: the runtime path must never re-decode. PCX decoding in GDScript
	# runs at ~3.1 Mpx/s (tools/smoke_gfx_reader.gd), so a per-frame `_load_tex`
	# without a cache would be catastrophic. Re-request the whole engine set on
	# the runtime path and time it -- every one of these is already in
	# `GfxBitmap._tex_cache`, so it must cost essentially nothing.
	print("")
	print("--- cache ---")
	var t0 := Time.get_ticks_usec()
	var px := 0
	var reps := 20
	for _r in reps:
		for n in names:
			var t := GfxBitmap.get_texture_from(str(n), true)
			if t != null:
				px += t.get_width() * t.get_height()
	var cached_ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("  %d cached runtime lookups (%s px worth): %.2f ms total, %.4f ms each"
		% [reps * names.size(), _commas(px), cached_ms,
		cached_ms / maxf(float(reps * names.size()), 1.0)])

	print("")
	print("=== summary ===")
	print("engine-requested   : %d compared" % names.size())
	print("  MATCH            : %d" % totals["match"])
	print("  ALPHA-BORDER only: %d  (Godot import process/fix_alpha_border, RGB under alpha=0)" % totals["alpha"])
	print("  EXT-CHOICE       : %d  (deliberate .bmp/.pcx pick, NB-7)" % totals["ext"])
	print("  MISMATCH         : %d" % totals["bad"])
	print("  unresolved       : %d" % totals["missing"])
	print("colliding stems    : %d compared" % COLLIDING_STEMS.size())
	print("  MATCH            : %d" % ctotals["match"])
	print("  ALPHA-BORDER only: %d" % ctotals["alpha"])
	print("  EXT-CHOICE       : %d" % ctotals["ext"])
	print("  MISMATCH         : %d" % ctotals["bad"])
	print("  unresolved       : %d" % ctotals["missing"])

	var bad: int = int(totals["bad"]) + int(ctotals["bad"]) + int(totals["missing"]) + verbatim_bad
	print("")
	print("smoke_gfx_integration: %s" % ("PASS" if bad == 0 else "%d problem(s)" % bad))
	quit(0 if bad == 0 else 1)


## Every name the engine can ask the seam for: the five call sites' literals plus
## every map filename in wdl_meta.json.
func _requested_names() -> Array[String]:
	var seen := {}
	var out: Array[String] = []
	for n in CALL_SITE_NAMES:
		var s: String = str(n)
		if not seen.has(s.to_lower()):
			seen[s.to_lower()] = true
			out.append(s)
	var f := FileAccess.open(META_PATH, FileAccess.READ)
	if f != null:
		var data: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(data) == TYPE_DICTIONARY:
			var meta: Dictionary = data
			var blocks: Array = [meta.get("defaults", {})]
			var levels: Dictionary = meta.get("levels", {})
			for k in levels.keys():
				blocks.append(levels[k])
			for b in blocks:
				if typeof(b) != TYPE_DICTIONARY:
					continue
				var d: Dictionary = b
				for field in ["sky_map", "cloud_map", "scene_map"]:
					var v: String = str(d.get(field, ""))
					if v == "" or seen.has(v.to_lower()):
						continue
					seen[v.to_lower()] = true
					out.append(v)
	out.sort()
	return out


func _check(name: String, totals: Dictionary) -> String:
	var png_path := GfxBitmap.resolve_converted_path(name)
	var src_path := GfxBitmap.resolve_source_path(name)
	var a := GfxBitmap.get_texture_from(name, false)
	var b := GfxBitmap.get_texture_from(name, true)

	if a == null or b == null:
		totals["missing"] = int(totals["missing"]) + 1
		return "  UNRESOLVED %-16s png=%s src=%s" % [
			name, "yes" if a != null else "NO", "yes" if b != null else "NO"]

	var ia := _rgba(a)
	var ib := _rgba(b)
	var tail := "%s vs %s" % [png_path.get_file(), src_path.get_file()]

	if ia.get_width() != ib.get_width() or ia.get_height() != ib.get_height():
		# A size change on a colliding stem is the deliberate extension pick, not
		# a decoding bug -- classify it by whether the two paths really did read
		# different source files.
		if _is_ext_choice(name, png_path, src_path):
			totals["ext"] = int(totals["ext"]) + 1
			return "  EXT-CHOICE %-16s %dx%d -> %dx%d   %s" % [
				name, ia.get_width(), ia.get_height(),
				ib.get_width(), ib.get_height(), tail]
		totals["bad"] = int(totals["bad"]) + 1
		return "  MISMATCH   %-16s size %dx%d vs %dx%d   %s" % [
			name, ia.get_width(), ia.get_height(),
			ib.get_width(), ib.get_height(), tail]

	var da := ia.get_data()
	var db := ib.get_data()
	if da == db:
		totals["match"] = int(totals["match"]) + 1
		return "  MATCH      %-16s %dx%d   %s" % [name, ia.get_width(), ia.get_height(), tail]

	# Split the difference into "under alpha=0" (import artifact) and real.
	var visible_diff := 0
	var hidden_diff := 0
	var alpha_diff := 0
	var first_visible := -1
	var i := 0
	while i < da.size():
		var same_rgb: bool = da[i] == db[i] and da[i + 1] == db[i + 1] and da[i + 2] == db[i + 2]
		if da[i + 3] != db[i + 3]:
			alpha_diff += 1
		if not same_rgb:
			if da[i + 3] == 0 and db[i + 3] == 0:
				hidden_diff += 1
			else:
				visible_diff += 1
				if first_visible < 0:
					first_visible = i
		i += 4

	if _is_ext_choice(name, png_path, src_path):
		totals["ext"] = int(totals["ext"]) + 1
		return "  EXT-CHOICE %-16s same size, different source file   %s" % [name, tail]

	if alpha_diff == 0 and visible_diff == 0:
		totals["alpha"] = int(totals["alpha"]) + 1
		return "  ALPHA-BDR  %-16s %dx%d  %d transparent texel(s) differ in hidden RGB   %s" % [
			name, ia.get_width(), ia.get_height(), hidden_diff, tail]

	totals["bad"] = int(totals["bad"]) + 1
	var px: int = int(first_visible / 4) if first_visible >= 0 else -1
	return ("  MISMATCH   %-16s %dx%d  visible_rgb=%d alpha=%d hidden_rgb=%d"
		+ "  first visible px=%d (png %d,%d,%d,%d vs src %d,%d,%d,%d)   %s") % [
		name, ia.get_width(), ia.get_height(), visible_diff, alpha_diff, hidden_diff, px,
		da[maxi(first_visible, 0)], da[maxi(first_visible, 0) + 1],
		da[maxi(first_visible, 0) + 2], da[maxi(first_visible, 0) + 3],
		db[maxi(first_visible, 0)], db[maxi(first_visible, 0) + 1],
		db[maxi(first_visible, 0) + 2], db[maxi(first_visible, 0) + 3],
		tail]


## True when the two sides genuinely read different files on disk -- i.e. the
## stem collides and the runtime resolver picked the other extension on purpose.
func _is_ext_choice(name: String, png_path: String, src_path: String) -> bool:
	if png_path == "" or src_path == "":
		return false
	var stem := name.get_file().get_basename().to_lower()
	if not GfxBitmap.COLLIDING_STEM_EXT.has(stem):
		return false
	# The converted PNG for a colliding stem is always the .pcx-derived one (see
	# COLLIDING_STEM_EXT's own docstring, measured over all 17). So the two paths
	# differ exactly when the runtime resolver landed on the .bmp.
	return src_path.get_extension().to_lower() == "bmp"


func _commas(v: int) -> String:
	var s := str(v)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out


func _rgba(tex: Texture2D) -> Image:
	var img := tex.get_image()
	if img == null:
		return Image.create(1, 1, false, Image.FORMAT_RGBA8)
	var copy := img.duplicate(true) as Image
	if copy == null:
		copy = img
	if copy.is_compressed():
		copy.decompress()
	if copy.get_format() != Image.FORMAT_RGBA8:
		copy.convert(Image.FORMAT_RGBA8)
	return copy
