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
var _wdl_interp: WdlInterpreter  # generic AST-driven runtime, see _try_begin_interpreted_level()
## 2026-07-28: user explicitly requested switching the previously
## hand-ported chapters (Studio/Start/Shiks/Plane/Plane2/Town/Range) over to
## the generic WdlInterpreter too, ahead of the originally-planned order
## (prove the interpreter on never-ported levels + a Shiks parity check
## first -- see docs/CONTRACT.md §4.1). Flagged here as a single-point,
## easily-revertible switch rather than deleting the hand-ported functions:
## none of that code was removed, only bypassed. Flip back to false to
## restore the hand-ported chapters immediately if the interpreter
## regresses behavior that took many playtest rounds to get right.
const HAND_PORTS_ENABLED := false
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
## Shiks.wdl `Photo` state machine (action Piposh3, DialogIndex 2/Choice 2):
## 0=idle, 1=morph to photo pose + spawn the Photos prop, 2=posing (Talk2),
## 3=morph back. Driven by _photo_watch during the PIP020.WAV line only —
## see docs/SESSION_LOG.md 2026-07-28.
var _photo := 0
var _photo_watch := false
var _photo_skill1 := 0.0
var _photos_prop: Node3D
var _water_wheel_roll := 0.0
var _turn_vase_tilt := 0.0
var _turn_vase_roll := 0.0
var _pipis: Array[Node3D] = []
var _stand_here_x := 0.0
var _ztemp := 0.0
var _shiks_active := false
var _cam_show := 1
var _piposh_skill2 := 1
var _dialog_index := 0
var _shiks_path: PackedVector3Array = PackedVector3Array()
var _shiks_path_i := 0
var _shiks_seg_t := 0.0  # 0..1 progress through the current Catmull-Rom segment
var _shiks_walking := false
var _shiks_fly := false
var _walk_away := false

## Plane.wdl state
var _plane_active := false
var _plane_piposh: Node3D
var _plane_krupnik: Node3D  # ThePlaneMovie
var _plane_krup: Node3D
var _plane_pip: Node3D
var _plane_cam2: Node3D
var _plane_cams: Array[Node3D] = []  # Camera1..3 by order
var _plane_vase1: Node3D
var _plane_vase2: Node3D
var _plane_path: PackedVector3Array = PackedVector3Array()
var _plane_path_i := 0
var _plane_walking := false
var _plane_phase := 0
var _plane_vase := 0
var _plane_pip2 := 0
var _plane_arv := 0.0
var _plane_cam_timer := 0.0
var _plane_update_logged := false
var _plane_log_t := 0.0
var _plane_view: Node3D  # current ChangeCamera / Camera1 hold

## Plane2.wdl state
var _plane2_active := false
var _p2_goal_hp := false
var _p2_goal_tv := false
var _p2_goal_pass := false
var _p2_goal_sikot := false
var _p2_hit_him := 0
var _p2_vview := 1
var _p2_movie := false
var _p2_finale := false
var _p2_passanger: Node3D
var _p2_stu1: Node3D
var _p2_stu2: Node3D
var _p2_tv: Node3D
var _p2_sikot: Node3D
var _p2_krupnik: Node3D
var _p2_cam3: Node3D
var _p2_cam4: Node3D
var _p2_cam_plane: Node3D
var _p2_b747: Node3D
var _p2_a1s: Array[Node3D] = []
var _p2_piposh_hit: Node3D
var _p2_headphones: Array[Node3D] = []
var _p2_b747_skill1 := 10.0
var _p2_jet_played := false
var _p2_hammer_t := 0.0  # Plane2.wdl Krupnik my.skill10: 0 = idle, 1..100 = swing scrub
var _p2_hammer_played := false
var _p2_tv_t := 0.0
var _p2_tv_skin := 1
## Fixed VView=3 cams from Plane2.wdl cameraX/Y/Z (Acknex → Godot).
const P2_VVIEW3: Array[Vector3] = [
	Vector3(35.0, 90.0, -533.0),
	Vector3(-73.0, 240.0, -282.0),
	Vector3(-40.0, 240.0, 475.0),
]
## Idle scenery (Wind / Land / Dome pan jitter).
var _idle_spinners: Array[Node3D] = []

