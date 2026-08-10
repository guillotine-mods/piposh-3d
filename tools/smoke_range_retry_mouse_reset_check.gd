extends SceneTree
## GB-7 continued: "the [aim] location doesn't reset when we're
## restarting." Reproduces the actual reported sequence: aim away from
## spawn, die, move the mouse (as if blindly hunting for the Retry
## button while it was invisible/captured), click Retry, and confirm the
## camera's pan/tilt end up back at the spawn pose -- not nudged by the
## leftover mouse motion the instant `action CamTarget` resumes.
##
## Run: godot --headless --path . -s res://tools/smoke_range_retry_mouse_reset_check.gd

const LEVEL := "Range"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	for i in 5:
		await process_frame

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null
	if interp == null:
		print("FAIL: no interpreter")
		quit(1)
		return

	interp.call("_set_var", "MoviePlaying", 0.0, null)
	interp.call("_call", "ShowPanel", [], null)
	for i in 10:
		await process_frame

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var camtarget: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "CamTarget":
			camtarget = n
			break
	if camtarget == null:
		print("FAIL: no CamTarget entity")
		quit(1)
		return

	var spawn_pan: float = float(camtarget.get_meta("wdl_spawn_pan", 0.0))
	var spawn_tilt: float = float(camtarget.get_meta("wdl_spawn_tilt", 0.0))

	# Aim away from spawn (simulating normal play before dying).
	interp.call("_set_field", {"t": "id", "name": "my"}, "pan", spawn_pan + 40.0, camtarget)
	interp.call("_set_field", {"t": "id", "name": "my"}, "tilt", 20.0, camtarget)
	for i in 3:
		await process_frame

	# Die -> pRIP shows.
	interp.call("_set_var", "Health", 0.0, null)
	for i in 15:
		await process_frame
	print("frozen after death=%s" % interp.get("_frozen"))

	# Blindly move the mouse hunting for the Retry button, same as a real
	# player would while pRIP is up.
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(300, -150)
	Input.parse_input_event(motion)
	for i in 2:
		await process_frame

	# Click Retry for real.
	interp.call("_set_var", "MoviePlaying", 0.0, null)
	interp.call("invoke_event", null, "fRIP1")
	for i in 30:
		await process_frame

	var pan_after: float = float(camtarget.get_meta("pan", -9999.0))
	var tilt_after: float = float(camtarget.get_meta("tilt", -9999.0))
	print("spawn pan=%.3f tilt=%.3f | after retry pan=%.3f tilt=%.3f" % [
		spawn_pan, spawn_tilt, pan_after, tilt_after,
	])

	var ok: bool = (
		is_equal_approx(pan_after, spawn_pan)
		and is_equal_approx(tilt_after, spawn_tilt)
	)
	print("OK" if ok else "FAIL: aim didn't land back on spawn pose after retry")
	quit(0 if ok else 1)
