extends CanvasLayer
## On-screen touch controls for mobile / touchscreen play.
##
## NB-2 / PORTING_MANUAL Phase 7 ("Mobile / touch"). What was here before was
## a move pad + a look pad and nothing else, so on a real device this game was
## unplayable: essentially every level in the corpus is click-driven, and the
## two things a click-driven level needs -- a left click, and the RIGHT click
## that flips `WdlDirector.mouse_look` into "Cursor mode -- click targets" --
## had no touch equivalent at all.
##
## HOW INTERACT IS ACTUALLY DETECTED IN THIS PROJECT (read before editing):
## the `interact` InputMap action declared in project.godot (key E + mouse
## button 1) is *never read by any script* -- `grep is_action_pressed` finds
## only "pause_menu". The real interact path is raw `InputEventMouseButton`
## events, consumed in four places:
##
##   1. `WdlDirector._unhandled_input()` -- LEFT + `not mouse_look` ->
##      `_try_click()`, the world raycast that fires a clickable entity's
##      `click_action`/`action` meta. This is the main "click a target" path.
##   2. `WdlDirector._unhandled_input()` -- RIGHT -> toggles `mouse_look`
##      (IO.wdl's `mouse_toggle`). `mouse_look` starts `true` on every level,
##      so without a right click nothing in (1) is ever reachable.
##   3. `WdlInterpreter._input()` -- LEFT pressed -> `_mouse_left_clicked`,
##      the WDL script-visible "mouse was clicked" flag.
##   4. Godot GUI hit-testing -- `WdlInterpreter._on_panel_button_input()`
##      (WDL panel BUTTONs) and `GameHud`'s dialogue-choice TextureButtons.
##
## So the ACTION and CURSOR buttons here do NOT invent a parallel interact
## mechanism: they synthesize the exact same `InputEventMouseButton` and push
## it through `Input.parse_input_event()`, which feeds all four consumers
## above at once (and, as a free side effect, also satisfies the unused
## `interact` action's own mouse-button-1 binding, so nothing in project.godot
## needs to change).
##
## Pointer position matters as much as the button: `_try_click()` raycasts
## through `get_viewport().get_mouse_position()`, NOT through the event's own
## position -- for the root viewport that reads the real pointer from the
## DisplayServer. So `_move_pointer_to()` moves the pointer first (a zero-
## relative motion event, which is what updates Input's cached position and
## therefore `DisplayServerAndroid::mouse_get_position()`, plus a real
## `Input.warp_mouse()` where the platform supports one) and only then emits
## the button.

## The look/move pads, the two buttons, and every synthetic event they emit.
const SYNTHETIC_DEVICE := -7

## Physical sizes, in inches, converted to pixels via screen DPI (Phase 7:
## "Scale hit targets to physical size, not pixels"). ~0.72in is comfortably
## above the ~9mm (0.35in) minimum touch target both platform HIGs ask for.
const MOVE_PAD_INCHES := 1.15
const BUTTON_INCHES := 0.72
const MARGIN_INCHES := 0.14
const GAP_INCHES := 0.09
## Used when `DisplayServer.screen_get_dpi()` returns something unusable
## (0 on headless, 72 on some Linux/X11 setups, absurd values on others).
const FALLBACK_DPI := 160.0
const DPI_MIN := 72.0
const DPI_MAX := 1200.0

const SETTINGS_PATH := "user://settings.cfg"

