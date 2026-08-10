extends SceneTree
## QOL-6 / PORTING_MANUAL Phase 7 -- settings menu + REAL Godot audio buses.
##
## Before this change the project had no `[audio]` section and no
## default_bus_layout.tres: the Voice/SFX/Music buses only came into
## existence inside AudioChannels._ready(), so "the first frame is already
## correct" (Phase 7's own wording) was not true, and an export that never
## reached that autoload had no per-category volume at all.
##
## Proves, in order:
##   1. the committed bus layout resource itself declares Master ->
##      {Music, SFX, Voice} at the documented default volumes -- this is the
##      pre-autoload, first-frame state, checked by reading the .tres, not
##      the live AudioServer, so it cannot be satisfied by runtime fixups;
##   2. the live AudioServer has those buses with those names and every one
##      of them sending to Master;
##   3. Voice defaults ~30-40% louder than Music and SFX (QOL-6's ask);
##   4. moving a real settings-panel HSlider moves the real bus volume_db
##      (not just a stored number) -- driven through the slider's own
##      value_changed signal, exactly as a mouse drag would;
##   5. settings round-trip through user://settings.cfg across a simulated
##      restart: values are written, then a FRESH AudioChannels instance is
##      constructed and its own _ready() must read them back and re-apply
##      them to the buses. Non-audio settings (mouse-look) round-trip too.
##
## Run: godot --headless --path . -s res://tools/smoke_settings_buses_check.gd

const AudioChannelsScript = preload("res://autoload/audio_channels.gd")
## Deliberately NOT preloaded: settings_panel.gd references the AudioChannels
## autoload singleton by name, and a `-s` SceneTree script's own preloads are
## compiled before ProjectSettings' autoloads are registered, so a preload
## here fails to compile with "Identifier not found: AudioChannels". Loaded
## inside _run(), after the first process_frame, where the singleton exists.
## (level_runner.gd/main_menu.gd preload it perfectly happily -- they are
## instantiated long after autoload registration.)
const SETTINGS_PANEL_PATH := "res://scripts/ui/settings_panel.gd"

const BUS_LAYOUT := "res://default_bus_layout.tres"
const SETTINGS_PATH := "user://settings.cfg"
const DB_EPS := 0.05

var _fails: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_fails.append(label)


func _run() -> void:
	await process_frame

	var audio: Node = root.get_node_or_null("AudioChannels")
	if audio == null:
		print("FAIL: AudioChannels autoload missing")
		quit(1)
		return

	_check_layout_resource()
	_check_live_buses()
	_check_voice_louder(audio)
	await _check_slider_moves_bus(audio)
	await _check_settings_roundtrip(audio)
	await _check_in_level_menu()

	# Leave the user's file at the shipped mix rather than at whatever the
	# round-trip step happened to write last.
	audio.call("reset_volumes_to_defaults")
	audio.call("set_setting", "input", "mouse_look", true)

	print("")
	if _fails.is_empty():
		print("OK")
		quit(0)
	else:
		for f in _fails:
			print("failed: %s" % f)
		print("FAIL")
		quit(1)


