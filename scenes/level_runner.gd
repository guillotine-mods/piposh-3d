extends Node3D
## Hosts a WMB level and runs WDL-derived behaviours (cameras, HUD, mouse).

@onready var loader: WmbLevelLoader = $WmbLevelLoader
@onready var player: CharacterBody3D = $Player
@onready var hud_title: Label = $UI/Title
@onready var hud_hint: Label = $UI/Hint

const DEBUG_LEVELS := ["Studio", "Start", "Town", "Map", "Travel", "Desert", "Mansion", "Inn"]
## Levels that always use WDL scripted cameras (never free-player gravity).
const SCRIPTED_LEVELS := [
	"studio", "start", "town", "menu", "credits", "shiks", "plane", "plane2", "plane3"
]

var _director: WdlDirector
var _script_cam: Camera3D
var _game_hud: GameHud
var _acknex_sky: AcknexSky


func _ready() -> void:
	AudioBus.rebuild_index()
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

	var use_scripted := _director.scripted_camera or _level_forces_scripted(level)
	if use_scripted:
		_disable_player_controller()
		_script_cam.current = true
		_director.ensure_scripted_view()
	else:
		player.global_position = loader.spawn_position
		player.visible = true
		player.set_physics_process(true)
		player.set_process_unhandled_input(true)
		player.collision_layer = 1
		player.collision_mask = 1
		if player_cam:
			player_cam.current = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	_game_hud.set_debug_text(
		level,
		"script=%s | F1=Menu F3=Next F10=debug" % str(loader.last_level_data.get("script", "?"))
	)
	if not ok:
		_game_hud.set_status("MISSING JSON")


func _level_forces_scripted(level: String) -> bool:
	return level.to_lower() in SCRIPTED_LEVELS


func _level_is(level: String, name: String) -> bool:
	return level.to_lower() == name


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
			_game_hud.set_debug_text(GameState.current_level, "F1=Menu F3=Next F10=debug")


func _on_status(msg: String) -> void:
	if _game_hud:
		_game_hud.set_status(msg)


func _on_run(level_name: String) -> void:
	LevelRouter.goto_level(level_name)


func _on_entity_triggered(action: String, _skills: Array, node: Node3D) -> void:
	_director.handle_action(action)
	_game_hud.set_status("Trigger: %s (%s)" % [action, node.get_meta("file", "")])
