extends CanvasLayer
class_name GameHud
## Acknex-style 2D panels (640×480 design space), cursor, dialog, Town BIO.

signal dialog_choice(choice: int)
signal skip_line_pressed

const DESIGN := Vector2(640, 480)
const GFX := "res://assets/converted/gfx/"

var mouse_look := true  # mouse_mode==0 in WDL
var show_debug := false
## See show_dialog()/hide_dialog() -- mirrors WdlInterpreter's own
## `_mouse_mode_before_rip` save/restore around the pRIP death panel.
var _mouse_mode_before_dialog: int = -1

var _scale := 1.0
var _root: Control
var _overlay_layer: CanvasLayer
var _overlay_root: Control
var _cursor: TextureRect
var _p_som: TextureRect
var _p_ovr: TextureRect
var _p_shkufit: TextureRect
var _bio: TextureRect
var _zoom_label: Label
var _range_label: Label
var _dialog_root: Control
var _dialog_bg: TextureRect
var _opt_btns: Array[BaseButton] = []
var _opt_labels: Array[Label] = []
var _debug_title: Label
var _debug_hint: Label
var _skip_btn: Button

var _ovr_base_x := 223.0
# Start.wdl uses y=460 for a 23px strip (clips past 480). Keep the full
# glyph row on-screen and a bit higher so text reads centered in the band.
var _som_base_y := 450.0
var _ovr_x := 223.0
var _crawl_active := false
var _blink_t := 0.0  # my.skill35 in Studio/Start.wdl: drives pOvr's blink.
var _hold_t := 0.0  # my.skill34: gates the downward scroll behind a hold.
var _subtitle_kind := ""  # start | studio | ""
var _subtitle_heartbeat_t := 0.0
var _logged_reveal_done := false
var _logged_scroll_started := false


func _ready() -> void:
	layer = 20
	_root = Control.new()
	_root.name = "DesignRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# GB-7 continued (2026-08-06, Range): "the skip button is still beneath
	# the graphic that's shown when we die." Two earlier fixes (a z_index
	# default, then an explicit `move_to_front()` tree reorder -- see
	# WdlInterpreter._reorder_panels_by_layer()) both should have put
	# pSkip visually on top within this same CanvasLayer, and both were
	# reported live as not actually fixing it. Rather than keep guessing
	# at why intra-layer z_index/tree-order isn't winning here, moved to a
	# mechanism this project already relies on and knows works reliably:
	# a SEPARATE CanvasLayer with a strictly higher `layer` number always
	# draws over everything in a lower one, unconditionally, regardless of
	# z_index or tree position within either layer (the same guarantee
	# already used for the loading screen (40) and level-select menu (30)
	# sitting over ordinary gameplay/HUD (20) here). `_overlay_root` mirrors
	# `_root`'s own scale/position every `_layout()` call so panels parented
	# under it still use the identical 640x480 design-space coordinates as
	# every other panel.
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "HudOverlay"
	_overlay_layer.layer = 21
	add_child(_overlay_layer)
	_overlay_root = Control.new()
	_overlay_root.name = "OverlayDesignRoot"
	_overlay_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_layer.add_child(_overlay_root)

	_p_som = _tex("pSom", "")
	_p_ovr = _tex("pOvr", "")
	_p_shkufit = _tex("pShkufit", "SHKUFIT.png")
	_p_shkufit.visible = false
	_bio = _tex("BIO", "BIO.png")
	_bio.visible = false
	_bio.position = Vector2.ZERO

	_zoom_label = Label.new()
	_zoom_label.name = "Zoom"
	_zoom_label.position = Vector2(60, 455)
	_zoom_label.add_theme_font_size_override("font_size", 14)
	_zoom_label.add_theme_color_override("font_color", Color(0.95, 0.9, 0.2))
	_zoom_label.visible = false
	_root.add_child(_zoom_label)

	## Range.wdl GUI: health/terrorist/civilian counters. Simplified from the
	## original's pixel-art panel row (Hit1-5.pcx) to text — always visible,
	## not gated behind the F10 debug overlay like status.emit() text is.
	_range_label = Label.new()
	_range_label.name = "RangeHud"
	_range_label.position = Vector2(10, 10)
	_range_label.add_theme_font_size_override("font_size", 16)
	_range_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
	_range_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_range_label.add_theme_constant_override("outline_size", 3)
	_range_label.visible = false
	_root.add_child(_range_label)

	_build_dialog()
	_build_skip_button()
	_cursor = _tex("Cursor", "cursor1.png")
	_cursor.z_index = 100
	_cursor.visible = false
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_debug_title = Label.new()
	_debug_title.position = Vector2(8, 8)
	_debug_title.add_theme_font_size_override("font_size", 16)
	_debug_title.visible = false
	_root.add_child(_debug_title)
	_debug_hint = Label.new()
	_debug_hint.position = Vector2(8, 28)
	_debug_hint.add_theme_font_size_override("font_size", 12)
	_debug_hint.visible = false
	_root.add_child(_debug_hint)

	get_viewport().size_changed.connect(_layout)
	_layout()


