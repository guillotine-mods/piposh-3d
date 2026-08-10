extends SceneTree
## NB-2 / PORTING_MANUAL Phase 7 ("Mobile / touch"): verifies the touch
## controls headlessly, as far as a machine with no touchscreen can.
##
## What this proves:
##   1. Desktop no-regression -- with no touchscreen and no force flag, the
##      whole touch layer stays invisible and swallows no input.
##   2. The ACTION button emits a real left `InputEventMouseButton` that
##      reaches the same `_unhandled_input`/`_input` consumers the keyboard-E
##      / mouse-click interact path already uses, and sets the WDL
##      interpreter's own `_mouse_left_clicked` flag.
##   3. The CURSOR button emits a right `InputEventMouseButton` that flips
##      `WdlDirector.mouse_look` -- i.e. reaches "Cursor mode - click
##      targets", the mode every click-driven level needs and that touch had
##      no way to enter at all.
##   4. Safe-area inset maths (notch/gesture bar), including the degenerate
##      inputs a desktop DisplayServer actually returns.
##   5. DPI -> physical-size maths, including bogus DPI fallback.
##   6. Handedness mirroring is an exact mirror.
##   7. Settings are read defensively from a ConfigFile: present keys apply,
##      absent keys leave defaults, junk values do not crash.
##
## What it CANNOT prove -- see the report notes: real finger input, real
## `DisplayServer.get_display_safe_area()` values, whether `Input.warp_mouse`
## /`mouse_get_position()` behave as assumed on Android, and haptics.
##
## Run: godot --headless --path . -s res://tools/smoke_touch_controls.gd

const TouchControls = preload("res://scripts/ui/touch_controls.gd")
const LEVEL := "Town"
const SCRATCH_CFG := "user://__smoke_touch_settings.cfg"

var _failures: Array[String] = []


## Records every mouse button event that survives to _unhandled_input, i.e.
## the same stage WdlDirector listens at, plus everything at _input, the
## stage WdlInterpreter listens at.
class InputProbe:
	extends Node
	var unhandled: Array[Dictionary] = []
	var raw: Array[Dictionary] = []

	func _input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			raw.append({"button": mb.button_index, "pressed": mb.pressed, "pos": mb.position})

	func _unhandled_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			unhandled.append({"button": mb.button_index, "pressed": mb.pressed, "pos": mb.position})


func _init() -> void:
	call_deferred("_run")


func _check(name: String, ok: bool, detail: String = "") -> void:
	print("%s %s%s" % ["PASS" if ok else "FAIL", name, ("  -- " + detail) if detail != "" else ""])
	if not ok:
		_failures.append(name)


func _run() -> void:
	# parse_input_event() is buffered when accumulation is on; turn it off so
	# a synthesized click is dispatched synchronously and the assertions below
	# are deterministic rather than frame-timing dependent.
	Input.use_accumulated_input = false

	_test_pure_maths()
	await _test_in_level()

	print("---")
	if _failures.is_empty():
		print("OK")
		quit(0)
	else:
		print("FAILED: %s" % ", ".join(_failures))
		quit(1)