## Another agent owns `user://settings.cfg` and its schema, so nothing here
## writes it and nothing here assumes a single spelling: each of these is a
## list of (section, key) pairs tried in order, first present wins, and if
## none is present the built-in default stands. Extend the list rather than
## renaming, so an older settings file keeps working.
const SETTING_KEYS_SIDE: Array = [
	["controls", "touch_side"],
	["controls", "touch_handedness"],
	["controls", "handedness"],
	["controls", "touch_layout_side"],
	["touch", "side"],
	["touch", "handedness"],
	["input", "touch_side"],
]
const SETTING_KEYS_LEFT_HANDED: Array = [
	["controls", "left_handed"],
	["touch", "left_handed"],
]
const SETTING_KEYS_OPACITY: Array = [
	["controls", "touch_opacity"],
	["controls", "on_screen_opacity"],
	["controls", "control_opacity"],
	["touch", "opacity"],
	["video", "touch_opacity"],
]
const SETTING_KEYS_SCALE: Array = [
	["controls", "touch_scale"],
	["controls", "touch_size"],
	["controls", "on_screen_size"],
	["controls", "control_size"],
	["touch", "scale"],
	["touch", "size"],
]

var _player: CharacterBody3D
var _root: Control
var _move_base: Panel
var _move_knob: Panel
var _look_base: Panel
var _action_btn: Panel
var _cursor_btn: Panel
var _cursor_label: Label

## `_active` = the move/look pads are wanted (first-person levels only --
## LevelRunner._enable_first_person() is the only caller of set_active()).
## The ACTION/CURSOR buttons are needed on *every* level, including the
## scripted/cutscene ones that never call set_active() at all, so they have
## their own visibility rule -- see _buttons_wanted().
var _active := false
## Set true by a smoke test (or any harness) that needs the touch UI without
## a touchscreen. Never set at runtime.
var _force_touch_ui := false
## Latches on the first real InputEventScreenTouch: once a device has proven
## it delivers real touch events, stop synthesizing pad touches from mouse
## clicks (the emulate-mouse-from-touch duplicate would double-handle them).
var _saw_real_touch := false

var _move_touch := -1
var _look_touch := -1
var _action_touch := -1
var _cursor_touch := -1
var _look_last := Vector2.ZERO
var _move_radius := 72.0
const LOOK_SENS := 0.55

# --- Settings-backed presentation (defaults used when settings.cfg is absent
# or does not carry the key yet). ---
## "left" = move pad on the left, look/buttons on the right.
var _move_side := "left"
var _opacity := 0.85
var _ui_scale := 1.0

# Cached display metrics, refreshed on every layout so a rotation or a
# window resize re-reads the safe area and DPI.
var _safe_insets := Vector4.ZERO
var _px_per_inch := FALLBACK_DPI
var _window_size := Vector2i.ZERO


func _ready() -> void:
	layer = 40
	_root = Control.new()
	_root.name = "TouchRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_move_base = _make_pad(Color(1, 1, 1, 0.18))
	_move_knob = _make_pad(Color(1, 1, 1, 0.45))
	_look_base = _make_pad(Color(1, 1, 1, 0.14))
	_action_btn = _make_pad(Color(0.35, 0.85, 0.45, 0.30))
	_cursor_btn = _make_pad(Color(0.35, 0.60, 0.95, 0.30))
	_root.add_child(_move_base)
	_root.add_child(_move_knob)
	_root.add_child(_look_base)
	_root.add_child(_action_btn)
	_root.add_child(_cursor_btn)
	_move_base.add_child(_label("MOVE"))
	_look_base.add_child(_label("LOOK"))
	_action_btn.add_child(_label("ACTION"))
	_cursor_label = _label("CURSOR")
	_cursor_btn.add_child(_cursor_label)
	reload_settings()
	set_active(false)
	get_viewport().size_changed.connect(_layout)
	_layout()


func bind_player(player: CharacterBody3D) -> void:
	_player = player


## Enables/disables the MOVE + LOOK pads. Unchanged contract: LevelRunner
## calls this true only for first-person levels on a touch device. The
## ACTION/CURSOR buttons are deliberately NOT gated on it -- see
## _buttons_wanted().
func set_active(on: bool) -> void:
	_active = on and _want_touch()
	if not _active and _player and _player.get("touch_move") != null:
		_player.touch_move = Vector2.ZERO
	_move_touch = -1
	_look_touch = -1
	_action_touch = -1
	_cursor_touch = -1
	_layout()


