extends Node
class_name MdlAnimator
## Plays Acknex MDL vertex-frame animations (ent_cycle / ent_frame)
## and switches my.skin textures when a .skins sidecar is present.
##
## Godot's glTF import may reorder vertices vs our .mdlanim sidecar. We remap
## each imported mesh vertex to the nearest bind-pose anim vertex so morphs
## keep correct UVs.

@export var fps := 12.0
@export var autoplay_clip := "Stand"

var _mesh_instance: MeshInstance3D
var _base_arrays: Array = []
var _material: BaseMaterial3D
var _anim_verts: int = 0  # vert count in .mdlanim
var _mesh_verts: int = 0  # vert count on imported mesh
var _frame_count: int = 0
var _positions: PackedFloat32Array = PackedFloat32Array()
var _clips: Dictionary = {}  # String -> PackedInt32Array
var _remap: PackedInt32Array = PackedInt32Array()  # mesh_i -> anim_i

var _clip_frames: PackedInt32Array = PackedInt32Array()
var _percent := 0.0
var _playing := false
var _current_clip := ""

var _skin_textures: Array[Texture2D] = []
var _skin_index := 0
var _skin_timer := 0.0
var _talk_skins := false
## Acknex Talk()/Blink() — hold a frame and occasionally snap Talk + skins.
var _acknex_talk := false
var _acknex_blink := false
var _blink_hold := 0.0
var _talk_frame_timer := 0.0


func setup_from_stem(stem: String, host: Node) -> bool:
	_mesh_instance = _find_mesh(host)
	if _mesh_instance == null:
		return false
	_load_skins(stem)
	var path := _resolve_anim(stem)
	var has_anim := path != "" and FileAccess.file_exists(path) and _load_anim(path)
	if not (_mesh_instance.mesh is ArrayMesh):
		return _skin_textures.size() > 0
	var am := _mesh_instance.mesh as ArrayMesh
	if am.get_surface_count() < 1:
		return _skin_textures.size() > 0
	_base_arrays = am.surface_get_arrays(0)
	var vert_arr: Variant = _base_arrays[Mesh.ARRAY_VERTEX]
	if vert_arr is PackedVector3Array:
		_mesh_verts = (vert_arr as PackedVector3Array).size()
	if has_anim and _mesh_verts > 0 and _anim_verts > 0:
		_build_remap(vert_arr as PackedVector3Array)
	elif has_anim and _mesh_verts != _anim_verts:
		push_warning(
			"MdlAnimator: %s mesh verts %d != anim %d — skipping morph"
			% [stem, _mesh_verts, _anim_verts]
		)
		has_anim = false
	var mat := _mesh_instance.get_active_material(0)
	if mat == null:
		mat = am.surface_get_material(0)
	if mat is BaseMaterial3D:
		_material = (mat as BaseMaterial3D).duplicate()
	else:
		_material = StandardMaterial3D.new()
	_apply_material_style(_material)
	_mesh_instance.set_surface_override_material(0, _material)
	_mesh_instance.lod_bias = 128.0
	if _skin_textures.size() > 0:
		set_skin(0)
	if not has_anim:
		return _skin_textures.size() > 0 or _material != null
	# Restore bind pose through remap before any clip (fixes import reorder).
	if _remap.size() == _mesh_verts and _mesh_verts > 0:
		_set_blended_frame(0, 0, 0.0)
	# Idle must HOLD a frame — animated Stand1/2 cycling looks like bobbing.
	var idle := autoplay_clip if _clips.has(autoplay_clip) else ""
	if idle == "" and _clips.has("Stand"):
		idle = "Stand"
	if idle != "":
		var low := idle.to_lower()
		if low in ["stand", "closed", "speech"] or low.begins_with("stand"):
			play_frame(idle, 0.0)
		else:
			play_cycle(idle, 0.0)
	elif _clips.has("Frame"):
		# Props (fan/smoke) intentionally loop Frame*.
		play_cycle("Frame", 0.0)
	return true


func play_cycle(clip: String, percent: float = 0.0) -> void:
	var key := _resolve_clip(clip)
	if key == "":
		return
	if key == _current_clip and _playing:
		return
	_acknex_talk = false
	_acknex_blink = false
	_current_clip = key
	_clip_frames = _clips[key]
	_percent = clampf(percent, 0.0, 100.0)
	_playing = true
	_talk_skins = _is_mouth_clip(key)
	_apply_percent(_percent)


func play_frame(clip: String, percent: float = 0.0) -> void:
	var key := _resolve_clip(clip)
	if key == "":
		return
	_acknex_talk = false
	_acknex_blink = false
	_current_clip = key
	_clip_frames = _clips[key]
	_percent = clampf(percent, 0.0, 100.0)
	_playing = false
	_talk_skins = false
	if _skin_textures.size() > 0:
		set_skin(1)  # Acknex default skin 1
	_apply_percent(_percent)