# ---------------------------------------------------------------------------
# Pure maths (no scene needed)
# ---------------------------------------------------------------------------
func _test_pure_maths() -> void:
	print("== safe area ==")
	# A phone: 1080x2400 window, 90px notch top, 60px gesture bar bottom,
	# rendered into this project's 1280x720-class stretched viewport.
	var insets := TouchControls.compute_safe_insets(
		Rect2i(0, 90, 1080, 2250), Vector2i(1080, 2400), Vector2(1080, 2400)
	)
	_check("safe_area/portrait_notch", is_equal_approx(insets.y, 90.0) and is_equal_approx(insets.w, 60.0),
		"top=%.1f bottom=%.1f (expect 90/60)" % [insets.y, insets.w])

	# Landscape phone with a notch on the left and a gesture bar on the right,
	# stretched into a half-size viewport: insets must scale with it.
	insets = TouchControls.compute_safe_insets(
		Rect2i(80, 0, 2200, 1080), Vector2i(2400, 1080), Vector2(1200, 540)
	)
	_check("safe_area/scaled_to_viewport",
		is_equal_approx(insets.x, 40.0) and is_equal_approx(insets.z, 60.0),
		"left=%.1f right=%.1f (expect 40/60 = half of 80/120)" % [insets.x, insets.z])

	# Desktop: the "display safe area" is the whole screen while the window is
	# a small fraction of it. Must produce no insets, not a giant right inset.
	insets = TouchControls.compute_safe_insets(
		Rect2i(0, 0, 2560, 1440), Vector2i(1280, 720), Vector2(1280, 720)
	)
	_check("safe_area/desktop_window_smaller_than_screen", insets == Vector4.ZERO,
		"got %s" % insets)

	# Degenerate: headless reports a zero rect / zero window.
	_check("safe_area/zero_rect",
		TouchControls.compute_safe_insets(Rect2i(), Vector2i(1280, 720), Vector2(1280, 720)) == Vector4.ZERO)
	_check("safe_area/zero_window",
		TouchControls.compute_safe_insets(Rect2i(0, 40, 100, 100), Vector2i(), Vector2(1280, 720)) == Vector4.ZERO)

	# A bogus safe area claiming most of the screen must be refused (capped at
	# 20% per edge) rather than parking controls in the middle of the view.
	insets = TouchControls.compute_safe_insets(
		Rect2i(0, 600, 1280, 60), Vector2i(1280, 720), Vector2(1280, 720)
	)
	_check("safe_area/absurd_inset_capped", insets.y <= 720.0 * 0.2 + 0.001 and insets.w <= 720.0 * 0.2 + 0.001,
		"top=%.1f bottom=%.1f cap=144" % [insets.y, insets.w])

	print("== dpi / physical size ==")
	# 1:1 viewport, 440dpi phone: a 0.72in button is 316.8 real pixels.
	var px := TouchControls.physical_px(0.72, 440.0, Vector2i(1080, 2400), Vector2(1080, 2400))
	_check("dpi/exact", is_equal_approx(px, 316.8), "got %.2f" % px)
	# Same physical size must survive the viewport stretch: half-size viewport
	# -> half the viewport units, so the finger still covers 0.72in of glass.
	var px_half := TouchControls.physical_px(0.72, 440.0, Vector2i(1080, 2400), Vector2(540, 1200))
	_check("dpi/scaled_by_stretch", is_equal_approx(px_half, px * 0.5), "got %.2f vs %.2f" % [px_half, px * 0.5])
	# A high-DPI phone must get MORE pixels than a low-DPI one for the same
	# physical size -- that is the entire point of the change.
	var lo := TouchControls.physical_px(0.72, 160.0, Vector2i(1080, 2400), Vector2(1080, 2400))
	_check("dpi/high_dpi_bigger_in_px", px > lo, "440dpi=%.1fpx 160dpi=%.1fpx" % [px, lo])
	# Bogus DPI (headless 0, X11 72-ish underreport, absurd 5000) -> fallback.
	var fb := TouchControls.physical_px(1.0, 160.0, Vector2i(1280, 720), Vector2(1280, 720))
	for bad in [0.0, 1.0, 5000.0, -3.0, NAN]:
		var got := TouchControls.physical_px(1.0, bad, Vector2i(1280, 720), Vector2(1280, 720))
		_check("dpi/fallback_%s" % bad, is_equal_approx(got, fb), "got %.2f expect %.2f" % [got, fb])

	print("== handedness mirror ==")
	var m := TouchControls.mirror_x(28.0, 160.0, 1280.0)
	_check("mirror/basic", is_equal_approx(m, 1092.0), "got %.1f" % m)
	_check("mirror/involutive", is_equal_approx(TouchControls.mirror_x(m, 160.0, 1280.0), 28.0))


