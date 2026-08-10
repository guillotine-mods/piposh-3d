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
