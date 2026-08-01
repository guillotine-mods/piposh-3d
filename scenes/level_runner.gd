extends Node3D
## Hosts a WMB level and runs WDL-derived behaviours (cameras, HUD, mouse).

@onready var loader: WmbLevelLoader = $WmbLevelLoader
@onready var player: CharacterBody3D = $Player
@onready var hud_title: Label = $UI/Title
@onready var hud_hint: Label = $UI/Hint

const DEBUG_LEVELS := [
	"Studio", "Start", "Town", "Map", "Travel", "Desert", "Mansion", "Inn",
	"Plane", "Plane2", "Range", "Plane3",
]
## Cutscene / fixed-cam chapters — never free-player, even if a Cam exists.
const CUTSCENE_LEVELS := [
	"studio", "start", "town", "menu", "credits", "shiks", "plane",
]

var _director: WdlDirector
var _script_cam: Camera3D
var _game_hud: GameHud
var _touch: TouchControls
var _acknex_sky: AcknexSky
var _level_select: CanvasLayer

## Set once at setup(); used by _process()'s per-frame camera-authority
## arbitration. Only fp-mode levels need this: scripted/free modes already
## have a single, unambiguous camera owner decided once at setup with no
## per-frame contention.
var _use_fp := false
var _player_cam: Camera3D
var _camera_authority := CameraAuthority.new()


func _ready() -> void:
	# Level load (WMB/GLB parsing, entity spawn, every action coroutine
	# starting) is a heavy synchronous block below -- nothing renders while
	# it runs, which reads as "the game froze" rather than "it's loading"
	# (reported live, 2026-07-31: "stages are first 'stuck' and then
	# play"). A real progress bar would need the load itself made async,
	# which is a much bigger change; this is the minimal fix for the
	# actual complaint -- show *something* before the freeze starts, so it
	# reads as a loading screen instead of a hang. Two `await process_frame`
	# calls force Godot to actually paint this overlay before the heavy
	# synchronous work below begins: one frame to process the newly added
	# node into the tree, another to render it.
	var loading := _show_loading_screen()
	await get_tree().process_frame
	await get_tree().process_frame

	AudioChannels.rebuild_index()
	_ensure_environment()
	_acknex_sky = AcknexSky.new()
	_acknex_sky.name = "AcknexSky"
	add_child(_acknex_sky)
	hud_title.visible = false
	hud_hint.visible = false

	# Player camera must not stay current — tscn defaults it on and that causes
	# free-fall views when scripted levels forget to switch.
	var player_cam := player.get_node_or_null("Camera3D") as Camera3D
	if player_cam:
		player_cam.current = false
		player_cam.far = 12000.0
		player_cam.near = 1.0

	_game_hud = GameHud.new()
	_game_hud.name = "GameHud"
	add_child(_game_hud)

	_touch = TouchControls.new()
	_touch.name = "TouchControls"
	add_child(_touch)
	_touch.bind_player(player)

	_script_cam = Camera3D.new()
	_script_cam.name = "ScriptCamera"
	_script_cam.far = 12000.0
	_script_cam.near = 1.0
	_script_cam.current = true
	add_child(_script_cam)

	_director = WdlDirector.new()
	_director.name = "WdlDirector"
	add_child(_director)
	_director.status.connect(_on_status)
	_director.request_run.connect(_on_run)

	var level := GameState.current_level
	loader.entity_triggered.connect(_on_entity_triggered)
	var ok := loader.load_level(level)
	_apply_wdl_sky(level)

	_director.setup(loader, _script_cam, loader.last_level_data, _game_hud)

	# Plane2.wdl Vview=1 → move_view_1st. Any WMB with player_walk* wins over cams.
	var use_fp := loader.has_first_person() and not _is_cutscene(level)
	var use_scripted := (not use_fp) and (_director.scripted_camera or _is_cutscene(level))
	_use_fp = use_fp
	_player_cam = player.get_node_or_null("Camera3D") as Camera3D
	if use_fp:
		_camera_authority.configure(_player_cam, _script_cam, _director.get("_wdl_interp"))

	if use_fp:
		_enable_first_person()
	elif use_scripted:
		_disable_player_controller()
		_script_cam.current = true
		_director.ensure_scripted_view()
	else:
		_enable_free_player(loader.spawn_position)

	_game_hud.set_debug_text(
		level,
		"script=%s | mode=%s | F1=Menu F3=Next F4=Levels F10=debug"
		% [
			str(loader.last_level_data.get("script", "?")),
			"FP" if use_fp else ("scripted" if use_scripted else "free"),
		]
	)
	if not ok:
		_game_hud.set_status("MISSING JSON")

	loading.queue_free()


