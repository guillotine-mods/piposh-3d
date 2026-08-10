extends Node3D
class_name AcknexSky
## Acknex IO.wdl sky stack from assets/converted/wdl_meta.json (uniform).
## scene_field=60 → texture wraps 6×; scene_angle.tilt=-10.

const GFX := "res://assets/converted/gfx/"
const META_PATH := "res://assets/converted/wdl_meta.json"
const SCENE_REPEAT := 6.0

var _meta: Dictionary = {}


## `live_scene_map`/`live_sky_map`/`live_cloud_map`, when non-empty,
## override the static `wdl_meta.json` guess for this level's own
## `scene_map`/`sky_map`/`cloud_map`. Reported live (2026-08-09): "some of
## the world backgrounds are not correct still." `wdl_meta.json`'s own
## extraction takes whichever assignment appears textually LAST in a
## level's own source -- correct for a level with one unconditional
## assignment, but wrong for one that branches on runtime state
## (Desert.wdl picks one of six horizon textures based on `Stage`, read
## from a save file at level start) -- the static guess always landed on
## the last `if` branch in the file regardless of which one actually ran.
## `level_runner.gd`'s own `_apply_wdl_sky()` runs AFTER `_director.
## setup()` and polls continuously for the rest of the level (not just a
## short post-load window) specifically so this can pick up the REAL WDL
## interpreter's own live values whenever they change -- see that call
## site's own comment.
##
## `sky_map`/`cloud_map` didn't get this treatment at all until 2026-08-10
## (GB-20 continued), reported live: "the background has the same weird
## cloud pattern... vastly different background and sky for scenes...
## not seen in the back." `WDL/Weather.wdl`'s own `storm()`/`lightning()`/
## `let_it_snow()`/`SetWeather()`-style functions (Desert's Mansion stage,
## Intro3, Mount, and Ziggy's own per-wave `SetWeather()` re-dispatch, all
## confirmed via a full corpus grep) write `SKY_MAP`/`CLOUD_MAP` -- some
## repeatedly, for the rest of the level, as a genuine ongoing weather
## effect -- and the WDL interpreter genuinely executes all of it
## correctly. None of it ever reached the actual rendered sky before this,
## since only `scene_map` had a live-value hook at all.
func apply(
	level_name: String, bounds: AABB, env: Environment,
	live_scene_map: String = "", live_sky_map: String = "", live_cloud_map: String = ""
) -> void:
	_clear_children()
	_ensure_meta()
	var key := level_name.to_lower()
	var defaults: Dictionary = _meta.get("defaults", {})
	var sky_file := str(defaults.get("sky_map", "sky.png"))
	var cloud_file := str(defaults.get("cloud_map", "clds.png"))
	var level_meta: Dictionary = _meta.get("levels", {}).get(key, {})
	if level_meta.has("sky_map") and str(level_meta["sky_map"]) != "":
		sky_file = str(level_meta["sky_map"])
	if live_sky_map != "":
		sky_file = live_sky_map
	if live_cloud_map != "":
		cloud_file = live_cloud_map

	_apply_sky_maps(env, sky_file, cloud_file)

	var indoor := bool(level_meta.get("indoor", false)) \
		or key in ["studio", "menu", "credits", "vilend"]
	var scene_file := live_scene_map if live_scene_map != "" else str(level_meta.get("scene_map", ""))
	if scene_file == "" and not indoor:
		scene_file = str(defaults.get("scene_map", "horizon.png"))
	if indoor or scene_file == "":
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.12, 0.12, 0.14) if key == "studio" else Color(0.2, 0.22, 0.28)
		env.ambient_light_energy = 1.0 if key == "studio" else 0.85
		env.ambient_light_color = Color(0.55, 0.5, 0.45) if key == "studio" else Color(0.55, 0.55, 0.6)
		return
	_spawn_scene_cylinder(scene_file, bounds)


func _ensure_meta() -> void:
	if not _meta.is_empty():
		return
	if ResourceLoader.exists(META_PATH) or FileAccess.file_exists(META_PATH):
		var f := FileAccess.open(META_PATH, FileAccess.READ)
		if f:
			var data = JSON.parse_string(f.get_as_text())
			if typeof(data) == TYPE_DICTIONARY:
				_meta = data
				return
	_meta = {
		"defaults": {"sky_map": "sky.png", "cloud_map": "clds.png", "scene_map": "horizon.png"},
		"levels": {},
	}


func _apply_sky_maps(env: Environment, sky_file: String, cloud_file: String) -> void:
	var sky_tex := _load_tex(sky_file)
	if sky_tex == null:
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.45, 0.55, 0.7)
		return
	var img := _tex_image(sky_tex)
	if img == null:
		env.background_mode = Environment.BG_COLOR
		return
	var sky := Sky.new()
	var mat := PanoramaSkyMaterial.new()
	mat.panorama = ImageTexture.create_from_image(_make_sky_panorama(img, _load_tex(cloud_file)))
	sky.sky_material = mat
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.62, 0.66)
	env.ambient_light_energy = 0.9