## Test/harness hook: pretend a touchscreen is present. Production code never
## calls this, so desktop behaviour is untouched.
func force_touch_ui(on: bool) -> void:
	_force_touch_ui = on
	_layout()


func is_active() -> bool:
	return _active


func _want_touch() -> bool:
	return (
		_force_touch_ui
		or OS.has_feature("mobile")
		or OS.get_name() == "Android"
		or OS.get_name() == "iOS"
		or DisplayServer.is_touchscreen_available()
	)


## True only on a real handheld. Used for the one place where the touch UI
## turns itself on without LevelRunner asking (see _buttons_wanted()), so a
## desktop machine that merely *has* a touchscreen keeps exactly today's
## behaviour and nothing new appears on it.
func _is_handheld() -> bool:
	return _force_touch_ui or OS.has_feature("mobile") or OS.get_name() in ["Android", "iOS"]


## The ACTION/CURSOR buttons are the only way to reach a click-driven level on
## touch, and `LevelRunner` only ever calls `set_active(true)` for first-person
## levels -- which is a small minority of this corpus. So on a handheld they
## show up regardless; everywhere else they follow `_active` exactly as the
## pads always have.
func _buttons_wanted() -> bool:
	return _want_touch() and (_active or _is_handheld())


# ---------------------------------------------------------------------------
# Settings (read-only; the settings system owns the file and its schema)
# ---------------------------------------------------------------------------
## Re-reads presentation settings. `path` is a parameter purely so tests can
## point at a scratch file instead of touching the real one.
func reload_settings(path: String = SETTINGS_PATH) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		# No settings file yet (the common case until the settings system
		# lands, and also on a first run) -- keep the defaults.
		_layout()
		return
	var side = _lookup(cfg, SETTING_KEYS_SIDE)
	if side == null:
		var lefty = _lookup(cfg, SETTING_KEYS_LEFT_HANDED)
		if typeof(lefty) == TYPE_BOOL:
			side = "left" if bool(lefty) else "right"
	if side != null:
		set_handedness(str(side))
	var op = _lookup(cfg, SETTING_KEYS_OPACITY)
	if op != null and (typeof(op) == TYPE_FLOAT or typeof(op) == TYPE_INT):
		set_opacity(float(op))
	var sc = _lookup(cfg, SETTING_KEYS_SCALE)
	if sc != null and (typeof(sc) == TYPE_FLOAT or typeof(sc) == TYPE_INT):
		set_ui_scale(float(sc))
	_layout()


## Push-style entry point for the settings UI (so it never has to know this
## node re-reads a file). Unknown keys are ignored, missing keys leave the
## current value alone.
func apply_settings(values: Dictionary) -> void:
	for k in values.keys():
		var key := str(k).to_lower()
		var v = values[k]
		if key in ["touch_side", "handedness", "side", "touch_handedness", "touch_layout_side"]:
			set_handedness(str(v))
		elif key == "left_handed" and typeof(v) == TYPE_BOOL:
			set_handedness("left" if bool(v) else "right")
		elif key in ["touch_opacity", "opacity", "on_screen_opacity", "control_opacity"]:
			set_opacity(float(v))
		elif key in ["touch_scale", "touch_size", "scale", "size", "on_screen_size", "control_size"]:
			set_ui_scale(float(v))
	_layout()


func _lookup(cfg: ConfigFile, candidates: Array):
	for pair in candidates:
		var section := str(pair[0])
		var key := str(pair[1])
		if cfg.has_section_key(section, key):
			return cfg.get_value(section, key)
	return null


## "left"/"l"/"lefty" -> move pad on the left. Anything else -> right. Values
## arrive from a file this node does not own, so nothing here may assert.
func set_handedness(side: String) -> void:
	var s := side.strip_edges().to_lower()
	_move_side = "right" if s.begins_with("r") else "left"
	_layout()


