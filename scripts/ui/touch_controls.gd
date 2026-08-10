extends CanvasLayer
## On-screen move (left) + look (right) pads for mobile / touch FP play.

var _player: CharacterBody3D
var _root: Control
var _move_base: Panel
var _move_knob: Panel
var _look_base: Panel
var _active := false

var _move_touch := -1
var _look_touch := -1
var _move_origin := Vector2.ZERO
var _look_last := Vector2.ZERO
const MOVE_RADIUS := 72.0
const LOOK_SENS := 0.55


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
	_root.add_child(_move_base)
	_root.add_child(_move_knob)
	_root.add_child(_look_base)
	var move_lbl := _label("MOVE")
	var look_lbl := _label("LOOK")
	_move_base.add_child(move_lbl)
	_look_base.add_child(look_lbl)
	set_active(false)
	get_viewport().size_changed.connect(_layout)
	_layout()


func bind_player(player: CharacterBody3D) -> void:
	_player = player


func set_active(on: bool) -> void:
	_active = on and _want_touch()
	_root.visible = _active
	if not _active and _player and _player.get("touch_move") != null:
		_player.touch_move = Vector2.ZERO
	_move_touch = -1
	_look_touch = -1
	_layout()


func _want_touch() -> bool:
	return (
		OS.has_feature("mobile")
		or OS.get_name() == "Android"
		or DisplayServer.is_touchscreen_available()
	)


func _make_pad(color: Color) -> Panel:
	var p := Panel.new()
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
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	return l


func _layout() -> void:
	var vp := get_viewport().get_visible_rect().size
	var pad := minf(vp.x, vp.y) * 0.22
	pad = clampf(pad, 110.0, 168.0)
	var margin := 28.0
	_move_base.size = Vector2(pad, pad)
	_move_base.position = Vector2(margin, vp.y - pad - margin)
	_move_knob.size = Vector2(pad * 0.42, pad * 0.42)
	_center_knob()
	_look_base.size = Vector2(pad, pad)
	_look_base.position = Vector2(vp.x - pad - margin, vp.y - pad - margin)


func _center_knob() -> void:
	_move_knob.position = _move_base.position + (_move_base.size - _move_knob.size) * 0.5


func _input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventScreenTouch:
		_on_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_on_drag(event as InputEventScreenDrag)
	elif event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		# Desktop touchscreen / editor testing via mouse.
		var mb := event as InputEventMouseButton
		var fake := InputEventScreenTouch.new()
		fake.index = 0
		fake.position = mb.position
		fake.pressed = mb.pressed
		_on_touch(fake)
	elif event is InputEventMouseMotion and (_move_touch == 0 or _look_touch == 0):
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			var mm := event as InputEventMouseMotion
			var drag := InputEventScreenDrag.new()
			drag.index = 0
			drag.position = mm.position
			drag.relative = mm.relative
			_on_drag(drag)


func _on_touch(ev: InputEventScreenTouch) -> void:
	if ev.pressed:
		if _point_in(_move_base, ev.position) and _move_touch < 0:
			_move_touch = ev.index
			_move_origin = _move_base.position + _move_base.size * 0.5
			_update_move(ev.position)
		elif _point_in(_look_base, ev.position) and _look_touch < 0:
			_look_touch = ev.index
			_look_last = ev.position
	else:
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
	if offset.length() > MOVE_RADIUS:
		offset = offset.normalized() * MOVE_RADIUS
	_move_knob.position = center + offset - _move_knob.size * 0.5
	var v := offset / MOVE_RADIUS
	# UI y grows down; invert so up = forward.
	if _player:
		_player.touch_move = Vector2(v.x, -v.y)


func _point_in(ctrl: Control, pos: Vector2) -> bool:
	return Rect2(ctrl.global_position, ctrl.size).has_point(pos)