## Studio.wdl Talk(): hold pose, random Talk frame snaps + mouth skins.
func play_talk() -> void:
	var key := _resolve_clip("Talk")
	if key == "":
		key = _resolve_clip("Speech")
	if key == "":
		play_cycle("Talk")
		return
	if not _acknex_talk or _current_clip != key:
		_current_clip = key
		_clip_frames = _clips[key]
		_percent = 0.0
		_playing = false
		_acknex_talk = true
		_acknex_blink = false
		_talk_skins = true
		_apply_percent(0.0)


## Studio.wdl Talk2(): keep current anim (Dance) but cycle mouth skins.
func enable_talk_skins(enabled: bool = true) -> void:
	_talk_skins = enabled
	_acknex_blink = false


## Studio.wdl Blink(): Stand frame 0, rare blink skin.
func play_blink() -> void:
	var key := _resolve_clip("Stand")
	if key == "":
		play_frame("Stand", 0.0)
		return
	if not _acknex_blink or _current_clip != key:
		_current_clip = key
		_clip_frames = _clips[key]
		_percent = 0.0
		_playing = false
		_acknex_talk = false
		_acknex_blink = true
		_talk_skins = false
		_blink_hold = 0.0
		set_skin(1)
		_apply_percent(0.0)


func skin_count() -> int:
	return _skin_textures.size()


func set_skin(index: int) -> void:
	if _skin_textures.is_empty() or _material == null or _mesh_instance == null:
		return
	var i := index
	# Acknex my.skin is 1-based; accept 0 as first skin too.
	if i >= 1:
		i -= 1
	i = clampi(i, 0, _skin_textures.size() - 1)
	_skin_index = i
	_material.albedo_texture = _skin_textures[i]
	_apply_material_style(_material)
	_mesh_instance.set_surface_override_material(0, _material)


func _is_mouth_clip(key: String) -> bool:
	var k := key.to_lower()
	# Dance uses Talk2() skins only when director enables them explicitly.
	return k.contains("talk") or k.contains("speech")


func _resolve_clip(clip: String) -> String:
	if _clips.has(clip):
		return clip
	for k in _clips.keys():
		if str(k).to_lower() == clip.to_lower():
			return str(k)
	return ""


func _process(delta: float) -> void:
	# Mouth skins ~ every 1.5 * time ticks (≈0.22s at 16fps game tick).
	if _talk_skins and _skin_textures.size() > 1:
		_skin_timer += delta
		if _skin_timer > 0.22:
			_skin_timer = 0.0
			set_skin(1 + randi() % mini(_skin_textures.size(), 7))
	# Talk(): random Talk frame snaps (~Acknex 1/40 per 16Hz tick).
	if _acknex_talk and not _clip_frames.is_empty():
		_talk_frame_timer += delta
		if _talk_frame_timer >= 0.06:
			_talk_frame_timer = 0.0
			if randi() % 40 == 20:
				var n := _clip_frames.size()
				_percent = (float(randi() % maxi(n, 1)) / maxf(float(n), 1.0)) * 100.0
				_apply_percent(_percent)
		return
	# Blink(): Stand hold; rare skin 7 blink (~Acknex 1/100 per tick).
	if _acknex_blink:
		if _blink_hold > 0.0:
			_blink_hold -= delta
			if _blink_hold <= 0.0:
				set_skin(1)
		else:
			_talk_frame_timer += delta
			if _talk_frame_timer >= 0.06:
				_talk_frame_timer = 0.0
				if randi() % 100 == 50 and _skin_textures.size() >= 7:
					set_skin(7)
					_blink_hold = 0.35
		return
	if not _playing or _clip_frames.is_empty():
		return
	var speed := fps / maxf(float(_clip_frames.size()), 1.0)
	_percent = fmod(_percent + delta * speed * 100.0, 100.0)
	_apply_percent(_percent)


func _apply_percent(percent: float) -> void:
	if _clip_frames.is_empty() or _anim_verts <= 0 or _mesh_verts <= 0:
		return
	var t := clampf(percent, 0.0, 99.999) / 100.0
	var f := t * float(_clip_frames.size())
	var i0 := int(f) % _clip_frames.size()
	var i1 := (i0 + 1) % _clip_frames.size()
	var frac := f - float(i0)
	_set_blended_frame(_clip_frames[i0], _clip_frames[i1], frac)