## Range.wdl state (shooting-gallery minigame)
var _range_active := false
var _range_cam: Node3D
var _range_handgun: Node3D
var _range_pan := 0.0
var _range_tilt := 0.0
var _range_fire_length := 0.0
var _range_health := 609.0
var _range_terrorists := 15
var _range_civilians := 5
var _range_rapidness := 400.0
var _range_over := false
## One dict per Terrorist entity: node, pop, dying, going_up, delay, type, base, original_z.
var _range_targets: Array[Dictionary] = []
const RANGE_DEFAULT_DELAY := 10.0
const RANGE_DMG := 20.0


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
	_water_wheel_roll = 0.0
	_turn_vase_tilt = 0.0
	_turn_vase_roll = 0.0
	if _wdl_interp and is_instance_valid(_wdl_interp):
		_wdl_interp.queue_free()
	_wdl_interp = null
	_photo = 0
	_photo_watch = false
	_photo_skill1 = 0.0
	if _photos_prop and is_instance_valid(_photos_prop):
		_photos_prop.queue_free()
	_photos_prop = null
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
	_shiks_seg_t = 0.0
	_shiks_walking = false
	_shiks_fly = false
	_walk_away = false
	_stand_here_x = 0.0
	_ztemp = 0.0
	_plane_active = false
	_plane_piposh = null
	_plane_krupnik = null
	_plane_krup = null
	_plane_pip = null
	_plane_cam2 = null
	_plane_cams.clear()
	_plane_vase1 = null
	_plane_vase2 = null
	_plane_path = PackedVector3Array()
	_plane_path_i = 0
	_plane_walking = false
	_plane_phase = 0
	_plane_vase = 0
	_plane_pip2 = 0
	_plane_arv = 0.0
	_plane_cam_timer = 0.0
	_plane_view = null
	_cam_show = 0
	_plane2_active = false
	_p2_goal_hp = false
	_p2_goal_tv = false
	_p2_goal_pass = false
	_p2_goal_sikot = false
	_p2_hit_him = 0
	_p2_vview = 1
	_p2_movie = false
	_p2_finale = false
	_p2_passanger = null
	_p2_stu1 = null
	_p2_stu2 = null
	_p2_tv = null
	_p2_sikot = null
	_p2_krupnik = null
	_p2_cam3 = null
	_p2_cam4 = null
	_p2_cam_plane = null
	_p2_b747 = null
	_p2_a1s.clear()
	_p2_piposh_hit = null
	_p2_headphones.clear()
	_p2_b747_skill1 = 10.0
	_p2_jet_played = false
	_p2_hammer_t = 0.0
	_p2_hammer_played = false
	_p2_tv_t = 0.0
	_p2_tv_skin = 1
	_range_update_logged = false
	_town_cam_range_warned = false
	_plane_update_logged = false
	_plane_log_t = 0.0
	_idle_spinners.clear()
	_range_active = false
	_range_cam = null
	_range_handgun = null
	_range_pan = 0.0
	_range_tilt = 0.0
	_range_fire_length = 0.0
	_range_health = 609.0
	_range_terrorists = 15
	_range_civilians = 5
	_range_rapidness = 400.0
	_range_over = false
	_range_targets.clear()
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
				# Afgan.wdl collectible: my.skill1 = card index (0-31), click
				# picks it up (persists to GameState.afg, removes entity).
				# Was previously wrongly aliased to ShikKlik (Shiks scene) —
				# that guessed at behavior from wall proximity instead of
				# reading original/piposh3d/WDL/Afgan.wdl; see SESSION_LOG.
				var card_i := int(round(float(skills[0]))) if skills.size() > 0 else -1
				if card_i >= 0 and card_i < GameState.afg.size() and GameState.afg[card_i] == 1:
					node.queue_free()  # already collected in a prior session
				else:
					node.set_meta("afg_card_index", card_i)
					_make_clickable(node, "AFG_Take")
			"Dummy":
				# Studio.wdl Dummy = room tone; Plane/Plane2 = cockpit loop.
				if _is_studio_level():
					AudioBus.play_sfx("SFX105.WAV", -8.0)
				elif _is_plane_level() or _is_plane2_level():
					AudioBus.play_music("SFX089.WAV", -10.0)
			"Passanger":
				_p2_passanger = node
				_anim_frame(node, "Sit", 0.0)
			"STU1":
				_p2_stu1 = node
				_anim_cycle(node, "Stand")
			"STU2":
				_p2_stu2 = node
				_anim_blink(node)
			"TV":
				_p2_tv = node
			"Sikot":
				_p2_sikot = node
			"HeadPhone":
				_p2_headphones.append(node)
			"Krupnik":
				_p2_krupnik = node
				_anim_cycle(node, "Stand")
			"Cam3":
				_p2_cam3 = node
				_hide_cam_mesh(node)
			"Cam4":
				_p2_cam4 = node
				_hide_cam_mesh(node)
			"CamPlane":
				_p2_cam_plane = node
				_hide_cam_mesh(node)
			"B747":
				_p2_b747 = node
			"A1":
				_p2_a1s.append(node)
				node.visible = false
			"PiposhHit":
				_p2_piposh_hit = node
				node.visible = false
			"CameraEngine":
				_hide_cam_mesh(node)
			"Wind", "Land":
				_idle_spinners.append(node)
			"CamTarget":
				_range_cam = node
				_hide_cam_mesh(node)
			"Handgun":
				_range_handgun = node
				node.visible = false
			"Terrorist":
				_range_targets.append({
					"node": node,
					"pop": false,
					"dying": false,
					"going_up": false,
					"delay": 0.0,
					"type": 0,
					"base": 1,
					"original_y": node.global_position.y,
				})
				node.set_meta("range_target", true)
				_anim_frame(node, "Stand", 0.0)
			"PiposhWalk":
				_plane_piposh = node
				_anim_frame(node, "Stand", 0.0)
			"ThePlaneMovie":
				_plane_krupnik = node
				_anim_frame(node, "Peek", 0.0)
			"Krup":
				_plane_krup = node
				node.visible = false
				_anim_frame(node, "Stand", 0.0)
			"Pip":
				_plane_pip = node
				node.visible = false
				_anim_frame(node, "LookBack", 0.0)
			"Cam2":
				_plane_cam2 = node
				_cams.append(node)
				_hide_cam_mesh(node)
			"Vase1":
				_plane_vase1 = node
				node.visible = false
			"Vase2":
				_plane_vase2 = node
				node.visible = false
			"Dome":
				_anim_cycle(node, "Frame")
				_idle_spinners.append(node)
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

	# Plane.wdl: Camera1..3 from Cam.skill1 (OLD ENTITY pad fixed in extractor).
	if _is_plane_level():
		_plane_cams.clear()
		var by_skill: Dictionary = {}
		for c in _cams:
			if c == _plane_cam2:
				continue
			var sk := int(round(float(c.get_meta("skills", [0])[0]))) if c.get_meta("skills", []).size() > 0 else 0
			if sk < 1:
				sk = int(c.get_meta("view_id", 0))
			if sk >= 1 and sk <= 3 and not by_skill.has(sk):
				by_skill[sk] = c
		for i in range(1, 4):
			if by_skill.has(i):
				var cam_n: Node3D = by_skill[i]
				cam_n.set_meta("view_id", i)
				cam_n.set_meta("skill1", i)
				_plane_cams.append(cam_n)
		# Fallback: first three non-Cam2 cams in WMB order.
		if _plane_cams.size() < 3:
			_plane_cams.clear()
			for c in _cams:
				if c == _plane_cam2:
					continue
				_plane_cams.append(c)
				if _plane_cams.size() >= 3:
					break
			for i in _plane_cams.size():
				_plane_cams[i].set_meta("view_id", i + 1)
				_plane_cams[i].set_meta("skill1", i + 1)

	if _hud and not _hud.dialog_choice.is_connected(_on_dialog_choice):
		_hud.dialog_choice.connect(_on_dialog_choice)
	if _hud and not _hud.skip_line_pressed.is_connected(_on_skip_line_pressed):
		_hud.skip_line_pressed.connect(_on_skip_line_pressed)

	var fp := _loader != null and _loader.has_first_person()
	scripted_camera = (
		not fp
		and (
			_cams.size() > 0
			or _the_cam != null
			or _the_cam2 != null
			or _look_at_me != null
			or _plane_krupnik != null
			or _plane_piposh != null
		)
	)

	if HAND_PORTS_ENABLED and _is_start_level():
		_begin_start_sequence()
	elif HAND_PORTS_ENABLED and _is_studio_level():
		_begin_studio_sequence()
	elif HAND_PORTS_ENABLED and _is_town_level():
		_begin_town()
	elif HAND_PORTS_ENABLED and _is_shiks_level():
		_begin_shiks()
	elif HAND_PORTS_ENABLED and _is_plane_level():
		_begin_plane()
	elif HAND_PORTS_ENABLED and _is_plane2_level():
		_begin_plane2()
	elif HAND_PORTS_ENABLED and _is_range_level():
		_begin_range()
	elif fp:
		# Generic FP (Inn/Mansion/…): LevelRunner owns the camera.
		scripted_camera = false
		mouse_look = true
		_wire_generic_run_clickables()
		_wire_first_person_clickables()
		status.emit("%s — first person" % str(_loader.level_name))
	elif scripted_camera and _try_begin_interpreted_level():
		pass  # driven entirely by WdlInterpreter now
	elif scripted_camera:
		_begin_generic_level()
	else:
		status.emit("Free player camera")


func _process(delta: float) -> void:
	if HAND_PORTS_ENABLED and _is_start_level() and _start_active:
		_update_start(delta)
	elif HAND_PORTS_ENABLED and _is_studio_level():
		_update_studio(delta)
	elif HAND_PORTS_ENABLED and _is_shiks_level() and _shiks_active:
		_update_shiks(delta)
	elif HAND_PORTS_ENABLED and _is_plane_level() and _plane_active:
		_update_plane(delta)
	elif HAND_PORTS_ENABLED and _is_plane2_level() and _plane2_active:
		_update_plane2(delta)
	elif HAND_PORTS_ENABLED and _is_range_level() and _range_active:
		_update_range(delta)
	elif _wdl_interp != null:
		# Interpreted level (see _try_begin_interpreted_level()): the
		# script's own coroutines drive camera.x/y/z/pan/tilt/roll directly
		# every tick. _update_town_cam()'s generic "snap to nearest Cam
		# entity" fallback must not also run here -- same camera-fight bug
		# class already found and fixed for Range (see docs/SESSION_LOG.md
		# 2026-07-27), just a different generic function catching a new
		# scripted_camera=true level with no dedicated branch.
		pass
	elif scripted_camera:
		_update_town_cam()
	_update_patrols(delta)
	_update_idle_spinners(delta)
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
		elif event.keycode == KEY_V and _is_plane2_level() and _plane2_active and not _p2_movie:
			# Plane2.wdl ToggleView — F1 kept for Menu; V cycles 1↔3.
			_p2_vview = 3 if _p2_vview == 1 else 1
			if _p2_vview == 1:
				_restore_fp_camera()
			else:
				_steal_camera()
			status.emit("Plane2 VView %d" % _p2_vview)
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
		elif event.button_index == MOUSE_BUTTON_LEFT and _is_range_level() and _range_active:
			_range_fire()
		elif event.button_index == MOUSE_BUTTON_LEFT and not mouse_look:
			# Let dialog TextureButtons handle GUI clicks first.
			if _hud and _hud.is_dialog_open():
				return
			_try_click()

	if event is InputEventMouseMotion and _is_range_level() and _range_active:
		# Range.wdl CamTarget: pan/tilt -= mickey/SEN(3), tilt clamped -15..45.
		_range_pan -= event.relative.x / 3.0
		_range_tilt = clampf(_range_tilt - event.relative.y / 3.0, -15.0, 45.0)

	if event is InputEventMouseMotion and mouse_look and scripted_camera \
			and not _is_start_level() and not _is_shiks_level() and not _is_plane_level() \
			and not _is_range_level():
		# Town.wdl / generic Cam: pan/tilt -= mickey/5 while mouse_mode==0
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


func _begin_plane2() -> void:
	## Plane2.wdl: Vview=1 FP + four goals → Scene 2 movie → Range.
	_plane2_active = true
	scripted_camera = false
	mouse_look = true
	scene = 0
	talking = 0
	_p2_vview = 1
	_p2_movie = false
	_p2_finale = false
	_p2_hit_him = 0
	_apply_mouse_mode()
	_wire_generic_run_clickables()
	_wire_first_person_clickables()
	if not AudioBus.is_music_playing():
		AudioBus.play_music("SFX089.WAV", -10.0)
	status.emit("Plane2 — collect four goals (V=view, RMB=cursor)")


