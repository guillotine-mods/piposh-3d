extends CanvasLayer
## Right-side settings / QOL menu. Pure-code CanvasLayer, same convention as
## GameHud/TouchControls -- no .tscn.
##
## Started 2026-08-09 as a minimal centered volume panel, per a direct
## playtest request ("let's have an FX / voice volume control in settings").
## Extended 2026-08-10 to the shape QOL-6 actually asks for: "a right-side
## menu: debug, mouse-look toggle, level select, settings, and separate
## volume sliders for SFX / Music / Voice -- default voice ~30-40% louder
## than music and SFX." The volume rows, the mouse-mode save/restore and the
## toggle_visible() entry point are unchanged from the first pass; the panel
## moved from centered to right-anchored full-height and gained the debug,
## mouse-look and level-select sections.
##
## Toggled via toggle_visible() -- level_runner.gd/main_menu.gd both wire F9
## to it; this class has no input handling of its own beyond its own
## controls, so it can't fight another screen's input while hidden.
##
## Everything outside the audio section reaches its target through
## get_parent() + has_method()/property probes rather than a hard reference,
## because the two hosts differ: level_runner.gd has a WdlDirector and a
## GameHud (so mouse-look and the debug overlay are real there), main_menu.gd
## has neither. A missing target disables the row instead of erroring.

const PANEL_WIDTH := 340.0
const LEVELS_INDEX := "res://assets/converted/levels.json"

var _panel: PanelContainer
## Saved the instant the panel opens, restored the instant it closes --
## same pattern as GameHud.show_dialog()/hide_dialog()'s own mouse-mode
## save/restore around the dialogue panel. Reported live (2026-08-09):
## "The SFX volume choice isn't working for editing" -- FP levels
## (Range, Plane2, ...) keep `Input.mouse_mode` CAPTURED (cursor hidden
## and locked to screen center, all motion read as camera-look) the
## whole time they're playing; opening this panel over that state left
## the OS cursor invisible and unusable, so the slider could never
## actually be clicked or dragged, only fought against camera-look.
var _mouse_mode_before_open := Input.MOUSE_MODE_VISIBLE

var _voice_slider: HSlider
var _sfx_slider: HSlider
var _music_slider: HSlider
var _mouse_look_check: CheckBox
var _debug_check: CheckBox
var _level_list: ItemList
var _level_filter: LineEdit
## Full level name list from levels.json, and the subset currently shown
## after the filter box -- kept separate so a click maps back to the right
## name regardless of filtering.
var _all_levels: Array[String] = []
var _shown_levels: Array[String] = []
## Set while _sync_from_state() is writing control values, so the resulting
## value_changed/toggled signals don't write straight back out (which would
## save settings on every open and, worse, re-apply a stale value).
var _syncing := false


