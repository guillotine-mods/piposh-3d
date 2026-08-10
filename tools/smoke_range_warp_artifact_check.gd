extends SceneTree
## GB-7 continued: "it spawns correctly in the middle but now 180
## degrees back." Input.warp_mouse() can generate its own synthetic
## InputEventMouseMotion reporting the jump, arriving a frame or two
## AFTER the warp call, not necessarily the same frame. Simulates that
## exact scenario directly: retry (which warps and arms a multi-frame
## suppression window), then inject a large synthetic motion event one
## frame later, and confirm it gets swallowed instead of spinning the
## just-reset aim back around.
##
## Run: godot --headless --path . -s res://tools/smoke_range_warp_artifact_check.gd

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

	# Aim away, die.
	interp.call("_set_field", {"t": "id", "name": "my"}, "pan", spawn_pan + 40.0, camtarget)
	for i in 3:
		await process_frame
	interp.call("_set_var", "Health", 0.0, null)
	for i in 15:
		await process_frame

	# Click Retry for real -- this warps the mouse and arms the
	# suppression window (see _warp_mouse_to_center()).
	interp.call("_set_var", "MoviePlaying", 0.0, null)
	interp.call("invoke_event", null, "fRIP1")
	await process_frame

	# ONE frame later, simulate the synthetic post-warp motion event a
	# real warp can generate -- large enough that, unswallowed, it would
	# rotate the aim most of the way around (matching the user's report).
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(540, 0)
	Input.parse_input_event(motion)

	for i in 29:
		await process_frame

	var pan_after: float = float(camtarget.get_meta("pan", -9999.0))
	var tilt_after: float = float(camtarget.get_meta("tilt", -9999.0))
	print("spawn pan=%.3f | after retry + synthetic warp motion, pan=%.3f (suppress_frames should have swallowed the 540px injection)" % [
		spawn_pan, pan_after,
	])

	var ok: bool = is_equal_approx(pan_after, spawn_pan) and is_equal_approx(tilt_after, spawn_tilt)
	print("OK" if ok else "FAIL: synthetic post-warp motion wasn't swallowed, aim got knocked off spawn pose")
	quit(0 if ok else 1)
