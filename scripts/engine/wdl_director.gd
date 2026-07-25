extends Node
class_name WdlDirector
## WDL-derived level behaviour: cameras, mouse modes, panels, dialogs, anims.

signal status(msg: String)
signal request_run(level_name: String)

const HOUSES: Array[String] = [
	"House1", "House2", "House3", "House4", "House5",
	"House6", "House7", "House8", "House9", "House10",
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

var talking := 0
var scene := 0
var dance := 1
var genia := 0
var _level_script := ""
var _start_active := false
var _scene_timer := 0.0
var _scene_hold := false
var _yachdal: Node3D
var _look_at_me: Node3D
var _look_at_mes: Array[Node3D] = []
var _far_cam: Node3D
var _the_cam: Node3D
var _the_cam2: Node3D
var _ami: Node3D
var _naknik: Node3D
var _crowds: Array[Node3D] = []
var _dialog_busy := false
var _studio_boot := false
var _look_path: PackedVector3Array = PackedVector3Array()
var _look_path_i := 0
var _lock_y := 0.0
## Start.wdl only copies camera.x/y from LookAtMe — height stays locked.
var _cam_lock_y := 0.0
var _cam_height_locked := false
var _skip_line := false
## Smoothed scripted-camera pose (avoids TheCam↔TheCam2 "falling" jumps).
var _cam_follow: Node3D = null
var _cam_pos := Vector3.ZERO
var _cam_pos_ready := false
const CAM_FOLLOW_SPEED := 6.0

## Shiks.wdl state
var _piposh2: Node3D
var _piposh3: Node3D
var _shik_x: Node3D
var _my_camera: Node3D
var _pipi_cams: Array[Node3D] = []
var _shtomba: Node3D
var _vase: Node3D
var _turn_vase: Node3D
var _weasel: Node3D
var _bus: Node3D
var _water_wheel: Node3D
var _pipis: Array[Node3D] = []
var _stand_here_x := 0.0
var _ztemp := 0.0
var _shiks_active := false
var _cam_show := 1
var _piposh_skill2 := 1
var _dialog_index := 0
var _shiks_path: PackedVector3Array = PackedVector3Array()
var _shiks_path_i := 0
var _shiks_walking := false
var _shiks_fly := false
var _walk_away := false


func setup(loader: WmbLevelLoader, camera: Camera3D, level_data: Dictionary, hud: GameHud = null) -> void:
	_loader = loader
	_world_camera = camera
	_hud = hud
	_cams.clear()
	_patrols.clear()
	_clickables.clear()
	_paths.clear()
	_crowds.clear()
	_look_at_mes.clear()
	_yachdal = null
	_look_at_me = null
	_far_cam = null
	_the_cam = null
	_the_cam2 = null
	_ami = null
	_naknik = null
	_piposh2 = null
	_piposh3 = null
	_shik_x = null
	_my_camera = null
	_pipi_cams.clear()
	_shtomba = null
	_vase = null
	_turn_vase = null
	_weasel = null
	_bus = null
	_water_wheel = null
	_pipis.clear()
	talking = 0
	scene = 0
	dance = 1
	genia = 0
	_start_active = false
	_scene_timer = 0.0
	_scene_hold = false
	_dialog_busy = false
	_studio_boot = false
	_look_path = PackedVector3Array()
	_look_path_i = 0
	_cam_lock_y = 0.0
	_cam_height_locked = false
	_skip_line = false
	_cam_follow = null
	_cam_pos_ready = false
	_shiks_active = false
	_cam_show = 1
	_piposh_skill2 = 1
	_dialog_index = 0
	_shiks_path = PackedVector3Array()
	_shiks_path_i = 0
	_shiks_walking = false
	_shiks_fly = false
	_walk_away = false
	_stand_here_x = 0.0
	_ztemp = 0.0
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
		match action:
			"Cam", "Cammy", "SCam":
				cam_i += 1
				var skill1 := int(round(float(skills[0]))) if skills.size() > 0 else 0
				var vid := skill1 if skill1 > 0 else cam_i
				node.set_meta("view_id", vid)
				_cams.append(node)
				_hide_cam_mesh(node)
			"MyCamera":
				_my_camera = node
				_cams.append(node)
				_hide_cam_mesh(node)
			"PipiCam":
				_pipi_cams.append(node)
				_cams.append(node)
				_hide_cam_mesh(node)
			"TheCam":
				_the_cam = node
				_hide_cam_mesh(node)
			"TheCam2":
				_the_cam2 = node
				_hide_cam_mesh(node)
			"FarCam":
				_far_cam = node
				_hide_cam_mesh(node)
			"RandomBuilding":
				_apply_random_building(node)
			"PatrolCity", "SportCar":
				_start_patrol(node, skills)
				_anim_cycle(node, "Walk")
			"Taxi", "Inn", "MOI", "Travel", "Pisa", "Kazale":
				_make_clickable(node, action)
			"GoToTaxi", "GoToInn", "GoToMOI", "GoToTravel", "GoToDesert":
				_make_clickable(node, action)
			"Ami":
				_ami = node
				_make_clickable(node, "StartDialog")
				_anim_blink(node)
			"Naknik":
				_naknik = node
				# Studio.wdl: my.skin = 9 (clamped to available skins).
				_anim_set_skin(node, 9)
				_anim_blink(node)
			"StartDialog":
				_make_clickable(node, "StartDialog")
			"DefineYachdel":
				_yachdal = node
				_anim_frame(node, "Speech", 0.0)
			"LookAtMe":
				_look_at_mes.append(node)
				_hide_cam_mesh(node)
				node.set_meta("lock_y", node.global_position.y)
				node.set_meta("path_name", _nearest_path_name(node.global_position))
				if _look_at_me == null:
					_look_at_me = node
			"Crowd":
				_crowds.append(node)
				_anim_cycle(node, "Frame")
			"Cow", "Cow2", "Arrow1", "Arrow2", "Ship", "Falling", "PisaFall":
				_anim_cycle(node, "Frame")
			"DrawBridge":
				_anim_frame(node, "Closed", 0.0)
			"ShikNote":
				_make_clickable(node, "ShikKlik")
			"AFG_Card":
				# Visible notepad next to ShikNote — same click → Shiks.
				_make_clickable(node, "ShikKlik")
			"Dummy":
				# Studio.wdl Dummy = room tone; Shiks.wdl Dummy only stores XX.
				if _is_studio_level():
					AudioBus.play_sfx("SFX105.WAV", -8.0)
			"Piposh2":
				_piposh2 = node
				_anim_frame(node, "Stand", 0.0)
			"Piposh3":
				_piposh3 = node
				_anim_frame(node, "Stand", 0.0)
			"ShikX":
				_shik_x = node
				_anim_frame(node, "Stand", 0.0)
			"Shik1":
				_ztemp = node.global_position.y
			"StandHere":
				_stand_here_x = node.global_position.x
			"Shtomba":
				_shtomba = node
			"Vase":
				_vase = node
			"TurnVase":
				_turn_vase = node
				node.visible = false
			"Weasel":
				_weasel = node
				node.visible = false
			"Bus":
				_bus = node
			"WaterWheel":
				_water_wheel = node
				# Shiks.wdl: loop Lake = SFX100 while the wheel turns.
				AudioBus.play_music("SFX100.WAV", -12.0)
			"Pipi":
				_pipis.append(node)
				node.visible = false
			"Watrfall":
				# Prefer waterfall Mapal if present; else lake already from wheel.
				AudioBus.play_music("SFX140.WAV", -10.0)
			_:
				pass

	# WED skills for PipiCam are empty — assign CamShow 3..8 in list order.
	for i in _pipi_cams.size():
		var pc := _pipi_cams[i]
		var sk := int(round(float(pc.get_meta("skills", [0])[0]))) if pc.get_meta("skills", []).size() > 0 else 0
		if sk < 3:
			sk = 3 + i
		pc.set_meta("cam_show", sk)
		pc.set_meta("view_id", sk)

	if _hud and not _hud.dialog_choice.is_connected(_on_dialog_choice):
		_hud.dialog_choice.connect(_on_dialog_choice)
	if _hud and not _hud.skip_line_pressed.is_connected(_on_skip_line_pressed):
		_hud.skip_line_pressed.connect(_on_skip_line_pressed)

	scripted_camera = (
		_cams.size() > 0
		or _the_cam != null
		or _the_cam2 != null
		or _look_at_me != null
	)

	if _is_start_level():
		_begin_start_sequence()
	elif _is_studio_level():
		_begin_studio_sequence()
	elif _is_town_level():
		_begin_town()
	elif _is_shiks_level():
		_begin_shiks()
	elif scripted_camera:
		mouse_look = true
		_apply_mouse_mode()
		view_index = 1
		_snap_to_active_cam(true)
		status.emit("Cam mode — RMB toggles cursor, V=view, scroll=zoom")
	else:
		status.emit("Free player camera")


func _process(delta: float) -> void:
	if _is_start_level() and _start_active:
		_update_start(delta)
	elif _is_studio_level():
		_update_studio(delta)
	elif _is_shiks_level() and _shiks_active:
		_update_shiks(delta)
	elif scripted_camera:
		_update_town_cam()
	_update_patrols(delta)
	if _hud and _is_town_level():
		# Town.wdl Zoom = ((60 - camera.arc) / 4) + 1
		var z := int(((60.0 - fov_arc) / 4.0) + 1.0)
		_hud.set_zoom_digit(z)


func _on_skip_line_pressed() -> void:
	# Same as Space during voice / intro — advances the current line.
	if _is_start_level() and _start_active:
		AudioBus.stop_sfx()
		_advance_start_scene(true)
		return
	if _is_shiks_level() and _shiks_active and not _dialog_busy and _dialog_index == 1 and _piposh_skill2 == 1:
		_start_shiks_fly()
		return
	# Any in-progress voice line (Studio boot/dialogs, Shiks walk-in, etc.)
	if _studio_boot or _dialog_busy or _shiks_walking or AudioBus.is_voice_playing():
		_skip_line = true
		AudioBus.stop_sfx()
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
		if event.button_index == MOUSE_BUTTON_RIGHT and (_is_town_level() or _is_studio_level()):
			# IO.wdl mouse_toggle
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

	if event is InputEventMouseMotion and mouse_look and _is_town_level():
		# Town.wdl Cam: pan/tilt -= mickey/5 while mouse_mode==0
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


func _is_shiks_level() -> bool:
	return _level_script.contains("shik") or str(_loader.level_name).to_lower() == "shiks"


func _begin_shiks() -> void:
	scripted_camera = true
	mouse_look = false
	_shiks_active = true
	_cam_show = 1
	_piposh_skill2 = 1
	_dialog_index = 0
	scene = 1
	_shiks_walking = true
	_shiks_fly = false
	_walk_away = false
	_apply_mouse_mode()
	# Prefer path_002 (7 pts) for MyCamera flyby.
	_shiks_path = PackedVector3Array()
	for k in _paths.keys():
		var pts: PackedVector3Array = _paths[k]
		if pts.size() >= 7:
			_shiks_path = pts
			break
	if _shiks_path.is_empty() and _paths.size() > 0:
		var first_key: String = str(_paths.keys()[0])
		_shiks_path = _paths[first_key]
	_shiks_path_i = 0
	if _my_camera:
		_cam_follow = _my_camera
		if _ztemp != 0.0:
			_my_camera.global_position.y = _ztemp
		_copy_cam(_my_camera, true)
	if _hud:
		_hud.set_mouse_look(false)
	# Ensure lake ambience even if WaterWheel/Watrfall bind order differed.
	if not AudioBus.is_music_playing():
		AudioBus.play_music("SFX100.WAV", -12.0)
	status.emit("Shiks — Piposh arrives…")
	_run_shiks_boot()


func _run_shiks_boot() -> void:
	# Shiks.wdl Piposh2: sPlay SHK003 while walking to StandHere.
	AudioBus.play_sfx("SHK003.WAV")
	var t := 0.0
	while _shiks_walking and t < 40.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		if _skip_line:
			_skip_line = false
			break
	_shiks_walking = false
	if _piposh2:
		_anim_frame(_piposh2, "Stand", 0.0)
	scene = 2
	_dialog_index = 1
	_dialog_busy = false
	if _hud:
		_hud.show_dialog(1)
	status.emit("Shiks — choose a line")


func _update_shiks(delta: float) -> void:
	_apply_shiks_cam()
	if _water_wheel:
		_water_wheel.rotation_degrees.z += 5.0 * delta * 16.0
	if _turn_vase and _turn_vase.visible:
		_turn_vase.rotation_degrees.x += 20.0 * delta * 16.0
		_turn_vase.rotation_degrees.z += 20.0 * delta * 16.0
	if _shtomba and _piposh2 and _piposh_skill2 < 4:
		_shtomba.global_position = _piposh2.global_position + Vector3(-5.0, 20.0, 0.0)

	if _shiks_walking and _piposh2:
		_anim_cycle(_piposh2, "Walk")
		var speed := 40.0
		_piposh2.global_position.x = move_toward(
			_piposh2.global_position.x, _stand_here_x + 2.0, speed * delta
		)
		if _piposh2.global_position.x >= _stand_here_x:
			_shiks_walking = false

	if _walk_away and _piposh2:
		_anim_cycle(_piposh2, "Walk")
		_piposh2.global_position.x += 55.0 * delta
		# Hit Bumpin region → start camera path (Shiks.wdl Bumped).
		if _piposh2.global_position.x > -160.0 and _piposh_skill2 == 1:
			_start_shiks_fly()

	if _shiks_fly and _my_camera and _shiks_path.size() > 0:
		var idx := mini(_shiks_path_i, _shiks_path.size() - 1)
		var target := _shiks_path[idx]
		var pos := _my_camera.global_position
		var to := Vector3(target.x - pos.x, 0.0, target.z - pos.z)
		if to.length() < 12.0:
			_shiks_path_i += 1
			if _shiks_path_i >= mini(7, _shiks_path.size()):
				_shiks_fly = false
				_piposh_skill2 = 4
				_dialog_index = 2
				_dialog_busy = false
				if _hud:
					_hud.show_dialog(2)
				status.emit("Shiks — dialog 2")
				return
		else:
			var step := to.normalized() * minf(80.0 * delta, to.length())
			_my_camera.global_position = pos + step
			if _ztemp != 0.0:
				_my_camera.global_position.y = _ztemp
			# Face travel direction (Acknex actor_turnto).
			var pan := rad_to_deg(atan2(-step.z, step.x))
			_my_camera.set_meta("pan", pan)
			_my_camera.set_meta("tilt", 0.0)

	_update_shiks_actors(delta)


func _update_shiks_actors(delta: float) -> void:
	if talking == 1 and _piposh3:
		_anim_cycle(_piposh3, "Talk")
	elif talking == 2 and _shik_x:
		_anim_cycle(_shik_x, "Talk")
	elif talking == 22 and _shik_x:
		_anim_frame(_shik_x, "Scream", 0.0)
	elif talking == 11 and _piposh3:
		_anim_cycle(_piposh3, "Dumb")
		if _turn_vase:
			_turn_vase.visible = true
	elif talking == 12 and _piposh3:
		_anim_cycle(_piposh3, "Walk")
		_piposh3.global_position += Vector3(-10.0, 0.0, 10.0) * delta
		if _shik_x:
			var to := _piposh3.global_position - _shik_x.global_position
			_shik_x.rotation_degrees.y = rad_to_deg(atan2(-to.z, to.x))
	elif talking == 13 and _piposh3:
		_piposh3.visible = false

	for p in _pipis:
		if _cam_show == 3:
			p.visible = true
		elif _cam_show == 8:
			p.visible = false
	if _weasel:
		_weasel.visible = _cam_show == 6
		if _cam_show == 6:
			_anim_cycle(_weasel, "Frame")
	if _bus and _cam_show == 8:
		_bus.global_position.z += 100.0 * delta


func _apply_shiks_cam() -> void:
	if _world_camera == null:
		return
	var cam: Node3D = null
	if _cam_show == 1 and _my_camera:
		cam = _my_camera
	else:
		for pc in _pipi_cams:
			if int(pc.get_meta("cam_show", 0)) == _cam_show:
				cam = pc
				break
	if cam == null:
		cam = _cam_follow
	if cam:
		_cam_follow = cam
		_copy_cam(cam, true)


func _start_shiks_fly() -> void:
	if _piposh_skill2 >= 2:
		return
	_walk_away = false
	_piposh_skill2 = 2
	_shiks_fly = true
	_shiks_path_i = 0
	if _hud:
		_hud.hide_dialog()
	if _my_camera and _shiks_path.size() > 0:
		var p0 := _shiks_path[0]
		_my_camera.global_position = Vector3(p0.x, _ztemp if _ztemp != 0.0 else p0.y, p0.z)
	status.emit("Shiks — camera fly…")


func _run_shiks_choice(choice: int) -> void:
	_dialog_busy = true
	if _hud:
		_hud.hide_dialog()
	if _dialog_index == 1:
		match choice:
			1:
				await _line("PIP012.WAV", 1, _piposh2)
				await _line("SHK004.WAV", 2, _shik_x)
			2:
				await _line("PIP013.WAV", 1, _piposh2)
				await _line("SHK005.WAV", 2, _shik_x)
				await _line("PIP014.WAV", 1, _piposh2)
				await _line("SHK006.WAV", 2, _shik_x)
				await _line("PIP015.WAV", 1, _piposh2)
			3:
				await _line("PIP016.WAV", 1, _piposh2)
				await _line("SHK007.WAV", 2, _shik_x)
				_walk_away = true
				_dialog_busy = false
				talking = 0
				status.emit("Shiks — Piposh walks on…")
				return
		# Choices 1/2: bump into the path after a short beat (Space/FF also works).
		_dialog_busy = false
		talking = 0
		await get_tree().create_timer(0.4).timeout
		_start_shiks_fly()
		return

	if _dialog_index == 2:
		match choice:
			1:
				await _line("PIP017.WAV", 1, _piposh3)
				await _line("SHK010.WAV", 2, _shik_x)
				await _line("PIP018.WAV", 1, _piposh3)
				await _line("SHK011.WAV", 2, _shik_x)
			2:
				if _vase:
					_vase.visible = false
				await _line("PIP019.WAV", 1, _piposh3)
				await _line("SHK012.WAV", 2, _shik_x)
				await _line("PIP020.WAV", 1, _piposh3)
				await _line("SHK015.WAV", 2, _shik_x)
				talking = 12
				await _line("PIP024.WAV", 12, _piposh3)
				await _shiks_ending_montage()
				_dialog_busy = false
				return
			3:
				if _vase:
					_vase.visible = false
				await _line("PIP021.WAV", 1, _piposh3)
				await _line("PIP022.WAV", 11, _piposh3)
				await _line("SHK013.WAV", 2, _shik_x)
				await _line("PIP023.WAV", 1, _piposh3)
				await _line("SHK014.WAV", 22, _shik_x)
		talking = 0
		_dialog_busy = false
		if _hud:
			_hud.show_dialog(2)
		status.emit("Shiks — choose again / Space skips")


func _shiks_ending_montage() -> void:
	# CamShow 3..8 with SHK016…PIP027 then Plane.
	var shots: Array = [
		[3, 13, "SHK016.WAV", null],
		[4, 14, "PIP025.WAV", null],
		[5, 15, "SHK017.WAV", null],
		[6, 16, "PIP026.WAV", null],
		[7, 17, "SHK018.WAV", null],
		[8, 18, "PIP027.WAV", null],
	]
	for s in shots:
		_cam_show = int(s[0])
		talking = int(s[1])
		_apply_shiks_cam()
		await _line(str(s[2]), talking, null)
	status.emit("Shiks → Plane")
	request_run.emit("Plane")


func _apply_mouse_mode() -> void:
	if _hud:
		_hud.set_mouse_look(mouse_look)
	elif mouse_look:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _begin_start_sequence() -> void:
	_start_active = true
	scene = 0
	_scene_timer = 0.0
	scripted_camera = true
	mouse_look = true  # no cursor look during intro
	if _hud:
		_hud.setup_start_subtitles()
		_hud.set_mouse_look(true)
	# Bind each LookAtMe to its nearest path (Start.wdl scan_path).
	for lam in _look_at_mes:
		var lock_y: float = float(lam.get_meta("lock_y", lam.global_position.y))
		lam.set_meta("lock_y", lock_y)
		var pname := str(lam.get_meta("path_name", ""))
		if pname == "" or not _paths.has(pname):
			pname = _nearest_path_name(lam.global_position)
			lam.set_meta("path_name", pname)
		if pname != "" and _paths.has(pname):
			var pts: PackedVector3Array = _paths[pname]
			if pts.size() > 0:
				lam.global_position = Vector3(pts[0].x, lock_y, pts[0].z)
	if _look_at_me:
		_lock_y = float(_look_at_me.get_meta("lock_y", _look_at_me.global_position.y))
		_cam_lock_y = _lock_y
		_cam_height_locked = true
		var pn := str(_look_at_me.get_meta("path_name", ""))
		_look_path = _paths[pn] if _paths.has(pn) else PackedVector3Array()
	_look_path_i = 0
	status.emit("Start intro — Space skips, Esc=Menu")
	AudioBus.play_sfx("SFX097.WAV", -6.0)
	_play_start_voice()


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


func _update_start(delta: float) -> void:
	_scene_timer += delta
	_move_look_at_me(delta)

	if scene == 4 and _far_cam != null:
		_copy_cam(_far_cam)
	elif _look_at_me != null:
		_apply_start_camera()

	if _yachdal and scene in [0, 2, 4] and Engine.get_process_frames() % 45 == 0:
		_anim_frame(_yachdal, "Speech", randf() * 100.0)
	elif _yachdal and scene in [1, 3, 5]:
		_anim_frame(_yachdal, "Speech", 0.0)

	# Scene 3: Shkufit hold (Start.wdl)
	if scene == 3:
		if _hud:
			_hud.set_shkufit(true)
		if not _scene_hold:
			_scene_hold = true
			_scene_timer = 0.0
			AudioBus.stop_sfx()
		if _scene_timer > 1.25:  # Delay ~20 ticks
			_scene_hold = false
			if _hud:
				_hud.set_shkufit(false)
			scene = 4
			_scene_timer = 0.0
			_play_start_voice()
		return

	if _hud:
		_hud.set_shkufit(false)

	var voice_done := not AudioBus.is_voice_playing()
	if _scene_timer > 10.0 or (voice_done and _scene_timer > 2.0):
		_advance_start_scene(false)


func _move_look_at_me(delta: float) -> void:
	# Only move during scenes 0/2 (flag1 off) or 1/5 (flag1 on LookAtMe).
	var moving := scene in [0, 2] or (scene in [1, 5] and _look_at_mes.size() > 1)
	if not moving:
		return
	var node := _look_at_me
	if scene in [1, 5] and _look_at_mes.size() > 1:
		node = _look_at_mes[1]
	if node == null:
		return
	var lock_y: float = float(node.get_meta("lock_y", node.global_position.y))
	var pname := str(node.get_meta("path_name", ""))
	if pname == "" or not _paths.has(pname):
		return
	var pts: PackedVector3Array = _paths[pname]
	if pts.size() < 2:
		return
	var idx := int(node.get_meta("path_i", 0))
	var target := pts[idx % pts.size()]
	var pos := node.global_position
	var to := Vector3(target.x - pos.x, 0.0, target.z - pos.z)
	if to.length() < 8.0:
		node.set_meta("path_i", mini(idx + 1, pts.size() - 1))
		return
	var speed := 25.0 if scene in [0, 2] else 8.0
	node.global_position = pos + to.normalized() * minf(speed * delta, to.length())
	node.global_position.y = lock_y


func _apply_start_camera() -> void:
	if _world_camera == null or _look_at_me == null:
		return
	var node := _look_at_me
	if scene in [1, 5] and _look_at_mes.size() > 1:
		node = _look_at_mes[1]
	# Start.wdl: camera.x/y = my.x/y — do NOT copy entity Z (Godot Y).
	if not _cam_height_locked:
		_cam_lock_y = float(_look_at_me.get_meta("lock_y", _look_at_me.global_position.y))
		_cam_height_locked = true
	_world_camera.global_position = Vector3(node.global_position.x, _cam_lock_y, node.global_position.z)
	if scene in [0, 2] and _yachdal != null:
		var look := _yachdal.global_position
		look.y = _cam_lock_y
		_world_camera.look_at(look, Vector3.UP)
	elif scene in [1, 5]:
		# Start.wdl: camera.pan = 270
		_apply_acknex_view(_world_camera, 270.0, 0.0, 0.0)
	else:
		_world_camera.global_rotation = node.global_rotation
	_world_camera.fov = 60.0
	_world_camera.current = true


func _advance_start_scene(force: bool) -> void:
	if scene == 3 and not force:
		return
	if force and scene == 3:
		_scene_hold = false
		if _hud:
			_hud.set_shkufit(false)
	scene += 1
	if scene == 3:
		_scene_timer = 0.0
		_scene_hold = false
		status.emit("Start scene 3 (Shkufit)")
		return
	_scene_timer = 0.0
	if scene >= 6:
		if _hud:
			_hud.clear_subtitles()
		status.emit("Start → Menu")
		request_run.emit("Menu")
		_start_active = false
		return
	status.emit("Start scene %d" % scene)
	_play_start_voice()


func _play_start_voice() -> void:
	var map := {
		0: "YCH003.WAV",
		1: "CRD001.WAV",
		2: "YCH004.WAV",
		4: "YCH005.WAV",
		5: "CRD002.WAV",
	}
	if map.has(scene):
		AudioBus.play_sfx(str(map[scene]))


func ensure_scripted_view() -> void:
	## Called by LevelRunner so the first frame isn't a free-player / origin view.
	scripted_camera = true
	if _is_studio_level():
		_snap_studio_cam()
	elif _is_start_level() and _look_at_me != null:
		_apply_start_camera()
	elif _is_shiks_level():
		_apply_shiks_cam()
	elif _cams.size() > 0:
		_snap_to_active_cam(true)
	if _world_camera:
		_world_camera.current = true


func _begin_studio_sequence() -> void:
	scripted_camera = true
	mouse_look = false  # enable_click on Ami
	_studio_boot = true
	scene = 0
	talking = 0
	dance = 1
	if _hud:
		_hud.setup_studio_subtitles()
		_hud.set_mouse_look(false)
	_snap_studio_cam()
	status.emit("Studio intro…")
	_run_studio_boot()


func _run_studio_boot() -> void:
	# Studio.wdl SetVoice chain
	await _line("Wait.wav", 0, null)
	scene = 1
	talking = 1
	dance = 1
	if _naknik:
		_anim_cycle(_naknik, "Dance")
		_anim_talk_skins(_naknik, true)  # Talk2 during Dance
	await _line("SNG010.WAV", 1, _naknik)
	scene = 2
	dance = 0
	talking = 2
	if _naknik:
		_anim_blink(_naknik)
	await _line("AMI001.WAV", 2, _ami)
	scene = 3
	talking = 0
	_studio_boot = false
	if _hud:
		_hud.show_dialog(0)
	status.emit("Studio — choose a line / click Ami")


func _update_studio(_delta: float) -> void:
	# Studio.wdl: TheCam while Piposh talks (Talking==1); TheCam2 otherwise.
	_apply_studio_cam()
	if dance == 1 and _naknik:
		_anim_cycle(_naknik, "Dance")
		_anim_talk_skins(_naknik, true)
		if talking == 2 and _ami:
			_anim_talk(_ami)
		elif talking != 2 and _ami:
			_anim_blink(_ami)
		return
	if talking == 1 and _naknik:
		_anim_talk(_naknik)
		if _ami:
			_anim_blink(_ami)
	elif talking == 2 and _ami:
		_anim_talk(_ami)
		if _naknik:
			_anim_blink(_naknik)
	else:
		_anim_blink(_ami)
		_anim_blink(_naknik)


func _apply_studio_cam() -> void:
	# TheCam = Piposh close-up; TheCam2 = Ami / idle wide shot.
	var cam: Node3D = null
	if talking == 1 and _the_cam != null:
		cam = _the_cam
	elif _the_cam2 != null:
		cam = _the_cam2
	else:
		cam = _the_cam
	if cam == null:
		return
	_cam_follow = cam
	_copy_cam(cam, true)


func _begin_town() -> void:
	scripted_camera = _cams.size() > 0
	mouse_look = true
	fov_arc = 60.0
	view_index = 1
	if _hud:
		_hud.setup_town_bio()
		_hud.set_zoom_digit(1)
	_apply_mouse_mode()
	_snap_to_active_cam(true)
	status.emit("Town — RMB cursor/look, V view, wheel zoom, click Inns/Taxi")


func _update_town_cam() -> void:
	var cam := _active_cam()
	if cam == null or _world_camera == null:
		return
	_copy_cam(cam)
	_world_camera.fov = maxf(fov_arc, 1.0)


func _snap_studio_cam() -> void:
	_apply_studio_cam()


func _snap_to_active_cam(_reset_look: bool) -> void:
	var cam := _active_cam()
	if cam:
		_copy_cam(cam, true)


func _apply_cam_smooth(cam: Node3D, delta: float) -> void:
	if cam == null or _world_camera == null:
		return
	var target_pos := cam.global_position
	if not _cam_pos_ready:
		_cam_pos = target_pos
		_cam_pos_ready = true
		_copy_cam(cam, true)
		return
	# Exponential blend — kills the multi-metre Y jump between studio cams.
	var k := 1.0 - exp(-CAM_FOLLOW_SPEED * delta)
	_cam_pos = _cam_pos.lerp(target_pos, k)
	_world_camera.global_position = _cam_pos
	var pan: float = float(cam.get_meta("pan", 0.0))
	var tilt: float = float(cam.get_meta("tilt", 0.0))
	var roll: float = float(cam.get_meta("roll", 0.0))
	_apply_acknex_view(_world_camera, pan, tilt, roll)
	_world_camera.fov = maxf(fov_arc, 1.0)
	_world_camera.current = true


func _copy_cam(cam: Node3D, hard: bool = true) -> void:
	if cam == null or _world_camera == null:
		return
	# Position from entity; orientation from Acknex ang_to_vec(pan,tilt).
	# Entity euler is for MDL +X facing — wrong for Camera3D (−Z).
	if hard:
		_cam_pos = cam.global_position
		_cam_pos_ready = true
		_world_camera.global_position = cam.global_position
	var pan: float = float(cam.get_meta("pan", 0.0))
	var tilt: float = float(cam.get_meta("tilt", 0.0))
	var roll: float = float(cam.get_meta("roll", 0.0))
	_apply_acknex_view(_world_camera, pan, tilt, roll)
	_world_camera.fov = maxf(fov_arc, 1.0)
	_world_camera.current = true


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
	node.rotation_degrees.y = pans[randi() % pans.size()]


func _resolve_glb(stem: String) -> String:
	var direct := "res://assets/converted/mdl/%s.glb" % stem
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
			return "res://assets/converted/mdl/" + fn
		fn = dir.get_next()
	return ""


func _start_patrol(node: Node3D, skills: Array) -> void:
	var path_names: Array[String] = ["path_001", "path_002", "path_003", "path_004"]
	var pick: String = path_names[randi() % path_names.size()]
	if skills.size() > 19 and int(skills[19]) == 1:
		_make_clickable(node, "Taxi")
	if not _paths.has(pick):
		if _paths.is_empty():
			return
		pick = str(_paths.keys()[randi() % _paths.size()])
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
		node.global_position = pos + to.normalized() * step
		node.rotation.y = atan2(-to.x, -to.z)
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
		# Studio notepad (AFG / ShikNote) sits far from TheCam2 — large pick.
		shape.radius = 48.0 if action == "ShikKlik" else 28.0
		cs.shape = shape
		area.add_child(cs)
		node.add_child(area)


func _try_click() -> void:
	if _world_camera == null:
		return
	var from := _world_camera.project_ray_origin(get_viewport().get_mouse_position())
	var dir := _world_camera.project_ray_normal(get_viewport().get_mouse_position())
	var space := _world_camera.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 8000.0)
	q.collide_with_areas = true
	q.collide_with_bodies = true
	q.collision_mask = 0xFFFFFFFF
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	var n: Node = hit.get("collider") as Node
	while n:
		if n.has_meta("click_action") or n.has_meta("action"):
			_handle_click_action(str(n.get_meta("click_action", n.get_meta("action", ""))))
			return
		n = n.get_parent()