func _update_plane2(delta: float) -> void:
	var t := delta * 16.0
	# Krupnik hammer / talk skins when visible.
	# Plane2.wdl action Krupnik: idle Stand cycle; ~1/40 chance per tick to
	# start a hammer swing, then scrub my.skill10 0->100 via ent_frame
	# ("Hammer", skill10) -- a continuous animated swing, not a static pose.
	if _p2_krupnik and is_instance_valid(_p2_krupnik):
		if talking == 3:
			_anim_talk_skins(_p2_krupnik, true)
			_face_toward(_p2_krupnik, _player_pos())
		else:
			_anim_talk_skins(_p2_krupnik, false)
			if _p2_hammer_t <= 0.0 and int(randi() % 40) == 20:
				_p2_hammer_t = 1.0
				_p2_hammer_played = false
			if _p2_hammer_t > 0.0:
				_p2_hammer_t += 10.0 * t
				_anim_frame(_p2_krupnik, "Hammer", clampf(_p2_hammer_t, 0.0, 100.0))
				if _p2_hammer_t > 50.0 and _p2_hammer_t < 60.0 and not _p2_hammer_played:
					_p2_hammer_played = true
					AudioBus.play_sfx("SFX090.WAV", -12.0)
				if _p2_hammer_t > 100.0:
					_p2_hammer_t = 0.0
			else:
				_anim_cycle(_p2_krupnik, "Stand")
	# Plane2.wdl action TV: continuous skin flip 1..12 every 4 ticks (~0.25s).
	if _p2_tv and is_instance_valid(_p2_tv):
		_p2_tv_t += t
		if _p2_tv_t >= 4.0:
			_p2_tv_t = 0.0
			_p2_tv_skin += 1
			if _p2_tv_skin > 12:
				_p2_tv_skin = 1
			_anim_set_skin(_p2_tv, _p2_tv_skin)
	# STU1 always faces player when idle.
	if _p2_stu1 and is_instance_valid(_p2_stu1) and not _p2_movie:
		_face_toward(_p2_stu1, _player_pos())
		_anim_cycle(_p2_stu1, "Stand")
	if _p2_stu2 and is_instance_valid(_p2_stu2) and not _p2_movie:
		_face_toward(_p2_stu2, _player_pos())
		if talking == 2:
			_anim_talk(_p2_stu2)
			_anim_talk_skins(_p2_stu2, true)
		else:
			_anim_talk_skins(_p2_stu2, false)
			_anim_blink(_p2_stu2)
	# A1 / Cam4 while headphones movie (Scene == 1).
	for a1 in _p2_a1s:
		if a1 and is_instance_valid(a1):
			a1.visible = scene == 1
			if scene == 1 and talking == 1:
				_anim_talk_skins(a1, true)
			else:
				_anim_talk_skins(a1, false)
	if scene == 1 and _p2_cam4:
		_copy_cam(_p2_cam4, true)
	# Cam3 during passenger hit.
	if _p2_hit_him > 0 and _p2_cam3:
		_copy_cam(_p2_cam3, true)
	# VView 3 fixed cams.
	if _p2_vview == 3 and _p2_hit_him == 0 and scene == 0 and not _p2_movie:
		_apply_plane2_vview3()
	# Scene 2 finale: CamPlane tracks B747.
	if scene == 2 and _p2_cam_plane and _p2_b747:
		_p2_cam_plane.global_position += Vector3(-5.0, -10.0, -10.0) * t
		_p2_b747.global_position += Vector3(0.0, 0.0, -_p2_b747_skill1) * t
		if AudioBus.is_voice_playing():
			# Near end of KRP009 — accelerate + climb (Jet).
			pass
		var look := _p2_b747.global_position - _p2_cam_plane.global_position
		if look.length_squared() > 1.0:
			var pan := rad_to_deg(atan2(-look.z, look.x))
			var tilt := rad_to_deg(atan2(look.y, Vector2(look.x, look.z).length()))
			_p2_cam_plane.set_meta("pan", pan)
			_p2_cam_plane.set_meta("tilt", tilt)
			_p2_cam_plane.set_meta("roll", 0.0)
		_copy_cam(_p2_cam_plane, true)
	# Goals complete → finale once.
	if (
		not _p2_finale
		and _p2_goal_hp and _p2_goal_tv and _p2_goal_pass and _p2_goal_sikot
		and not _p2_movie
	):
		_run_plane2_finale()


func _apply_plane2_vview3() -> void:
	var p := _player_pos()
	var best_i := 0
	var best_d := INF
	for i in P2_VVIEW3.size():
		var d := P2_VVIEW3[i].distance_squared_to(p)
		if d < best_d:
			best_d = d
			best_i = i
	if _world_camera == null:
		return
	_steal_camera()
	_world_camera.global_position = P2_VVIEW3[best_i]
	var look := p - _world_camera.global_position
	if look.length_squared() > 1.0:
		var pan := rad_to_deg(atan2(-look.z, look.x))
		var tilt := rad_to_deg(atan2(look.y, Vector2(look.x, look.z).length()))
		_apply_acknex_view(_world_camera, pan, tilt, 0.0)
	_world_camera.current = true


func _player_pos() -> Vector3:
	var player := _find_player()
	if player:
		return player.global_position
	if _loader and not _loader.first_person_spawn.is_empty():
		return _loader.first_person_spawn.get("origin", Vector3.ZERO)
	return Vector3.ZERO


func _find_player() -> CharacterBody3D:
	var parent := get_parent()
	if parent == null:
		return null
	return parent.get_node_or_null("Player") as CharacterBody3D


func _face_toward(node: Node3D, target: Vector3) -> void:
	if node == null or not is_instance_valid(node):
		return
	var d := target - node.global_position
	d.y = 0.0
	if d.length_squared() < 1e-4:
		return
	var pan := rad_to_deg(atan2(-d.z, d.x))
	_set_entity_pan(node, pan)


func _steal_camera() -> void:
	scripted_camera = true
	if _world_camera:
		_world_camera.current = true
	var player := _find_player()
	if player:
		var cam := player.get_node_or_null("Camera3D") as Camera3D
		if cam:
			cam.current = false
		player.set_physics_process(false)
		player.set_process_unhandled_input(false)


func _restore_fp_camera() -> void:
	scripted_camera = false
	_p2_vview = 1
	var player := _find_player()
	if player:
		player.set_physics_process(true)
		player.set_process_unhandled_input(true)
		var cam := player.get_node_or_null("Camera3D") as Camera3D
		if cam:
			cam.current = true
	if _world_camera:
		_world_camera.current = false
	mouse_look = true
	_apply_mouse_mode()


func _run_plane2_hp() -> void:
	if _p2_goal_hp or _p2_movie:
		return
	_p2_movie = true
	scene = 1
	_steal_camera()
	if _p2_cam4:
		_copy_cam(_p2_cam4, true)
	await _line("SHK019.WAV", 0, null)
	await _line("PIP039.WAV", 1, _p2_a1s[0] if _p2_a1s.size() > 0 else null)
	await _line("SHK020.WAV", 0, null)
	await _line("PIP040.WAV", 1, _p2_a1s[0] if _p2_a1s.size() > 0 else null)
	await _line("SHK021.WAV", 0, null)
	talking = 0
	scene = 0
	_p2_movie = false
	_p2_goal_hp = true
	_restore_fp_camera()
	status.emit("Goal: Headphones")


func _run_plane2_tv() -> void:
	if _p2_goal_tv or _p2_movie:
		return
	_p2_movie = true
	await _line("KRP008.WAV", 3, _p2_krupnik)
	talking = 0
	_p2_movie = false
	_p2_goal_tv = true
	status.emit("Goal: TV")


func _run_plane2_passanger() -> void:
	if _p2_goal_pass or _p2_movie:
		return
	_p2_movie = true
	_p2_hit_him = 1
	_steal_camera()
	if _p2_cam3:
		_copy_cam(_p2_cam3, true)
	var player := _find_player()
	var saved_y := 0.0
	if player:
		saved_y = player.global_position.y
		player.global_position.y = saved_y + 500.0
	if _p2_piposh_hit:
		_p2_piposh_hit.visible = true
	AudioBus.play_sfx("SFX026.WAV")
	if _p2_passanger:
		for pct in range(0, 101, 8):
			_anim_frame(_p2_passanger, "Hit", float(pct))
			await get_tree().process_frame
		_anim_frame(_p2_passanger, "Sit", 0.0)
	await _line("SFX119.WAV", 0, _p2_passanger)
	_p2_hit_him = 2
	await _line("PIP034.WAV", 1, null)
	_p2_hit_him = 0
	if _p2_piposh_hit:
		_p2_piposh_hit.visible = false
	if player:
		player.global_position.y = saved_y
	_p2_movie = false
	_p2_goal_pass = true
	_restore_fp_camera()
	status.emit("Goal: Passenger")