func _set_blended_frame(a: int, b: int, frac: float) -> void:
	var out := PackedVector3Array()
	out.resize(_mesh_verts)
	var oa := a * _anim_verts * 3
	var ob := b * _anim_verts * 3
	var use_remap := _remap.size() == _mesh_verts
	for i in _mesh_verts:
		var ai := _remap[i] if use_remap else i
		if ai < 0 or ai >= _anim_verts:
			ai = mini(i, _anim_verts - 1)
		out[i] = Vector3(
			lerpf(_positions[oa + ai * 3], _positions[ob + ai * 3], frac),
			lerpf(_positions[oa + ai * 3 + 1], _positions[ob + ai * 3 + 1], frac),
			lerpf(_positions[oa + ai * 3 + 2], _positions[ob + ai * 3 + 2], frac)
		)
	var arrays := _base_arrays.duplicate()
	arrays[Mesh.ARRAY_VERTEX] = out
	var new_mesh := ArrayMesh.new()
	new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = new_mesh
	if _material:
		_apply_material_style(_material)
		_mesh_instance.set_surface_override_material(0, _material)


func _build_remap(mesh_verts: PackedVector3Array) -> void:
	_remap.resize(mesh_verts.size())
	# Identity fast-path when import preserved order.
	var identity := mesh_verts.size() == _anim_verts
	if identity:
		var max_d := 0.0
		for i in mesh_verts.size():
			var q := Vector3(_positions[i * 3], _positions[i * 3 + 1], _positions[i * 3 + 2])
			max_d = maxf(max_d, mesh_verts[i].distance_squared_to(q))
			_remap[i] = i
		if max_d < 1e-4:
			return
	# Nearest bind-pose match (handles Godot glTF vertex reorder / weld).
	for i in mesh_verts.size():
		var p := mesh_verts[i]
		var best := 0
		var best_d := INF
		for j in _anim_verts:
			var q := Vector3(_positions[j * 3], _positions[j * 3 + 1], _positions[j * 3 + 2])
			var d := p.distance_squared_to(q)
			if d < best_d:
				best_d = d
				best = j
				if d < 1e-8:
					break
		_remap[i] = best


func _apply_material_style(bm: BaseMaterial3D) -> void:
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	bm.cull_mode = BaseMaterial3D.CULL_DISABLED
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	bm.alpha_scissor_threshold = 0.1
	bm.metallic = 0.0
	bm.roughness = 1.0
	bm.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	bm.disable_receive_shadows = true


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var m := _find_mesh(c)
		if m:
			return m
	return null


func _resolve_anim(stem: String) -> String:
	var anim_stems: Array[String] = [stem, stem.to_lower()]
	for s in anim_stems:
		var direct: String = "res://assets/converted/mdl/%s.mdlanim" % s
		if FileAccess.file_exists(direct):
			return direct
	var dir := DirAccess.open("res://assets/converted/mdl/")
	if dir == null:
		return ""
	var want := stem.to_lower() + ".mdlanim"
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if fn.to_lower() == want:
			return "res://assets/converted/mdl/" + fn
		fn = dir.get_next()
	return ""


func _load_skins(stem: String) -> void:
	_skin_textures.clear()
	var path := ""
	var skin_stems: Array[String] = [stem, stem.to_lower()]
	for s in skin_stems:
		var cand: String = "res://assets/converted/mdl/%s.skins" % s
		if FileAccess.file_exists(cand):
			path = cand
			break
	if path == "":
		var dir := DirAccess.open("res://assets/converted/mdl/")
		if dir:
			var want := stem.to_lower() + ".skins"
			dir.list_dir_begin()
			var fn := dir.get_next()
			while fn != "":
				if fn.to_lower() == want:
					path = "res://assets/converted/mdl/" + fn
					break
				fn = dir.get_next()
	if path == "" or not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	if f.get_buffer(4) != PackedByteArray([77, 68, 76, 83]):  # MDLS
		return
	if f.get_32() != 1:
		return
	var count := int(f.get_32())
	for _i in count:
		var n := int(f.get_32())
		var png := f.get_buffer(n)
		var img := Image.new()
		if img.load_png_from_buffer(png) != OK:
			continue
		var tex := ImageTexture.create_from_image(img)
		_skin_textures.append(tex)


func _load_anim(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	if f.get_buffer(4) != PackedByteArray([77, 68, 76, 65]):  # MDLA
		return false
	if f.get_32() != 1:
		return false
	_anim_verts = int(f.get_32())
	_frame_count = int(f.get_32())
	for _i in _frame_count:
		f.get_buffer(16)
	var pbuf := f.get_buffer(_frame_count * _anim_verts * 12)
	_positions.resize(_frame_count * _anim_verts * 3)
	for i in _positions.size():
		_positions[i] = pbuf.decode_float(i * 4)
	var clip_count := int(f.get_32())
	_clips.clear()
	for _c in clip_count:
		var craw := f.get_buffer(16)
		var cname := ""
		for b in craw:
			if b == 0:
				break
			cname += String.chr(b)
		f.get_32()
		var count := int(f.get_32())
		var idxs := PackedInt32Array()
		for _j in count:
			idxs.append(int(f.get_32()))
		_clips[cname] = idxs
	return _frame_count > 0 and _anim_verts > 0
