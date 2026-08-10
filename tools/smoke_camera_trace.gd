extends SceneTree
## Instantiates the *real* level_runner.tscn for one level (same as
## boot.gd's normal flow, so LevelRunner's own _enable_first_person() /
## camera-authority logic actually runs -- unlike driving WmbLevelLoader +
## WdlDirector in isolation, which never exercises that layer) and reports
## which Camera3D is active + its transform every REPORT_EVERY frames.
## General-purpose: use whenever a reported symptom is camera-shaped
## ("camera cuts", "wrong view", "stuck camera") and needs real per-frame
## data instead of another guess from the WDL source. Built 2026-07-30
## while diagnosing a "camera shots moving one by one, no audio/animation"
## report on Plane2 (root cause turned out to be unrelated -- see
## docs/SESSION_LOG.md -- but this tool earns its keep for the next one).
##
## Run: godot --headless --path . -s res://tools/smoke_camera_trace.gd -- Plane2
## Run: godot --headless --path . -s res://tools/smoke_camera_trace.gd            (defaults to Plane2)

const DEFAULT_LEVEL := "Plane2"
const FRAMES := 900
const REPORT_EVERY := 15


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var level := args[0] if args.size() > 0 else DEFAULT_LEVEL

	# get_node()+set() instead of a static `Piposh3DState.current_level =`
	# reference -- a bare autoload identifier forces GDScript to resolve it
	# at this script's own parse time, before autoloads are registered in
	# `-s` custom-main-loop mode (see tools/smoke_dispatch.gd's header for
	# the fuller story); routing through the node tree defers it to runtime.
	root.get_node("Piposh3DState").set("current_level", level)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	await process_frame
	await process_frame

	var last_cam: Camera3D = null
	var last_pos := Vector3.INF
	var switches := 0
	var cuts := 0

	print("Tracing camera for level=%s\n" % level)
	for i in FRAMES:
		await process_frame
		if i % REPORT_EVERY != 0:
			continue
		var active := _find_active_camera()
		var pos := active.global_position if active else Vector3.INF
		var switched := active != last_cam
		var jumped := (
			active != null and last_cam == active
			and last_pos != Vector3.INF
			and pos.distance_to(last_pos) > 50.0
		)
		if switched and last_cam != null:
			switches += 1
		if jumped:
			cuts += 1
		print(
			"frame=%4d active_cam=%s pos=%s%s%s"
			% [
				i,
				active.get_path() if active else "<none>",
				pos,
				" <<CAMERA SWITCH>>" if switched and last_cam != null else "",
				" <<POS JUMP>>" if jumped else "",
			]
		)
		last_cam = active
		last_pos = pos

	print(
		"\nDone. %d camera-node switch(es), %d position jump(s) >50u, across %d samples."
		% [switches, cuts, FRAMES / REPORT_EVERY]
	)
	quit(0)


func _find_active_camera() -> Camera3D:
	for cam in _all_cameras(root):
		if cam.current:
			return cam
	return null


func _all_cameras(node: Node) -> Array[Camera3D]:
	var found: Array[Camera3D] = []
	if node is Camera3D:
		found.append(node)
	for c in node.get_children():
		found.append_array(_all_cameras(c))
	return found
