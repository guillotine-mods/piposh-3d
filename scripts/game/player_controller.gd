extends CharacterBody3D

@export var move_speed := 8.0
@export var look_sensitivity := 0.15
@export var gravity := 24.0
@export var capture_mouse_on_ready := true

@onready var camera: Camera3D = $Camera3D

var _yaw := 0.0
var _pitch := 0.0


func _ready() -> void:
	add_to_group("player")
	if capture_mouse_on_ready:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * look_sensitivity
		_pitch -= event.relative.y * look_sensitivity
		_pitch = clampf(_pitch, -85.0, 85.0)
		rotation_degrees.y = _yaw
		camera.rotation_degrees.x = _pitch
	if event.is_action_pressed("pause_menu"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	# Scripted levels disable this; keep a hard guard so we never free-fall
	# if a Camera3D on this node accidentally becomes current.
	if not camera or not camera.current:
		velocity = Vector3.ZERO
		return
	var input_dir := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back") - Input.get_action_strength("move_forward")
	)
	var basis_y := global_transform.basis
	var direction := (basis_y * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed
	move_and_slide()
