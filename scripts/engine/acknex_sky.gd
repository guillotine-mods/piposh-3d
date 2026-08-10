extends Node3D
## Acknex IO.wdl sky stack from assets/converted/wdl_meta.json (uniform).
## scene_field=60 → texture wraps 6×; scene_angle.tilt=-10.

const GFX := "res://assets/converted/gfx/"
const META_PATH := "res://assets/converted/wdl_meta.json"
const SCENE_REPEAT := 6.0
## Reported live (2026-08-10), confirmed via direct inspection of a real
## running Town instance: the horizon cylinder is a real, literal piece
## of world-space geometry sized off the LEVEL's OWN bounding box
## (`WmbLevelLoader.level_bounds`) -- for Town that produced a radius of
## ~4768 and height of ~2146 GS units. A real Acknex horizon/"scene" band
## is NOT world-space geometry at all -- like the sky dome itself, it's
## an infinite-distance backdrop that always appears the same apparent
## size regardless of where the camera physically stands in the level
## (only rotating with view direction, never translating with camera
## position). Sizing it off the level's own raw bounds instead meant its
## apparent size on screen varied wildly by level (and by where in a
## level the camera happened to be relative to the cylinder's own fixed
## world position) -- for a level with large bounds like Town, the
## texture ended up filling a huge vertical arc of the screen instead of
## a thin horizon strip, and its own 6x horizontal tiling read as a dense
## repeating "wallpaper" pattern rather than a scattered few repeats at
## the true horizon. Fixed by decoupling the cylinder's own size from
## level bounds entirely (fixed radius/height, chosen to read as a
## reasonably thin band) and re-centering it on the camera's own XZ
## position every frame (`_process()`, see `_follow_camera()`) so it
## behaves like the infinite-distance backdrop it's meant to be.
const SCENE_RADIUS := 3000.0
const SCENE_HEIGHT := 650.0

var _meta: Dictionary = {}
var _scene_map_node: MeshInstance3D


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
	# Reported live (2026-08-10), confirmed via direct isolation (hiding
	# the horizon cylinder entirely made NO difference -- the artifact is
	# the sky dome itself): a dense, fine repeating noise pattern covered
	# the whole visible sky in a real non-headless capture, even though
	# reading the panorama's own `Image` back directly (raw pixels, no
	# rendering pipeline involved) showed the correct, sparse cloud
	# layout. Root cause: Godot's own `Sky` resource never renders the
	# raw panorama texture directly for the visible background -- it
	# always bakes it into a bounded-resolution radiance cubemap first
	# (`radiance_size`, default `RADIANCE_SIZE_256`) and samples THAT for
	# both reflections and the direct background view. This panorama's
	# own sky.png layer is mostly a handful of ISOLATED, SHARP, near-
	# single-pixel star dots against large empty regions -- exactly the
	# kind of high-frequency content that aliases severely when baked
	# down into a comparatively low-resolution (256) cubemap, producing
	# visible Moire/noise-like artifacts unrelated to the source image's
	# own actual (correct) content. Raised to the max available
	# resolution so the bake has enough headroom to represent those
	# sharp points faithfully instead of aliasing.
	var mat := PanoramaSkyMaterial.new()
	mat.panorama = ImageTexture.create_from_image(_make_sky_panorama(img, _load_tex(cloud_file)))
	sky.sky_material = mat
	sky.radiance_size = Sky.RADIANCE_SIZE_1024
	# Reported live (2026-08-10), confirmed via a real non-headless Town
	# capture: even at RADIANCE_SIZE_1024 the visible sky rendered as a
	# nearly flat, featureless medium blue -- no visible gradient, no star
	# dots, no cloud puffs, despite `_make_sky_panorama()`'s own `Image`
	# (verified directly, headless) containing all three correctly. Root
	# cause is Sky's default `process_mode` (PROCESS_MODE_AUTOMATIC, which
	# for a PanoramaSkyMaterial resolves to QUALITY): that mode convolves
	# the panorama with importance-sampled blur for physically-plausible
	# rough-reflection use, which spreads a handful of near-single-pixel
	# bright star dots' energy across a huge solid-angle radius -- exactly
	# the kind of sparse high-frequency content this panorama has --
	# washing them down to near-invisible while also smearing the gradient
	# and cloud silhouette toward a flat average. This sky is 2D stylized
	# backdrop art, not a physically-based environment probe feeding rough
	# reflections, so the accuracy QUALITY mode buys isn't wanted here.
	# REALTIME mode does a cheap mip-based downsample instead (no
	# importance-sampled convolution), preserving sharp point/edge detail
	# like the star dots and cloud silhouette edges.
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.62, 0.66)
	env.ambient_light_energy = 0.9