func handle_action(action: String) -> void:
	_handle_click_action(action)


func _handle_click_action(action: String) -> void:
	if action == "StartDialog":
		if _dialog_busy or _studio_boot:
			return
		if _hud:
			_hud.show_dialog(0)
		return
	if action == "ShikKlik":
		_run_shik()
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
	else:
		status.emit("WDL action: %s" % action)


func _on_dialog_choice(choice: int) -> void:
	if _dialog_busy or _studio_boot:
		return
	status.emit("Dialog choice %d" % choice)
	if _is_shiks_level() and _shiks_active:
		_run_shiks_choice(choice)
	else:
		_run_studio_choice(choice)


func _run_studio_choice(choice: int) -> void:
	_dialog_busy = true
	match choice:
		1:
			await _line("PIP001.WAV", 1, _naknik)
			await _line("AMI002.WAV", 2, _ami)
			await _line("PIP002.WAV", 1, _naknik)
		2:
			await _line("PIP003.WAV", 1, _naknik)
			await _line("PIP004.WAV", 1, _naknik)
			await _line("AMI003.WAV", 2, _ami)
			await _line("PIP005.WAV", 1, _naknik)
		3:
			if genia == 0:
				await _line("PIP006.WAV", 1, _naknik)
				await _line("AMI004.WAV", 2, _ami)
				await _line("PIP007.WAV", 1, _naknik)
				genia = 1
				_dialog_busy = false
				if _hud:
					_hud.show_dialog(0)
				return
			elif genia == 1:
				await _line("PIP531.WAV", 1, _naknik)
				await _line("AMI004.WAV", 2, _ami)
				await _line("PIP008.WAV", 1, _naknik)
				genia = 2
				_dialog_busy = false
				if _hud:
					_hud.show_dialog(0)
				return
			else:
				await _line("PIP531.WAV", 1, _naknik)
				await _line("AMI007.WAV", 2, _ami)
				await _line("PIP009.WAV", 1, _naknik)
				genia = 0
	talking = 0
	_anim_blink(_ami)
	_anim_blink(_naknik)
	_dialog_busy = false
	status.emit("Studio — click Ami / RMB cursor")