func _run_plane2_sikot() -> void:
	if _p2_goal_sikot or _p2_movie:
		return
	_p2_movie = true
	await _line("PIP036.WAV", 1, null)
	await _line("STU001.WAV", 2, _p2_stu2)
	await _line("PIP037.WAV", 1, null)
	await _line("STU002.WAV", 2, _p2_stu2)
	await _line("PIP038.WAV", 1, null)
	talking = 0
	_p2_movie = false
	_p2_goal_sikot = true
	status.emit("Goal: Sikot")


func _run_plane2_stu1() -> void:
	if _p2_movie:
		return
	_p2_movie = true
	await _line("PIP035.WAV", 1, null)
	talking = 0
	_p2_movie = false


func _run_plane2_finale() -> void:
	_p2_finale = true
	_p2_movie = true
	scene = 2
	_steal_camera()
	status.emit("Plane2 Scene 2 — departure")
	await _line("KRP009.WAV", 3, _p2_krupnik)
	if not _p2_jet_played:
		_p2_jet_played = true
		AudioBus.play_sfx("SFX143.WAV", -6.0)
		_p2_b747_skill1 = 40.0
	await get_tree().create_timer(0.8).timeout
	_p2_movie = false
	status.emit("Plane2 → Range")
	request_run.emit("Range")


## ---- Range.wdl: shooting-gallery minigame ----------------------------
## Terrorist/civilian targets (shared Fakeguy.MDL, skin swap for type/hit)
## pop up at random; shoot terrorists, avoid civilians. All terrorists dead
## -> Run("Plane3"). Health <= 0 or all civilians dead -> restart the level.


func _begin_range() -> void:
	scripted_camera = true
	mouse_look = true
	_apply_mouse_mode()
	# Range has no free-roam/3rd-person mode in the original at all — always
	# aim-with-mouse from a fixed CamTarget. Explicitly take the camera and
	# disable the player controller so nothing can fall back to free/FP
	# movement (reported: could walk out of first person during the game).
	_steal_camera()
	if _hud:
		# This button defaults to visible with mouse_filter=STOP and is never
		# hidden anywhere in the codebase — confirmed as a real, general HUD
		# gap while diagnosing "there was a skip button" during Range. Hiding
		# it here at minimum; see docs/SESSION_LOG.md for the broader note.
		_hud.set_skip_visible(false)
		_hud.hide_dialog()
	_range_active = true
	_range_over = false
	_range_health = 609.0
	_range_terrorists = 15
	_range_civilians = 5
	_range_rapidness = 400.0
	if _range_cam:
		_range_pan = float(_range_cam.get_meta("pan", 270.0))
		_range_tilt = 0.0
	if _range_handgun:
		_range_handgun.visible = true
		_anim_frame(_range_handgun, "Aim", 0.0)
		# It's an FP viewmodel, not a hittable prop — the generic FP-collision
		# rule in wmb_level_loader.gd still gives it a solid body, which would
		# otherwise block the shooting raycast at point-blank range.
		_disable_collision(_range_handgun)
	for t in _range_targets:
		var node: Node3D = t["node"]
		if node and is_instance_valid(node):
			node.visible = true
	status.emit("Range — shoot the terrorists, spare the civilians (LMB fires)")
	_update_range_hud()
	PiposhDebug.log_msg(
		"range",
		"begin: cam=%s handgun=%s targets=%d pan=%.1f tilt=%.1f mouse_mode=%s"
		% [
			str(_range_cam), str(_range_handgun), _range_targets.size(),
			_range_pan, _range_tilt, str(Input.mouse_mode),
		]
	)


var _range_update_logged := false


func _update_range(delta: float) -> void:
	if not _range_update_logged:
		_range_update_logged = true
		PiposhDebug.log_msg(
			"range",
			"update running: cam=%s world_cam=%s over=%s"
			% [str(_range_cam), str(_world_camera), _range_over]
		)
	if _range_cam == null or _world_camera == null or _range_over:
		return
	var t := delta * 16.0  # Acknex ticks (~16Hz) used by the original timers
	_world_camera.global_position = _range_cam.global_position
	_apply_acknex_view(_world_camera, _range_pan, _range_tilt, 0.0)
	_world_camera.fov = _acknex_arc_to_godot_fov(fov_arc)
	_world_camera.current = true

	if _range_fire_length > 0.0:
		_anim_frame(_range_handgun, "Fire", clampf(100.0 - _range_fire_length * 10.0, 0.0, 100.0))
		_range_fire_length -= 3.0 * t
	elif _range_handgun:
		_anim_frame(_range_handgun, "Aim", 0.0)

	for target in _range_targets:
		_update_range_target(target, delta, t)

	if _range_health <= 0.0 or _range_civilians <= 0:
		_range_lose()
	elif _range_terrorists <= 0:
		_range_win()


func _update_range_target(target: Dictionary, delta: float, t: float) -> void:
	var node: Node3D = target["node"]
	if node == null or not is_instance_valid(node):
		return
	if bool(target["dying"]):
		node.global_position.y -= 5.0 * t * delta
		if node.global_position.y < float(target["original_y"]):
			node.global_position.y = float(target["original_y"])
			target["dying"] = false
			target["pop"] = false
	if bool(target["going_up"]):
		node.global_position.y += 10.0 * t * delta
		if node.global_position.y > float(target["original_y"]) + 60.0:
			target["going_up"] = false

	if not bool(target["pop"]) and randi() % int(_range_rapidness) == int(_range_rapidness / 2.0):
		var civilian := randi() % 6 != 3  # 1-in-6 chance of a terrorist, else civilian
		if civilian:
			target["type"] = 2
			target["base"] = [1, 10, 13, 16].pick_random()
			target["delay"] = RANGE_DEFAULT_DELAY * 2.0
		else:
			target["type"] = 1
			target["base"] = [1, 4, 7].pick_random()
			target["delay"] = RANGE_DEFAULT_DELAY * 1.8
		target["going_up"] = true
		target["pop"] = true
		_anim_set_skin(node, int(target["base"]))

	if bool(target["pop"]):
		target["delay"] = float(target["delay"]) - t
		if float(target["delay"]) < 10.0 and int(target["type"]) == 2:
			_anim_set_skin(node, int(target["base"]) + 1)
		if float(target["delay"]) < 0.0:
			if int(target["type"]) == 2:
				target["dying"] = true
			elif int(target["type"]) == 1:
				_anim_set_skin(node, int(target["base"]) + 1)
				_range_health -= RANGE_DMG
				target["delay"] = RANGE_DEFAULT_DELAY
				_update_range_hud()


func _range_fire() -> void:
	PiposhDebug.log_msg(
		"range",
		"fire attempt: fire_length=%.1f world_cam=%s active=%s over=%s"
		% [_range_fire_length, str(_world_camera), _range_active, _range_over]
	)
	if _range_fire_length > 0.0 or _world_camera == null:
		return
	_range_fire_length = 10.0
	AudioBus.play_sfx("wham.wav", -6.0)
	var center: Vector2 = Vector2(get_viewport().size) / 2.0
	var from := _world_camera.project_ray_origin(center)
	var dir := _world_camera.project_ray_normal(center)
	var space := _world_camera.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 4000.0)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		PiposhDebug.log_msg("range", "fire: MISS (no collider under crosshair)")
		return
	var n: Node = hit.get("collider") as Node
	var collider_name: String = str(n.name) if n else "?"
	while n:
		if n.has_meta("range_target"):
			PiposhDebug.log_msg("range", "fire: HIT target %s (via %s)" % [n.name, collider_name])
			_range_target_hit(n as Node3D)
			return
		if str(n.get_meta("action", "")) == "TNT":
			PiposhDebug.log_msg("range", "fire: HIT TNT %s" % n.name)
			(n as Node3D).visible = false
			return
		n = n.get_parent()
	PiposhDebug.log_msg("range", "fire: hit %s but no range_target/TNT in its ancestry" % collider_name)