## Reported live (2026-08-10), with real reference screenshots from the
## running original engine (3D GameStudio A5, launched directly via the
## project's own `piposh_3d_cursor` dgVoodoo2 test harness): "one pattern
## added to the background looks better but the weird clouds are still
## the wrong pattern." Compared this port's own panorama directly against
## the reference and found two real, separate bugs, not one:
##
## 1. **Cloud shape was a single, heavily-distorted stretch, not tiled
##    wisps.** The previous version mapped the ENTIRE 1024px-wide
##    panorama row to exactly one pass across clds.png's own 320px width
##    (`cx = x * cloud_img.get_width() / w`, no repeat) -- squashing one
##    square (320x320) cloud silhouette into a roughly 4.5x-wider-than-
##    tall smear covering the WHOLE horizontal sky at once. The reference
##    screenshots instead show several distinct, naturally-proportioned
##    soft cloud puffs scattered across the sky, clearly the same source
##    shape repeated at something close to its own native aspect ratio,
##    not one warped band. Fixed by tiling clds.png at roughly its own
##    square aspect ratio (`CLOUD_REPEAT` copies across the panorama
##    width, chosen so each tile's width:height ratio in panorama-pixel
##    space is close to 1:1, matching the source texture's own 320x320
##    square) instead of one full-width stretch.
##
## 2. **Cloud color was wrong.** clds.png's own opaque pixels are almost
##    pure black (confirmed via direct pixel read: dominant values are
##    RGB 1-17 out of 255) with a lighter grey highlight streak -- a
##    literal alpha-blend of that RGB would paint the clouds nearly
##    invisible-dark, not the soft white puffs the reference clearly
##    shows. Reasoned this is a hand-painted DENSITY/SHADING mask (common
##    technique for this engine's era) rather than a literal display
##    color: rendered here as a soft, warm-white cloud tint whose
##    strength is driven by the texture's own alpha (overall silhouette)
##    modulated by its own luminance (the lighter "highlight" streak
##    reads as denser/more opaque cloud, the near-black majority as a
##    softer, more translucent wisp) -- giving internal shading instead
##    of a flat silhouette. This is a reasoned, best-effort interpretation,
##    not a confirmed byte-exact match to the original engine's own
##    blend algorithm (still unverified against a live A5 render, which
##    kept crashing in this environment's dgVoodoo2/DirectDraw wrapper --
##    see docs/SESSION_LOG.md for the full attempt).
##
## 3. **Base sky color was too light/pale.** The reference shows a rich,
##    fairly dark blue-purple at the zenith, lightening toward a more
##    saturated mid-blue near the horizon -- not the previous version's
##    pale, washed-out blue. Re-picked directly from the reference
##    screenshots (visual color estimate, not a measured constant).
## Reported live (2026-08-10), confirmed via a real non-headless capture
## of this port's own Town level: the first cell-tiling attempt (4 equal,
## identical cells around the full 360 degree wrap) still read as an
## obvious repeating "wallpaper" pattern -- evenly-spaced identical puffs
## are exactly the kind of regularity the human eye latches onto, even
## though the earlier flat 2D panorama render looked reasonable in
## isolation. The reference screenshots' own clouds are irregular: varied
## size, uneven spacing, some areas of clear sky much larger than others.
## Fixed by using a deterministic per-cell RNG (`CLOUD_SEED`, fixed so the
## generated sky doesn't change between runs) across many more, smaller
## candidate cells (`CLOUD_CELLS`): each cell independently rolls whether
## it gets a puff at all (`CLOUD_DENSITY`), and if so, its own scale and
## position jitter within the cell -- breaking the obvious grid regularity
## while keeping the same underlying sparse/separated silhouette+shading
## logic from the first pass.
const CLOUD_CELLS := 14
const CLOUD_DENSITY := 0.4
const CLOUD_SEED := 20260810
const CLOUD_BAND_CENTER := 0.22
const CLOUD_BAND_HALF_HEIGHT := 0.16
const CLOUD_FILL_MIN := 0.5
const CLOUD_FILL_MAX := 0.85
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
	var cloud_w := (cloud_img.get_width() if cloud_img else 1)
	var cloud_h := (cloud_img.get_height() if cloud_img else 1)
	var cloud_tint := Color(0.93, 0.95, 0.98)
	var band_lo := CLOUD_BAND_CENTER - CLOUD_BAND_HALF_HEIGHT
	var band_hi := CLOUD_BAND_CENTER + CLOUD_BAND_HALF_HEIGHT
	var cell_w := float(w) / float(CLOUD_CELLS)
	var cell_h := band_hi - band_lo

	# Precompute each cell's own roll once (not per-pixel): has_cloud,
	# fill fraction, and a small [-0.5,0.5]-ish center offset within the
	# cell so puffs don't all sit dead-center either.
	var rng := RandomNumberGenerator.new()
	rng.seed = CLOUD_SEED
	var cell_active: Array[bool] = []
	var cell_fill: Array[float] = []
	var cell_offset_u: Array[float] = []
	var cell_offset_v: Array[float] = []
	for i in CLOUD_CELLS:
		cell_active.append(cloud_img != null and rng.randf() < CLOUD_DENSITY)
		cell_fill.append(rng.randf_range(CLOUD_FILL_MIN, CLOUD_FILL_MAX))
		cell_offset_u.append(rng.randf_range(-0.15, 0.15))
		cell_offset_v.append(rng.randf_range(-0.15, 0.15))

	for y in h:
		var v := float(y) / float(h - 1)
		var src_v := clampf(v * 1.6, 0.0, 0.999)
		var sy := clampi(int(src_v * float(ch - 1)), 0, ch - 1)
		var base: Color
		if v < 0.5:
			base = Color(0.14, 0.16, 0.42).lerp(Color(0.32, 0.42, 0.75), clampf(v / 0.5, 0.0, 1.0))
		else:
			base = Color(0.32, 0.42, 0.75).darkened(clampf((v - 0.5) / 0.5, 0.0, 0.8))
		var band_frac := (v - band_lo) / cell_h if cell_h > 0.0 else -1.0
		var in_band := cloud_img != null and band_frac >= 0.0 and band_frac <= 1.0
		for x in w:
			var sx := x * cw / w
			var col := base
			var star := sky_img.get_pixel(sx % cw, sy)
			if star.a > 0.01:
				col = col.lerp(Color(star.r, star.g, star.b), star.a)
			if in_band:
				var cell_i := clampi(int(float(x) / cell_w), 0, CLOUD_CELLS - 1)
				if cell_active[cell_i]:
					var fill: float = cell_fill[cell_i]
					var cell_frac := fmod(float(x), cell_w) / cell_w
					var lu := (cell_frac - 0.5 - cell_offset_u[cell_i]) / fill + 0.5
					var lv := (band_frac - 0.5 - cell_offset_v[cell_i]) / fill + 0.5
					if lu >= 0.0 and lu <= 1.0 and lv >= 0.0 and lv <= 1.0:
						var cx := clampi(int(lu * float(cloud_w)), 0, cloud_w - 1)
						var cy := clampi(int(lv * float(cloud_h)), 0, cloud_h - 1)
						var cc := cloud_img.get_pixel(cx, cy)
						if cc.a > 0.01:
							var luma := (cc.r + cc.g + cc.b) / 3.0
							var strength := cc.a * clampf(0.35 + 1.4 * luma, 0.0, 1.0)
							col = col.lerp(cloud_tint, strength)
			out.set_pixel(x, y, col)
	return out