func _process(delta: float) -> void:
	_update_cursor()
	if _crawl_active:
		_update_crawl(delta)


func set_debug_text(title: String, hint: String) -> void:
	_debug_title.text = title
	_debug_hint.text = hint
	_debug_title.visible = show_debug
	_debug_hint.visible = show_debug


func set_status(msg: String) -> void:
	_debug_hint.text = msg
	_debug_hint.visible = show_debug


## Position/visibility/z-order snapshot -- call at any point to see
## exactly where the subtitle actually is in both design and real screen
## space, and what's drawn immediately around/after it in the tree.
func _log_subtitle_frame(context: String) -> void:
	var p_som_screen: Vector2 = _root.position + _p_som.position * _scale
	var p_ovr_screen: Vector2 = _root.position + _p_ovr.position * _scale
	PiposhDebug.log_msg(
		"hud-event",
		("subtitle %s: pSom design_pos=%s screen_pos=%s visible=%s | " +
		"pOvr design_pos=%s screen_pos=%s visible=%s | scale=%.3f " +
		"hold_t=%.2f blink_t=%.2f ovr_x=%.1f")
		% [
			context,
			_p_som.position, p_som_screen, _p_som.visible,
			_p_ovr.position, p_ovr_screen, _p_ovr.visible,
			_scale, _hold_t, _blink_t, _ovr_x,
		]
	)


func clear_subtitles() -> void:
	PiposhDebug.log_msg("hud-event", "subtitle CLEAR kind=%s" % _subtitle_kind)
	_crawl_active = false
	_subtitle_kind = ""
	_p_som.visible = false
	_p_ovr.visible = false
	_p_shkufit.visible = false


func set_shkufit(on: bool) -> void:
	_p_shkufit.visible = on
	if on:
		_p_shkufit.position = Vector2(0, 0)
		_fit(_p_shkufit)


func setup_town_bio() -> void:
	_bio.visible = true
	_zoom_label.visible = true
	_fit(_bio)
	_bio.position = Vector2.ZERO


func set_zoom_digit(zoom: int) -> void:
	_zoom_label.text = "%02d" % clampi(zoom, 1, 14)


## WdlInterpreter's Acknex `panel`/`text` HUD objects (health bars, hit
## icons, win/lose screens, ...) mount here -- same design-space (640x480,
## `_scale`-applied) root every other HUD element already uses, so panel
## `pos_x`/`pos_y` values from the original WDL line up without any extra
## conversion.
func get_panel_root() -> Control:
	return _root


## See `_overlay_layer`'s own comment in _ready(). Same 640x480 design
## space and coordinate convention as `get_panel_root()` -- the only
## difference is the CanvasLayer it's rendered through, which always
## draws above everything from `get_panel_root()`, unconditionally.
func get_overlay_panel_root() -> Control:
	return _overlay_root


func set_range_hud(text: String) -> void:
	_range_label.visible = true
	_range_label.text = text


func hide_range_hud() -> void:
	_range_label.visible = false


