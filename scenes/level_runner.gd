extends Node3D
## Hosts a WMB level and runs WDL-derived behaviours (cameras, HUD, mouse).

const AcknexSky = preload("res://scripts/engine/acknex_sky.gd")
const CameraAuthority = preload("res://scripts/engine/camera_authority.gd")
const GameHud = preload("res://scripts/ui/game_hud.gd")
const SettingsPanel = preload("res://scripts/ui/settings_panel.gd")
const TouchControls = preload("res://scripts/ui/touch_controls.gd")
const WdlDirector = preload("res://scripts/engine/wdl_director.gd")
const WmbLevelLoader = preload("res://scripts/engine/wmb_level_loader.gd")

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
var _settings: SettingsPanel

## Set once at setup(); used by _process()'s per-frame camera-authority
## arbitration. Only fp-mode levels need this: scripted/free modes already
## have a single, unambiguous camera owner decided once at setup with no
## per-frame contention.
var _use_fp := false
var _player_cam: Camera3D
var _camera_authority := CameraAuthority.new()

## See _apply_wdl_sky()'s own docstring. Originally a short (300-frame)
## post-load-only window sized for main()'s own opening wait(3), but
## `sky_map`/`cloud_map` genuinely change for the REST of a level's
## runtime in several real scripts (Ziggy's own per-wave `SetWeather()`,
## Desert's Mansion-stage storm, Intro3's storm, Mount's snow -- all real,
## ongoing `WDL/Weather.wdl`-driven effects, not one-shot setup) --
## reported live (2026-08-10): "vastly different background and sky for
## scenes... not seen in the back." Polls for the whole level's lifetime
## now; three cheap string reads per frame is not worth special-casing
## away, and `_apply_wdl_sky()` itself only does real work (clearing/
## rebuilding the sky dome + cylinder) when a value actually changed.
var _last_applied_scene_map := ""
var _last_applied_sky_map := ""
var _last_applied_cloud_map := ""
## See `_apply_wdl_fog()`'s own docstring. -1.0 = "no value read yet".
var _last_applied_fog := -1.0
var _last_applied_fog_color := Vector3(-1.0, -1.0, -1.0)


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

	_settings = SettingsPanel.new()
	_settings.name = "SettingsPanel"
	add_child(_settings)

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

	var level := Piposh3DState.current_level
	loader.entity_triggered.connect(_on_entity_triggered)
	var ok := loader.load_level(level)
	print("[level] starting level=%s script=%s source=%s" % [
		level,
		str(loader.last_level_data.get("script", "?")),
		str(loader.last_level_data.get("source", "?")),
	])
	_director.setup(loader, _script_cam, loader.last_level_data, _game_hud)

	_apply_wdl_sky(level)

	# Plane2.wdl Vview=1 → move_view_1st. Any WMB with player_walk* wins over cams.
	var use_fp := loader.has_first_person() and not _is_cutscene(level)
	var use_scripted := (not use_fp) and (_director.scripted_camera or _is_cutscene(level))
	_use_fp = use_fp
	_player_cam = player.get_node_or_null("Camera3D") as Camera3D
	if use_fp:
		var fp_body := loader.first_person_spawn.get("node") as Node3D
		_camera_authority.configure(_player_cam, _script_cam, _director.get("_wdl_interp"), fp_body)

	if use_fp:
		_enable_first_person()
	elif use_scripted:
		_disable_player_controller()
		_script_cam.current = true
		_director.ensure_scripted_view()
		# GB-7 (2026-08-04, Range): scripted-camera levels that aim via
		# raw mouse delta (`action CamTarget`'s own `mickey.x/y`, e.g.
		# Range's shooting gallery) need the same captured/hidden cursor
		# _enable_first_person() already gives real FP levels -- otherwise
		# the OS cursor sits visible and free-roaming, giving the player a
		# misleading "aim point" that has nothing to do with where the
		# camera (and therefore shots) actually point. See
		# WdlInterpreter.uses_mickey_aiming()'s own comment.
		var interp: Node = _director.get("_wdl_interp")
		if interp != null and bool(interp.call("uses_mickey_aiming")):
			PiposhDebug.log_msg("mouse-mode", "level_runner setup -> CAPTURED (mickey aiming)")
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		_enable_free_player(loader.spawn_position)

	_game_hud.set_debug_text(
		level,
		"script=%s | mode=%s | F1=Menu F3=Next F4=Levels F6=Plane3 F7=Plane2 F8=Smash F9=Settings Space=Recenter F10=debug"
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
	var live_scene := _live_scene_map_file()
	var live_sky := _live_bmap_file("sky_map")
	var live_cloud := _live_bmap_file("cloud_map")
	if (
		(live_scene != "" and live_scene != _last_applied_scene_map)
		or (live_sky != "" and live_sky != _last_applied_sky_map)
		or (live_cloud != "" and live_cloud != _last_applied_cloud_map)
	):
		_apply_wdl_sky(Piposh3DState.current_level)
	_apply_wdl_fog()
	if not _use_fp:
		return
	_camera_authority.update()


## Reported live (2026-08-10): "when Piposh falls there's fog... that
## don't exist in the current graphics" and, follow-up same day: "the fog
## is not implemented well." `camera.fog = N;` (11 corpus levels, e.g.
## Plane2/Plane3/Smash's own main()) was entirely unbridged in the
## interpreter before this session -- see `WdlInterpreter._set_camera_
## field()`'s own "fog" case, which stores the live value as camera meta
## since the interpreter has no direct Environment reference of its own.
## Polled continuously here (same shape as sky_map/cloud_map/scene_map
## above) since some levels change it mid-level too (Plane2's own
## `camera.fog=0;` partway through, to clear fog for a specific moment).
##
## `fog_color` was FIRST left unapplied, guessed to be unused boilerplate
## since every level that sets it always uses the same literal `1`. Re-
## examined after getting a real, live reference render of the actual
## engine running (3D GameStudio A5, launched directly via the project's
## own `piposh_3d_cursor` dgVoodoo2 test harness -- see docs/SESSION_LOG.md
## for the full capture story): the game's own sky is genuinely a NIGHT
## scene (deep blue-purple, visible stars, confirmed both via that live
## capture and user-provided screenshots). Per this session's own earlier
## "VECTOR = SCALAR sets only .x" finding (GB-20), `fog_color=1;` really
## does mean (red=1, green=0, blue=0) -- in the same roughly-0-255 scale
## `sky_color.red` is seen using elsewhere in the corpus (up to 250) --
## i.e. very close to pure BLACK. Read as "boilerplate" that seemed odd
## in isolation, but is exactly the sensible, deliberate choice for a
## NIGHT-time fog (distant geometry fading to near-black darkness, not a
## daytime gray haze) -- so this now reads the real live `fog_color`
## value and applies it as the actual fog tint instead of a fixed guess.
##
## Follow-up (2026-08-10): "now the plane3 level is really dark. It
## looked better before you added the fog." Got a real, live A5 capture
## of Plane3 itself this time (same dgVoodoo2 harness): distant trees are
## completely crisp and unfogged even near the edge of view -- confirmed
## `camera.fog=10;` (Plane3's own value) produces NO perceptible fog in
## the real engine. Also captured this port's own Plane3 non-headless
## (loading `level_runner.tscn` directly, real GPU rendering, not the
## headless dummy renderer): the ENTIRE screen was solid black except a
## small foreground character. Root cause: the previous `fog_depth_end =
## 60000.0/value` guess treated `camera.fog`'s own small values (0/10/30
## corpus-wide) as if they scaled inversely to a literal GS-unit
## distance -- but Plane3's own falling/aerial scene naturally has the
## camera thousands of units from most geometry (confirmed elsewhere this
## session: `PipFall`'s own Z sits around 4100+), so a fixed 6000-unit
## fog_depth_end put nearly the WHOLE visible scene beyond full fog
## density, at the SAME near-black `fog_color` GB-24 correctly derived --
## a level-agnostic constant can't work when GS scene scale varies this
## much between levels (Town's close-quarters street vs. Plane3's
## kilometers-wide open-sky fall).
##
## Not guessing at a new constant this time -- anchored to something the
## engine actually knows regardless of level: `loader.level_bounds`, the
## same real per-level AABB `_spawn_scene_cylinder()` already sizes the
## horizon cylinder from. Fog now only reaches full density well beyond
## the level's own diagonal extent, so it can act as a distant depth cue
## at the true edges of a level's geometry without ever fogging out
## normal gameplay framing, on any level, regardless of its own absolute
## scale -- matching the real engine's own observed "not perceptible in
## ordinary play" behavior. `camera.fog`'s own numeric value now only
## controls a mild relative thickening (higher = a little closer/denser
## within that safe range), not the primary distance driver.
func _apply_wdl_fog() -> void:
	if _script_cam == null:
		return
	var raw = _script_cam.get_meta("fog", -1.0)
	var value := float(raw)
	var interp: Node = _director.get("_wdl_interp") if _director else null
	var fog_color_gs: Vector3 = (interp.get("_vectors") as Dictionary).get("fog_color", Vector3.ZERO) if interp else Vector3.ZERO
	if value == _last_applied_fog and fog_color_gs == _last_applied_fog_color:
		return
	_last_applied_fog = value
	_last_applied_fog_color = fog_color_gs
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we == null or we.environment == null:
		return
	var env := we.environment
	env.fog_enabled = value > 0.0
	# Reported live (2026-08-10 continued): "the fog issue still occurs" /
	# Plane3 "really dark" persisted even after anchoring fog_depth_end to
	# the level's own real bounds (above). Godot's `Environment.fog_sky_
	# affect` defaults to 1.0 -- full effect -- meaning the sky/background
	# itself gets blended toward `fog_light_color` as if it sat at the fog's
	# own far depth, same as any other fogged surface. The real engine this
	# game shipped on (3D GameStudio A5, confirmed boot banner "commercial
	# release V5.240") used classic DirectX fixed-function depth fog, which
	# by design exempts the skybox/background entirely -- a skybox has no
	# real depth to fog against, and every DirectX-era engine of this kind
	# renders it fog-free so a distant hazy scene doesn't also paint the sky
	# solid fog-color. With `fog_color=1` (near-black, GB-24's own finding)
	# active for Plane3's whole falling/aerial sequence, a `fog_sky_affect`
	# of 1.0 would wash the ENTIRE sky -- which dominates the frame in an
	# aerial shot -- toward solid black regardless of how generously
	# `fog_depth_end` is tuned, since the sky is conceptually at infinite
	# distance and always exceeds any finite fog range. No amount of
	# distance-formula tuning could ever fix that; this is a different,
	# structural mismatch (fog fogging out to backdrop, when the real
	# engine only ever fogged worldgeometry). Zeroed to match.
	env.fog_sky_affect = 0.0
	if value > 0.0:
		# fog_color defaults to (0,0,0) (never assigned) for levels that
		# set camera.fog without ever touching fog_color -- treat that as
		# "no real color chosen", not "pure black fog", falling back to a
		# neutral mid-gray instead.
		#
		# Reported live again (2026-08-16): "the fog/stage of plane3 is
		# still really really dark... it goes for all implementations of
		# light and fog in the game." Measured directly why, for Plane3
		# specifically: `fog_color=1` really is (per WDL's own SET-only-
		# sets-.x quirk, GB-20) essentially raw (1,0,0) on a 0-255 scale --
		# 0.0039 normalized, i.e. genuinely, deliberately near-black, not a
		# misread. That part of the data was never the bug. Floored to a
		# minimum per channel so a "near black" script value still reads as
		# a dark, moody haze instead of literal, total information loss --
		# the original's own DirectX-era fog blending is very unlikely to
		# have ever rendered as perfectly, uniformly (0,0,0) in practice
		# (dithering, dynamic range, CRT black levels of the era all argue
		# against it), and a hard floor costs nothing on levels that never
		# push fog this dark to begin with.
		var floor_c := 0.08
		if fog_color_gs.length() > 0.001:
			env.fog_light_color = Color(
				maxf(clampf(fog_color_gs.x / 255.0, 0.0, 1.0), floor_c),
				maxf(clampf(fog_color_gs.y / 255.0, 0.0, 1.0), floor_c),
				maxf(clampf(fog_color_gs.z / 255.0, 0.0, 1.0), floor_c),
			)
		else:
			env.fog_light_color = Color(0.5, 0.5, 0.5)
		env.fog_light_energy = 1.0
		# Anchor to the level's own real size instead of a fixed guess --
		# see this function's own docstring for why a level-agnostic
		# constant broke Plane3 specifically. `value` (0-30ish in the
		# corpus) only nudges thickness within that safe range, never
		# drives the primary distance.
		#
		# Reported again 2026-08-16 (same report as the color floor above):
		# measured directly that the OLD formula (`fog_depth_begin =
		# safe_end*0.6` with `safe_end = diag*1.5`) put `fog_depth_begin`
		# at 9082 units for Plane3, while the level's own real bounds
		# diagonal is 10091 -- meaning fog was already engaging BEFORE the
		# camera even reached the far edge of the level's own real, meant-
		# to-be-visible geometry, not just a distant backdrop past it. A
		# real prop rendered fully fogged-out (near black, hard silhouette
		# edge) in a live screenshot despite sitting well within the
		# level's own bounds. Pushed the safe start point past the level's
		# own FULL diagonal with real margin (not a fraction of an already-
		# inflated number), so ordinary playable-area geometry stays clear;
		# `value` still modulates how quickly it then thickens toward full
		# fog color beyond that point, not whether real geometry gets
		# swallowed at all.
		var diag: float = loader.level_bounds.size.length() if loader else 10000.0
		env.fog_depth_begin = maxf(diag * 1.3, 5000.0)
		var fade_span: float = maxf(diag * 0.8, 3000.0) * clampf(1.6 - value * 0.02, 0.7, 1.6)
		env.fog_depth_end = env.fog_depth_begin + fade_span


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


## Reported live (2026-08-10): "the lighting effects are vastly different
## than the ones from the original game." This port had NO directional
## light source anywhere -- every level was lit purely by flat ambient
## (`_ensure_environment()`'s own fixed color/energy) plus WMB-placed
## `OmniLight3D` point lights (`WmbLevelLoader._spawn_light()`), and every
## mesh has `cast_shadow`/`disable_receive_shadows` forced off
## (`_force_unshaded_if_needed()`) -- the whole game is flat-lit with zero
## directional shading or shadows, structurally, not per-level. Acknex
## itself has a real directional "sun" concept (`WDL/lflare.wdl`'s own
## `sun_pos`, read by every level's lens-flare code -- see
## `lensflare_start()`), but no WDL script in this corpus ever assigns it
## a value, so there's no live per-level direction to read back. Adds one
## generic `DirectionalLight3D` (fixed angle, warm-neutral, moderate
## energy so it complements rather than overrides the existing ambient +
## WMB point lights) -- shadows deliberately left off, since enabling them
## is a separate, higher-risk change (performance + visual quality on
## this corpus's low-poly models) that needs to be verified visually, not
## guessed at blind. This is a first-pass structural fix for "no
## directional light at all", not a tuned match to a specific reference
## screenshot -- flagged as such since headless Godot can't render a
## frame to compare against the original directly.
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
	# 2026-08-15/16: went through two rounds of cutting this (0.85 -> 0.4 ->
	# 0.22) trying to make WMB point lights' contribution visible against
	# it. Reverted -- that whole direction was solving the wrong problem.
	# The original engine lit brush geometry with static lightmaps baked at
	# level-compile time, not with ambient-vs-dynamic-light contrast (see
	# WmbLevelLoader._spawn_light()'s own note and `rewrite_skill/
	# PORTING_MANUAL.md`). Without extracted lightmap data, flat ambient at
	# a reasonable level is the honest fallback for unlit brush geometry,
	# not something to darken further to manufacture contrast with lights
	# that shouldn't have been dynamic in the first place.
	env.ambient_light_energy = 0.85
	# Follow-up (2026-08-17), Shiks: "the indoor has the Shik character
	# model 'glowing' light." Root cause wasn't a material bug (checked --
	# `shading_mode`/emission on the Shik meshes are ordinary, same as
	# every other lit character) -- it's a real, measured near-field
	# overexposure: `Shik_mdl_046` sits 137.8 units from one of Shiks' own
	# WMB lights, well inside the range where GB-44/46's `energy=1500`
	# calibration reads as fully clipped white (matches the earlier Studio
	# purple-lamp calibration: ~0.99 at a comparable ~134-unit distance).
	# Godot's own tonemap default is `TONE_MAPPER_LINEAR` -- no rolloff at
	# all, so anything pushed past 1.0 just flatlines to solid white,
	# reading as "glowing" rather than "a bright highlight." This isn't
	# specific to Shiks or to `_spawn_light()`'s energy value -- ANY
	# character standing close to any of this port's lights will clip the
	# same way under Linear, corpus-wide, so the general, non-guessed fix
	# is the tonemap curve itself, not another per-scene energy tweak.
	# ACES is the standard choice for exactly this (graceful highlight
	# rolloff instead of a hard clip) and is a broadly-applicable rendering
	# default, not a value tuned to this one report.
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	we.environment = env
	add_child(we)

	# Follow-up (2026-08-17): "the fog and the level is still just DARK"
	# (Plane3). Traced to a real, corpus-wide dead-code bug, same shape as
	# GB-42's ambient one: `level_runner.tscn` itself had a "Sun" node
	# baked directly into the scene file (added at some earlier point,
	# outside this function's own history) with NEITHER `light_color` NOR
	# `light_energy` set -- i.e. Godot's own bare defaults, white/1.0 --
	# at a fixed, never-revisited rotation. `if not has_node("Sun")` below
	# always found that node already present and never once ran this
	# function's own tuned setup, for ANY level, ever. Removed the baked
	# node from the .tscn so this code is the sun's one real owner, same
	# fix shape as GB-42's `acknex_sky.gd`/`_ensure_environment()` ambient
	# conflict.
	if not has_node("Sun"):
		var sun := DirectionalLight3D.new()
		sun.name = "Sun"
		sun.light_color = Color(1.0, 0.96, 0.88)
		sun.light_energy = 0.75
		# Reported live again (2026-08-10, this round): "the lighting
		# effects from the original game are missing" -- previously left
		# off pending live visual verification (see this function's own
		# docstring above); re-reported explicitly enough times now
		# ("light and shadows that don't exist in the current graphics")
		# that leaving it off any longer isn't the safer choice. One
		# directional light's shadow map is cheap regardless of scene size
		# (unlike per-point-light shadows, which this session also enabled
		# corpus-wide since WMB point-light counts are small -- see
		# WmbLevelLoader._spawn_light()).
		sun.shadow_enabled = true
		sun.rotation_degrees = Vector3(-50.0, -35.0, 0.0)
		add_child(sun)


## 2026-08-09: "some of the world backgrounds are not correct still."
## `assets/converted/wdl_meta.json`'s own static extraction takes
## whichever `scene_map = X;` assignment appears LAST, textually, in a
## level's own source -- correct for a level with exactly one
## unconditional assignment (Smash), but WRONG for one that branches on
## runtime state: Desert.wdl's own `main()` reads `Stage` from a save
## file and picks one of six different horizon textures based on it
## (`if(Stage==_TOWN){scene_map=bmapBack1;} ...
## if(Stage==_VOLCANO){scene_map=bmapBack6;}`) -- the static extraction
## always picked the LAST textual branch (_VOLCANO's own horizon6.png)
## regardless of which location was actually visited.
##
## The real, live value isn't available as soon as it looks, either:
## `main()`'s own opening `wait(3);` (a corpus-wide convention, present
## in BOTH Desert's and Smash's own main()) means everything after it --
## including every one of Desert's own Stage-based branches -- only runs
## on a LATER real frame, never synchronously within `begin_level()`
## itself (confirmed live: reading `scene_map` immediately after
## `_director.setup()` returns still saw the pre-assignment default,
## 0.0, for both levels). So this polls for a bounded window after
## level load (`_scene_map_poll_frames`, in `_process()`) instead of a
## single read, re-applying whenever the interpreter's own live value
## changes to something real -- correctly picks up Desert's own
## Stage-based choice whenever main() actually reaches it, without
## polling forever once a level has settled.
##
## Known remaining gap, found chasing this exact report and deliberately
## NOT fixed here (separate, riskier issue -- see docs/SESSION_LOG.md
## 2026-08-09 for the full trace): Desert.wdl's own `main()`, for most
## `Stage` values, calls a weather helper (`let_it_rain()`/`storm()`)
## BEFORE its own `scene_map=...` lines -- and those helpers call their
## own `_akt()` companion (`rain_akt()`/etc), a genuine forever-loop
## (`while(weather==...){...wait();}`) meant to run as an independent
## background task for the rest of the level. Called as a bare, NON-TAIL
## statement, `_call_user_function_async()`'s own "await the whole
## callee" semantics block `main()` at that exact statement forever,
## since the callee never naturally returns -- so `scene_map` (along
## with everything else later in `main()`) never gets set at all for
## Village/Asylum/Olympic destinations. This needs `_call_user_function_
## async()` to stop awaiting PAST a callee's own first `wait()` (matching
## real Acknex: a `wait()` yields to the engine's own scheduler, which
## resumes the ORIGINAL caller too, not just the callee) -- but
## `player_move2()`/`perform_handle()`'s own existing, verified fixes
## (2026-08-01) rely on the CURRENT "block forever" behavior when the
## call is in tail position (nothing after it in the caller anyway, so
## blocking is harmless there). Changing this safely needs its own
## careful pass, not a rushed fix alongside everything else today.
func _apply_wdl_sky(level: String) -> void:
	## IO.wdl / Level.wdl sky_map + scene_map (not solid placeholder colors).
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we == null or we.environment == null or _acknex_sky == null:
		return
	_last_applied_scene_map = _live_scene_map_file()
	_last_applied_sky_map = _live_bmap_file("sky_map")
	_last_applied_cloud_map = _live_bmap_file("cloud_map")
	_acknex_sky.apply(
		level, loader.level_bounds, we.environment,
		_last_applied_scene_map, _last_applied_sky_map, _last_applied_cloud_map
	)


## See _apply_wdl_sky()'s own docstring. Returns "" (meaning "no live
## value yet, fall back to the static wdl_meta.json guess") until the
## level's own WDL script has actually assigned a real `bmap` symbol to
## the given global (`scene_map`/`sky_map`/`cloud_map`).
func _live_bmap_file(var_name: String) -> String:
	var interp: Node = _director.get("_wdl_interp") if _director else null
	if interp == null:
		return ""
	# `sky_map = bsky;` -- the RHS is a bare `bmap` symbol name, not a
	# string; `_get_var()` already resolves it to that symbol's own
	# canonical name (GB-4, 2026-08-03), not the actual filename, so it
	# still needs one more lookup through the interpreter's own `_bmaps`
	# table (symbol name -> real file, e.g. "Horizon1.pcx") to get
	# something AcknexSky._load_tex() can actually open.
	var raw = interp.call("_get_var", var_name, null)
	if raw == null or typeof(raw) != TYPE_STRING or str(raw) == "":
		return ""
	var sym := str(raw)
	var bmaps: Dictionary = interp.get("_bmaps")
	if bmaps.has(sym):
		return str(bmaps[sym])
	var low := sym.to_lower()
	for k in bmaps:
		if String(k).to_lower() == low:
			return str(bmaps[k])
	return ""


func _live_scene_map_file() -> String:
	return _live_bmap_file("scene_map")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			LevelRouter.goto_level("Menu")
		elif event.keycode == KEY_F2:
			Piposh3DState.save_slot(1)
			_game_hud.set_status("Saved slot 1 @ %s" % Piposh3DState.current_level)
		elif event.keycode == KEY_F3:
			var idx := DEBUG_LEVELS.find(Piposh3DState.current_level)
			idx = (idx + 1) % DEBUG_LEVELS.size()
			LevelRouter.goto_level(DEBUG_LEVELS[idx])
		elif event.keycode == KEY_F10:
			_game_hud.show_debug = not _game_hud.show_debug
			_game_hud.set_debug_text(Piposh3DState.current_level, "F1=Menu F3=Next F4=Levels F6=Plane3 Space=Recenter F10=debug")
		elif event.keycode == KEY_F4:
			_toggle_level_select()
		elif event.keycode == KEY_F6:
			LevelRouter.goto_level("Plane3")
		elif event.keycode == KEY_F7:
			# Matches F6's own precedent (jump straight to the level
			# currently being worked on) -- reassigned from "Map" (still
			# reachable via F3's DEBUG_LEVELS cycle) to Plane2 (2026-08-17).
			LevelRouter.goto_level("Plane2")
		elif event.keycode == KEY_F8:
			LevelRouter.goto_level("Smash")
		elif event.keycode == KEY_F9:
			_settings.toggle_visible()
		elif event.keycode == KEY_ESCAPE and _level_select:
			_toggle_level_select()
		elif event.keycode == KEY_SPACE:
			_try_recenter_aim()


## QOL (2026-08-04, Range): "adding a button - space - that resets the
## cursor to the middle of the screen." Only meaningful for levels using
## the scripted-camera mouse-look idiom (same `uses_mickey_aiming()` gate
## the mouse-capture fix above already uses) -- other levels have no
## "spawn pose" concept for Space to recenter to, and Space already does
## something else project-wide (WdlDirector's own skip-dialogue-line
## binding), so this stays a no-op everywhere else.
func _try_recenter_aim() -> void:
	var interp: Node = _director.get("_wdl_interp")
	if interp != null and bool(interp.call("uses_mickey_aiming")):
		interp.call("recenter_aim")


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

	# Source the roster from levels.json, NOT DirAccess. CONTRACT.md 6 and
	# PORTING_MANUAL Phase 7 both forbid DirAccess on res:// here, and for a
	# concrete reason: directory listing does not work inside an exported PCK,
	# so the old implementation produced an EMPTY list in every exported build
	# while looking fine when run from source. levels.json is the committed
	# index and is PCK-safe.
	#
	# It is also the only source that still works once the 0-py runtime readers
	# are enabled, since assets/converted/levels/ need not exist at all then.
	var names: Array[String] = []
	var f := FileAccess.open("res://assets/converted/levels.json", FileAccess.READ)
	if f != null:
		var parsed = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(parsed) == TYPE_DICTIONARY:
			# levels.json is keyed by level name; accept either a top-level map
			# or a "levels" sub-map so a future reshape does not silently empty
			# the list again.
			var src: Dictionary = parsed.get("levels", parsed)
			for k in src.keys():
				names.append(str(k))
		elif typeof(parsed) == TYPE_ARRAY:
			for e in parsed:
				if typeof(e) == TYPE_STRING:
					names.append(str(e))
				elif typeof(e) == TYPE_DICTIONARY and e.has("name"):
					names.append(str(e["name"]))
	if names.is_empty():
		# Last resort only, and loudly: an empty picker is the exact failure
		# this change exists to prevent.
		push_warning("[level-select] levels.json gave no levels; falling back to DirAccess (will be empty in an exported build)")
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
