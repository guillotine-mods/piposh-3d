extends Node
class_name WdlDirector
## WDL-derived level behaviour that isn't already covered by WdlInterpreter's
## own AST execution: camera wiring/arbitration, mouse mode, generic entity
## classification (cameras/patrols/random buildings/AFG cards), and click
## dispatch.
##
## Every level with a parsed WDL AST runs through WdlInterpreter (see
## _try_begin_interpreted_level()) — this director no longer hand-ports any
## chapter's dialogue/camera choreography itself. Until 2026-07-30 this file
## also carried ~2000 lines of per-chapter hand-ported code (Start/Studio/
## Town/Shiks/Plane/Plane2/Range: _begin_X()/_update_X()/_apply_X_cam()/
## _run_X_choice() functions plus ~40 exclusive instance fields feeding
## them), left in place but permanently bypassed since 2026-07-28 when
## HAND_PORTED was emptied in favor of interpreter-first execution for every
## level. It was deleted outright rather than kept disabled: none of it had
## run in two days, so removing it doesn't change any in-game behavior, only
## replaces dead code with nothing. See docs/CONTRACT.md §4.1 and
## docs/SESSION_LOG.md for the full reasoning and the parity-test rule the
## interpreter went through before earning that trust.

signal status(msg: String)
signal request_run(level_name: String)

const HOUSES: Array[String] = [
	"House1", "House2", "House3", "House4", "House5",
	"House6", "House7", "House8", "House9", "House10",
]

## Camera-class WMB entity actions — every one of these is just a placed
## "camera pose" marker (real Acknex has one camera; these are candidate
## viewpoints a script picks between via camera.x/y/z/pan/tilt/roll writes
## or, for cutscene chapters, wdl_director itself snaps the world camera to
## one directly). Treated uniformly: hide the marker's own mesh, register it
## in _cams so _active_cam()/_snap_to_active_cam() can find it.
const CAMERA_ACTIONS: Array[String] = [
	"Cam", "Cammy", "SCam", "MyCamera", "PipiCam", "TheCam", "TheCam2",
	"FarCam", "Cam2", "Cam3", "Cam4", "CamPlane", "CameraEngine",
]

var view_index := 1
var fov_arc := 60.0
var scripted_camera := false
var mouse_look := true  # WDL mouse_mode == 0

var _loader: WmbLevelLoader
var _world_camera: Camera3D
var _hud: GameHud
var _cams: Array[Node3D] = []
var _paths: Dictionary = {}
var _patrols: Array[Dictionary] = []
var _clickables: Array[Node3D] = []

var _level_script := ""
var _wdl_interp: WdlInterpreter  # generic AST-driven runtime, see _try_begin_interpreted_level()

## Smoothed scripted-camera pose, read/written by _copy_cam().
var _cam_pos := Vector3.ZERO
var _cam_pos_ready := false