func set_mouse_look(enabled: bool) -> void:
	mouse_look = enabled
	if enabled:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_cursor.visible = false
	else:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN  # we draw cursor1
		_cursor.visible = true


func toggle_mouse_look() -> void:
	set_mouse_look(not mouse_look)


func is_dialog_open() -> bool:
	return _dialog_root != null and _dialog_root.visible


func show_dialog(index: int) -> void:
	_dialog_root.visible = true
	_dialog_root.z_index = 50
	_dialog_root.move_to_front()
	var lines := _dialog_lines(index)
	for i in 3:
		_opt_labels[i].text = lines[i] if i < lines.size() else ""
		_opt_btns[i].disabled = false
		_opt_btns[i].visible = true
		_opt_btns[i].mouse_filter = Control.MOUSE_FILTER_STOP
		_opt_btns[i].focus_mode = Control.FOCUS_ALL
	# Dialog needs a real OS cursor for TextureButton hit-testing.
	# Reported live (2026-08-07, Range): "a real system cursor is visible
	# and wanders" during actual shooting-gallery aiming, well after the
	# intro dialogue had closed. Root cause: this forced MOUSE_MODE_VISIBLE
	# unconditionally and hide_dialog() never put it back -- Range's own
	# `main()` (original/piposh3d/Range.wdl:290-311) shows a real DoDialog
	# choice before gameplay starts, same as most levels, and nothing ever
	# restored the captured/hidden mouse mode `action CamTarget`'s own
	# mickey-based aiming depends on afterward, so the real OS pointer
	# stayed visible and freely movable for the rest of the level --
	# independent of, and confusing next to, the WDL-drawn crosshair.
	# Saved/restored the same way WdlInterpreter's own
	# `_mouse_mode_before_rip` already does around the pRIP death panel.
	if _mouse_mode_before_dialog == -1:
		_mouse_mode_before_dialog = Input.mouse_mode
	mouse_look = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_cursor.visible = false


func hide_dialog() -> void:
	if _dialog_root:
		_dialog_root.visible = false
	if _mouse_mode_before_dialog != -1:
		Input.mouse_mode = _mouse_mode_before_dialog as Input.MouseMode
		_mouse_mode_before_dialog = -1
		mouse_look = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		_cursor.visible = Input.mouse_mode == Input.MOUSE_MODE_HIDDEN


func set_skip_visible(on: bool) -> void:
	if _skip_btn:
		_skip_btn.visible = on


func _build_skip_button() -> void:
	_skip_btn = Button.new()
	_skip_btn.name = "SkipLine"
	_skip_btn.text = "Skip ▶"
	_skip_btn.focus_mode = Control.FOCUS_NONE
	_skip_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	_skip_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_skip_btn.z_index = 80
	_skip_btn.custom_minimum_size = Vector2(96, 40)
	_skip_btn.add_theme_font_size_override("font_size", 16)
	_skip_btn.add_theme_color_override("font_color", Color(1, 1, 0.9))
	_skip_btn.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	_skip_btn.add_theme_stylebox_override("normal", _skip_style(Color(0.05, 0.05, 0.08, 0.72)))
	_skip_btn.add_theme_stylebox_override("hover", _skip_style(Color(0.12, 0.14, 0.2, 0.85)))
	_skip_btn.add_theme_stylebox_override("pressed", _skip_style(Color(0.2, 0.18, 0.1, 0.9)))
	_skip_btn.pressed.connect(func() -> void: skip_line_pressed.emit())
	_skip_btn.visible = true
	_root.add_child(_skip_btn)


