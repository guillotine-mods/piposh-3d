extends Node3D
## 3D menu shell based on Menu.wdl / Menu.WMB

@onready var loader: WmbLevelLoader = $WmbLevelLoader
@onready var player: CharacterBody3D = $Player
@onready var hud: Label = $UI/Hint
@onready var panel: PanelContainer = $UI/MenuPanel
@onready var bg: TextureRect = $UI/BG

var _script_cam: Camera3D
var _menu_cam: Node3D
var _piposh: Node3D
var _p_show: TextureRect
var _show_idx := 1


func _ready() -> void:
	_ensure_environment()
	AudioChannels.rebuild_index()

	# mainmsg is the death/retry panel in WDL — keep faint, not a full takeover
	var art := "res://assets/converted/gfx/mainmsg.png"
	if ResourceLoader.exists(art):
		bg.texture = load(art)
		bg.modulate = Color(1, 1, 1, 0.15)

	_script_cam = Camera3D.new()
	_script_cam.name = "MenuCam"
	_script_cam.far = 8000.0
	_script_cam.near = 1.0
	_script_cam.fov = 60.0
	add_child(_script_cam)

	loader.entity_triggered.connect(_on_entity_triggered)
	loader.load_level("Menu")
	_find_menu_cam()
	_find_piposh()
	_add_show_mov_panel()

	player.visible = false
	player.set_physics_process(false)
	player.set_process_unhandled_input(false)
	_script_cam.current = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	AudioChannels.play_music("SNG032.WAV", -8.0)
	panel.visible = true
	hud.text = "Menu — New Game → Studio | click ShowMov (bottom-right) | Esc quits look"


func _process(_delta: float) -> void:
	if _menu_cam == null or _script_cam == null:
		return
	# Menu.wdl: camera at Cam, vec_to_angle toward player (Piposh).
	_script_cam.global_position = _menu_cam.global_position
	var target := Vector3.ZERO
	if _piposh != null:
		target = _piposh.global_position
	else:
		target = loader.spawn_position
	if target.distance_to(_script_cam.global_position) > 1.0:
		var aim := target
		aim.y = _script_cam.global_position.y
		_script_cam.look_at(aim, Vector3.UP)
	elif _menu_cam.has_meta("pan"):
		var pan: float = float(_menu_cam.get_meta("pan", 0.0))
		var tilt: float = float(_menu_cam.get_meta("tilt", 0.0))
		var p: float = deg_to_rad(pan)
		var t: float = deg_to_rad(tilt)
		var fwd: Vector3 = Vector3(cos(p) * cos(t), sin(t), -sin(p) * cos(t)).normalized()
		_script_cam.look_at(_script_cam.global_position + fwd, Vector3.UP)


func _find_menu_cam() -> void:
	var entities := loader.get_node_or_null("Entities")
	if entities == null:
		return
	for n in entities.get_children():
		if n is Node3D and str(n.get_meta("action", "")).to_lower() == "cam":
			_menu_cam = n
			return


func _find_piposh() -> void:
	var entities := loader.get_node_or_null("Entities")
	if entities == null:
		return
	for n in entities.get_children():
		if not (n is Node3D):
			continue
		var action := str(n.get_meta("action", "")).to_lower()
		var file := str(n.get_meta("file", "")).to_lower()
		if action in ["player_walk2", "player"] or file.contains("piposh"):
			_piposh = n
			return


func _add_show_mov_panel() -> void:
	# Menu.wdl pShow @ (460,450) — toggles movie skip flag
	var layer := CanvasLayer.new()
	layer.layer = 30
	add_child(layer)
	_p_show = TextureRect.new()
	_p_show.texture = _gfx("ShowMov1.png")
	_p_show.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_p_show.stretch_mode = TextureRect.STRETCH_KEEP
	if _p_show.texture:
		_p_show.size = _p_show.texture.get_size()
	_p_show.position = Vector2(460, 450) * (get_viewport().get_visible_rect().size.x / 640.0) * 0.5
	# Place bottom-right-ish in 1280x720
	var vp := get_viewport().get_visible_rect().size
	var s := minf(vp.x / 640.0, vp.y / 480.0)
	_p_show.scale = Vector2(s, s)
	_p_show.position = Vector2(460.0 * s + (vp.x - 640.0 * s) * 0.5, 450.0 * s + (vp.y - 480.0 * s) * 0.5)
	_p_show.gui_input.connect(_on_show_mov_input)
	_p_show.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(_p_show)


func _on_show_mov_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_show_idx = 1 + (_show_idx % 3)
		var tex := _gfx("ShowMov%d.png" % _show_idx)
		if tex:
			_p_show.texture = tex
			_p_show.size = tex.get_size()
		# ShowMov2/3 mean skip intro movies next boot
		GameState.skip_intro_movies = _show_idx > 1
		hud.text = "Movies %s" % ("OFF" if GameState.skip_intro_movies else "ON")


func _gfx(name: String) -> Texture2D:
	var path := "res://assets/converted/gfx/%s" % name
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null


func _ensure_environment() -> void:
	if has_node("WorldEnvironment"):
		return
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.1, 0.16)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.55, 0.7)
	env.ambient_light_energy = 0.9
	we.environment = env
	add_child(we)


func _on_entity_triggered(action: String, _skills: Array, node: Node3D) -> void:
	var file := str(node.get_meta("file", "")).to_lower()
	if action == "MenuDoor" or action == "GoToDoor":
		if "new" in file:
			_new_game()
		elif "load" in file:
			_show_load()
		elif "exit" in file:
			get_tree().quit()
		elif "cred" in file:
			AudioChannels.stop_music()
			LevelRouter.goto_level("Credits")
		else:
			_new_game()


func _new_game() -> void:
	GameState.reset_new_game()
	AudioChannels.stop_music()
	AudioChannels.play_sfx("MenuNew.wav")
	await get_tree().create_timer(0.35).timeout
	LevelRouter.goto_level("Studio")


func _show_load() -> void:
	AudioChannels.play_sfx("MenuLoad.wav")
	panel.visible = true


func _on_new_pressed() -> void:
	_new_game()


func _on_load1_pressed() -> void:
	if GameState.load_slot(1):
		LevelRouter.goto_level(GameState.current_level)
	else:
		hud.text = "No save in slot 1"


func _on_credits_pressed() -> void:
	AudioChannels.stop_music()
	LevelRouter.goto_level("Credits")


func _on_quit_pressed() -> void:
	get_tree().quit()