func _range_target_hit(node: Node3D) -> void:
	for target in _range_targets:
		if target["node"] != node or not bool(target["pop"]) or bool(target["dying"]):
			continue
		_anim_set_skin(node, int(target["base"]) + 2)
		if int(target["type"]) == 2:
			_range_civilians -= 1
		else:
			_range_terrorists -= 1
			_range_rapidness = maxf(float(_range_terrorists) * 20.0, 20.0)
		target["dying"] = true
		target["pop"] = false
		_update_range_hud()
		return


func _update_range_hud() -> void:
	var msg := (
		"Health: %d\nTerrorists: %d\nCivilians: %d"
		% [maxi(int(_range_health), 0), _range_terrorists, _range_civilians]
	)
	if _hud:
		_hud.set_range_hud(msg)
	status.emit("Range — health=%d terrorists=%d civilians=%d"
		% [maxi(int(_range_health), 0), _range_terrorists, _range_civilians])


func _range_win() -> void:
	_range_over = true
	_range_active = false
	status.emit("Range cleared — all terrorists down")
	if _hud:
		_hud.hide_range_hud()
	await get_tree().create_timer(1.5).timeout
	request_run.emit("Plane3")


func _range_lose() -> void:
	_range_over = true
	_range_active = false
	status.emit(
		"Range failed — %s" % ("out of health" if _range_health <= 0.0 else "a civilian was lost")
	)
	if _hud:
		_hud.hide_range_hud()
	await get_tree().create_timer(1.5).timeout
	request_run.emit("Range")


func _update_idle_spinners(delta: float) -> void:
	var t := delta * 16.0
	for n in _idle_spinners:
		if n == null or not is_instance_valid(n):
			continue
		var action := str(n.get_meta("action", "")).to_lower()
		if action == "dome":
			var pan := float(n.get_meta("pan", 0.0)) + 0.2 * t
			_set_entity_pan(n, pan)
		elif action in ["wind", "land"]:
			# Subtle pan jitter / cycle if clips exist.
			var anim := n.get_node_or_null("MdlAnimator") as MdlAnimator
			if anim:
				_anim_cycle(n, "Frame")
			else:
				var pan2 := float(n.get_meta("pan", 0.0)) + 0.05 * t
				n.set_meta("pan", pan2)


func _try_begin_interpreted_level() -> bool:
	## Generic AST-driven runtime (WdlInterpreter, added 2026-07-28) — reads
	## the level's actual .wdl (via tools/parse_wdl.py's JSON AST) and
	## executes it directly, instead of _begin_generic_level()'s bare
	## camera/click fallback with zero scripted behavior. See
	## docs/CONTRACT.md for the parity-test rule this went through before
	## being wired in here. Any hand-ported level above in this if/elif
	## chain (Studio/Start/Shiks/Plane/Plane2/Town/Range) never reaches
	## this — they're untouched.
	var stems: Array[String] = [_level_script.get_basename(), str(_loader.level_name)]
	var found := ""
	for s in stems:
		var path := "res://assets/converted/wdl_ast/%s.json" % s
		if ResourceLoader.exists(path) or FileAccess.file_exists(path):
			found = s
			break
	if found == "":
		return false
	var interp := WdlInterpreter.new()
	interp.name = "WdlInterpreter"
	add_child(interp)
	if not interp.setup(found, _loader, _world_camera):
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
	## Uniform fallback: any level with Cam/paths works without a custom chapter.
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
	## afg_card is deliberately excluded: the main entity loop already wires
	## it to the real "AFG_Take" handler (and removes already-collected
	## cards). Re-wiring it here with the raw "AFG_Card" action clobbered
	## that with an unhandled action string, silently breaking the click in
	## Plane2 (Studio's AFG_Card was unaffected — its director never calls
	## this function). See docs/SESSION_LOG.md.
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


func _begin_plane() -> void:
	# Plane.wdl main → SetVoice boot + dialog 3 + path walk.
	scripted_camera = true
	mouse_look = false
	_plane_active = true
	scene = -1
	talking = 0
	_plane_phase = 0
	_plane_vase = 0
	_plane_pip2 = 0
	_plane_arv = 0.0
	_plane_cam_timer = 0.0
	_cam_show = 0
	_dialog_index = 0
	_dialog_busy = true
	_apply_mouse_mode()
	if _hud:
		_hud.hide_dialog()
		_hud.set_mouse_look(false)
	# Bind walk path (Plane.WMB path_001).
	_plane_path = PackedVector3Array()
	_plane_path_i = 0
	for k in _paths.keys():
		_plane_path = _paths[k]
		break
	_plane_view = _plane_cams[0] if _plane_cams.size() > 0 else _plane_cam2
	_apply_plane_cam(true)
	# PiposhWalk follows the path during Wait/KRP001 (before DialogIndex==3).
	_plane_walking = true
	status.emit("Plane — boarding…")
	PiposhDebug.log_msg(
		"plane",
		(
			"begin: piposh=%s krupnik=%s path_pts=%d cams=%d view=%s "
			+ "cam_positions=%s piposh_pos=%s"
		)
		% [
			str(_plane_piposh), str(_plane_krupnik), _plane_path.size(),
			_plane_cams.size(), str(_plane_view),
			str(_plane_cams.map(func(c): return c.global_position)),
			str(_plane_piposh.global_position if _plane_piposh else null),
		]
	)
	_plane_update_logged = false
	_run_plane_boot()


func _run_plane_boot() -> void:
	# SetVoice: Scene -1 Wait, 0 KRP001, 1 DoDialog(3)
	await _line("Wait.wav", 0, null)
	scene = 0
	if _plane_krupnik:
		_anim_frame(_plane_krupnik, "Peek", 0.0)
	await _line("KRP001.WAV", 2, _plane_krupnik)
	scene = 1
	talking = 0
	# Plane.wdl: while Dialog.visible → Blink only (no walk).
	_plane_walking = false
	if _plane_piposh:
		_anim_blink(_plane_piposh)
	_dialog_index = 3
	_dialog_busy = false
	if _hud:
		_hud.show_dialog(3)
	status.emit("Plane — choose a line")


func _apply_plane_cam(hard: bool = false) -> void:
	# ThePlaneMovie holds Camera1; Cam2 while CamShow==1; else ChangeCamera picks.
	if _cam_show == 1 and _plane_cam2:
		_copy_cam(_plane_cam2, hard)
	elif _plane_view:
		_copy_cam(_plane_view, hard)
	elif _plane_cams.size() > 0:
		_copy_cam(_plane_cams[0], hard)
	elif _plane_cam2:
		_copy_cam(_plane_cam2, hard)


