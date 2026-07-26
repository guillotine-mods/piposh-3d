extends Node3D
class_name AcknexSky
## Acknex IO.wdl sky stack from assets/converted/wdl_meta.json (uniform).
## scene_field=60 → texture wraps 6×; scene_angle.tilt=-10.

const GFX := "res://assets/converted/gfx/"
const META_PATH := "res://assets/converted/wdl_meta.json"
const SCENE_REPEAT := 6.0

var _meta: Dictionary = {}


func apply(level_name: String, bounds: AABB, env: Environment) -> void:
	_clear_children()
	_ensure_meta()
	var key := level_name.to_lower()
	var defaults: Dictionary = _meta.get("defaults", {})
	var sky_file := str(defaults.get("sky_map", "sky.png"))
	var cloud_file := str(defaults.get("cloud_map", "clds.png"))
	var level_meta: Dictionary = _meta.get("levels", {}).get(key, {})
	if level_meta.has("sky_map") and str(level_meta["sky_map"]) != "":
		sky_file = str(level_meta["sky_map"])

	_apply_sky_maps(env, sky_file, cloud_file)

	var indoor := bool(level_meta.get("indoor", false)) \
		or key in ["studio", "menu", "credits", "vilend"]
	var scene_file := str(level_meta.get("scene_map", ""))
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
	for y in h:
		var v := float(y) / float(h - 1)
		var src_v := clampf(v * 1.6, 0.0, 0.999)
		var sy := clampi(int(src_v * float(ch - 1)), 0, ch - 1)
		for x in w:
			var sx := x * cw / w
			var col := sky_img.get_pixel(sx % cw, sy)
			if cloud_img and v < 0.45:
				var cx := x * cloud_img.get_width() / w
				var cy := int(v / 0.45 * float(cloud_img.get_height() - 1))
				var cc := cloud_img.get_pixel(cx % cloud_img.get_width(), cy)
				col = col.lerp(cc, 0.35 * cc.a)
			if v > 0.55:
				col = col.darkened(clampf((v - 0.55) / 0.45, 0.0, 0.85))
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