func _show_loading_screen() -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.name = "LoadingScreen"
	layer.layer = 40  # above GameHud (20) and the level-select menu (30).
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.07, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)
	var label := Label.new()
	label.text = "Loading..."
	label.add_theme_font_size_override("font_size", 28)
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bg.add_child(label)
	add_child(layer)
	return layer


func _is_cutscene(level: String) -> bool:
	return level.to_lower() in CUTSCENE_LEVELS


## Per-frame camera-authority arbitration for fp-mode levels: real Acknex
## has one camera, so a script writing camera.x/y/z (a Cam-entity-driven
## shot during a click interaction, e.g. WDL/Afgan.wdl's pattern) always
## affects what the player sees. Delegated to CameraAuthority (see
## docs/CONTRACT.md §4.1.1); fixed-camera-mode levels never call update().
func _process(_delta: float) -> void:
	if not _use_fp:
		return
	_camera_authority.update()


func _entity_mesh_aabb(root: Node3D) -> AABB:
	var acc := AABB()
	var has := false
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh:
			var mi := n as MeshInstance3D
			var local := mi.transform * mi.mesh.get_aabb()
			if not has:
				acc = local
				has = true
			else:
				acc = acc.merge(local)
		for c in n.get_children():
			stack.append(c)
	return acc if has else AABB(Vector3(0, -58, 0), Vector3(1, 115, 1))


func _enable_first_person() -> void:
	## Plane2 / Mansion / Inn… — camera at player (move_view_1st).
	_director.scripted_camera = false
	_director.mouse_look = true
	var spawn: Dictionary = loader.first_person_spawn
	var origin: Vector3 = spawn.get("origin", loader.spawn_position)
	var pan := float(spawn.get("pan", 0.0))
	# Piposh-class AABB after convert ≈ minY=-58 maxY=57 (move_view_1st eye factor).
	var min_z := -58.0
	var max_z := 57.0
	var body: Node3D = spawn.get("node") as Node3D
	if body:
		var aabb := _entity_mesh_aabb(body)
		if aabb.size.y > 1.0:
			min_z = aabb.position.y
			max_z = aabb.position.y + aabb.size.y
	if player.has_method("configure_acknex_first_person"):
		player.configure_acknex_first_person(pan, min_z, max_z)
	player.global_position = origin
	player.visible = true
	player.set_physics_process(true)
	player.set_process_unhandled_input(true)
	player.collision_layer = 1
	player.collision_mask = 1
	var player_cam := player.get_node_or_null("Camera3D") as Camera3D
	if player_cam:
		player_cam.current = true
	_script_cam.current = false
	# Land on brush collision (WED Y can sit under the walkable deck).
	# max_drop kept small (not the 400-unit default): Plane2's own spawn
	# point has no collision geometry between the WED spawn Y and the
	# next surface straight down, which happens to be a lower deck ~59
	# units below -- a full-range raycast finds that as its "closest
	# hit" and snaps the player into it, embedded in collision and unable
	# to move at all. Reported live (2026-08-01): "the character is lower
	# than the plane so we can't move." A tight max_drop means a genuine
	# small WED/collision gap still gets corrected, but a wrong deck this
	# far away is out of range -- the raycast finds nothing and leaves
	# the player at the original (trustworthy) WED spawn position instead.
	if player.has_method("snap_to_floor"):
		await get_tree().physics_frame
		player.snap_to_floor(40.0)
	var use_touch := (
		OS.has_feature("mobile")
		or OS.get_name() == "Android"
		or DisplayServer.is_touchscreen_available()
	)
	if use_touch and _touch:
		_touch.set_active(true)
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	else:
		if _touch:
			_touch.set_active(false)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if _game_hud:
			_game_hud.set_mouse_look(true)
	_director.status.emit(
		"%s — first person (%s)" % [
			str(loader.level_name),
			"touch pads" if use_touch else "WASD + mouse",
		]
	)