func _make_sky_panorama(sky_img: Image, cloud_tex: Texture2D) -> Image:
	var w := 1024
	var h := 512
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	sky_img.convert(Image.FORMAT_RGBA8)
	var cw := sky_img.get_width()
	var ch := sky_img.get_height()
	var cloud_img: Image = _tex_image(cloud_tex)
	if cloud_img:
		cloud_img.convert(Image.FORMAT_RGBA8)
	# Reported live (2026-08-10): "the background has the same weird cloud
	# pattern in all of the area... in all of the game's levels." Root
	# cause confirmed via direct pixel inspection: sky.png (256x256) is
	# 99.9% alpha=0 (a handful of white star-dot pixels are the only real
	# content), and clds.png (320x320) is ~85% OPAQUE near-black pixels
	# over ~15% alpha=0 gaps. The previous version wrote sky_img's own
	# pixels straight into `out` and only used cloud alpha to lerp
	# TOWARD clds' color, so `out`'s RGB stayed at (0,0,0) almost
	# everywhere -- and PanoramaSkyMaterial reads a panorama's RGB
	# directly with no notion of alpha at all (nothing "behind" a sky
	# dome to blend against), so nearly the whole dome rendered as solid
	# opaque BLACK, with the sparse star/cloud fragments poking through
	# reading as "a weird cloud pattern" on a black sky. Fixed by
	# establishing a real opaque blue-sky gradient as the base FIRST,
	# then compositing the star and cloud layers onto it using each
	# layer's OWN alpha as blend weight, so a transparent source pixel
	# correctly shows the sky base instead of black. Applies uniformly to
	# every level via the shared `defaults.sky_map`/`cloud_map`, matching
	# the "same pattern in all of the game's levels" report.
	for y in h:
		var v := float(y) / float(h - 1)
		var src_v := clampf(v * 1.6, 0.0, 0.999)
		var sy := clampi(int(src_v * float(ch - 1)), 0, ch - 1)
		var base: Color
		if v < 0.55:
			base = Color(0.55, 0.68, 0.88).lerp(Color(0.22, 0.4, 0.72), clampf(v / 0.55, 0.0, 1.0))
		else:
			base = Color(0.22, 0.4, 0.72).darkened(clampf((v - 0.55) / 0.45, 0.0, 0.85))
		for x in w:
			var sx := x * cw / w
			var col := base
			var star := sky_img.get_pixel(sx % cw, sy)
			if star.a > 0.01:
				col = col.lerp(Color(star.r, star.g, star.b), star.a)
			if cloud_img and v < 0.45:
				var cx := x * cloud_img.get_width() / w
				var cy := int(v / 0.45 * float(cloud_img.get_height() - 1))
				var cc := cloud_img.get_pixel(cx % cloud_img.get_width(), cy)
				if cc.a > 0.01:
					col = col.lerp(Color(cc.r, cc.g, cc.b), 0.55 * cc.a)
			out.set_pixel(x, y, col)
	return out


func _spawn_scene_cylinder(scene_file: String, bounds: AABB) -> void:
	var tex := _load_tex(scene_file)
	if tex == null:
		return
	var center := bounds.get_center()
	var radius := maxf(maxf(bounds.size.x, bounds.size.z) * 0.65, 400.0)
	var height := maxf(radius * 0.45, 180.0)
	var y_center := center.y + height * 0.15
	var mi := MeshInstance3D.new()
	mi.name = "SceneMap"
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	cyl.radial_segments = 48
	cyl.cap_top = false
	cyl.cap_bottom = false
	mi.mesh = cyl
	mi.position = Vector3(center.x, y_center, center.z)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_FRONT
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.albedo_texture = tex
	mat.uv1_scale = Vector3(SCENE_REPEAT, 1.0, 1.0)
	mat.texture_repeat = true
	# Reported live (2026-08-09, Smash): "the backgrounds... look like a
	# weird cloud pattern with black background." These horizon strips
	# (e.g. horizon1.png) are drawn as a building/scenery silhouette over
	# a genuinely TRANSPARENT sky region -- confirmed via direct pixel
	# inspection: ~27% of horizon1.png is alpha=0 with RGB=(0,0,0),
	# meant to let the real sky dome show through above the skyline.
	# StandardMaterial3D ignores a texture's own alpha channel entirely
	# unless `transparency` is explicitly enabled, so those "transparent"
	# pixels rendered as solid, opaque BLACK instead -- the sky dome
	# behind them (a mostly-white sky.png blended with clds.png's own
	# dark cloud silhouettes, see _make_sky_panorama()) only became
	# visible in whatever gap the cylinder didn't cover at all, reading
	# as "a weird cloud pattern" floating above a solid black skyline
	# instead of the real sky showing cleanly through the silhouette.
	# ALPHA_SCISSOR (not smooth ALPHA) since this mask is confirmed
	# binary (every pixel checked was either fully 0 or fully 255, no
	# partial values) -- a hard cutout avoids the transparency-sorting
	# artifacts a large, mostly-opaque cylinder would otherwise risk.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _load_tex(file_name: String) -> Texture2D:
	var names: Array[String] = [file_name, file_name.to_lower()]
	# Horizon1.pcx → horizon1.png (extract_wdl_meta lowercases)
	if not file_name.to_lower().ends_with(".png"):
		names.append(file_name.get_basename() + ".png")
		names.append(file_name.get_basename().to_lower() + ".png")
	for n in names:
		var path: String = GFX + n
		if ResourceLoader.exists(path):
			return load(path) as Texture2D
	return null


func _tex_image(tex: Texture2D) -> Image:
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null:
		return null
	if img.is_compressed():
		img.decompress()
	return img


func _clear_children() -> void:
	for c in get_children():
		remove_child(c)
		c.free()