## 1. The committed resource -- the state the engine builds BEFORE any
## script runs.
func _check_layout_resource() -> void:
	print("[1] default_bus_layout.tres (pre-autoload / first-frame state)")
	if not ResourceLoader.exists(BUS_LAYOUT):
		_check(false, "%s exists" % BUS_LAYOUT)
		return
	var layout: Resource = load(BUS_LAYOUT)
	_check(layout is AudioBusLayout, "%s loads as AudioBusLayout" % BUS_LAYOUT)
	if not (layout is AudioBusLayout):
		return

	# AudioBusLayout exposes its buses only through bus/N/* properties.
	var names: Array[String] = []
	var sends: Dictionary = {}
	var volumes: Dictionary = {}
	var i := 0
	while true:
		var n: Variant = layout.get("bus/%d/name" % i)
		if n == null:
			break
		var bus_name: String = str(n)
		names.append(bus_name)
		sends[bus_name] = str(layout.get("bus/%d/send" % i))
		volumes[bus_name] = float(layout.get("bus/%d/volume_db" % i))
		i += 1

	print("      buses in resource: %s" % [names])
	_check(names.size() == 4, "resource declares 4 buses (got %d)" % names.size())
	_check(names.size() > 0 and names[0] == "Master", "bus 0 is Master")
	for w in ["Music", "SFX", "Voice"]:
		var want: String = str(w)
		_check(names.has(want), "resource has %s bus" % want)
		if names.has(want):
			_check(str(sends[want]) == "Master", "%s sends to Master (got '%s')"
				% [want, str(sends[want])])

	# The declared dB must equal linear_to_db() of the code's own defaults,
	# or the first frame and the first slider read disagree.
	var want_db: Dictionary = {
		"Voice": linear_to_db(AudioChannelsScript.DEFAULT_VOICE_VOLUME),
		"SFX": linear_to_db(AudioChannelsScript.DEFAULT_SFX_VOLUME),
		"Music": linear_to_db(AudioChannelsScript.DEFAULT_MUSIC_VOLUME),
	}
	for key in want_db.keys():
		var bus_name: String = str(key)
		if not names.has(bus_name):
			continue
		var got: float = float(volumes[bus_name])
		var expect: float = float(want_db[key])
		_check(absf(got - expect) < DB_EPS,
			"%s resource volume_db %.4f matches linear_to_db(default) %.4f"
				% [bus_name, got, expect])


## 2. The live server.
func _check_live_buses() -> void:
	print("[2] live AudioServer bus layout")
	_check(AudioServer.get_bus_name(0) == "Master", "live bus 0 is Master")
	for w in ["Music", "SFX", "Voice"]:
		var want: String = str(w)
		var idx: int = AudioServer.get_bus_index(want)
		_check(idx != -1, "live bus '%s' exists (index %d)" % [want, idx])
		if idx == -1:
			continue
		_check(idx > 0, "'%s' is not the Master bus" % want)
		var send: String = str(AudioServer.get_bus_send(idx))
		_check(send == "Master", "'%s' routes to Master (got '%s')" % [want, send])


## 3. QOL-6: "default voice ~30-40% louder than music and SFX".
func _check_voice_louder(_audio: Node) -> void:
	print("[3] default mix (QOL-6: voice ~30-40% above music and SFX)")
	var v: float = AudioChannelsScript.DEFAULT_VOICE_VOLUME
	var s: float = AudioChannelsScript.DEFAULT_SFX_VOLUME
	var m: float = AudioChannelsScript.DEFAULT_MUSIC_VOLUME
	print("      voice=%.2f sfx=%.2f music=%.2f" % [v, s, m])
	var vs := (v / s - 1.0) * 100.0
	var vm := (v / m - 1.0) * 100.0
	_check(vs >= 30.0 and vs <= 40.0, "voice is %.1f%% above SFX (want 30-40%%)" % vs)
	_check(vm >= 30.0 and vm <= 40.0, "voice is %.1f%% above Music (want 30-40%%)" % vm)