func _update_plane(delta: float) -> void:
	if not _plane_update_logged:
		_plane_update_logged = true
		PiposhDebug.log_msg(
			"plane",
			"update running: piposh_visible=%s piposh_pos=%s active_cam=%s"
			% [
				str(_plane_piposh.visible if _plane_piposh else null),
				str(_plane_piposh.global_position if _plane_piposh else null),
				str(_plane_view),
			]
		)
	_plane_log_t += delta
	if _plane_log_t >= 1.0:
		_plane_log_t = 0.0
		PiposhDebug.log_msg(
			"plane",
			(
				"tick: scene=%d talking=%d phase=%d walking=%s piposh_visible=%s "
				+ "piposh_pos=%s cam_show=%d view=%s world_cam_pos=%s"
			)
			% [
				scene, talking, _plane_phase, str(_plane_walking),
				str(_plane_piposh.visible if _plane_piposh else null),
				str(_plane_piposh.global_position if _plane_piposh else null),
				_cam_show, str(_plane_view),
				str(_world_camera.global_position if _world_camera else null),
			]
		)
	# Vase visibility
	if _plane_vase1:
		_plane_vase1.visible = _plane_vase == 1
	if _plane_vase2:
		_plane_vase2.visible = _plane_vase == 2
	if _plane_krup:
		_plane_krup.visible = _plane_phase == 1 or _plane_phase == 2
	if _plane_pip:
		_plane_pip.visible = _plane_pip2 == 1

	# Cam2 while CamShow==1 (hammer beat); else hold current view / ChangeCamera.
	if _cam_show == 0 and _plane_pip2 == 0 and _plane_cams.size() > 0:
		_plane_cam_timer -= delta
		if _plane_cam_timer <= 0.0 and scene > 0 and _plane_arv >= 100.0:
			if randi() % 100 == 50:
				_plane_view = _plane_cams[randi() % _plane_cams.size()]
				_plane_cam_timer = randf_range(2.5, 5.0)  # ~150–200 ticks
			else:
				_plane_cam_timer = 0.05
	_apply_plane_cam(false)

	# ThePlaneMovie Arrive scrub while Piposh talks early
	if _plane_krupnik and talking == 1 and _plane_arv < 100.0 and _plane_phase < 3:
		_plane_arv = minf(100.0, _plane_arv + 80.0 * delta)
		_anim_frame(_plane_krupnik, "Arrive", _plane_arv)

	# Walk Piposh along path only while DialogIndex != 3 (boot / non-dialog).
	if _plane_walking and _plane_piposh and _plane_phase < 3:
		_plane_walk_step(delta)

	# Talk / blink actors — match Plane.wdl ThePlaneMovie / PiposhWalk / Pip / Krup.
	if _plane_piposh and _plane_phase != 3:
		if _plane_vase == 1:
			# PIP031: ent_frame("Take",100) + Talk2 skins.
			_anim_frame(_plane_piposh, "Take", 100.0)
			_anim_talk_skins(_plane_piposh, talking == 1)
		elif _plane_walking:
			pass  # walk step sets Walk cycle
		elif talking == 1:
			_anim_talk(_plane_piposh)
		else:
			_anim_talk_skins(_plane_piposh, false)
			_anim_blink(_plane_piposh)

	if _plane_krupnik:
		if _plane_phase == 3:
			_anim_frame(_plane_krupnik, "Jump", 0.0)
			_anim_talk_skins(_plane_krupnik, talking == 2)
		elif talking == 1 and _plane_arv < 100.0:
			_anim_talk_skins(_plane_krupnik, false)
		elif scene == 0:
			# Peek + Talk2 skins while Krupnik's opening line plays.
			if talking == 2:
				_anim_talk_skins(_plane_krupnik, true)
				if Engine.get_process_frames() % 40 == 20:
					_anim_frame(_plane_krupnik, "Peek", float(randi() % 3) * 50.0)
			else:
				_anim_talk_skins(_plane_krupnik, false)
				_anim_frame(_plane_krupnik, "Peek", 0.0)
		elif talking == 2:
			_anim_talk_skins(_plane_krupnik, true)
			if Engine.get_process_frames() % 40 == 20:
				_anim_frame(_plane_krupnik, "Talk", float(randi() % 7) * 16.0)
		else:
			_anim_talk_skins(_plane_krupnik, false)
			if _plane_arv >= 100.0:
				_anim_blink(_plane_krupnik)

	if _plane_pip and _plane_pip2 == 1:
		if talking == 1:
			_anim_talk(_plane_pip)
		else:
			_anim_frame(_plane_pip, "LookBack", 0.0)

	# Krup.wdl: Stand jitters in phase 1; Hammer scrub in phase 2.
	if _plane_krup and (_plane_phase == 1 or _plane_phase == 2):
		_anim_talk_skins(_plane_krup, talking == 2)
		if _plane_phase == 1 and Engine.get_process_frames() % 40 == 20:
			_anim_frame(_plane_krup, "Stand", float(randi() % 3) * 50.0)
		elif _plane_phase == 2:
			_anim_frame(_plane_krup, "Hammer", fmod(Time.get_ticks_msec() / 50.0, 100.0))


func _plane_walk_step(delta: float) -> void:
	if _plane_path.is_empty() or _plane_piposh == null:
		return
	if _plane_path_i >= _plane_path.size():
		_anim_blink(_plane_piposh)
		return
	var target := _plane_path[_plane_path_i]
	var pos := _plane_piposh.global_position
	# Acknex actor_move keeps Z (height) from path; we lerp Y toward waypoint.
	var to := Vector3(target.x - pos.x, 0.0, target.z - pos.z)
	if to.length() < 25.0:
		_plane_path_i = mini(_plane_path_i + 1, _plane_path.size())
		_plane_piposh.global_position.y = target.y
		return
	var step := to.normalized() * minf(35.0 * delta, to.length())
	_plane_piposh.global_position += step
	_plane_piposh.global_position.y = move_toward(pos.y, target.y, 20.0 * delta)
	_plane_piposh.rotation_degrees.y = rad_to_deg(atan2(-step.z, step.x))
	_anim_cycle(_plane_piposh, "Walk")


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
	_shiks_seg_t = 0.0
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
		# Shiks.wdl WaterWheel: my.roll += 5 (about the wheel's own local
		# forward axis, not a fixed world axis — see _set_entity_tilt_roll).
		_water_wheel_roll += 5.0 * delta * 16.0
		_set_entity_roll(_water_wheel, _water_wheel_roll)
	if _turn_vase and _turn_vase.visible:
		# Shiks.wdl TurnVase: my.tilt += 20*time; my.roll += 20*time.
		_turn_vase_tilt += 20.0 * delta * 16.0
		_turn_vase_roll += 20.0 * delta * 16.0
		_set_entity_tilt_roll(_turn_vase, _turn_vase_tilt, _turn_vase_roll)
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
		_update_shiks_fly_cam(delta)

	_update_shiks_actors(delta)


func _update_shiks_fly_cam(delta: float) -> void:
	## Continuous Catmull-Rom flight through _shiks_path instead of straight
	## point-to-point hops — the original per-waypoint linear moves read as
	## "a couple of stitched movements" rather than one flow (user report).
	## Y is left untouched, matching the original (which never interpolated
	## height along this path either — see the pre-refactor version).
	var count := mini(7, _shiks_path.size())
	if _shiks_path_i == 0:
		_shiks_path_i = 1
		_shiks_seg_t = 0.0
	if _shiks_path_i >= count:
		_shiks_fly = false
		_piposh_skill2 = 4
		_dialog_index = 2
		_dialog_busy = false
		if _hud:
			_hud.show_dialog(2)
		status.emit("Shiks — dialog 2")
		# Landing spot check: Shiks.wdl has no explicit look-at once the fly
		# loop ends (MyCamera's own action stops updating camera at skill2==4)
		# — camera just freezes at the last flown position/heading. Log where
		# that actually lands vs. where Piposh3/ShikX stand, since a static
		# geometric check on the extracted path found the last waypoint
		# ~550-620 units away with a ~294° facing mismatch (docs/SESSION_LOG.md
		# 2026-07-27) — confirm live whether that's really what renders.
		PiposhDebug.log_msg(
			"shiks",
			(
				"fly-cam ended: cam_pos=%s cam_pan_meta=%s piposh3=%s "
				+ "piposh3_pos=%s piposh3_visible=%s shikx=%s shikx_pos=%s "
				+ "world_cam_pos=%s"
			)
			% [
				str(_my_camera.global_position if _my_camera else null),
				str(_my_camera.get_meta("pan", null) if _my_camera else null),
				str(_piposh3), str(_piposh3.global_position if _piposh3 else null),
				str(_piposh3.visible if _piposh3 else null),
				str(_shik_x), str(_shik_x.global_position if _shik_x else null),
				str(_world_camera.global_position if _world_camera else null),
			]
		)
		return
	var i := _shiks_path_i
	var p0 := _shiks_path[maxi(i - 2, 0)]
	var p1 := _shiks_path[i - 1]
	var p2 := _shiks_path[i]
	var p3 := _shiks_path[mini(i + 1, count - 1)]
	var seg_len := maxf(Vector2(p2.x - p1.x, p2.z - p1.z).length(), 1.0)
	var old_y := _my_camera.global_position.y
	_shiks_seg_t += (80.0 * delta) / seg_len
	if _shiks_seg_t >= 1.0:
		_shiks_seg_t = 0.0
		_shiks_path_i += 1
		var arrived := _catmull_rom_xz(p0, p1, p2, p3, 1.0)
		_my_camera.global_position = Vector3(arrived.x, old_y, arrived.y)
	else:
		var pos_xz := _catmull_rom_xz(p0, p1, p2, p3, _shiks_seg_t)
		var next_xz := _catmull_rom_xz(p0, p1, p2, p3, minf(_shiks_seg_t + 0.02, 1.0))
		_my_camera.global_position = Vector3(pos_xz.x, old_y, pos_xz.y)
		var dir := next_xz - pos_xz
		if dir.length_squared() > 1e-6:
			# Face travel direction (Acknex actor_turnto).
			var pan := rad_to_deg(atan2(-dir.y, dir.x))
			_my_camera.set_meta("pan", pan)
			_my_camera.set_meta("tilt", 0.0)
	if _ztemp != 0.0:
		_my_camera.global_position.y = _ztemp