func _ready() -> void:
	layer = 50  # above GameHud (see its own layer) and any level UI
	visible = false

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	# Right edge, full height -- QOL-6's "right-side menu". Anchored rather
	# than positioned so it stays glued to the right on any window size or
	# aspect (the project stretches with "expand").
	_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_panel.offset_left = -PANEL_WIDTH
	_panel.offset_right = 0.0
	_panel.offset_top = 0.0
	_panel.offset_bottom = 0.0
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	_panel.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	var title := Label.new()
	title.text = "Settings"
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	# --- Audio -----------------------------------------------------------
	vbox.add_child(_make_header("Audio"))
	var voice_row := _make_slider_row("Voice", AudioChannels.get_voice_volume(), _on_voice_changed)
	_voice_slider = voice_row.get_meta("slider") as HSlider
	vbox.add_child(voice_row)
	var sfx_row := _make_slider_row("SFX", AudioChannels.get_sfx_volume(), _on_sfx_changed)
	_sfx_slider = sfx_row.get_meta("slider") as HSlider
	vbox.add_child(sfx_row)
	var music_row := _make_slider_row("Music", AudioChannels.get_music_volume(), _on_music_changed)
	_music_slider = music_row.get_meta("slider") as HSlider
	vbox.add_child(music_row)

	var reset_btn := Button.new()
	reset_btn.text = "Reset audio to defaults"
	reset_btn.pressed.connect(_on_reset_audio)
	vbox.add_child(reset_btn)

	# --- Gameplay --------------------------------------------------------
	vbox.add_child(_make_header("Gameplay"))

	_mouse_look_check = CheckBox.new()
	_mouse_look_check.text = "Mouse look (right-click also toggles)"
	_mouse_look_check.toggled.connect(_on_mouse_look_toggled)
	vbox.add_child(_mouse_look_check)

	_debug_check = CheckBox.new()
	_debug_check.text = "Debug overlay (F10)"
	_debug_check.toggled.connect(_on_debug_toggled)
	vbox.add_child(_debug_check)

	# --- Level select ----------------------------------------------------
	vbox.add_child(_make_header("Level select"))

	_level_filter = LineEdit.new()
	_level_filter.placeholder_text = "filter..."
	_level_filter.text_changed.connect(_on_level_filter_changed)
	vbox.add_child(_level_filter)

	_level_list = ItemList.new()
	_level_list.custom_minimum_size = Vector2(0, 260)
	_level_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_level_list.select_mode = ItemList.SELECT_SINGLE
	_level_list.item_activated.connect(_on_level_activated)
	_level_list.item_clicked.connect(_on_level_clicked)
	vbox.add_child(_level_list)

	_all_levels = _load_level_names()
	_rebuild_level_list("")

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(_close)
	vbox.add_child(close_btn)

	# Keeps a second panel (main menu vs level) and any non-UI volume change
	# from leaving these sliders stale.
	AudioChannels.volume_changed.connect(_on_external_volume_changed)


func toggle_visible() -> void:
	if visible:
		_close()
	else:
		_open()


func _open() -> void:
	_mouse_mode_before_open = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_sync_from_state()
	visible = true


func _close() -> void:
	visible = false
	# Restoring the saved mode blindly would undo a mouse-look change the
	# player just made in this very panel, so if a director is present its
	# own current mouse_look wins; otherwise fall back to the saved mode.
	var director := _find_director()
	if director != null and director.has_method("_apply_mouse_mode"):
		director.call("_apply_mouse_mode")
	else:
		Input.mouse_mode = _mouse_mode_before_open


## Pulls every control's value from the real state each time the panel
## opens, so nothing here can drift from what the game is actually doing
## (mouse-look in particular is toggled by right-click during play).
func _sync_from_state() -> void:
	_syncing = true
	_voice_slider.value = AudioChannels.get_voice_volume()
	_sfx_slider.value = AudioChannels.get_sfx_volume()
	_music_slider.value = AudioChannels.get_music_volume()

	var director := _find_director()
	if director != null:
		_mouse_look_check.disabled = false
		_mouse_look_check.button_pressed = bool(director.get("mouse_look"))
	else:
		# main_menu.gd has no director -- nothing to toggle there.
		_mouse_look_check.disabled = true
		_mouse_look_check.button_pressed = bool(
			AudioChannels.get_setting("input", "mouse_look", true)
		)

	var hud := _find_hud()
	if hud != null:
		_debug_check.disabled = false
		_debug_check.button_pressed = bool(hud.get("show_debug"))
	else:
		_debug_check.disabled = true
		_debug_check.button_pressed = bool(
			AudioChannels.get_setting("debug", "overlay", false)
		)
	_syncing = false


func _make_header(text: String) -> Control:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	return l


