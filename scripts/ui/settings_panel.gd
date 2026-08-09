extends CanvasLayer
class_name SettingsPanel
## Minimal volume-control settings panel. Added 2026-08-09 per direct
## request during a playtest ("let's have an FX / voice volume control
## in settings") -- also QOL-6's own long-standing backlog ask (separate
## SFX/Music/Voice sliders). Pure-code CanvasLayer, same convention as
## GameHud/TouchControls -- no .tscn.
##
## Toggled via toggle_visible() -- level_runner.gd/main_menu.gd both wire
## a debug key to it; this class itself has no input handling of its own
## beyond its own slider/close controls, so it can't fight another
## screen's own input handling while hidden.

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


func _ready() -> void:
	layer = 50  # above GameHud (see its own layer) and any level UI
	visible = false

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.position = Vector2(-160, -110)
	_panel.custom_minimum_size = Vector2(320, 220)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Settings"
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	vbox.add_child(_make_slider_row("Voice", AudioChannels.get_voice_volume(), _on_voice_changed))
	vbox.add_child(_make_slider_row("SFX", AudioChannels.get_sfx_volume(), _on_sfx_changed))
	vbox.add_child(_make_slider_row("Music", AudioChannels.get_music_volume(), _on_music_changed))

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(_close)
	vbox.add_child(close_btn)


func toggle_visible() -> void:
	if visible:
		_close()
	else:
		_open()


func _open() -> void:
	_mouse_mode_before_open = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	visible = true


func _close() -> void:
	visible = false
	Input.mouse_mode = _mouse_mode_before_open


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

	return row


func _on_voice_changed(v: float) -> void:
	AudioChannels.set_voice_volume(v)


func _on_sfx_changed(v: float) -> void:
	AudioChannels.set_sfx_volume(v)


func _on_music_changed(v: float) -> void:
	AudioChannels.set_music_volume(v)