func _skip_style(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


func _build_dialog() -> void:
	_dialog_root = Control.new()
	_dialog_root.name = "Dialog"
	_dialog_root.visible = false
	# Only the Opt buttons capture clicks — full-screen STOP blocked Studio
	# ShikNote / AFG_Card (and any world pick) while the dialog was open.
	_dialog_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dialog_root.z_index = 50
	_root.add_child(_dialog_root)

	_dialog_bg = TextureRect.new()
	_dialog_bg.texture = _load_tex("Steel.png")
	_dialog_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_dialog_bg.stretch_mode = TextureRect.STRETCH_KEEP
	_dialog_bg.position = Vector2(0, 333)
	_dialog_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dialog_root.add_child(_dialog_bg)

	_opt_btns.clear()
	_opt_labels.clear()
	# DIalog.wdl: steel @ y=333; buttons @ (0,-15)/(0,40)/(0,97).
	# Labels are vertically centered in each Opt bar (Godot font metrics sit
	# lower than Acknex TEXT at the same pos_y).
	var btn_ys := [318.0, 373.0, 430.0]
	var opt_tex := _load_tex("Opt1.png")
	var opt_hover := _load_tex("Opt2.png")
	var btn_h := 56.0
	if opt_tex:
		btn_h = float(opt_tex.get_height())
	for i in 3:
		var btn := TextureButton.new()
		btn.position = Vector2(0, btn_ys[i])
		btn.size = Vector2(640, btn_h)
		btn.stretch_mode = TextureButton.STRETCH_SCALE
		btn.ignore_texture_size = true
		if opt_tex:
			btn.texture_normal = opt_tex
		if opt_hover:
			btn.texture_hover = opt_hover
			btn.texture_pressed = opt_hover
		btn.mouse_filter = Control.MOUSE_FILTER_STOP
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.pressed.connect(_emit_choice.bind(i + 1))
		_dialog_root.add_child(btn)
		_opt_btns.append(btn)

		var lab := Label.new()
		# Center in Opt bar, then nudge up — Godot Label descent sits low vs A5 TEXT.
		lab.position = Vector2(50, btn_ys[i] - 6.0)
		lab.size = Vector2(560, btn_h)
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lab.text_direction = Control.TEXT_DIRECTION_RTL
		lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lab.add_theme_font_size_override("font_size", 15)
		lab.add_theme_color_override("font_color", Color(1.0, 1.0, 0.85))
		lab.add_theme_constant_override("line_spacing", 0)
		lab.add_theme_constant_override("outline_size", 0)
		_dialog_root.add_child(lab)
		_opt_labels.append(lab)


func _emit_choice(idx: int) -> void:
	if not is_dialog_open():
		return
	hide_dialog()
	dialog_choice.emit(idx)


func _dialog_lines(index: int) -> Array[String]:
	# Hebrew from DIalog.wdl comments (DialogIndex)
	match index:
		0:
			return [
				"אז למתי אתה רושם לי את הצ'ק עמי?",
				"עמי, רציתי לדבר איתך בעניין הסכום...",
				"פוי....מישהו מוכן להוציא אותי מהשטומבה הזו?",
			]
		1:
			return [
				"שלום באתי בקשר למודעה",
				"שלום אולי אתה רוצה לתרום לאגודת : \"איך אני מוציא את חזי מהשטומבה הזו?\"",
				"תסלח לי על הפוני, בדרך כלל לא תראה אותי ככה..",
			]
		2:
			return [
				"אוייש תהרוג אותי! זו עטיפת פקפקים! לקח לי שנה להיגמל מזה",
				"שאני אאסוף לך בזה קצוות של שמיר ממערת הנטיפים?",
				"אוי, בוא תראה טריק שלמדתי בחוג קורדינציה לאפרסק בבית הספר ב.צבי..",
			]
		3:
			# Plane.wdl DialogIndex 3 (DIalog.wdl)
			return [
				"בחורצ'יק...אתה עובד כאן לא?!",
				"תן לי מקום להניח את הרגלים שלי! איפה אתה מושיב אותי?",
				"בלבוסטע אכפת לך שאני אשים את האגרטל הזה על הראש שלך?",
			]
		4:
			# Range.wdl DialogIndex 4 (DIalog.wdl) -- decoded 2026-08-01, was
			# never transcribed (fell through to the "…" placeholder, see
			# docs/SESSION_LOG.md). DIalog.wdl stores these reversed and run
			# through a per-letter Hebrew-alphabet substitution (a→א, b→ב,
			# c→ג, ... in alphabetical order -- NOT a keyboard layout, a
			# straight a-z→א-ת cipher) instead of real Hebrew text, decoded
			# by cross-referencing the already-solved DialogIndex 0-3 pairs
			# above to recover the exact mapping, then applying it here.
			return [
				"ניחוש פרוע! אתה לא יודע איך להטיס מטוס",
				"אוך! תן לי כבר אני אנהג במקומך",
				"אגב קרופניק אולי תשפיע בשבילי לקבל סיכת קברניט מה?!",
			]
		_:
			return ["…", "…", "…"]


func _update_crawl(delta: float) -> void:
	# Clamp: the first _process() after setup_*_subtitles() lands right
	# after a whole level's worth of synchronous boot work (WMB/GLB load,
	# every entity's action coroutine starting) -- Godot's delta for that
	# frame is the REAL elapsed wall-clock time, which can be large enough
	# that this animation (an 8-units/real-tick crawl, tuned for a normal
	# ~16ms frame) skips most or all of the way to its end state in a
	# single step, so the subtitle is never actually seen on screen even
	# though every node property (visible/texture/position) ends up
	# "correct" by the next frame -- a headless property check can't catch
	# this, only an eyes-on-the-real-window report can.
	delta = minf(delta, 1.0 / 30.0)
	var stop_x := -310.0 if _subtitle_kind == "studio" else -200.0
	if _ovr_x > stop_x:
		_ovr_x -= 8.0 * delta * 16.0  # ~time units → seconds
		_layout_subtitles()
		_subtitle_heartbeat_t += delta
		if _subtitle_heartbeat_t > 1.0:
			_subtitle_heartbeat_t = 0.0
			_log_subtitle_frame("reveal in progress")
		return
	if not _logged_reveal_done:
		_logged_reveal_done = true
		_log_subtitle_frame("reveal done, holding")
	# `my.skill34`/`my.skill35` in the source: skill35 drives the blink,
	# skill34 gates the downward scroll behind a ~60-tick (3.75s) HOLD --
	# `pOvr.pos_y`/`pSom.pos_y` only start incrementing once skill34 > 60,
	# so the fully-revealed line sits still and readable for ~3.75s before
	# any scrolling starts. Missing that gate here made the line start
	# sliding away within under 2 seconds of finishing its reveal --
	# functionally still "shown", but easy to miss entirely at that speed.
	_hold_t += delta
	_blink_t += delta
	if _hold_t > 60.0 / 16.0:
		if not _logged_scroll_started:
			_logged_scroll_started = true
			_log_subtitle_frame("hold done, scrolling away")
		var dy := (_hold_t - 60.0 / 16.0) * 16.0  # slow downward crawl
		# Design-space, unscaled -- see _layout_subtitles()'s comment.
		_p_som.position.y = _som_base_y + dy
		_p_ovr.position.y = _som_base_y + dy
	if _blink_t > 5.0 / 16.0:
		_blink_t = 0.0
		_p_ovr.visible = not _p_ovr.visible


func _layout_subtitles() -> void:
	# Design-space coordinates, unscaled -- `_p_som`/`_p_ovr` are children
	# of `_root`, which already carries `_root.scale = Vector2(_scale,
	# _scale)` (see _layout()). Every other element in this file (
	# `_zoom_label`, `_range_label`, dialog buttons, ...) sets `.position`
	# this same unscaled way for that exact reason. This function used to
	# multiply by `_scale` a SECOND time here, so at any real viewport
	# size other than exactly 640x480 (i.e. essentially always) the
	# subtitle rendered `_scale` times further down/right than intended --
	# e.g. at `_scale=2.0`, `_som_base_y=450` design-space landed at
	# world y=1800 (plus `_root.position`), off the bottom of any normal
	# window. Found via the [hud-event] logging added for the "not
	# showing on screen" report (2026-08-01) -- its very first
	# `screen_pos` log line showed the panel positioned below the visible
	# viewport entirely.
	_p_som.position = Vector2(0, _som_base_y)
	_p_ovr.position = Vector2(_ovr_x, _som_base_y)
	_fit(_p_som)
	_fit(_p_ovr)


func _layout() -> void:
	var vp := get_viewport().get_visible_rect().size
	_scale = minf(vp.x / DESIGN.x, vp.y / DESIGN.y)
	_root.scale = Vector2(_scale, _scale)
	_root.position = Vector2(
		(vp.x - DESIGN.x * _scale) * 0.5,
		(vp.y - DESIGN.y * _scale) * 0.5
	)
	_root.size = DESIGN
	_overlay_root.scale = _root.scale
	_overlay_root.position = _root.position
	_overlay_root.size = DESIGN
	if _crawl_active:
		PiposhDebug.log_msg(
			"hud-event",
			"subtitle _layout(): viewport=%s scale=%.4f root_pos=%s"
			% [vp, _scale, _root.position]
		)
	_fit(_bio)
	_fit(_p_shkufit)
	_fit(_dialog_bg)
	_layout_subtitles()
	if _dialog_bg.texture:
		_dialog_bg.size = _dialog_bg.texture.get_size()
	_dialog_root.position = Vector2(0, 0)
	_dialog_root.size = DESIGN
	var btn_ys := [318.0, 373.0, 430.0]
	var btn_h := 56.0
	if _opt_btns.size() > 0 and _opt_btns[0].texture_normal:
		btn_h = float(_opt_btns[0].texture_normal.get_height())
	for i in _opt_btns.size():
		_opt_btns[i].position = Vector2(0, btn_ys[i])
		_opt_btns[i].size = Vector2(640, btn_h)
		_opt_labels[i].position = Vector2(50, btn_ys[i] - 6.0)
		_opt_labels[i].size = Vector2(560, btn_h)
	if _skip_btn:
		_skip_btn.position = Vector2(DESIGN.x - 108, 8)
		_skip_btn.size = Vector2(96, 40)


func _update_cursor() -> void:
	if not _cursor.visible:
		return
	# Cursor in design space
	var vp := get_viewport()
	var mp := vp.get_mouse_position()
	var local := (mp - _root.position) / _scale
	_cursor.position = local
	_fit(_cursor)


func _tex(node_name: String, file_name: String) -> TextureRect:
	var tr := TextureRect.new()
	tr.name = node_name
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.visible = false
	if file_name != "":
		_set_tex(tr, file_name)
	_root.add_child(tr)
	return tr


func _set_tex(tr: TextureRect, file_name: String) -> void:
	tr.texture = _load_tex(file_name)
	_fit(tr)


func _fit(tr: TextureRect) -> void:
	if tr.texture:
		tr.size = tr.texture.get_size()


func _load_tex(file_name: String) -> Texture2D:
	var path := _resolve_gfx(file_name)
	if path == "":
		push_warning("GFX missing: %s" % file_name)
		return null
	var tex := load(path) as Texture2D
	if tex == null:
		return null
	# A5 overlay: pure black is transparent. Re-key at load so older PNGs
	# without an alpha channel still composite correctly.
	return _ensure_overlay_alpha(tex)


func _resolve_gfx(file_name: String) -> String:
	var path := GFX + file_name
	if ResourceLoader.exists(path):
		return path
	var dir := DirAccess.open(GFX)
	if dir == null:
		return ""
	var want := file_name.to_lower()
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if fn.to_lower() == want:
			return GFX + fn
		fn = dir.get_next()
	return ""


func _ensure_overlay_alpha(tex: Texture2D) -> Texture2D:
	# Prefer pre-keyed PNGs from convert_gfx.py. Only rewrite if the texture
	# is fully opaque (legacy convert without A5 overlay color-key).
	var img := tex.get_image()
	if img == null:
		return tex
	if img.detect_alpha():
		return tex
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	var changed := false
	for i in range(0, data.size(), 4):
		if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 0:
			data[i + 3] = 0
			changed = true
	if not changed:
		return tex
	var out := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data)
	return ImageTexture.create_from_image(out)