func _run_shik() -> void:
	if talking != 0 or _dialog_busy:
		return
	_dialog_busy = true
	if _hud:
		_hud.hide_dialog()
	await _line("SHK001.WAV", 3, null)
	await _line("PIP010.WAV", 1, _naknik)
	await _line("SHK002.WAV", 3, null)
	await _line("PIP011.WAV", 1, _naknik)
	_dialog_busy = false
	talking = 0
	request_run.emit("Shiks")


func _line(wav: String, who: int, actor: Node3D) -> void:
	talking = who
	_skip_line = false
	if _is_studio_level():
		_snap_studio_cam()
	elif _is_shiks_level():
		_apply_shiks_cam()
	if actor:
		if dance == 1 and actor == _naknik:
			_anim_cycle(actor, "Dance")
			_anim_talk_skins(actor, true)
		elif who == 22:
			_anim_frame(actor, "Scream", 0.0)
		elif who == 1 or who == 2:
			_anim_talk(actor)
		else:
			_anim_blink(actor)
	AudioBus.play_sfx(wav)
	var t := 0.0
	while AudioBus.is_voice_playing() and t < 30.0 and not _skip_line:
		await get_tree().process_frame
		t += get_process_delta_time()
	var skipped := _skip_line
	_skip_line = false
	if not skipped:
		await get_tree().create_timer(0.05).timeout


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