## Accepts 0..1 or 0..100 (the settings UI may store either). Floored so a
## stray 0 cannot make the only usable controls invisible.
func set_opacity(value: float) -> void:
	var v := value
	if v > 1.5:
		v /= 100.0
	_opacity = clampf(v, 0.2, 1.0)
	if _root:
		_root.modulate.a = _opacity


## Accepts a multiplier (0.6..2.0) or a percentage (60..200).
func set_ui_scale(value: float) -> void:
	var v := value
	if v > 3.0:
		v /= 100.0
	_ui_scale = clampf(v, 0.6, 2.0)
	_layout()


func get_handedness() -> String:
	return _move_side


func get_opacity() -> float:
	return _opacity


func get_ui_scale() -> float:
	return _ui_scale


# ---------------------------------------------------------------------------
# Display metrics: safe area + physical (DPI) sizing
# ---------------------------------------------------------------------------
## Converts a screen-space safe-area rect into per-edge insets expressed in
## *viewport* units (this project stretches 1280x720 canvas_items/expand, so
## screen px and viewport units are not the same thing).
##
## Static and pure so the maths is testable headlessly, where
## `DisplayServer.get_display_safe_area()` reports nothing useful.
static func compute_safe_insets(safe: Rect2i, window: Vector2i, viewport: Vector2) -> Vector4:
	if window.x <= 0 or window.y <= 0 or viewport.x <= 0.0 or viewport.y <= 0.0:
		return Vector4.ZERO
	if safe.size.x <= 0 or safe.size.y <= 0:
		return Vector4.ZERO
	var sx := viewport.x / float(window.x)
	var sy := viewport.y / float(window.y)
	var left := maxf(float(safe.position.x), 0.0) * sx
	var top := maxf(float(safe.position.y), 0.0) * sy
	var right := maxf(float(window.x - (safe.position.x + safe.size.x)), 0.0) * sx
	var bottom := maxf(float(window.y - (safe.position.y + safe.size.y)), 0.0) * sy
	# A safe area that claims more than a fifth of an edge is not a notch, it
	# is a mismatched window/screen measurement (very common on desktop, where
	# the "display safe area" is the whole screen but the window is smaller).
	# Refuse it rather than parking the controls in the middle of the screen.
	return Vector4(
		clampf(left, 0.0, viewport.x * 0.2),
		clampf(top, 0.0, viewport.y * 0.2),
		clampf(right, 0.0, viewport.x * 0.2),
		clampf(bottom, 0.0, viewport.y * 0.2)
	)


## Physical size -> viewport units. `dpi` outside a plausible range is treated
## as "unknown" and replaced by FALLBACK_DPI rather than producing a pad the
## size of the screen (or one pixel across).
static func physical_px(inches: float, dpi: float, window: Vector2i, viewport: Vector2) -> float:
	var d := dpi
	if not is_finite(d) or d < DPI_MIN or d > DPI_MAX:
		d = FALLBACK_DPI
	var screen_px := inches * d
	var scale := 1.0
	if window.x > 0 and window.y > 0 and viewport.x > 0.0 and viewport.y > 0.0:
		scale = minf(viewport.x / float(window.x), viewport.y / float(window.y))
	return screen_px * scale


## Mirrors a control's x for the opposite handedness. Exposed (static) so the
## smoke test can assert the mirror is exact rather than eyeballing positions.
static func mirror_x(x: float, width: float, viewport_width: float) -> float:
	return viewport_width - x - width