## See `_spawn_scene_cylinder()`'s own docstring for why this exists
## instead of a plain `CylinderMesh`. Open-ended (no caps -- matches the
## old `cap_top=false, cap_bottom=false`), outward-facing normals/winding
## so `CULL_FRONT` (set by the caller) hides the outside and shows the
## inside, matching the old mesh's own visible-from-inside behavior.
func _build_scene_cylinder_mesh(radius: float, height: float, radial_segments: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var half_h := height * 0.5
	for i in radial_segments + 1:
		var t := float(i) / float(radial_segments)
		var angle := t * TAU
		var x := cos(angle) * radius
		var z := sin(angle) * radius
		var u := t * SCENE_REPEAT
		verts.append(Vector3(x, half_h, z))
		normals.append(Vector3(cos(angle), 0.0, sin(angle)))
		uvs.append(Vector2(u, 0.0))
		verts.append(Vector3(x, -half_h, z))
		normals.append(Vector3(cos(angle), 0.0, sin(angle)))
		uvs.append(Vector2(u, 1.0))
	for i in radial_segments:
		var top0 := i * 2
		var bot0 := i * 2 + 1
		var top1 := (i + 1) * 2
		var bot1 := (i + 1) * 2 + 1
		# Outward normal at this column ~ (cos, 0, sin); CCW as seen from
		# outside (matching that normal, right-hand rule) is top0,bot0,bot1
		# then top0,bot1,top1.
		indices.append(top0)
		indices.append(bot0)
		indices.append(bot1)
		indices.append(top0)
		indices.append(bot1)
		indices.append(top1)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Reported live (2026-08-10), with a direct original-vs-port screenshot
## comparison: the horizon in this port tiles as a broken, diagonally-
## sheared repeating pattern, while the original shows the SAME texture
## (`horizon1.png`, confirmed identical via direct pixel inspection --
## a single coherent factory skyline with chimney smoke over water) once,
## cleanly, filling the frame. Root cause: `CylinderMesh`'s own built-in
## UV generation does NOT produce a clean U/V grid -- dumped its raw
## `ARRAY_TEX_UV` data directly and confirmed each horizontal ring has a
## DIFFERENT U phase offset than the ring above/below it (e.g. two
## vertices at the same angular column but different heights land at
## u=0.417 and u=0.229, not the same u), a spiral/shear baked into
## Godot's own primitive-mesh algorithm (apparently meant for genuine
## cone taper, degenerating into a uniform-but-nonzero per-ring twist even
## with top_radius==bottom_radius). Combined with `uv1_scale.x`
## repeating the texture `SCENE_REPEAT` times, that per-ring shear reads
## exactly as the reported diagonal banding. Fixed by building the
## cylinder's side surface as a hand-authored `ArrayMesh` instead of
## relying on `CylinderMesh`'s own UV algorithm at all -- a simple ring of
## quads with UVs computed directly (u = column/radial_segments *
## SCENE_REPEAT, v = 0 at the top ring / 1 at the bottom, identical phase
## at every height), guaranteeing a clean, non-sheared wrap regardless of
## Godot's own primitive-mesh internals.
func _spawn_scene_cylinder(scene_file: String, bounds: AABB) -> void:
	var tex := _load_tex(scene_file)
	if tex == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "SceneMap"
	mi.mesh = _build_scene_cylinder_mesh(SCENE_RADIUS, SCENE_HEIGHT, 48)
	# Centered on whatever camera is active right now; _process() re-centers
	# it every frame from here on (see this file's own SCENE_RADIUS
	# docstring for why world-space level bounds were the wrong anchor).
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	mi.position = cam.global_position if cam else bounds.get_center()
	_scene_map_node = mi
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_FRONT
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.albedo_texture = tex
	# SCENE_REPEAT is already baked directly into the mesh's own UVs
	# (_build_scene_cylinder_mesh()) -- no uv1_scale here, that would
	# double-apply the repeat (SCENE_REPEAT^2 copies instead of SCENE_
	# REPEAT). texture_repeat still needs to be on so values > 1.0 wrap
	# instead of clamping to the texture's last-pixel-column edge.
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
	_scene_map_node = null
	for c in get_children():
		remove_child(c)
		c.free()


## Re-centers the horizon cylinder on whatever camera is actually
## rendering right now, every frame -- see SCENE_RADIUS's own docstring.
## `get_viewport().get_camera_3d()` (not a stored reference) since this
## project's own CameraAuthority switches which Camera3D is active
## (player FP vs. WDL-scripted) during normal play; querying fresh each
## frame always follows whichever one is really driving the view.
func _process(_delta: float) -> void:
	if _scene_map_node == null or not is_instance_valid(_scene_map_node):
		return
	var cam := get_viewport().get_camera_3d()
	if cam:
		_scene_map_node.global_position = cam.global_position
