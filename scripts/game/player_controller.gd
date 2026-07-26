extends CharacterBody3D

@export var move_speed := 8.0
@export var look_sensitivity := 0.15
@export var gravity := 24.0
@export var capture_mouse_on_ready := true

@onready var camera: Camera3D = $Camera3D

var _yaw := 0.0
var _pitch := 0.0
var _acknex_scale := false
## Touch stick: x = strafe (−1..1), y = forward (−1..1, +forward).
var touch_move := Vector2.ZERO


func _ready() -> void:
	add_to_group("player")
	if capture_mouse_on_ready and not _prefer_touch_ui():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func configure_acknex_first_person(
	pan_deg: float = 0.0,
	min_z: float = -58.0,
	max_z: float = 57.0
) -> void:
	## Acknex move_view_1st:
	## CAMERA.Z = player.Z + MIN_Z + (MAX_Z-MIN_Z)*eye_height_up (0.8).
	## Body yaw = Acknex pan (local +X = forward). Camera yawed −90° so −Z
	## look matches parent +X.
	_acknex_scale = true
	move_speed = 140.0
	gravity = 500.0
	look_sensitivity = 0.12
	var height := maxf(max_z - min_z, 40.0)
	# After feet-snap, origin ≈ feet → eye is 0.8 * hull height.
	var eye_height := height * 0.8
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is CapsuleShape3D:
		var cap := (col.shape as CapsuleShape3D).duplicate() as CapsuleShape3D
		cap.radius = clampf(height * 0.18, 16.0, 28.0)
		cap.height = clampf(height * 0.85, 60.0, 110.0)
		col.shape = cap
		col.position = Vector3(0.0, cap.height * 0.5, 0.0)
	if camera:
		camera.position = Vector3(0.0, eye_height, 0.0)
		camera.far = 12000.0
		camera.near = 1.0
		# Acknex camera.arc is horizontal FOV; Godot fov is vertical.
		camera.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(30.0)) / (4.0 / 3.0)))
	_yaw = pan_deg
	_pitch = 0.0
	rotation_degrees.y = _yaw
	_apply_camera_angles()


func snap_to_floor(max_drop: float = 400.0, max_lift: float = 80.0) -> void:
	## Place capsule feet on the nearest walkable surface under/near spawn.
	if not is_inside_tree():
		return
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var from := global_position + Vector3(0.0, max_lift, 0.0)
	var to := global_position + Vector3(0.0, -max_drop, 0.0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = false
	q.collide_with_bodies = true
	q.collision_mask = 1
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	global_position.y = float(hit.position.y) + 0.5


func apply_look_delta(dx: float, dy: float) -> void:
	## Shared mouse / touch look. Godot +X rotation looks UP — pitch as-is.
	_yaw -= dx * look_sensitivity
	_pitch -= dy * look_sensitivity
	_pitch = clampf(_pitch, -80.0, 80.0)
	rotation_degrees.y = _yaw
	_apply_camera_angles()


func _prefer_touch_ui() -> bool:
	return (
		OS.has_feature("mobile")
		or OS.get_name() == "Android"
		or DisplayServer.is_touchscreen_available()
	)


func _apply_camera_angles() -> void:
	if camera == null:
		return
	# Godot Camera3D: positive rotation.x looks UP.
	if _acknex_scale:
		camera.rotation_degrees = Vector3(_pitch, -90.0, 0.0)
	else:
		camera.rotation_degrees = Vector3(_pitch, 0.0, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		apply_look_delta(event.relative.x, event.relative.y)
	if event.is_action_pressed("pause_menu"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if not camera or not camera.current:
		velocity = Vector3.ZERO
		return
	var input_dir := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back") - Input.get_action_strength("move_forward")
	)
	# Touch stick: y+ = forward (maps to −move_back in keyboard space).
	if touch_move.length_squared() > 1e-4:
		input_dir.x = clampf(input_dir.x + touch_move.x, -1.0, 1.0)
		input_dir.y = clampf(input_dir.y - touch_move.y, -1.0, 1.0)
	var forward: Vector3
	var right: Vector3
	if _acknex_scale:
		forward = global_transform.basis.x
		right = -global_transform.basis.z
	else:
		forward = -global_transform.basis.z
		right = global_transform.basis.x
	var direction := (right * input_dir.x + forward * -input_dir.y)
	if direction.length_squared() > 1e-6:
		direction = direction.normalized()
		velocity.x = direction.x * move_speed
		velocity.z = direction.z * move_speed
	else:
		velocity.x = 0.0
		velocity.z = 0.0
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0
	move_and_slide()
