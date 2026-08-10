extends SceneTree
## Reported live (2026-08-10): "the background has the same weird cloud
## pattern in all of the area... in all of the game's levels." Root cause:
## sky.png (99.9% alpha=0, a handful of white star-dot pixels) and clds.png
## (~85% opaque near-black pixels) were composited into the sky panorama
## with their own alpha left mostly meaningless -- PanoramaSkyMaterial
## reads a panorama's RGB directly and has no notion of alpha at all, so
## the transparent regions rendered as solid opaque BLACK. Fixed in
## AcknexSky._make_sky_panorama() by compositing both layers onto a real
## opaque blue-sky base first. This is a shared helper used by every
## level's sky (assets/converted/wdl_meta.json "defaults"), so one check
## against the default sky.png/clds.png covers all of them.
##
## Run: godot --headless --path . -s res://tools/smoke_sky_panorama_check.gd

func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var sky: Object = load("res://scripts/engine/acknex_sky.gd").new()
	var sky_img: Image = sky.call("_tex_image", sky.call("_load_tex", "sky.png"))
	var cloud_tex: Texture2D = sky.call("_load_tex", "clds.png")
	if sky_img == null or cloud_tex == null:
		print("FAIL: could not load sky.png / clds.png")
		quit(1)
		return

	var pano: Image = sky.call("_make_sky_panorama", sky_img, cloud_tex)
	var w := pano.get_width()
	var h := pano.get_height()
	var total := w * h
	var black := 0
	var sum := Color(0, 0, 0)
	for y in h:
		for x in w:
			var c := pano.get_pixel(x, y)
			sum += c
			if c.r < 0.02 and c.g < 0.02 and c.b < 0.02:
				black += 1
	var avg := sum / total
	var black_pct := 100.0 * black / total
	print("black=%.2f%% avg=%s" % [black_pct, avg])

	# Previously ~90%+ of the dome rendered solid black; a real sky should
	# have next to none, and the average color should read as a plausible
	# blue sky, not near-zero-brightness.
	var ok: bool = black_pct < 5.0 and avg.r > 0.1 and avg.g > 0.1 and avg.b > 0.1
	print("OK" if ok else "FAIL")
	quit(0 if ok else 1)