func _refresh_display_metrics(vp: Vector2) -> void:
	var window := DisplayServer.window_get_size()
	if window.x <= 0 or window.y <= 0:
		window = Vector2i(int(vp.x), int(vp.y))
	var dpi := FALLBACK_DPI
	# screen_get_dpi() is not implemented on every platform/headless server;
	# a failure here must not take the controls down with it.
	if DisplayServer.has_method("screen_get_dpi"):
		dpi = float(DisplayServer.screen_get_dpi())
	_px_per_inch = dpi
	var safe := Rect2i()
	if DisplayServer.has_method("get_display_safe_area"):
		safe = DisplayServer.get_display_safe_area()
	_safe_insets = compute_safe_insets(safe, window, vp)
	_window_size = window


func _inches(v: float) -> float:
	return physical_px(v, _px_per_inch, _window_size, get_viewport().get_visible_rect().size)


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
func _layout() -> void:
	if _root == null or not is_inside_tree():
		return
	var vp := get_viewport().get_visible_rect().size
	_refresh_display_metrics(vp)
	var short_edge := minf(vp.x, vp.y)

	var pads := _active
	var buttons := _buttons_wanted()
	_root.visible = pads or buttons
	_root.modulate.a = _opacity
	_move_base.visible = pads
	_move_knob.visible = pads
	_look_base.visible = pads
	_action_btn.visible = buttons
	_cursor_btn.visible = buttons

	# Physical sizing first, then clamped so a wrong DPI (or a very small
	# window) can never produce controls that cover the play area.
	var pad := clampf(_inches(MOVE_PAD_INCHES) * _ui_scale, 96.0, short_edge * 0.34)
	var btn := clampf(_inches(BUTTON_INCHES) * _ui_scale, 64.0, short_edge * 0.24)
	var margin := clampf(_inches(MARGIN_INCHES), 10.0, 48.0)
	var gap := clampf(_inches(GAP_INCHES), 6.0, 32.0)

	# Safe area (notch / gesture bar) on top of the plain margin.
	var left_edge := margin + _safe_insets.x
	var right_edge := vp.x - margin - _safe_insets.z
	var bottom_edge := vp.y - margin - _safe_insets.w

	_move_base.size = Vector2(pad, pad)
	_move_knob.size = Vector2(pad * 0.42, pad * 0.42)
	_look_base.size = Vector2(pad, pad)
	_action_btn.size = Vector2(btn, btn)
	_cursor_btn.size = Vector2(btn, btn)
	_move_radius = pad * 0.42

	# Authored left-handed (move pad on the left), then mirrored wholesale for
	# right-handed so the two layouts are guaranteed to be exact mirrors.
	var move_x := left_edge
	var look_x := right_edge - pad
	var btn_x := look_x - gap - btn if pads else right_edge - btn
	var move_y := bottom_edge - pad
	var look_y := bottom_edge - pad
	var action_y := bottom_edge - btn
	var cursor_y := action_y - gap - btn

	if _move_side == "right":
		move_x = mirror_x(move_x, pad, vp.x)
		look_x = mirror_x(look_x, pad, vp.x)
		btn_x = mirror_x(btn_x, btn, vp.x)

	_move_base.position = Vector2(move_x, move_y)
	_look_base.position = Vector2(look_x, look_y)
	_action_btn.position = Vector2(btn_x, action_y)
	_cursor_btn.position = Vector2(btn_x, cursor_y)
	_center_knob()

	var font_px := int(clampf(btn * 0.22, 10.0, 22.0))
	for lbl in [_move_base, _look_base, _action_btn, _cursor_btn]:
		var l := (lbl as Control).get_node_or_null("Caption") as Label
		if l:
			l.add_theme_font_size_override("font_size", font_px)


func _center_knob() -> void:
	_move_knob.position = _move_base.position + (_move_base.size - _move_knob.size) * 0.5