func setup(loader: WmbLevelLoader, camera: Camera3D, level_data: Dictionary, hud: GameHud = null) -> void:
	_loader = loader
	_world_camera = camera
	_hud = hud
	_cams.clear()
	_patrols.clear()
	_clickables.clear()
	_paths.clear()
	if _wdl_interp and is_instance_valid(_wdl_interp):
		_wdl_interp.queue_free()
	_wdl_interp = null
	_cam_pos_ready = false
	view_index = 1
	fov_arc = 60.0
	_level_script = str(level_data.get("script", loader.level_name)).to_lower()

	var path_i := 0
	for p in level_data.get("paths", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var pts: Array = p.get("points", [])
		var arr := PackedVector3Array()
		for pt in pts:
			if pt is Array and pt.size() >= 3:
				arr.append(Vector3(float(pt[0]), float(pt[1]), float(pt[2])))
		if arr.size() > 0:
			var pname := str(p.get("name", ""))
			if pname == "" or _paths.has(pname):
				path_i += 1
				pname = "path_%03d" % path_i
			_paths[pname] = arr

	var cam_i := 0
	var entities := loader.get_node_or_null("Entities")
	if entities == null:
		return

	for n in entities.get_children():
		if not (n is Node3D):
			continue
		var node := n as Node3D
		var action := str(node.get_meta("action", ""))
		var skills: Array = node.get_meta("skills", [])
		if action in CAMERA_ACTIONS:
			cam_i += 1
			var skill1 := int(round(float(skills[0]))) if skills.size() > 0 else 0
			var vid := skill1 if skill1 > 0 else cam_i
			node.set_meta("view_id", vid)
			_cams.append(node)
			_hide_cam_mesh(node)
			continue
		match action:
			"RandomBuilding":
				_apply_random_building(node)
			"PatrolCity", "SportCar":
				_start_patrol(node, skills)
				_anim_cycle(node, "Walk")
			"Taxi", "Inn", "MOI", "Travel", "Pisa", "Kazale", \
			"GoToTaxi", "GoToInn", "GoToMOI", "GoToTravel", "GoToDesert":
				_make_clickable(node, action)
			"AFG_Card":
				# Afgan.wdl collectible: my.skill1 = card index (0-31), click
				# picks it up (persists to GameState.afg, removes entity).
				# See _run_afg_take()/_show_afg_card() -- a faithful port of
				# Afgan.wdl's real AFG_Take action (confirmed against
				# original/piposh3d/WDL/Afgan.wdl), not a guess.
				var card_i := int(round(float(skills[0]))) if skills.size() > 0 else -1
				if card_i >= 0 and card_i < GameState.afg.size() and GameState.afg[card_i] == 1:
					node.queue_free()  # already collected in a prior session
				else:
					node.set_meta("afg_card_index", card_i)
					_make_clickable(node, "AFG_Take")
			"Dummy":
				# Studio.wdl Dummy = room tone; Plane/Plane2 = cockpit loop.
				if _is_studio_level():
					AudioChannels.play_sfx("SFX105.WAV", -8.0)
				elif _is_plane_level() or _is_plane2_level():
					AudioChannels.play_music("SFX089.WAV", -10.0)
			"WaterWheel":
				# Shiks.wdl: loop Lake = SFX100 while the wheel turns.
				AudioChannels.play_music("SFX100.WAV", -12.0)
			"Watrfall":
				AudioChannels.play_music("SFX140.WAV", -10.0)
			"Cow", "Cow2", "Arrow1", "Arrow2", "Ship", "Falling", "PisaFall", \
			"Dome", "Wind", "Land":
				_anim_cycle(node, "Frame")
			"DrawBridge":
				_anim_frame(node, "Closed", 0.0)
			_:
				pass

	if _hud and not _hud.skip_line_pressed.is_connected(_on_skip_line_pressed):
		_hud.skip_line_pressed.connect(_on_skip_line_pressed)

	var fp := _loader != null and _loader.has_first_person()
	scripted_camera = not fp and _cams.size() > 0

	# PORTING_MANUAL.md Phase 1: camera ownership (who does LevelRunner point
	# the active camera at) and script execution (does this level's WDL run
	# at all) are independent questions and must not gate each other. Every
	# level tries the interpreter first, whenever a parsed AST exists,
	# regardless of fp/scripted_camera; camera wiring happens after and
	# doesn't care whether the interpreter is running underneath it
	# (LevelRunner._enable_first_person() independently forces
	# scripted_camera=false and switches to the player camera for fp levels
	# no matter what setup() decided here).
	var interpreted := _try_begin_interpreted_level()
	if fp:
		# Generic FP (Inn/Mansion/Plane2/…): LevelRunner owns the camera
		# regardless of the line above, but FP-specific click wiring still
		# needs to happen here — the interpreter path only wires the
		# generic Run()/GoTo clickables, not the FP action props.
		scripted_camera = false
		mouse_look = true
		if not interpreted:
			_wire_generic_run_clickables()
		_wire_first_person_clickables()
		status.emit(
			"%s — first person%s" % [
				str(_loader.level_name),
				" + interpreted WDL" if interpreted else "",
			]
		)
	elif interpreted:
		pass  # _try_begin_interpreted_level() already wired camera + clickables + status
	elif scripted_camera:
		_begin_generic_level()
	else:
		if _has_wdl_ast():
			push_warning(
				"[wdl_director] %s has a parsed WDL AST but reached the inert free-camera branch (interpreter setup failed, not fp, no scripted camera) — investigate before treating this level as done."
				% str(_loader.level_name)
			)
		status.emit("Free player camera")


func _process(delta: float) -> void:
	if _wdl_interp == null and scripted_camera:
		# Interpreted levels drive camera.x/y/z/pan/tilt/roll directly every
		# tick via their own coroutines — this generic "snap to nearest Cam
		# entity" fallback must not also run then, or the two fight over the
		# camera (see docs/SESSION_LOG.md 2026-07-27, originally found via Range).
		_update_town_cam()
	_update_patrols(delta)
	if _hud and _is_town_level():
		# Town.wdl Zoom = ((60 - camera.arc) / 4) + 1
		var z := int(((60.0 - fov_arc) / 4.0) + 1.0)
		_hud.set_zoom_digit(z)
	_log_camera_change_if_any()


## 2026-07-30: logs the *actually rendered* active camera's real position
## whenever it changes, same "cam-*" tag family as
## WdlInterpreter._set_camera_field()'s "cam-write" log -- compare the two
## against each other to tell a real script-driven camera cut apart from a
## stutter/low-framerate artifact that only *looks* like one: a cam-write
## with no matching cam-actual jump means the write never reached the
## camera that's actually on screen (e.g. wrong camera active, hidden
## behind fp mode); a cam-actual jump with no preceding cam-write means
## something *other* than the interpreter moved the visible camera.
## Change-detected, not per-frame, so this can't itself flood the console.
var _dbg_last_active_cam: Camera3D
var _dbg_last_cam_pos := Vector3.INF


func _log_camera_change_if_any() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var active := vp.get_camera_3d()
	if active == null:
		return
	var pos := active.global_position
	var switched := active != _dbg_last_active_cam
	var jumped := (
		not switched
		and _dbg_last_cam_pos != Vector3.INF
		and pos.distance_to(_dbg_last_cam_pos) > 1.0
	)
	if switched or jumped:
		PiposhDebug.log_msg(
			"cam-actual",
			"active=%s pos=%s%s" % [
				active.get_path(), pos,
				" <<CAMERA SWITCH>>" if switched and _dbg_last_active_cam != null else "",
			]
		)
	_dbg_last_active_cam = active
	_dbg_last_cam_pos = pos


func _on_skip_line_pressed() -> void:
	# Same as Space during a scripted dialogue moment — advances/ends the
	## current line. Interpreted levels don't need an explicit "skip" flag:
	# stopping the Voice channel makes GetPosition(Voice) report "finished"
	# on the very next poll, which is exactly what unblocks any
	# `while (GetPosition(Voice) < 1000000) { wait(1); }` loop in the script.
	if AudioChannels.is_voice_playing():
		AudioChannels.stop_voice()
		status.emit("Skipped line")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_V and _is_town_level():
			view_index = 2 if view_index == 1 else 1
			_snap_to_active_cam(true)
			status.emit("View %d" % view_index)
		elif event.keycode == KEY_SPACE:
			_on_skip_line_pressed()
		elif event.keycode == KEY_ESCAPE and _is_start_level():
			request_run.emit("Menu")

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT and (scripted_camera or _loader_has_fp()) \
				and not _is_range_level():
			# IO.wdl mouse_toggle — Town/Studio cams + Plane2 FP click targets.
			# Range has no cursor mode at all — always aim-with-mouse.
			mouse_look = not mouse_look
			_apply_mouse_mode()
			status.emit("Mouse look" if mouse_look else "Cursor mode — click targets")
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and _is_town_level() and mouse_look:
			fov_arc = maxf(1.0, fov_arc - 1.0)
			if _world_camera:
				_world_camera.fov = maxf(fov_arc, 1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and _is_town_level() and mouse_look:
			fov_arc = minf(60.0, fov_arc + 1.0)
			if _world_camera:
				_world_camera.fov = fov_arc
		elif event.button_index == MOUSE_BUTTON_LEFT and not mouse_look:
			# Let dialog TextureButtons handle GUI clicks first.
			if _hud and _hud.is_dialog_open():
				return
			_try_click()

	if event is InputEventMouseMotion and mouse_look and scripted_camera \
			and not _is_start_level() and not _is_shiks_level() and not _is_plane_level() \
			and not _is_range_level() and not _is_studio_level():
		# Town.wdl / generic Cam: pan/tilt -= mickey/5 while mouse_mode==0.
		# Studio excluded (2026-07-31): Studio.wdl's own script never reads
		# or toggles mouse state at all (confirmed reading the full file) --
		# its camera is entirely dictated by `TheCam`/`TheCam2` copying
		# `my.pan`/`my.tilt` from whichever Cam entity's action currently
		# matches `Talking`. This generic mouse-look-in-scripted-mode
		# feature mutates that SAME `my.pan`/`my.tilt` meta via
		# `cam.set_meta(...)` below, which `TheCam`/`TheCam2` then
		# faithfully copy to the real camera every frame -- so mouse
		# movement was silently corrupting the entity's own authored
		# facing, not just failing to do anything. Reported live: "the
		# mouse can actually move the camera while it shouldn't" during
		# Naknik's dialogue.
		var cam := _active_cam()
		if cam:
			var pan: float = float(cam.get_meta("pan", 0.0)) - event.relative.x / 5.0
			var tilt: float = clampf(
				float(cam.get_meta("tilt", 0.0)) - event.relative.y / 5.0, -45.0, 45.0
			)
			cam.set_meta("pan", pan)
			cam.set_meta("tilt", tilt)


func _is_start_level() -> bool:
	return _level_script.contains("start") or str(_loader.level_name).to_lower() == "start"


func _is_studio_level() -> bool:
	return _level_script.contains("studio") or str(_loader.level_name).to_lower() == "studio"


func _is_town_level() -> bool:
	return _level_script.contains("town") or str(_loader.level_name).to_lower() == "town"


func _is_range_level() -> bool:
	return _level_script.contains("range") or str(_loader.level_name).to_lower() == "range"


func _is_shiks_level() -> bool:
	return _level_script.contains("shik") or str(_loader.level_name).to_lower() == "shiks"


func _is_plane_level() -> bool:
	# Only Plane.wdl (not Plane2/Plane3 — different scripts).
	var n := str(_loader.level_name).to_lower() if _loader else ""
	return n == "plane" or _level_script == "plane.wdl"


func _is_plane2_level() -> bool:
	var n := str(_loader.level_name).to_lower() if _loader else ""
	return n == "plane2" or _level_script == "plane2.wdl"


func _loader_has_fp() -> bool:
	return _loader != null and _loader.has_first_person()


func _wdl_ast_stem() -> String:
	## Returns the wdl_ast/ stem for this level's script, or "" if no parsed
	## AST exists for it. Shared by _try_begin_interpreted_level() (to start
	## the interpreter) and setup()'s inert-branch guard (to tell "no script"
	## apart from "script exists but nothing ran it").
	var stems: Array[String] = [_level_script.get_basename(), str(_loader.level_name)]
	for s in stems:
		var path := "res://assets/converted/wdl_ast/%s.json" % s
		if ResourceLoader.exists(path) or FileAccess.file_exists(path):
			return s
	return ""


func _has_wdl_ast() -> bool:
	return _wdl_ast_stem() != ""


func _try_begin_interpreted_level() -> bool:
	## Generic AST-driven runtime (WdlInterpreter) — reads the level's actual
	## .wdl (via tools/parse_wdl.py's JSON AST) and executes it directly.
	## See docs/CONTRACT.md for the parity-test rule this went through
	## before being wired in here.
	var found := _wdl_ast_stem()
	if found == "":
		return false
	var interp := WdlInterpreter.new()
	interp.name = "WdlInterpreter"
	add_child(interp)
	if not interp.setup(found, _loader, _world_camera, _hud):
		interp.queue_free()
		return false
	_wdl_interp = interp
	scripted_camera = true
	mouse_look = true
	_apply_mouse_mode()
	view_index = 1
	_snap_to_active_cam(true)
	_wire_generic_run_clickables()
	_wdl_interp.begin_level()
	status.emit("%s — interpreted WDL" % str(_loader.level_name))
	return true


func _begin_generic_level() -> void:
	## Uniform fallback: any level with Cam/paths works without a parsed AST.
	## Transitions come from levels.json Run list + clickable entity actions.
	scripted_camera = true
	mouse_look = true
	_apply_mouse_mode()
	view_index = 1
	_snap_to_active_cam(true)
	_wire_generic_run_clickables()
	status.emit(
		"%s — generic cam (RMB cursor, click exits)" % str(_loader.level_name)
	)


func _wire_generic_run_clickables() -> void:
	var flow_path := "res://assets/converted/levels.json"
	if not (ResourceLoader.exists(flow_path) or FileAccess.file_exists(flow_path)):
		return
	var f := FileAccess.open(flow_path, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	if typeof(data) != TYPE_DICTIONARY:
		return
	var levels: Dictionary = data.get("levels", {})
	var key := str(_loader.level_name)
	var info: Dictionary = levels.get(key, levels.get(key.to_lower(), {}))
	var runs: Array = info.get("run", [])
	var run_keys: Dictionary = {}  # lower -> canonical
	for r in runs:
		var name := str(r).replace(".exe", "").replace(".EXE", "")
		run_keys[name.to_lower()] = name
	# Also allow GoToX / action name matching any known level.
	for lk in levels.keys():
		run_keys[str(lk).to_lower()] = str(lk)

	var entities := _loader.get_node_or_null("Entities")
	if entities == null:
		return
	for n in entities.get_children():
		if not (n is Node3D):
			continue
		var node := n as Node3D
		var action := str(node.get_meta("action", ""))
		if action == "":
			continue
		var a := action.to_lower()
		if a.begins_with("goto"):
			var target := action.substr(4)  # GoToDesert → Desert
			_make_clickable(node, target if target != "" else action)
			continue
		if run_keys.has(a):
			_make_clickable(node, str(run_keys[a]))


func _wire_first_person_clickables() -> void:
	## Plane2 / Mansion-style enable_click props (STU1, TV, Sikot, headphones…).
	var entities := _loader.get_node_or_null("Entities") if _loader else null
	if entities == null:
		return
	## afg_card is deliberately excluded: setup()'s entity loop already wires
	## it to the real "AFG_Take" handler (and removes already-collected
	## cards). Re-wiring it here with the raw "AFG_Card" action would clobber
	## that with an unhandled action string. See docs/SESSION_LOG.md.
	const CLICK := [
		"stu1", "stu2", "tv", "sikot", "headphone", "passanger",
		"hitme", "a1", "item_pickup",
	]
	for n in entities.get_children():
		if not (n is Node3D):
			continue
		var node := n as Node3D
		var action := str(node.get_meta("action", ""))
		var a := action.to_lower()
		if a in CLICK or a.begins_with("headphone") or a.begins_with("stu"):
			_make_clickable(node, action)


func ensure_scripted_view() -> void:
	## Called by LevelRunner so the first frame isn't a free-player / origin
	## view. Interpreted levels set their own camera.* from the script's own
	## coroutines (see _try_begin_interpreted_level()/WdlInterpreter) — this
	## one-time snap only matters before that's had a chance to run yet.
	scripted_camera = true
	if _cams.size() > 0 and _wdl_interp == null:
		_snap_to_active_cam(true)
	if _world_camera:
		_world_camera.current = true


func _update_town_cam() -> void:
	var cam := _active_cam()
	if cam == null or _world_camera == null:
		return
	_copy_cam(cam)
	_world_camera.fov = _acknex_arc_to_godot_fov(fov_arc)


func _snap_to_active_cam(_reset_look: bool) -> void:
	var cam := _active_cam()
	if cam:
		_copy_cam(cam, true)


func _copy_cam(cam: Node3D, hard: bool = true) -> void:
	if cam == null or _world_camera == null:
		return
	# Position + orientation copied 1:1 from the entity, matching the original
	# engine exactly (Studio.wdl TheCam/TheCam2: `camera.x=my.x; camera.z=my.z;
	# camera.tilt=my.tilt; camera.pan=my.pan; camera.roll=my.roll` — no offset,
	# no softening).
	var pos := cam.global_position
	if hard:
		_cam_pos = pos
		_cam_pos_ready = true
		_world_camera.global_position = pos
	elif _cam_pos_ready:
		_world_camera.global_position = _cam_pos
	else:
		_world_camera.global_position = pos
	var pan: float = float(cam.get_meta("pan", 0.0))
	var tilt: float = float(cam.get_meta("tilt", 0.0))
	var roll: float = float(cam.get_meta("roll", 0.0))
	_apply_acknex_view(_world_camera, pan, tilt, roll)
	_world_camera.fov = _acknex_arc_to_godot_fov(fov_arc)
	_world_camera.current = true
	if hard:
		PiposhDebug.log_msg(
			"copy-cam",
			"level=%s cam_entity=%s pos=%s pan=%.1f tilt=%.1f roll=%.1f -> world_cam_pos=%s world_cam_rot=%s"
			% [
				str(_loader.level_name) if _loader else "?",
				cam.name,
				str(pos),
				pan,
				tilt,
				roll,
				str(_world_camera.global_position),
				str(_world_camera.rotation_degrees),
			]
		)


func _acknex_arc_to_godot_fov(arc_deg: float) -> float:
	## Acknex camera.arc is horizontal FOV; Godot Camera3D.fov is vertical.
	## Use original 4:3 design aspect so vertical framing matches 640×480 A5
	## (widescreen then gains extra horizontal FOV via stretch/expand).
	var h := absf(arc_deg)
	if h < 1.0:
		h = 60.0
	const DESIGN_ASPECT := 4.0 / 3.0
	var v := rad_to_deg(2.0 * atan(tan(deg_to_rad(h * 0.5)) / DESIGN_ASPECT))
	return clampf(v, 1.0, 170.0)


func _apply_acknex_view(cam: Camera3D, pan_deg: float, tilt_deg: float, roll_deg: float = 0.0) -> void:
	var p := deg_to_rad(pan_deg)
	# Acknex tilt is usually ±90; WED sometimes stores 345 meaning −15.
	var tilt := tilt_deg
	if tilt > 180.0:
		tilt -= 360.0
	elif tilt < -180.0:
		tilt += 360.0
	var t := deg_to_rad(tilt)
	# Acknex ang_to_vec → Godot (x, z, -y)
	var fwd := Vector3(cos(p) * cos(t), sin(t), -sin(p) * cos(t))
	if fwd.length_squared() < 1e-8:
		fwd = Vector3(0, 0, -1)
	else:
		fwd = fwd.normalized()
	var target := cam.global_position + fwd
	if absf(fwd.dot(Vector3.UP)) > 0.99:
		cam.look_at(target, Vector3.FORWARD)
	else:
		cam.look_at(target, Vector3.UP)
	if not is_zero_approx(roll_deg):
		cam.rotate_object_local(Vector3.FORWARD, deg_to_rad(roll_deg))


func _active_cam() -> Node3D:
	for c in _cams:
		if int(c.get_meta("view_id", 0)) == view_index:
			return c
	return _cams[0] if _cams.size() > 0 else null


func _hide_cam_mesh(node: Node) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).visible = false
	for c in node.get_children():
		_hide_cam_mesh(c)


func _apply_random_building(node: Node3D) -> void:
	var house: String = HOUSES[randi() % HOUSES.size()]
	var glb_path := _resolve_glb(house)
	if glb_path == "":
		return
	var to_free: Array[Node] = []
	for c in node.get_children():
		if c is Area3D or c is MdlAnimator:
			continue
		to_free.append(c)
	for c in to_free:
		node.remove_child(c)
		c.free()
	var packed := load(glb_path)
	if packed is PackedScene:
		node.add_child((packed as PackedScene).instantiate())
	var pans: Array[float] = [0.0, 90.0, 180.0, 270.0]
	_set_entity_pan(node, pans[randi() % pans.size()])


func _resolve_glb(stem: String) -> String:
	var glb_stems: Array[String] = [stem, stem.to_lower()]
	for s in glb_stems:
		var direct: String = "res://assets/converted/mdl/%s.glb" % s
		if ResourceLoader.exists(direct):
			return direct
	var dir := DirAccess.open("res://assets/converted/mdl/")
	if dir == null:
		return ""
	var want := stem.to_lower() + ".glb"
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if fn.to_lower() == want:
			var path := "res://assets/converted/mdl/" + fn
			if ResourceLoader.exists(path):
				return path
		fn = dir.get_next()
	return ""


func _set_entity_tilt_roll(node: Node3D, tilt_deg: float, roll_deg: float) -> void:
	## Rebuild ang_to_matrix basis for a tilt/roll change, keeping authored
	## pan. Acknex tilt/roll rotate about the entity's OWN local axes (post
	## pan), not fixed world axes — hardcoded `rotation_degrees.x/z +=`
	## (Godot world/local axes) only coincidentally matches for pan=0.
	if node == null or not is_instance_valid(node):
		return
	var scl := node.transform.basis.get_scale()
	if scl.x <= 0.001 or scl.y <= 0.001 or scl.z <= 0.001:
		scl = Vector3.ONE
	var pan := float(node.get_meta("pan", 0.0))
	var b := _acknex_entity_basis_local(pan, tilt_deg, roll_deg)
	var pos := node.global_position
	node.global_transform = Transform3D(b * Basis.from_scale(scl.abs()), pos)
	node.set_meta("tilt", tilt_deg)
	node.set_meta("roll", roll_deg)


func _set_entity_roll(node: Node3D, roll_deg: float) -> void:
	_set_entity_tilt_roll(node, float(node.get_meta("tilt", 0.0)), roll_deg)


func _set_entity_pan(node: Node3D, pan_deg: float) -> void:
	## Rebuild ang_to_matrix basis for pure pan — preserves local scale.
	if node == null or not is_instance_valid(node):
		return
	var scl := node.transform.basis.get_scale()
	if scl.x <= 0.001 or scl.y <= 0.001 or scl.z <= 0.001:
		scl = Vector3.ONE
	var b := _acknex_entity_basis_local(pan_deg, 0.0, 0.0)
	var pos := node.global_position
	node.global_transform = Transform3D(b * Basis.from_scale(scl.abs()), pos)
	node.set_meta("pan", pan_deg)
	node.set_meta("tilt", 0.0)
	node.set_meta("roll", 0.0)


func _acknex_entity_basis_local(pan_deg: float, tilt_deg: float, roll_deg: float) -> Basis:
	## Conitec ang_to_matrix → Godot (same as WmbLevelLoader).
	var tilt := tilt_deg
	if tilt > 180.0:
		tilt -= 360.0
	elif tilt < -180.0:
		tilt += 360.0
	var p := deg_to_rad(pan_deg)
	var t := deg_to_rad(tilt)
	var r := deg_to_rad(roll_deg)
	var cp := cos(p)
	var sp := sin(p)
	var ct := cos(t)
	var st := sin(t)
	var cr := cos(r)
	var sr := sin(r)
	var x_dx := Vector3(ct * cp, st, ct * sp)
	var y_dx := Vector3(-cr * st * cp + sr * sp, cr * ct, -cr * st * sp - sr * cp)
	var z_dx := Vector3(-sr * st * cp - cr * sp, sr * ct, cr * cp - sr * st * sp)
	return Basis(
		Vector3(x_dx.x, x_dx.y, -x_dx.z),
		Vector3(y_dx.x, y_dx.y, -y_dx.z),
		Vector3(-z_dx.x, -z_dx.y, z_dx.z)
	)


func _nearest_path_name(origin: Vector3) -> String:
	var best := ""
	var best_d := INF
	for k in _paths.keys():
		var pts: PackedVector3Array = _paths[k]
		if pts.is_empty():
			continue
		var d := Vector2(pts[0].x - origin.x, pts[0].z - origin.z).length_squared()
		if d < best_d:
			best_d = d
			best = str(k)
	return best


func _start_patrol(node: Node3D, skills: Array) -> void:
	# Bind nearest WMB path (Town.wdl scan_path) — not a random pick.
	var pick := _nearest_path_name(node.global_position)
	if skills.size() > 19 and int(skills[19]) == 1:
		_make_clickable(node, "Taxi")
	if pick == "" or not _paths.has(pick):
		if _paths.is_empty():
			return
		pick = str(_paths.keys()[0])
	_patrols.append({
		"node": node,
		"path": pick,
		"index": 0,
		"speed": 12.0 + randf() * 8.0,
	})


func _update_patrols(delta: float) -> void:
	for p in _patrols:
		var node: Node3D = p["node"]
		if node == null or not is_instance_valid(node):
			continue
		var pts: PackedVector3Array = _paths[p["path"]]
		if pts.size() < 2:
			continue
		var idx: int = p["index"]
		var target: Vector3 = pts[idx]
		var pos := node.global_position
		var to := target - pos
		to.y = 0.0
		var dist := to.length()
		if dist < 2.0:
			p["index"] = (idx + 1) % pts.size()
			continue
		var step := minf(p["speed"] * delta, dist)
		var dir := to.normalized()
		node.global_position = pos + dir * step
		# Entity +X forward (Acknex pan), not Godot −Z.
		var pan_deg := rad_to_deg(atan2(-dir.z, dir.x))
		_set_entity_pan(node, pan_deg)
		_anim_cycle(node, "Walk")


func _make_clickable(node: Node3D, action: String) -> void:
	node.set_meta("click_action", action)
	_clickables.append(node)
	var has_area := false
	for c in node.get_children():
		if c is Area3D:
			has_area = true
			(c as Area3D).input_ray_pickable = true
			break
	if not has_area:
		var area := Area3D.new()
		area.collision_layer = 2
		area.collision_mask = 0
		area.input_ray_pickable = true
		var cs := CollisionShape3D.new()
		var shape := SphereShape3D.new()
		shape.radius = 28.0
		cs.shape = shape
		cs.position = _clickable_center_offset(node)
		area.add_child(cs)
		node.add_child(area)
	PiposhDebug.log_msg(
		"click-wire",
		"node=%s action=%s pos=%s had_existing_area=%s"
		% [node.name, action, str(node.global_position), has_area]
	)


## Same fix/reasoning as WdlInterpreter._clickable_center_offset() -- kept
## as a separate copy since this hand-wired click path (Plane2/Mansion-
## style `enable_click` props, see the comment above _start_patrol()'s
## caller) and the interpreter's own `my.enable_click = on` path live in
## different files with no shared base to put one copy in.
func _clickable_center_offset(node: Node3D) -> Vector3:
	var mi := _find_mesh_instance(node)
	if mi == null:
		return Vector3.ZERO
	var world_center: Vector3 = mi.global_transform * mi.get_aabb().get_center()
	return node.to_local(world_center)


func _find_mesh_instance(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var found := _find_mesh_instance(c)
		if found:
			return found
	return null


func _try_click() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		cam = _world_camera
	if cam == null:
		return
	var from := cam.project_ray_origin(get_viewport().get_mouse_position())
	var dir := cam.project_ray_normal(get_viewport().get_mouse_position())
	var space := cam.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 8000.0)
	q.collide_with_areas = true
	q.collide_with_bodies = true
	q.collision_mask = 0xFFFFFFFF
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		PiposhDebug.log_msg("click-hit", "MISS (no collider under cursor)")
		return
	var collider: Node = hit.get("collider") as Node
	var n: Node = collider
	while n:
		if n.has_meta("click_action") or n.has_meta("action"):
			var resolved := str(n.get_meta("click_action", n.get_meta("action", "")))
			PiposhDebug.log_msg(
				"click-hit",
				"collider=%s resolved_node=%s action=%s point=%s"
				% [collider.name, n.name, resolved, str(hit.get("position"))]
			)
			_handle_click_action(resolved, n as Node3D)
			return
		n = n.get_parent()
	PiposhDebug.log_msg(
		"click-hit",
		"collider=%s had no click_action/action in its ancestry" % collider.name
	)


func handle_action(action: String) -> void:
	_handle_click_action(action, null)


func _handle_click_action(action: String, node: Node3D = null) -> void:
	if node != null and node.has_meta("afg_card_index"):
		# Afgan.wdl collectible: needs a Godot-side persistence + HUD-feedback
		# hook WDL alone can't express (GameState.afg/save_slot — Acknex's
		# own WriteGameData()/PANEL system has no equivalent here). Must run
		# before the generic wdl_event dispatch below: this entity's own
		# `my.event = AFG_Take;` (set by its action coroutine, see setup()'s
		# AFG_Card handling) would otherwise route through invoke_event()
		# instead, which only mutates the interpreter's own ephemeral AFG[]
		# global (lost on level change, never saved) and can't show the
		# collected-card HUD feedback (AFG_Show is an unbridged PANEL
		# reference). Confirmed as a real regression introduced by this
		# session's own wdl_event-priority click fix — see docs/SESSION_LOG.md
		# 2026-07-30.
		_run_afg_take(node)
		return
	if node != null and _wdl_interp != null and node.has_meta("wdl_event"):
		# Generic interpreter-driven click dispatch (PORTING_MANUAL.md
		# "applies to all levels at once"): if the clicked entity's own WDL
		# action assigned `my.event = X` while running under the
		# interpreter, that assignment is authoritative and takes priority
		# over every hardcoded action-string branch below.
		var ev := str(node.get_meta("wdl_event"))
		PiposhDebug.log_msg(
			"click-hit-interp", "node=%s wdl_event=%s -> WdlInterpreter.invoke_event()" % [node.name, ev]
		)
		_wdl_interp.invoke_event(node, ev)
		return
	var map := {
		"Taxi": "Taxi", "GoToTaxi": "Taxi",
		"Inn": "Inn", "GoToInn": "Inn",
		"MOI": "MOI", "GoToMOI": "MOI",
		"Travel": "Travel", "GoToTravel": "Travel",
		"GoToDesert": "Map", "ReturnToMap": "Map",
	}
	if map.has(action):
		status.emit("WDL Run(\"%s.exe\")" % map[action])
		request_run.emit(str(map[action]))
		return
	# Uniform: any clickable whose action is a known level name → Run.
	var level_name := action
	if action.to_lower().begins_with("goto") and action.length() > 4:
		level_name = action.substr(4)
	var json_path := "res://assets/converted/levels/%s.json" % level_name
	var json_alt := "res://assets/converted/levels/%s.json" % level_name.capitalize()
	if ResourceLoader.exists(json_path) or FileAccess.file_exists(json_path) \
			or ResourceLoader.exists(json_alt) or FileAccess.file_exists(json_alt):
		status.emit("WDL Run(\"%s.exe\")" % level_name)
		request_run.emit(level_name)
		return
	status.emit("WDL action: %s" % action)


func _run_afg_take(node: Node3D) -> void:
	## Afgan.wdl AFG_Take: AFG[my.skill1]=1; WriteGameData(0); remove(my);
	## plus a HUD "card shown" fade the original does via AFG_Show. Persisting
	## the flag + removing the entity is the gameplay-relevant part: without
	## it the same card could be picked up again every visit.
	if node == null:
		return
	var card_i := int(node.get_meta("afg_card_index", -1))
	if card_i < 0 or card_i >= GameState.afg.size():
		return
	GameState.afg[card_i] = 1
	GameState.save_slot(0)
	status.emit("Afgan card %d collected" % card_i)
	node.queue_free()
	_show_afg_card(card_i)


func _find_first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var m := _find_first_mesh(c)
		if m:
			return m
	return null


func _show_afg_card(card_i: int) -> void:
	## Afgan.wdl AFG_Show: a view=camera LeCards.mdl entity, skin=my.skill1,
	## visible ~60 ticks then alpha-fades out. Simplified here: shown as a
	## flat, unshaded quad parented to the active camera (so it reads as a
	## HUD card) for a fixed duration, no alpha ramp.
	## Must attach to whichever Camera3D is actually rendering right now —
	## _world_camera is the scripted-cam reference and is NOT current in
	## first-person levels (Plane2), which is why the card didn't show
	## there even though pickup worked (see docs/SESSION_LOG.md).
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		cam = _world_camera
	if cam == null:
		return
	var path := "res://assets/converted/mdl/LeCards.glb"
	if not ResourceLoader.exists(path):
		return
	var packed := load(path)
	if not (packed is PackedScene):
		return
	var card := (packed as PackedScene).instantiate() as Node3D
	if card == null:
		return
	cam.add_child(card)
	const CARD_SCALE := 0.12
	const CARD_DIST := 30.0
	card.position = Vector3(8.0, -4.0, -CARD_DIST)
	card.scale = Vector3.ONE * CARD_SCALE
	card.rotation_degrees = Vector3.ZERO
	var anim := MdlAnimator.new()
	anim.name = "MdlAnimator"
	card.add_child(anim)
	if anim.setup_from_stem("LeCards", card):
		anim.set_skin(card_i)
	var card_mesh := _find_first_mesh(card)
	PiposhDebug.log_msg(
		"afg-card",
		"card_i=%d mesh_aabb=%s scale=%.2f dist=%.1f"
		% [
			card_i,
			str(card_mesh.get_aabb()) if card_mesh else "no mesh found",
			CARD_SCALE,
			CARD_DIST,
		]
	)
	var t := get_tree().create_timer(3.0)
	t.timeout.connect(func() -> void:
		if is_instance_valid(card):
			card.queue_free()
	)


func _anim_cycle(node: Node3D, clip: String) -> void:
	if node == null or not is_instance_valid(node):
		return
	var anim := node.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.play_cycle(clip, 0.0)


func _anim_frame(node: Node3D, clip: String, percent: float) -> void:
	if node == null or not is_instance_valid(node):
		return
	var anim := node.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.play_frame(clip, percent)


func _anim_talk(node: Node3D) -> void:
	if node == null or not is_instance_valid(node):
		return
	var anim := node.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.play_talk()


func _anim_blink(node: Node3D) -> void:
	if node == null or not is_instance_valid(node):
		return
	var anim := node.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.play_blink()


func _anim_talk_skins(node: Node3D, enabled: bool) -> void:
	if node == null or not is_instance_valid(node):
		return
	var anim := node.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.enable_talk_skins(enabled)


func _anim_set_skin(node: Node3D, skin: int) -> void:
	if node == null or not is_instance_valid(node):
		return
	var anim := node.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim:
		anim.set_skin(skin)


func _apply_mouse_mode() -> void:
	if _hud:
		_hud.set_mouse_look(mouse_look)
	elif mouse_look:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