## 4. A real slider drag reaches the real bus.
func _check_slider_moves_bus(audio: Node) -> void:
	print("[4] settings panel slider -> AudioServer bus volume_db")
	var host := Node.new()
	host.name = "SettingsHost"
	root.add_child(host)
	var panel_script: GDScript = load(SETTINGS_PANEL_PATH)
	if panel_script == null:
		_check(false, "settings_panel.gd loads")
		host.queue_free()
		return
	var panel: CanvasLayer = panel_script.new()
	panel.name = "SettingsPanel"
	host.add_child(panel)
	await process_frame

	var was_visible: bool = panel.visible
	panel.call("toggle_visible")
	_check(panel.visible != was_visible, "toggle_visible() flips visibility")

	var levels: Array = panel.get("_all_levels")
	print("      level select entries: %d" % levels.size())
	_check(levels.size() > 0, "level select is populated from levels.json")

	var sfx_idx := AudioServer.get_bus_index("SFX")
	var slider: HSlider = panel.get("_sfx_slider") as HSlider
	_check(slider != null, "panel exposes an SFX slider")
	if slider == null or sfx_idx == -1:
		host.queue_free()
		return

	# Drive it the way a mouse drag does: set .value, let value_changed fire.
	slider.value = 1.0
	await process_frame
	var loud_db: float = AudioServer.get_bus_volume_db(sfx_idx)
	slider.value = 0.25
	await process_frame
	var quiet_db: float = AudioServer.get_bus_volume_db(sfx_idx)
	print("      SFX bus: %.3f dB @slider 1.00 -> %.3f dB @slider 0.25" % [loud_db, quiet_db])
	_check(quiet_db < loud_db, "moving the slider down lowers the SFX bus")
	_check(absf(quiet_db - linear_to_db(0.25)) < DB_EPS,
		"SFX bus dB equals linear_to_db(0.25) = %.3f" % linear_to_db(0.25))
	_check(absf(float(audio.call("get_sfx_volume")) - 0.25) < 0.0001,
		"AudioChannels.get_sfx_volume() agrees with the slider")

	# Voice slider must move the Voice bus and NOT the SFX bus (proves the
	# three categories are genuinely independent, not one shared fader).
	var voice_idx := AudioServer.get_bus_index("Voice")
	var voice_slider: HSlider = panel.get("_voice_slider") as HSlider
	if voice_slider != null and voice_idx != -1:
		var sfx_before: float = AudioServer.get_bus_volume_db(sfx_idx)
		voice_slider.value = 0.5
		await process_frame
		_check(absf(AudioServer.get_bus_volume_db(voice_idx) - linear_to_db(0.5)) < DB_EPS,
			"Voice slider moves the Voice bus")
		_check(absf(AudioServer.get_bus_volume_db(sfx_idx) - sfx_before) < DB_EPS,
			"Voice slider leaves the SFX bus alone")

	panel.call("toggle_visible")
	host.queue_free()
	await process_frame


## 5. user://settings.cfg round-trip across a simulated restart.
func _check_settings_roundtrip(audio: Node) -> void:
	print("[5] user://settings.cfg round-trip across a simulated restart")
	audio.call("set_voice_volume", 0.81)
	audio.call("set_sfx_volume", 0.42)
	audio.call("set_music_volume", 0.13)
	audio.call("set_setting", "input", "mouse_look", false)

	var cfg := ConfigFile.new()
	var err := cfg.load(SETTINGS_PATH)
	_check(err == OK, "%s written (err=%d)" % [SETTINGS_PATH, err])
	if err == OK:
		_check(absf(float(cfg.get_value("audio", "voice", -1.0)) - 0.81) < 0.0001,
			"cfg [audio] voice == 0.81")
		_check(absf(float(cfg.get_value("audio", "sfx", -1.0)) - 0.42) < 0.0001,
			"cfg [audio] sfx == 0.42")
		_check(absf(float(cfg.get_value("audio", "music", -1.0)) - 0.13) < 0.0001,
			"cfg [audio] music == 0.13")
		_check(bool(cfg.get_value("input", "mouse_look", true)) == false,
			"cfg [input] mouse_look == false (non-audio settings share the file)")

	# Wipe the live buses to a wrong value, then boot a FRESH AudioChannels.
	# Its own _ready() -- the same code path that runs before the first scene
	# on a real launch -- must restore the saved values.
	for b in ["Voice", "SFX", "Music"]:
		var i: int = AudioServer.get_bus_index(str(b))
		if i != -1:
			AudioServer.set_bus_volume_db(i, -30.0)

	var fresh: Node = AudioChannelsScript.new()
	fresh.name = "AudioChannelsRestarted"
	root.add_child(fresh)
	await process_frame

	_check(absf(float(fresh.call("get_voice_volume")) - 0.81) < 0.0001,
		"restarted instance read voice=0.81 from disk")
	_check(absf(float(fresh.call("get_sfx_volume")) - 0.42) < 0.0001,
		"restarted instance read sfx=0.42 from disk")
	_check(absf(float(fresh.call("get_music_volume")) - 0.13) < 0.0001,
		"restarted instance read music=0.13 from disk")
	_check(bool(fresh.call("get_setting", "input", "mouse_look", true)) == false,
		"restarted instance read mouse_look=false from disk")

	var voice_db: float = AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Voice"))
	var sfx_db: float = AudioServer.get_bus_volume_db(AudioServer.get_bus_index("SFX"))
	var music_db: float = AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Music"))
	print("      after restart: voice=%.3f sfx=%.3f music=%.3f dB" % [voice_db, sfx_db, music_db])
	_check(absf(voice_db - linear_to_db(0.81)) < DB_EPS,
		"Voice bus re-applied on boot, before any scene")
	_check(absf(sfx_db - linear_to_db(0.42)) < DB_EPS, "SFX bus re-applied on boot")
	_check(absf(music_db - linear_to_db(0.13)) < DB_EPS, "Music bus re-applied on boot")

	fresh.queue_free()
	await process_frame