func _make_pad(color: Color) -> Panel:
	var p := Panel.new()
	# MOUSE_FILTER_STOP: the emulate-mouse-from-touch click that Godot also
	# generates for this same finger must be swallowed by the GUI here, or it
	# would fall through to WdlDirector._unhandled_input() and fire a world
	# click wherever the pad happens to sit.
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.corner_radius_top_left = 999
	sb.corner_radius_top_right = 999
	sb.corner_radius_bottom_left = 999
	sb.corner_radius_bottom_right = 999
	sb.set_border_width_all(2)
	sb.border_color = Color(1, 1, 1, 0.35)
	p.add_theme_stylebox_override("panel", sb)
	return p


func _label(text: String) -> Label:
	var l := Label.new()
	l.name = "Caption"
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	return l


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------
func _input(event: InputEvent) -> void:
	if not (_active or _buttons_wanted()):
		return
	if event is InputEventScreenTouch:
		_saw_real_touch = true
		_on_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_saw_real_touch = true
		_on_drag(event as InputEventScreenDrag)
	elif event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		# Never re-enter on our own synthetic clicks, and never double-handle
		# the emulate-mouse-from-touch copy of a finger we already processed.
		if mb.device == SYNTHETIC_DEVICE or _saw_real_touch:
			return
		# Desktop / editor testing via mouse.
		var fake := InputEventScreenTouch.new()
		fake.index = 0
		fake.position = mb.position
		fake.pressed = mb.pressed
		_on_touch(fake)
	elif event is InputEventMouseMotion and (_move_touch == 0 or _look_touch == 0):
		var mm := event as InputEventMouseMotion
		if mm.device == SYNTHETIC_DEVICE or _saw_real_touch:
			return
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			var drag := InputEventScreenDrag.new()
			drag.index = 0
			drag.position = mm.position
			drag.relative = mm.relative
			_on_drag(drag)


func _on_touch(ev: InputEventScreenTouch) -> void:
	if ev.pressed:
		if _buttons_wanted() and _point_in(_action_btn, ev.position) and _action_touch < 0:
			_action_touch = ev.index
			_press_action(true)
		elif _buttons_wanted() and _point_in(_cursor_btn, ev.position) and _cursor_touch < 0:
			_cursor_touch = ev.index
			_press_cursor(true)
		elif _active and _point_in(_move_base, ev.position) and _move_touch < 0:
			_move_touch = ev.index
			_update_move(ev.position)
		elif _active and _look_touch < 0:
			# NB-2's "no 3D (look/turn) movement": the look drag used to only
			# start inside the small bottom-corner LOOK circle (~110-168px on
			# a 1280x720 canvas, i.e. a fingertip-sized target on a phone).
			# Missing it did nothing at all, which reads exactly as "look
			# doesn't work". The circle is now only an affordance -- any press
			# that is not on the move pad or a button starts a look drag, the
			# standard mobile-FPS arrangement. The event is deliberately NOT
			# consumed, so a tap that never moves still reaches the click path.
			_look_touch = ev.index
			_look_last = ev.position
	else:
		if ev.index == _action_touch:
			_action_touch = -1
			_press_action(false)
		if ev.index == _cursor_touch:
			_cursor_touch = -1
			_press_cursor(false)
		if ev.index == _move_touch:
			_move_touch = -1
			if _player:
				_player.touch_move = Vector2.ZERO
			_center_knob()
		if ev.index == _look_touch:
			_look_touch = -1


func _on_drag(ev: InputEventScreenDrag) -> void:
	if ev.index == _move_touch:
		_update_move(ev.position)
	elif ev.index == _look_touch:
		var delta := ev.position - _look_last
		_look_last = ev.position
		if _player and _player.has_method("apply_look_delta"):
			_player.apply_look_delta(delta.x * LOOK_SENS, delta.y * LOOK_SENS)


func _update_move(pos: Vector2) -> void:
	var center := _move_base.position + _move_base.size * 0.5
	var offset := pos - center
	if offset.length() > _move_radius:
		offset = offset.normalized() * _move_radius
	_move_knob.position = center + offset - _move_knob.size * 0.5
	var v := offset / _move_radius
	# UI y grows down; invert so up = forward.
	if _player:
		_player.touch_move = Vector2(v.x, -v.y)


