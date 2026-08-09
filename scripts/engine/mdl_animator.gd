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

## GB-2 follow-up: user reports Piposh's walk-in animation looks frozen in
## real play even though headless tests show `_percent` genuinely advancing.
## Temporary, tightly-scoped trace (only for the entity whose `action` meta
## is "PiposhWalk", so this doesn't spam every other animated entity in
## every level) to see the REAL play session's actual state transitions,
## since headless couldn't reproduce the freeze after two separate attempts.
var _debug_throttle := 0
func _debug_scope() -> bool:
	var host := get_parent()
	return host != null and str(host.get_meta("action", "")) == "PiposhWalk"

func _debug_log(msg: String) -> void:
	if _debug_scope():
		PiposhDebug.log_msg("mdl-anim", msg)

func _debug_log_throttled(msg: String) -> void:
	if not _debug_scope():
		return
	_debug_throttle += 1
	if _debug_throttle % 30 == 1:  # ~2x/sec at 60fps
		PiposhDebug.log_msg("mdl-anim", msg)


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
		# Props (fan/smoke) intentionally loop Frame* -- entities whose own
		# WDL action never calls ent_frame/ent_cycle at all get corrected
		# back to a static hold by WdlInterpreter._seed_static_pose_if_
		# never_animated(), which runs once at begin_level() (before the
		# first frame renders) since MdlAnimator has no AST access of its
		# own to make that call here.
		play_cycle("Frame", 0.0)
	return true


## Acknex `morph(<File.mdl>, entity)` — swaps this entity to a different
## MDL's mesh/animation/skin set at runtime, in place (same node, same
## transform/collision), then resumable back via a second morph_to() call.
## Previously entirely unimplemented — see docs/SESSION_LOG.md 2026-07-28.
func morph_to(stem: String) -> bool:
	if _mesh_instance == null:
		return false
	var glb := _resolve_glb(stem)
	if glb == "":
		return false
	var packed: Resource = load(glb)
	if not (packed is PackedScene):
		return false
	var temp: Node = (packed as PackedScene).instantiate()
	var src := _find_mesh(temp)
	if src == null or not (src.mesh is ArrayMesh) or (src.mesh as ArrayMesh).get_surface_count() < 1:
		temp.queue_free()
		return false
	var am := src.mesh as ArrayMesh
	_base_arrays = am.surface_get_arrays(0)
	var src_mat := src.get_active_material(0)
	if src_mat == null:
		src_mat = am.surface_get_material(0)
	temp.queue_free()

	_clips.clear()
	_remap = PackedInt32Array()
	_skin_textures.clear()
	_anim_verts = 0
	_frame_count = 0
	_positions = PackedFloat32Array()
	_current_clip = ""
	_playing = false
	_acknex_talk = false
	_acknex_blink = false
	_talk_skins = false

	var vert_arr: Variant = _base_arrays[Mesh.ARRAY_VERTEX]
	_mesh_verts = (vert_arr as PackedVector3Array).size() if vert_arr is PackedVector3Array else 0
	_bind_stem(stem, src_mat, vert_arr)
	return true


## Shared tail of setup_from_stem() / morph_to(): load skins/.mdlanim for
## `stem`, build the vertex remap against whatever mesh is currently in
## `_base_arrays`, apply material style, and start an idle pose/clip.
func _bind_stem(stem: String, src_mat: Material, vert_arr: Variant) -> void:
	_load_skins(stem)
	var path := _resolve_anim(stem)
	var has_anim := path != "" and FileAccess.file_exists(path) and _load_anim(path)
	if has_anim and _mesh_verts > 0 and _anim_verts > 0:
		_build_remap(vert_arr as PackedVector3Array)
	elif has_anim and _mesh_verts != _anim_verts:
		push_warning(
			"MdlAnimator: %s mesh verts %d != anim %d — skipping morph"
			% [stem, _mesh_verts, _anim_verts]
		)
		has_anim = false

	if src_mat is BaseMaterial3D:
		_material = (src_mat as BaseMaterial3D).duplicate()
	else:
		_material = StandardMaterial3D.new()
	_apply_material_style(_material)
	_mesh_instance.set_surface_override_material(0, _material)
	_mesh_instance.lod_bias = 128.0
	if _skin_textures.size() > 0:
		set_skin(0)

	if has_anim and _remap.size() == _mesh_verts and _mesh_verts > 0:
		# Restore bind pose through remap before any clip (fixes import reorder).
		_set_blended_frame(0, 0, 0.0)
	else:
		# Static single-frame model (no .mdlanim, or a verts mismatch): show
		# the bind-pose mesh directly instead of leaving the OLD mesh/clips
		# on screen from before this call.
		var arrays: Array = _base_arrays.duplicate()
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_mesh_instance.mesh = m
		_mesh_instance.set_surface_override_material(0, _material)

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
		play_cycle("Frame", 0.0)