## 6. The in-level host. Sections 1-5 exercise the panel with no WdlDirector
## and no GameHud (the main-menu shape); this one runs it inside the real
## level_runner scene, where the mouse-look and debug-overlay rows have live
## targets and _close() hands the mouse mode back to the director instead of
## restoring a stale saved value.
func _check_in_level_menu() -> void:
	print("[6] panel hosted by level_runner (mouse-look + debug rows live)")
	root.get_node("Piposh3DState").set("current_level", "Plane3")
	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	for i in 8:
		await process_frame

	var panel: Node = runner.get_node_or_null("SettingsPanel")
	_check(panel != null, "level_runner hosts a SettingsPanel")
	var director: Node = runner.get_node_or_null("WdlDirector")
	var hud: Node = runner.get_node_or_null("GameHud")
	_check(director != null, "WdlDirector present (mouse-look row has a target)")
	_check(hud != null, "GameHud present (debug row has a target)")
	if panel == null or director == null or hud == null:
		runner.queue_free()
		await process_frame
		return

	panel.call("toggle_visible")
	await process_frame
	_check(bool(panel.get("visible")), "panel opens in-level")
	_check(
		Input.mouse_mode == Input.MOUSE_MODE_VISIBLE,
		"opening frees the cursor (FP levels hold it CAPTURED otherwise)"
	)

	var check: CheckBox = panel.get("_mouse_look_check") as CheckBox
	_check(check != null and not check.disabled, "mouse-look row is enabled in-level")
	if check != null:
		var before: bool = bool(director.get("mouse_look"))
		check.button_pressed = not before
		await process_frame
		_check(bool(director.get("mouse_look")) == (not before),
			"mouse-look checkbox writes through to WdlDirector.mouse_look")
		# Panel is still open -- the cursor must stay usable regardless.
		_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE,
			"toggling mouse-look does not steal the cursor while open")
		check.button_pressed = before
		await process_frame

	var dbg: CheckBox = panel.get("_debug_check") as CheckBox
	_check(dbg != null and not dbg.disabled, "debug row is enabled in-level")
	if dbg != null:
		var was: bool = bool(hud.get("show_debug"))
		dbg.button_pressed = not was
		await process_frame
		_check(bool(hud.get("show_debug")) == (not was),
			"debug checkbox writes through to GameHud.show_debug")
		dbg.button_pressed = was
		await process_frame

	panel.call("toggle_visible")
	await process_frame
	_check(not bool(panel.get("visible")), "panel closes in-level")

	runner.queue_free()
	await process_frame