func _point_in(ctrl: Control, pos: Vector2) -> bool:
	if ctrl == null or not ctrl.visible:
		return false
	return Rect2(ctrl.global_position, ctrl.size).has_point(pos)


# ---------------------------------------------------------------------------
# The interact path (see this file's header for why it is shaped like this)
# ---------------------------------------------------------------------------
## Where a button-driven click lands. The pointer is not visible on touch, so
## there is no cursor to click "at" -- the centre of the play area is the
## crosshair in first-person mode and the most defensible default everywhere
## else. Direct taps on a target keep working independently (Godot's own
## emulate-mouse-from-touch already turns those into a click at the tap
## position); ACTION exists for the cases a bare tap cannot express.
func aim_point() -> Vector2:
	return get_viewport().get_visible_rect().size * 0.5


func _press_action(pressed: bool) -> void:
	if pressed:
		_move_pointer_to(aim_point())
		# PORTING_MANUAL Phase 7: "Add haptics on interact".
		if _is_handheld():
			Input.vibrate_handheld(25)
	_emit_mouse_button(MOUSE_BUTTON_LEFT, aim_point(), pressed)


## The right-click equivalent NB-2 asks for. `WdlDirector._unhandled_input()`
## flips `mouse_look` on any right press (IO.wdl `mouse_toggle`); every level
## in this project starts with `mouse_look = true`, so until this existed a
## touch player could never enter "Cursor mode -- click targets" and therefore
## could never reach `_try_click()` at all.
func _press_cursor(pressed: bool) -> void:
	_emit_mouse_button(MOUSE_BUTTON_RIGHT, aim_point(), pressed)


## `Input.parse_input_event()` feeds the *window*, and the root viewport then
## maps the event into viewport space with `get_final_transform()` inverted.
## This project stretches (canvas_items / expand, 1280x720 base), so a
## viewport-space aim point handed over raw arrives multiplied by the stretch
## factor -- caught by the smoke test, which saw a 640,640 click land at
## 12800,12800. Everything public here speaks viewport units; this is the one
## place that converts.
func _to_window(pos: Vector2) -> Vector2:
	if not is_inside_tree():
		return pos
	return get_viewport().get_final_transform() * pos


func _emit_mouse_button(button: int, pos: Vector2, pressed: bool) -> void:
	var win := _to_window(pos)
	var ev := InputEventMouseButton.new()
	ev.device = SYNTHETIC_DEVICE
	ev.button_index = button
	ev.pressed = pressed
	ev.position = win
	ev.global_position = win
	ev.button_mask = (1 << (button - 1)) if pressed else 0
	Input.parse_input_event(ev)


## `WdlDirector._try_click()` raycasts through `get_viewport().get_mouse_
## position()`, which for the root viewport reads the DisplayServer's pointer,
## not the event we are about to emit. Two complementary nudges, because no
## single one works on every platform:
##  * a zero-relative motion event -- this is what updates Input's own cached
##    mouse position, which is exactly what DisplayServerAndroid reports back
##    from mouse_get_position(); zero `relative` so WdlInterpreter's `mickey`
##    accumulator and the FP controller's own look both see no movement.
##  * a real warp on platforms that have one (desktop; a no-op on Android).
func _move_pointer_to(pos: Vector2) -> void:
	var win := _to_window(pos)
	var mm := InputEventMouseMotion.new()
	mm.device = SYNTHETIC_DEVICE
	mm.position = win
	mm.global_position = win
	mm.relative = Vector2.ZERO
	mm.velocity = Vector2.ZERO
	Input.parse_input_event(mm)
	# warp_mouse() is also window-relative. Skipped on handhelds, where it is
	# a no-op anyway and the motion event above is what actually moves the
	# reported pointer.
	if not _is_handheld():
		Input.warp_mouse(win)
