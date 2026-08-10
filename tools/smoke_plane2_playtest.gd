extends SceneTree
## Simulates an actual Plane2 playtest: loads the real level_runner.tscn
## flow, idles a few seconds, then clicks the Passenger entity (the one
## interaction in Plane2 that engages a WDL-driven camera -- action Cam3
## sets camera.x/y/z/pan/tilt/roll from its own position whenever
## HitHim > 0, which Passenger's click handler HitMe sets to 1). Logs both
## "cam-write" (WdlInterpreter._set_camera_field, what the script *thinks*
## the camera should be) and "cam-actual" (WdlDirector._process, what's
## *really* rendered) so a mismatch between them -- script drives a camera
## nobody's looking at vs. the visible camera actually jumping -- shows up
## as data instead of another guess.
##
## Run: godot --headless --path . -s res://tools/smoke_plane2_playtest.gd

const LEVEL := "Plane2"
const IDLE_FRAMES := 120
const POST_CLICK_FRAMES := 60


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	await process_frame
	await process_frame
	await process_frame

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director != null else null
	var loader: Node = runner.get("loader")
	print("Loaded %s: interpreted=%s fp=%s" % [LEVEL, interp != null, loader.has_first_person() if loader else "?"])

	print("\n--- Idling %d frames (no input) ---" % IDLE_FRAMES)
	for i in IDLE_FRAMES:
		await process_frame
	_report_camera_state("after idle")

	var passenger := _find_entity_by_action(loader, "Passanger")
	if passenger == null:
		print("FAIL: no Passanger entity found in Plane2")
		quit(1)
		return
	print("\n--- Clicking Passenger (%s), triggering HitMe -> Cam3 -> PiposhHit sequence ---" % passenger.name)
	director.call("_handle_click_action", str(passenger.get_meta("action", "")), passenger)

	for i in POST_CLICK_FRAMES:
		await process_frame
		if i % 10 == 0:
			_report_camera_state("post-click frame %d" % i)

	var hithim = _read_global(interp, "hithim")
	var goal_passenger = _read_global(interp, "goal_passanger")
	print("\nFinal state: HitHim=%s Goal_Passanger=%s" % [hithim, goal_passenger])
	print("\nDone. Compare the [cam-write] and [cam-actual] lines above:")
	print("- [cam-write] = what the WDL script told camera.x/y/z/pan/tilt/roll to be.")
	print("- [cam-actual] = the real position of whichever Camera3D is actually rendering.")
	print("If [cam-write] fires but no matching [cam-actual] jump follows, the script is")
	print("driving a camera that isn't the one on screen (e.g. fp mode owns the view).")
	quit(0)


func _report_camera_state(label: String) -> void:
	var active: Camera3D = null
	for cam in _all_cameras(root):
		if cam.current:
			active = cam
			break
	if active:
		print("[STATE] %s: active_cam=%s pos=%s" % [label, active.get_path(), active.global_position])
	else:
		print("[STATE] %s: no active camera" % label)


func _all_cameras(node: Node) -> Array[Camera3D]:
	var found: Array[Camera3D] = []
	if node is Camera3D:
		found.append(node)
	for c in node.get_children():
		found.append_array(_all_cameras(c))
	return found


func _find_entity_by_action(loader: Node, action_name: String) -> Node3D:
	if loader == null:
		return null
	var entities := loader.get_node_or_null("Entities")
	if entities == null:
		return null
	for n in entities.get_children():
		if n is Node3D and str(n.get_meta("action", "")) == action_name:
			return n
	return null


func _read_global(interp: Node, name: String) -> Variant:
	if interp == null:
		return null
	var globals: Dictionary = interp.get("_globals")
	var lower: Dictionary = interp.get("_globals_lower")
	var canonical := name
	if lower.has(name):
		canonical = str(lower[name])
	if not globals.has(canonical):
		return null
	return globals[canonical].get("value")