func _enable_free_player(at: Vector3) -> void:
	player.global_position = at
	player.visible = true
	player.set_physics_process(true)
	player.set_process_unhandled_input(true)
	player.collision_layer = 1
	player.collision_mask = 1
	var player_cam := player.get_node_or_null("Camera3D") as Camera3D
	if player_cam:
		player_cam.current = true
	_script_cam.current = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _disable_player_controller() -> void:
	player.visible = false
	player.set_physics_process(false)
	player.set_process_unhandled_input(false)
	player.velocity = Vector3.ZERO
	player.collision_layer = 0
	player.collision_mask = 0
	# Park far below the level so a mistaken current camera isn't near spawn.
	player.global_position = Vector3(0.0, -10000.0, 0.0)


func _ensure_environment() -> void:
	if has_node("WorldEnvironment"):
		return
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.45, 0.55, 0.7)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.55, 0.6)
	env.ambient_light_energy = 0.85
	we.environment = env
	add_child(we)


func _apply_wdl_sky(level: String) -> void:
	## IO.wdl / Level.wdl sky_map + scene_map (not solid placeholder colors).
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we == null or we.environment == null or _acknex_sky == null:
		return
	_acknex_sky.apply(level, loader.level_bounds, we.environment)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			LevelRouter.goto_level("Menu")
		elif event.keycode == KEY_F2:
			GameState.save_slot(1)
			_game_hud.set_status("Saved slot 1 @ %s" % GameState.current_level)
		elif event.keycode == KEY_F3:
			var idx := DEBUG_LEVELS.find(GameState.current_level)
			idx = (idx + 1) % DEBUG_LEVELS.size()
			LevelRouter.goto_level(DEBUG_LEVELS[idx])
		elif event.keycode == KEY_F10:
			_game_hud.show_debug = not _game_hud.show_debug
			_game_hud.set_debug_text(GameState.current_level, "F1=Menu F3=Next F4=Levels F10=debug")
		elif event.keycode == KEY_F4:
			_toggle_level_select()
		elif event.keycode == KEY_ESCAPE and _level_select:
			_toggle_level_select()


func _toggle_level_select() -> void:
	## Dev/debug level jump (F4) -- requested so any level (e.g. Range, which
	## otherwise only loads at the end of Plane -> Plane2 -> Range) can be
	## reached directly without playing through the levels before it.
	if _level_select:
		_level_select.queue_free()
		_level_select = null
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if not _director.mouse_look \
			else Input.MOUSE_MODE_CAPTURED
		return
	_level_select = CanvasLayer.new()
	_level_select.layer = 30
	var root_ctrl := Control.new()
	root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_STOP
	_level_select.add_child(root_ctrl)

	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.08, 0.85)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.add_child(bg)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(240, 40)
	panel.custom_minimum_size = Vector2(360, 640)
	root_ctrl.add_child(panel)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)
	var label := Label.new()
	label.text = "Level select (F4 to close, click a level)"
	label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(label)

	var list := ItemList.new()
	list.custom_minimum_size = Vector2(340, 600)
	list.select_mode = ItemList.SELECT_SINGLE
	vbox.add_child(list)

	var names: Array[String] = []
	var dir := DirAccess.open("res://assets/converted/levels/")
	if dir:
		dir.list_dir_begin()
		var fn := dir.get_next()
		while fn != "":
			if fn.ends_with(".json") and not fn.ends_with("_brush.json"):
				names.append(fn.get_basename())
			fn = dir.get_next()
	names.sort()
	for n in names:
		list.add_item(n)
	list.item_clicked.connect(func(index: int, _at: Vector2, _button: int) -> void:
		_toggle_level_select()
		LevelRouter.goto_level(names[index])
	)

	add_child(_level_select)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_status(msg: String) -> void:
	if _game_hud:
		_game_hud.set_status(msg)


func _on_run(level_name: String) -> void:
	LevelRouter.goto_level(level_name)


func _on_entity_triggered(action: String, _skills: Array, node: Node3D) -> void:
	_director.handle_action(action)
	_game_hud.set_status("Trigger: %s (%s)" % [action, node.get_meta("file", "")])