func _catmull_rom_xz(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector2:
	var a0 := Vector2(p0.x, p0.z)
	var a1 := Vector2(p1.x, p1.z)
	var a2 := Vector2(p2.x, p2.z)
	var a3 := Vector2(p3.x, p3.z)
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * (
		(2.0 * a1)
		+ (a2 - a0) * t
		+ (2.0 * a0 - 5.0 * a1 + 4.0 * a2 - a3) * t2
		+ (a3 - 3.0 * a2 + 3.0 * a1 - a0) * t3
	)


func _update_shiks_actors(delta: float) -> void:
	# Shiks.wdl TurnVase: `if (Talking==11) invisible=off; else invisible=on;`
	# re-checked every tick — mirror that exactly instead of only setting
	# visible=true inside the talking==11 branch below with no reset.
	if _turn_vase:
		_turn_vase.visible = talking == 11
	if _photo_watch and _photo == 0 and AudioBus.get_voice_progress() > 0.7:
		_photo = 1
	if _photo_watch and _photo != 0 and _photo != 3 and AudioBus.get_voice_progress() > 0.9:
		_photo = 3
	if talking == 1 and _photo != 0 and _piposh3:
		# Shiks.wdl action Piposh3: Photo overrides the normal Talk() call
		# while it runs (1=morph to pose + spawn Photos prop, 2=hold pose
		# with mouth-skin talk, 3=morph back to normal).
		if _photo == 1:
			_morph(_piposh3, "PipPhoto")
			_spawn_photos_prop()
			_photo = 2
			_photo_skill1 = 0.0
		elif _photo == 2:
			_anim_talk_skins(_piposh3, true)
			_photo_skill1 += 5.0 * delta
			_anim_frame(_photos_prop, "Photo", fmod(_photo_skill1, 100.0))
		elif _photo == 3:
			_morph(_piposh3, "Piposh")
			_anim_talk_skins(_piposh3, false)
			if _photos_prop and is_instance_valid(_photos_prop):
				_photos_prop.queue_free()
			_photos_prop = null
			_photo = 0
		if _shik_x:
			_anim_blink(_shik_x)
	elif talking == 1 and _piposh3:
		_anim_talk(_piposh3)
		if _shik_x:
			_anim_blink(_shik_x)
	elif talking == 2 and _shik_x:
		_anim_talk(_shik_x)
		if _piposh3:
			_anim_blink(_piposh3)
	elif talking == 22 and _shik_x:
		_anim_frame(_shik_x, "Scream", 0.0)
	elif talking == 11 and _piposh3:
		_anim_cycle(_piposh3, "Dumb")
	elif talking == 12 and _piposh3:
		_anim_cycle(_piposh3, "Walk")
		_piposh3.global_position += Vector3(-10.0, 0.0, 10.0) * delta
		if _shik_x:
			var to := _piposh3.global_position - _shik_x.global_position
			_shik_x.rotation_degrees.y = rad_to_deg(atan2(-to.z, to.x))
	elif talking == 13 and _piposh3:
		_piposh3.visible = false
	else:
		# Idle — do not keep cycling Talk after the line ends.
		if _piposh3:
			_anim_blink(_piposh3)
		if _shik_x:
			_anim_blink(_shik_x)

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
	_shiks_seg_t = 0.0
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
				_photo_watch = true
				await _line("PIP020.WAV", 1, _piposh3)
				_photo_watch = false
				if _photo != 0:
					# Safety net: line ended before voice progress crossed the
					# 90% morph-back threshold (e.g. very short tail) — don't
					# leave Piposh3 stuck as PipPhoto or the prop dangling.
					_morph(_piposh3, "Piposh")
					_anim_talk_skins(_piposh3, false)
					if _photos_prop and is_instance_valid(_photos_prop):
						_photos_prop.queue_free()
					_photos_prop = null
					_photo = 0
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

	# Mouth motion only while Start VO is actually playing.
	if _yachdal and AudioBus.is_voice_playing() and scene in [0, 2, 4] \
			and Engine.get_process_frames() % 45 == 0:
		_anim_frame(_yachdal, "Speech", randf() * 100.0)
	elif _yachdal:
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
		# Aim at chest/head — flattening look.y to cam height buried the actor.
		var look := _yachdal.global_position + Vector3(0.0, 55.0, 0.0)
		_world_camera.look_at(look, Vector3.UP)
	elif scene in [1, 5]:
		# Start.wdl: camera.pan = 270
		_apply_acknex_view(_world_camera, 270.0, 0.0, 0.0)
	else:
		_apply_acknex_view(
			_world_camera,
			float(node.get_meta("pan", 0.0)),
			float(node.get_meta("tilt", 0.0)),
			float(node.get_meta("roll", 0.0))
		)
	_world_camera.fov = _acknex_arc_to_godot_fov(60.0)
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
	if not HAND_PORTS_ENABLED:
		# Interpreted levels set their own camera.* from the script's own
		# coroutines (see _try_begin_interpreted_level()/WdlInterpreter) —
		# this one-time snap only matters for the hand-ported chapters,
		# currently disabled (see HAND_PORTS_ENABLED).
		if _cams.size() > 0 and _wdl_interp == null:
			_snap_to_active_cam(true)
		if _world_camera:
			_world_camera.current = true
		return
	if _is_studio_level():
		_snap_studio_cam()
	elif _is_start_level() and _look_at_me != null:
		_apply_start_camera()
	elif _is_shiks_level():
		_apply_shiks_cam()
	elif _is_plane_level():
		_apply_plane_cam(true)
	elif _is_range_level():
		# Range has its own CamTarget system (_update_range) — the generic
		# "any Cam entity" fallback below would otherwise grab Range.wmb's
		# unrelated movie-intro "Cam" entity (Cam_mdl_124) and fight with it
		# every frame, freezing the view and blocking aim. Confirmed via
		# [copy-cam] debug logs showing Cam_mdl_124 repeatedly overriding
		# the CamTarget-driven camera (see docs/SESSION_LOG.md).
		pass
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
		# Talk2() mouth skins only while Piposh's line is active.
		_anim_talk_skins(_naknik, talking == 1)
		if talking == 2 and _ami:
			_anim_talk(_ami)
		elif _ami:
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


var _town_cam_range_warned := false


func _update_town_cam() -> void:
	if _is_range_level():
		if not _town_cam_range_warned:
			_town_cam_range_warned = true
			PiposhDebug.log_msg(
				"range",
				"_update_town_cam() WAS being called during Range — confirms "
				+ "this was the source of the camera fight, not just "
				+ "ensure_scripted_view()'s one-time call"
			)
		# Defense in depth: _process()'s elif chain should already exclude
		# this level from ever reaching here while _range_active is true,
		# but Range's generic "Cam" entity (the movie-intro camera, unrelated
		# to CamTarget) must never drive the world camera regardless of how
		# this gets called — see ensure_scripted_view() and SESSION_LOG.md.
		return
	var cam := _active_cam()
	if cam == null or _world_camera == null:
		return
	_copy_cam(cam)
	_world_camera.fov = _acknex_arc_to_godot_fov(fov_arc)


func _snap_studio_cam() -> void:
	_apply_studio_cam()


func _snap_to_active_cam(_reset_look: bool) -> void:
	var cam := _active_cam()
	if cam:
		_copy_cam(cam, true)


func _apply_cam_smooth(cam: Node3D, delta: float) -> void:
	if cam == null or _world_camera == null:
		return
	if not _cam_pos_ready:
		_copy_cam(cam, true)
		return
	var target_pos := cam.global_position
	var k := 1.0 - exp(-CAM_FOLLOW_SPEED * delta)
	_cam_pos = _cam_pos.lerp(target_pos, k)
	_world_camera.global_position = _cam_pos
	_copy_cam(cam, false)


func _copy_cam(cam: Node3D, hard: bool = true) -> void:
	if cam == null or _world_camera == null:
		return
	# Position + orientation copied 1:1 from the entity, matching the original
	# engine exactly (Studio.wdl TheCam/TheCam2: `camera.x=my.x; camera.z=my.z;
	# camera.tilt=my.tilt; camera.pan=my.pan; camera.roll=my.roll` — no offset,
	# no softening). A prior session added a +14 Y "lens lift" and a tilt
	# softening curve here, both eyeballed guesses with no source backing —
	# removed after Shiks reported the camera sitting wrong (see SESSION_LOG).
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


func _set_entity_tilt_roll(node: Node3D, tilt_deg: float, roll_deg: float) -> void:
	## Rebuild ang_to_matrix basis for a tilt/roll change, keeping authored
	## pan. Acknex tilt/roll rotate about the entity's OWN local axes (post
	## pan), not fixed world axes — e.g. Shiks.wdl WaterWheel does
	## `my.roll += 5` and TurnVase does `my.tilt += 20*time; my.roll +=
	## 20*time`. Hardcoded `rotation_degrees.x/z +=` (Godot world/local
	## axes) only coincidentally matches for pan=0. Reported: water wheel
	## "spins on the wrong axis" once the facing pipeline changed its
	## authored pan — this is the general fix (see docs/SESSION_LOG.md).
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
	var radius := 48.0 if action == "ShikKlik" else 28.0
	if not has_area:
		var area := Area3D.new()
		area.collision_layer = 2
		area.collision_mask = 0
		area.input_ray_pickable = true
		var cs := CollisionShape3D.new()
		var shape := SphereShape3D.new()
		# Studio notepad (AFG / ShikNote) sits far from TheCam2 — large pick.
		shape.radius = radius
		cs.shape = shape
		area.add_child(cs)
		node.add_child(area)
	PiposhDebug.log_msg(
		"click-wire",
		"node=%s action=%s pos=%s radius=%.1f had_existing_area=%s"
		% [node.name, action, str(node.global_position), radius, has_area]
	)


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
	if action == "StartDialog":
		if _dialog_busy or _studio_boot:
			return
		if _hud:
			_hud.show_dialog(0)
		return
	if action == "ShikKlik":
		_run_shik()
		return
	if action == "AFG_Take":
		_run_afg_take(node)
		return
	if _is_plane2_level() and _plane2_active:
		if _p2_movie or _p2_finale:
			return
		var a := action.to_lower()
		if a == "headphone" or a.begins_with("headphone"):
			_run_plane2_hp()
			return
		if a == "tv":
			_run_plane2_tv()
			return
		if a == "passanger" or a == "hitme":
			_run_plane2_passanger()
			return
		if a == "sikot":
			_run_plane2_sikot()
			return
		if a == "stu1":
			_run_plane2_stu1()
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


func _on_dialog_choice(choice: int) -> void:
	if _dialog_busy or _studio_boot:
		return
	status.emit("Dialog choice %d" % choice)
	if _is_plane_level() and _plane_active:
		_run_plane_choice(choice)
	elif _is_shiks_level() and _shiks_active:
		_run_shiks_choice(choice)
	else:
		_run_studio_choice(choice)


func _run_plane_choice(choice: int) -> void:
	# Plane.wdl PiposhWalk DialogIndex==3 branches.
	_dialog_busy = true
	if _hud:
		_hud.hide_dialog()
	match choice:
		1:
			await _line("PIP028.WAV", 1, _plane_piposh)
			await _line("KRP002.WAV", 2, _plane_krupnik)
			await _line("PIP029.WAV", 1, _plane_piposh)
			await _line("KRP003.WAV", 2, _plane_krupnik)
			_dialog_busy = false
			_dialog_index = 3
			if _hud:
				_hud.show_dialog(3)
		2:
			await _line("PIP030.WAV", 1, _plane_piposh)
			await _line("KRP004.WAV", 2, _plane_krupnik)
			_dialog_busy = false
			_dialog_index = 3
			if _hud:
				_hud.show_dialog(3)
		3:
			_plane_vase = 1
			# PIP031: Take frame + Talk2 — driven by _update_plane while vase==1.
			await _line("PIP031.WAV", 1, null)
			_plane_vase = 0
			_plane_phase = 1
			_cam_show = 1
			await _line("KRP005.WAV", 2, _plane_krupnik)
			_plane_phase = 2
			await _line("KRP006.WAV", 2, _plane_krupnik)
			_cam_show = 0
			if _plane_cams.size() > 0:
				_plane_view = _plane_cams[0]
			_apply_plane_cam(true)
			if _plane_piposh:
				_plane_piposh.visible = false
			_plane_phase = 3
			_plane_pip2 = 1
			_plane_vase = 2
			await _line("PIP032.WAV", 1, _plane_pip)
			await _line("KRP007.WAV", 2, _plane_krupnik)
			await _line("PIP033.WAV", 1, _plane_pip)
			_dialog_busy = false
			_plane_walking = false
			status.emit("Plane → Plane2")
			request_run.emit("Plane2")
		_:
			_dialog_busy = false
			_dialog_index = 3
			if _hud:
				_hud.show_dialog(3)


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


func _run_afg_take(node: Node3D) -> void:
	## Afgan.wdl AFG_Take: AFG[my.skill1]=1; WriteGameData(0); remove(my);
	## plus a HUD "card shown" fade the original does via AFG_Show — not yet
	## ported (see docs/SESSION_LOG.md). Persisting the flag + removing the
	## entity is the gameplay-relevant part: without it the same card could
	## be picked up again every visit.
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


func _disable_collision(n: Node) -> void:
	if n is StaticBody3D:
		(n as StaticBody3D).collision_layer = 0
		(n as StaticBody3D).collision_mask = 0
	for c in n.get_children():
		_disable_collision(c)


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
	## HUD card) for a fixed duration, no alpha ramp — the original's smooth
	## fade is not yet ported (see docs/SESSION_LOG.md).
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
	# Small + far enough to read as a corner HUD card, not fill the screen.
	# Tune CARD_SCALE/CARD_DIST together after a playtest — LeCards.glb's
	# authored size wasn't known ahead of time (see docs/SESSION_LOG.md).
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


func _line(wav: String, who: int, actor: Node3D) -> void:
	talking = who
	_skip_line = false
	if _is_studio_level():
		_snap_studio_cam()
	elif _is_shiks_level():
		_apply_shiks_cam()
	elif _is_plane_level():
		_apply_plane_cam(false)
	if actor:
		if dance == 1 and actor == _naknik:
			_anim_cycle(actor, "Dance")
			_anim_talk_skins(actor, who == 1)
		elif who == 22:
			_anim_frame(actor, "Scream", 0.0)
		elif _is_plane_level() and actor == _plane_krupnik:
			# ThePlaneMovie: Talk2 skins + Peek/Arrive/Talk frames in _update_plane.
			_anim_talk_skins(actor, who == 2)
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
	# Stop mouth anim as soon as the VO ends (caller may set talking again).
	if talking == who:
		talking = 0
	if actor and who != 0:
		if dance == 1 and actor == _naknik:
			_anim_talk_skins(actor, false)
		elif _is_plane_level() and actor == _plane_krupnik:
			_anim_talk_skins(actor, false)
		else:
			_anim_blink(actor)
	if not skipped:
		await get_tree().create_timer(0.05).timeout


## Acknex `morph(<File.mdl>, entity)` — see MdlAnimator.morph_to(). Entities
## that never get an MdlAnimator at spawn (e.g. no .mdlanim/.skins and a
## static single-surface mesh) have nothing to morph; such a call is a no-op
## here exactly like it would be a silent do-nothing in the original engine
## if the entity had no animator either.
func _morph(node: Node3D, stem: String) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	var anim := node.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim == null:
		return false
	return anim.morph_to(stem)


## Shiks.wdl action Photos: `create(<Photos.mdl>, my.x, Photos)` then the new
## entity copies `you.x/y/z/pan/scale` once at spawn. `you` isn't assigned
## anywhere in Shiks.wdl (a built-in/shared-header binding this port can't
## trace) — approximated with Piposh3's own transform, the actual subject of
## the photo, since the prop is purely decorative (a camera-flash/photo
## overlay). Flagged here rather than guessed silently.
func _spawn_photos_prop() -> void:
	if _piposh3 == null or not is_instance_valid(_piposh3):
		return
	if _photos_prop and is_instance_valid(_photos_prop):
		_photos_prop.queue_free()
	var path := "res://assets/converted/mdl/Photos.glb"
	if not ResourceLoader.exists(path):
		return
	var packed := load(path)
	if not (packed is PackedScene):
		return
	var prop := (packed as PackedScene).instantiate() as Node3D
	if prop == null:
		return
	var parent := _piposh3.get_parent()
	if parent == null:
		return
	parent.add_child(prop)
	prop.global_transform = _piposh3.global_transform
	var anim := MdlAnimator.new()
	anim.name = "MdlAnimator"
	prop.add_child(anim)
	anim.setup_from_stem("Photos", prop)
	_photos_prop = prop


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