func _resolve_glb(stem: String) -> String:
	var cands: Array[String] = [stem, stem.to_lower()]
	for s in cands:
		var direct := "res://assets/converted/mdl/%s.glb" % s
		if FileAccess.file_exists(direct):
			return direct
	var dir := DirAccess.open("res://assets/converted/mdl/")
	if dir == null:
		return ""
	var want := stem.to_lower() + ".glb"
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if fn.to_lower() == want:
			return "res://assets/converted/mdl/" + fn
		fn = dir.get_next()
	return ""


## 2026-08-09 (Smash): "still the animation of genia is not walking."
## `action WalkGeniaWalk` calls `Blink()` (-> `ent_frame("Stand",0)` ->
## `play_frame()`, which unconditionally sets `_current_clip="Stand"`,
## `_playing=false`) EVERY tick, immediately before its own
## `ent_cycle("Walk", my.skill1)` -- so THIS function's own "already
## playing this clip, leave `_process()`'s natural per-frame advance
## alone" guard (`key == _current_clip and _playing`) never actually
## fires: `_current_clip` is always "Stand" (Blink's own doing) the
## instant this runs, so every single tick force-resets `_percent`
## straight from the WDL script's own `my.skill1` -- a plain
## `my.skill1 = my.skill1 + 15*time;` accumulator with no wrap-around of
## its own (the corpus-wide idiom assumes SOMETHING downstream handles
## that, same as every other `ent_cycle(name, my.skillN)` caller).
## `clampf(percent, 0, 100)` meant that once `my.skill1` first exceeded
## 100 (well under a second of walking), every further tick reset
## `_percent` to exactly 100.0 -- frozen on the cycle's own last frame
## for the rest of the walk, reading as "not walking" even though
## `_current_clip`/`_playing` both correctly said "Walk"/true the whole
## time. The identical clamp-vs-wrap bug already found and fixed once
## before (2026-08-02, Plane's own PiposhWalk via `_do_actor_move()`'s
## own auto-walk fallback) -- but that fix lives inside
## `_do_actor_move()` itself, not here, so it never covered a WDL script
## calling `ent_cycle()` directly (no `actor_move()` involved at all,
## Genia's own case). Fixed at the real source instead: `fmod`, not
## `clampf`, so ANY caller's own ever-growing phase value wraps and
## keeps animating instead of freezing at the boundary -- covers every
## corpus action with this exact "another ent_frame call interleaved
## every tick defeats the already-playing guard" shape, not just Genia.
func play_cycle(clip: String, percent: float = 0.0) -> void:
	var key := _resolve_clip(clip)
	if key == "":
		_debug_log("play_cycle NO-KEY clip=%s (not found in _clips, keys=%s)" % [clip, str(_clips.keys())])
		return
	if key == _current_clip and _playing:
		_debug_log("play_cycle EARLY-RETURN clip=%s percent=%.2f (already current_clip=%s playing=true)" % [clip, percent, _current_clip])
		return
	_acknex_talk = false
	_acknex_blink = false
	_current_clip = key
	_clip_frames = _clips[key]
	_percent = fposmod(percent, 100.0)
	_playing = true
	_talk_skins = _is_mouth_clip(key)
	_apply_percent(_percent)
	_debug_log("play_cycle APPLIED clip=%s percent=%.2f" % [clip, percent])


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
		_debug_log("play_blink APPLIED -> current_clip=Stand playing=false acknex_blink=true")
	else:
		_debug_log("play_blink NO-OP (already acknex_blink=true, current_clip=Stand)")


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
		_debug_log_throttled("PROCESS stuck in acknex_blink hold (current_clip=%s)" % _current_clip)
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
		_debug_log_throttled("PROCESS not advancing: playing=%s clip_frames_empty=%s current_clip=%s" % [_playing, _clip_frames.is_empty(), _current_clip])
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
	# Was SHADING_MODE_UNSHADED (commit df96b0d, undocumented) -- that makes
	# every character/prop ignore lighting entirely, while
	# wmb_level_loader.gd's _spawn_light() correctly creates a real
	# OmniLight3D per WMB light entity. Those lights had zero visible effect
	# because nothing could receive them -- confirmed by comparing an actual
	# original .exe screenshot (visibly shaded/lit models) against the flat,
	# unlit port. Switched to per-pixel lit shading so the level's own real
	# lights actually do something (docs/SESSION_LOG.md 2026-07-27).
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
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