func _make_slider_row(label_text: String, initial: float, changed_cb: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(60, 0)
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = initial
	slider.custom_minimum_size = Vector2(160, 0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(changed_cb)
	row.add_child(slider)

	var pct := Label.new()
	pct.text = "%d%%" % round(initial * 100.0)
	pct.custom_minimum_size = Vector2(40, 0)
	row.add_child(pct)
	slider.value_changed.connect(func(v: float): pct.text = "%d%%" % round(v * 100.0))

	row.set_meta("slider", slider)
	return row


func _on_voice_changed(v: float) -> void:
	if _syncing:
		return
	AudioChannels.set_voice_volume(v)


func _on_sfx_changed(v: float) -> void:
	if _syncing:
		return
	AudioChannels.set_sfx_volume(v)


func _on_music_changed(v: float) -> void:
	if _syncing:
		return
	AudioChannels.set_music_volume(v)


func _on_reset_audio() -> void:
	AudioChannels.reset_volumes_to_defaults()
	_syncing = true
	_voice_slider.value = AudioChannels.get_voice_volume()
	_sfx_slider.value = AudioChannels.get_sfx_volume()
	_music_slider.value = AudioChannels.get_music_volume()
	_syncing = false


func _on_external_volume_changed(_channel: String, _value: float) -> void:
	if _syncing or not visible:
		return
	_syncing = true
	_voice_slider.value = AudioChannels.get_voice_volume()
	_sfx_slider.value = AudioChannels.get_sfx_volume()
	_music_slider.value = AudioChannels.get_music_volume()
	_syncing = false


## IO.wdl's mouse_toggle, the same thing right-click does mid-level -- QOL-6
## asks for it as an explicit menu entry because right-click is undiscoverable
## and, on touch, unreachable.
func _on_mouse_look_toggled(pressed: bool) -> void:
	if _syncing:
		return
	AudioChannels.set_setting("input", "mouse_look", pressed)
	var director := _find_director()
	if director == null:
		return
	director.set("mouse_look", pressed)
	# Deliberately NOT applying the mouse mode here: the panel is open and
	# needs a usable cursor. _close() applies it.


func _on_debug_toggled(pressed: bool) -> void:
	if _syncing:
		return
	AudioChannels.set_setting("debug", "overlay", pressed)
	var hud := _find_hud()
	if hud == null:
		return
	hud.set("show_debug", pressed)
	if hud.has_method("set_debug_text"):
		hud.call(
			"set_debug_text",
			str(Piposh3DState.current_level),
			"F1=Menu F3=Next F4=Levels F9=Settings Space=Recenter F10=debug",
		)


## Phase 7: "Replace the DirAccess implementation with levels.json as the
## index -- it is already loaded and it is PCK-safe." DirAccess cannot list
## a packed folder in an exported build, so the old level select was empty
## on any real export. Falls back to DirAccess only if the index is missing.
func _load_level_names() -> Array[String]:
	var names: Array[String] = []
	if FileAccess.file_exists(LEVELS_INDEX) or ResourceLoader.exists(LEVELS_INDEX):
		var f := FileAccess.open(LEVELS_INDEX, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if typeof(parsed) == TYPE_DICTIONARY:
				var levels: Variant = (parsed as Dictionary).get("levels", {})
				if typeof(levels) == TYPE_DICTIONARY:
					for key in (levels as Dictionary).keys():
						names.append(str(key))
	if names.is_empty():
		var dir := DirAccess.open("res://assets/converted/levels/")
		if dir != null:
			dir.list_dir_begin()
			var fn := dir.get_next()
			while fn != "":
				if fn.ends_with(".json") and not fn.ends_with("_brush.json"):
					names.append(fn.get_basename())
				fn = dir.get_next()
	names.sort()
	return names


func _rebuild_level_list(filter: String) -> void:
	_shown_levels.clear()
	_level_list.clear()
	var low := filter.strip_edges().to_lower()
	var current := str(Piposh3DState.current_level)
	for n in _all_levels:
		if low != "" and not n.to_lower().contains(low):
			continue
		_shown_levels.append(n)
		_level_list.add_item(n + ("  (current)" if n == current else ""))


func _on_level_filter_changed(text: String) -> void:
	_rebuild_level_list(text)


func _on_level_clicked(index: int, _at: Vector2, _button: int) -> void:
	_goto_level_index(index)


func _on_level_activated(index: int) -> void:
	_goto_level_index(index)


func _goto_level_index(index: int) -> void:
	if index < 0 or index >= _shown_levels.size():
		return
	var target: String = _shown_levels[index]
	_close()
	LevelRouter.goto_level(target)


## level_runner.gd adds this panel as its own child alongside WdlDirector and
## GameHud; main_menu.gd adds it with neither present. Probed rather than
## injected so neither host file has to change.
func _find_director() -> Node:
	var p := get_parent()
	if p == null:
		return null
	return p.get_node_or_null("WdlDirector")


func _find_hud() -> Node:
	var p := get_parent()
	if p == null:
		return null
	return p.get_node_or_null("GameHud")