# ---------------------------------------------------------------------------
# In-level: the real interact path
# ---------------------------------------------------------------------------
func _test_in_level() -> void:
	print("== desktop no-regression (before any force flag) ==")
	var standalone := TouchControls.new()
	root.add_child(standalone)
	await process_frame
	var sroot := standalone.get_node_or_null("TouchRoot") as Control
	_check("desktop/hidden_by_default", sroot != null and not sroot.visible,
		"TouchRoot.visible=%s want_touch=%s" % [sroot.visible if sroot else "?", standalone.call("_want_touch")])
	standalone.set_active(true)
	_check("desktop/set_active_true_still_inactive", not standalone.is_active(),
		"set_active(true) must be a no-op without a touchscreen")
	standalone.queue_free()
	await process_frame

	print("== settings (read-only, defensive) ==")
	var t := TouchControls.new()
	root.add_child(t)
	await process_frame
	t.force_touch_ui(true)
	_check("settings/defaults", t.get_handedness() == "left" and is_equal_approx(t.get_ui_scale(), 1.0),
		"side=%s scale=%.2f opacity=%.2f" % [t.get_handedness(), t.get_ui_scale(), t.get_opacity()])
	# Missing file must not disturb the defaults.
	t.reload_settings("user://__definitely_not_here.cfg")
	_check("settings/missing_file_keeps_defaults", t.get_handedness() == "left")
	# A file carrying the keys the Phase 7 spec names.
	var cfg := ConfigFile.new()
	cfg.set_value("controls", "touch_side", "right")
	cfg.set_value("controls", "touch_opacity", 0.4)
	cfg.set_value("controls", "touch_scale", 1.4)
	cfg.save(SCRATCH_CFG)
	t.reload_settings(SCRATCH_CFG)
	_check("settings/applied", t.get_handedness() == "right"
		and is_equal_approx(t.get_opacity(), 0.4) and is_equal_approx(t.get_ui_scale(), 1.4),
		"side=%s opacity=%.2f scale=%.2f" % [t.get_handedness(), t.get_opacity(), t.get_ui_scale()])
	# Percentages instead of 0..1 multipliers (the settings UI may store
	# either) and an unknown handedness spelling must both be tolerated.
	cfg.clear()
	cfg.set_value("touch", "handedness", "LEFTY")
	cfg.set_value("touch", "opacity", 65)
	cfg.set_value("touch", "scale", 120)
	cfg.save(SCRATCH_CFG)
	t.reload_settings(SCRATCH_CFG)
	_check("settings/percent_and_alt_section", t.get_handedness() == "left"
		and is_equal_approx(t.get_opacity(), 0.65) and is_equal_approx(t.get_ui_scale(), 1.2),
		"side=%s opacity=%.2f scale=%.2f" % [t.get_handedness(), t.get_opacity(), t.get_ui_scale()])
	# Junk must not crash and must stay inside the clamps.
	t.apply_settings({"touch_opacity": -5.0, "touch_scale": 99.0, "touch_side": ""})
	_check("settings/clamped", t.get_opacity() >= 0.2 and t.get_ui_scale() <= 2.0,
		"opacity=%.2f scale=%.2f" % [t.get_opacity(), t.get_ui_scale()])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH_CFG))

	print("== handedness mirrors the real layout ==")
	t.apply_settings({"touch_side": "left"})
	t.set_active(true)
	await process_frame
	var mb_l: Control = t.get("_move_base")
	var lb_l: Control = t.get("_look_base")
	var ab_l: Control = t.get("_action_btn")
	var left_move_x := mb_l.position.x
	var left_look_x := lb_l.position.x
	var left_action_x := ab_l.position.x
	var vp_w: float = root.get_visible_rect().size.x
	_check("layout/left_handed_move_on_left", left_move_x < left_look_x,
		"move.x=%.1f look.x=%.1f" % [left_move_x, left_look_x])
	t.apply_settings({"touch_side": "right"})
	await process_frame
	_check("layout/right_handed_is_exact_mirror",
		is_equal_approx(mb_l.position.x, TouchControls.mirror_x(left_move_x, mb_l.size.x, vp_w))
		and is_equal_approx(lb_l.position.x, TouchControls.mirror_x(left_look_x, lb_l.size.x, vp_w))
		and is_equal_approx(ab_l.position.x, TouchControls.mirror_x(left_action_x, ab_l.size.x, vp_w)),
		"move %.1f->%.1f look %.1f->%.1f action %.1f->%.1f vp=%.0f" % [
			left_move_x, mb_l.position.x, left_look_x, lb_l.position.x,
			left_action_x, ab_l.position.x, vp_w])
	_check("layout/right_handed_move_on_right", mb_l.position.x > lb_l.position.x)
	t.apply_settings({"touch_side": "left"})
	await process_frame

	print("== hit targets clear the safe area ==")
	# With a simulated notch the controls must sit inside the safe rect. The
	# real DisplayServer reports nothing here, so drive the maths directly.
	var insets := TouchControls.compute_safe_insets(
		Rect2i(0, 0, 1200, 660), Vector2i(1280, 720), Vector2(1280, 720))
	_check("safe_area/would_inset_controls", insets.z > 0.0 and insets.w > 0.0,
		"right=%.1f bottom=%.1f" % [insets.z, insets.w])
	t.queue_free()
	await process_frame

	print("== interact path, in a real level (%s) ==" % LEVEL)
	root.get_node("Piposh3DState").set("current_level", LEVEL)
	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	for i in 12:
		await process_frame

	var touch: Node = runner.get_node_or_null("TouchControls")
	var director: Node = runner.get_node_or_null("WdlDirector")
	if touch == null or director == null:
		_check("level/nodes_present", false, "TouchControls=%s WdlDirector=%s" % [touch, director])
		return
	_check("level/nodes_present", true)

	# On this desktop the runner leaves the touch layer off -- exactly today's
	# behaviour. Force it on to stand in for a handheld.
	_check("level/inactive_on_desktop", not touch.is_active(),
		"must stay off on a machine with no touchscreen")
	touch.force_touch_ui(true)
	touch.set_active(true)
	await process_frame
	_check("level/active_when_forced", touch.is_active())

	var probe := InputProbe.new()
	root.add_child(probe)
	await process_frame

	var action_btn: Control = touch.get("_action_btn")
	var cursor_btn: Control = touch.get("_cursor_btn")
	_check("level/buttons_visible", action_btn.visible and cursor_btn.visible)
	_check("level/button_min_hit_size", action_btn.size.x >= 64.0 and cursor_btn.size.x >= 64.0,
		"action=%.0f cursor=%.0f px" % [action_btn.size.x, cursor_btn.size.x])
	_check("level/buttons_do_not_overlap",
		not action_btn.get_rect().intersects(cursor_btn.get_rect()),
		"action=%s cursor=%s" % [action_btn.get_rect(), cursor_btn.get_rect()])

	# --- ACTION -> left click on the same path E / mouse-click already use ---
	var interp: Node = director.get("_wdl_interp")
	if interp != null:
		interp.set("_mouse_left_clicked", false)
	probe.raw.clear()
	probe.unhandled.clear()
	_tap(touch, action_btn, 7)
	# Read the interpreter flag with NO frame in between: WdlInterpreter's own
	# _check_mouse_click() consumes and clears `_mouse_left_clicked` every
	# frame, so awaiting first would always observe false.
	var interp_saw_click: bool = bool(interp.get("_mouse_left_clicked")) if interp != null else false
	await process_frame

	var left_presses := probe.raw.filter(func(e): return e["button"] == MOUSE_BUTTON_LEFT and e["pressed"])
	var left_releases := probe.raw.filter(func(e): return e["button"] == MOUSE_BUTTON_LEFT and not e["pressed"])
	_check("action/emits_left_press", left_presses.size() >= 1, "presses=%d" % left_presses.size())
	_check("action/emits_left_release", left_releases.size() >= 1, "releases=%d" % left_releases.size())
	# The probe sees the event after the root viewport has mapped it back into
	# viewport space, so it must read as the aim point exactly -- this is what
	# catches the stretch-transform mistake (a raw viewport-space position fed
	# to parse_input_event() arrives multiplied by the stretch factor).
	var expect_pos: Vector2 = touch.call("aim_point")
	_check("action/click_at_aim_point",
		left_presses.size() >= 1 and (left_presses[0]["pos"] as Vector2).is_equal_approx(expect_pos),
		"got %s expect %s" % [left_presses[0]["pos"] if left_presses.size() else "none", expect_pos])
	_check("action/reaches_unhandled_input",
		probe.unhandled.filter(func(e): return e["button"] == MOUSE_BUTTON_LEFT).size() >= 1,
		"WdlDirector listens at _unhandled_input; %d left events reached it" % probe.unhandled.filter(func(e): return e["button"] == MOUSE_BUTTON_LEFT).size())
	if interp != null:
		_check("action/sets_interpreter_mouse_clicked", interp_saw_click,
			"WdlInterpreter._mouse_left_clicked latched by the ACTION button")
	else:
		print("SKIP action/sets_interpreter_mouse_clicked -- level has no interpreter")

	# --- CURSOR -> right click -> WdlDirector.mouse_look toggles ---
	var before: bool = bool(director.get("mouse_look"))
	probe.raw.clear()
	_tap(touch, cursor_btn, 8)
	await process_frame
	var after: bool = bool(director.get("mouse_look"))
	var right_presses := probe.raw.filter(func(e): return e["button"] == MOUSE_BUTTON_RIGHT and e["pressed"])
	_check("cursor/emits_right_press", right_presses.size() >= 1, "presses=%d" % right_presses.size())
	_check("cursor/toggles_mouse_look", after != before,
		"mouse_look %s -> %s (false == 'Cursor mode - click targets')" % [before, after])
	# And back again, so it is a real toggle rather than a one-way latch.
	_tap(touch, cursor_btn, 9)
	await process_frame
	_check("cursor/toggle_is_reversible", bool(director.get("mouse_look")) == before,
		"mouse_look back to %s" % before)

	# --- look drag anywhere (NB-2 "no 3D look/turn movement") ---
	var player: Node = runner.get_node_or_null("Player")
	if player != null and player.has_method("apply_look_delta"):
		var yaw_before: float = float(player.get("_yaw"))
		# Deliberately far from the LOOK circle: the old code only started a
		# look drag inside that small bottom-corner pad.
		var start := Vector2(root.get_visible_rect().size.x * 0.55, root.get_visible_rect().size.y * 0.3)
		_press(touch, start, 11)
		_drag(touch, start + Vector2(120, 0), 11)
		_release(touch, start + Vector2(120, 0), 11)
		await process_frame
		_check("look/drag_outside_pad_turns_camera", not is_equal_approx(float(player.get("_yaw")), yaw_before),
			"yaw %.3f -> %.3f after a 120px drag at %s" % [yaw_before, float(player.get("_yaw")), start])
	else:
		print("SKIP look/drag_outside_pad_turns_camera -- no player controller in this level")

	# --- move pad still works and is bounded ---
	if player != null and player.get("touch_move") != null:
		var mb: Control = touch.get("_move_base")
		var centre := mb.position + mb.size * 0.5
		_press(touch, centre, 12)
		_drag(touch, centre + Vector2(0, -400), 12)
		await process_frame
		var tm: Vector2 = player.get("touch_move")
		_check("move/forward_is_positive_y", tm.y > 0.5 and tm.length() <= 1.001,
			"touch_move=%s (up on screen must be forward, magnitude clamped to 1)" % tm)
		_release(touch, centre, 12)
		await process_frame
		_check("move/release_zeroes", (player.get("touch_move") as Vector2).is_zero_approx())
	else:
		print("SKIP move/* -- no player controller in this level")

	probe.queue_free()
	runner.queue_free()
	await process_frame


# ---------------------------------------------------------------------------
# Touch simulation. Feeds InputEventScreenTouch/Drag straight into the node's
# own _input(), which is where a real device's events land too.
# ---------------------------------------------------------------------------
func _press(node: Node, pos: Vector2, index: int) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.position = pos
	ev.pressed = true
	node.call("_input", ev)


func _release(node: Node, pos: Vector2, index: int) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.position = pos
	ev.pressed = false
	node.call("_input", ev)


func _drag(node: Node, pos: Vector2, index: int) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = pos
	ev.relative = Vector2(10, 0)
	node.call("_input", ev)


func _tap(node: Node, ctrl: Control, index: int) -> void:
	var centre := ctrl.position + ctrl.size * 0.5
	_press(node, centre, index)
	_release(node, centre, index)
