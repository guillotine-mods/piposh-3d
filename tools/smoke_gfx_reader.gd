extends SceneTree
## Oracle test for the runtime GFX reader.
##
## `scripts/engine/gfx_bitmap.gd` must reproduce `tools/convert_gfx.py` EXACTLY.
## The Python pipeline's committed output is the ground truth: for every source
## bitmap, decode it with the GDScript reader and compare pixel-for-pixel with
## the PNG the converter produced. Any mismatch is a bug in the reader.
##
## The reference PNGs are read with `load_png_from_buffer` on the raw file bytes,
## NOT through `load()`/ResourceLoader — importing them would apply Godot's VRAM
## compression and silently corrupt the comparison. That exact confusion is
## GB-19 in docs/BUGS.md.
##
##   godot --path . --headless -s res://tools/smoke_gfx_reader.gd
##   godot --path . --headless -s res://tools/smoke_gfx_reader.gd -- --limit 40

const GfxBitmap = preload("res://scripts/engine/gfx_bitmap.gd")

const SRC_DIR := "res://original/piposh3d/GFX"
const REF_DIR := "res://assets/converted/gfx"


func _init() -> void:
	var limit := 0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--limit"):
			var parts := a.split("=")
			limit = int(parts[1]) if parts.size() > 1 else 0

	var dir := DirAccess.open(SRC_DIR)
	if dir == null:
		push_error("cannot open %s" % SRC_DIR)
		quit(2)
		return

	var names: Array[String] = []
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		var e := n.get_extension().to_lower()
		if not dir.current_is_dir() and (e == "pcx" or e == "bmp"):
			names.append(n)
		n = dir.get_next()
	dir.list_dir_end()
	names.sort()

	# `convert_gfx.py` writes every source to `<stem>.png`, so when a stem exists
	# as BOTH .bmp and .pcx one silently overwrites the other and the reference
	# PNG corresponds to only one of them. Which one wins depends on ASCII case
	# ordering, so it is not knowable per-file here. Those stems are decoded and
	# timed, but excluded from the pixel comparison and reported separately —
	# comparing against the other format's output would be a false failure.
	var stem_count := {}
	for fname in names:
		var s := fname.get_basename().to_lower()
		stem_count[s] = int(stem_count.get(s, 0)) + 1

	if limit > 0:
		names = names.slice(0, limit)

	var exact := 0
	var mismatch := 0
	var no_ref := 0
	var failed := 0
	var ambiguous := 0
	var agreed_reject := 0
	var pixels := 0
	var fail_detail: Array[String] = []
	var mism_detail: Array[String] = []
	var ambig_detail: Array[String] = []
	var reject_detail: Array[String] = []

	var t0 := Time.get_ticks_usec()
	var decode_usec := 0

	for fname in names:
		var src := "%s/%s" % [SRC_DIR, fname]
		var d0 := Time.get_ticks_usec()
		var img := GfxBitmap.load_gfx(src)
		decode_usec += Time.get_ticks_usec() - d0

		if img == null:
			# Refusing a file the oracle also refused is AGREEMENT, not a defect:
			# convert_gfx.py writes no PNG for sources it cannot read (stat0.pcx
			# is 92 bytes and is not a PCX at all). Only count it against us when
			# Python succeeded and we did not.
			if FileAccess.file_exists("%s/%s.png" % [REF_DIR, fname.get_basename()]):
				failed += 1
				if fail_detail.size() < 12:
					fail_detail.append("%s -> %s" % [fname, GfxBitmap.last_error])
			else:
				agreed_reject += 1
				if reject_detail.size() < 12:
					reject_detail.append("%s (%s)" % [fname, GfxBitmap.last_error])
			continue

		pixels += img.get_width() * img.get_height()

		if int(stem_count.get(fname.get_basename().to_lower(), 1)) > 1:
			ambiguous += 1
			if ambig_detail.size() < 20:
				ambig_detail.append(fname)
			continue

		var ref_path := "%s/%s.png" % [REF_DIR, fname.get_basename()]
		var rf := FileAccess.open(ref_path, FileAccess.READ)
		if rf == null:
			no_ref += 1
			continue
		var ref_img := Image.new()
		var err := ref_img.load_png_from_buffer(rf.get_buffer(rf.get_length()))
		rf.close()
		if err != OK:
			no_ref += 1
			continue
		if ref_img.get_format() != Image.FORMAT_RGBA8:
			ref_img.convert(Image.FORMAT_RGBA8)

		if ref_img.get_width() != img.get_width() or ref_img.get_height() != img.get_height():
			mismatch += 1
			if mism_detail.size() < 12:
				mism_detail.append("%s: size %dx%d vs ref %dx%d" % [
					fname, img.get_width(), img.get_height(),
					ref_img.get_width(), ref_img.get_height()])
			continue

		var a := img.get_data()
		var b := ref_img.get_data()
		if a == b:
			exact += 1
		else:
			mismatch += 1
			var diff := 0
			var first := -1
			var i := 0
			while i < a.size():
				if a[i] != b[i]:
					diff += 1
					if first < 0:
						first = i
				i += 1
			if mism_detail.size() < 12:
				mism_detail.append("%s: %d/%d bytes differ, first at %d (got %d want %d)" % [
					fname, diff, a.size(), first, a[first], b[first]])

	var total_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var dec_ms := decode_usec / 1000.0

	print("")
	print("=== GFX runtime reader vs Python oracle ===")
	print("files            : %d" % names.size())
	print("PIXEL-EXACT      : %d" % exact)
	print("mismatched       : %d" % mismatch)
	print("decode failed    : %d  (Python produced a PNG and we did not)" % failed)
	print("agreed reject    : %d  (Python could not read it either)" % agreed_reject)
	print("no reference PNG : %d" % no_ref)
	print("ambiguous ref    : %d  (stem exists as both .bmp and .pcx —" % ambiguous)
	print("                      convert_gfx.py overwrites one with the other)")
	print("")
	print("pixels decoded   : %s" % _commas(pixels))
	print("decode time      : %.1f ms  (%.2f Mpx/s)" % [
		dec_ms, (pixels / 1000000.0) / maxf(dec_ms / 1000.0, 0.000001)])
	print("total incl verify: %.1f ms" % total_ms)
	for m in mism_detail:
		print("  MISMATCH %s" % m)
	for m in fail_detail:
		print("  FAIL     %s" % m)
	for m in reject_detail:
		print("  agreed   %s" % m)

	var bad := mismatch + failed
	print("")
	print("smoke_gfx_reader: %s" % ("PASS" if bad == 0 else "%d problem(s)" % bad))
	quit(0 if bad == 0 else 1)


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
