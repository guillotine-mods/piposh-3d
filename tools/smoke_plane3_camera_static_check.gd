extends SceneTree
## Reported live (2026-08-08): "the camera can 'move' even though it
## should be static." Root cause (GB-14, see docs/SESSION_LOG.md):
## `WdlDirector`'s own generic "mouse-look while scripted camera"
## feature directly mutated whichever Cam entity was currently active's
## own `pan`/`tilt` meta on every mouse-motion event (`-= event.relative
## / 5.0`), opted OUT for a hand-grown list of levels (Start/Shiks/
## Plane/Range/Studio) that nobody had added Plane3 to yet. Deleted
## entirely -- every level that actually wants free mouse-look already
## implements it in its own WDL script (Town/Golf/Range all do), so the
## generic fallback was always either redundant or actively wrong.
##
## Fires one LARGE, easily-distinguished mouse-motion event (relative =
## (10000, 10000) -- the old formula would have jumped pan/tilt by
## ~-2000 in a single frame, dwarfing anything Plane3's own script
## legitimately does) and confirms the active Cam entity's own pan/tilt
## meta barely moves.
##
## Run: godot --headless --path . -s res://tools/smoke_plane3_camera_static_check.gd

const LEVEL := "Plane3"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	for i in 10:
		await process_frame

	var director: Node = runner.get("_director")
	if director == null:
		print("FAIL: no director")
		quit(1)
		return

	var cam: Camera3D = get_root().get_viewport().get_camera_3d()
	if cam == null:
		print("FAIL: no active camera")
		quit(1)
		return

	var pos_before: Vector3 = cam.global_position
	var rot_before: Vector3 = cam.global_rotation
	print("camera before: pos=%s rot=%s" % [pos_before, rot_before])

	# A single huge mouse-motion event -- the OLD buggy formula
	# (-= event.relative / 5.0) would jump the active Cam entity's own
	# pan/tilt meta by ~2000 in one frame, dwarfing anything Plane3's own
	# script legitimately does in that time.
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(10000, 10000)
	Input.parse_input_event(motion)
	await process_frame
	await process_frame

	var pos_after: Vector3 = cam.global_position
	var rot_after: Vector3 = cam.global_rotation
	print("camera after huge mouse motion: pos=%s rot=%s" % [pos_after, rot_after])

	var pos_delta := pos_before.distance_to(pos_after)
	var rot_delta := rot_before.distance_to(rot_after)
	print("pos_delta=%.2f rot_delta=%.4f (expect both small -- a real jump would be huge/obvious)" % [pos_delta, rot_delta])

	var ok: bool = pos_delta < 50.0 and rot_delta < 0.5
	print("OK" if ok else "FAIL: camera jumped after mouse motion -- the removed mouse-look feature (or something like it) is still active")
	quit(0 if ok else 1)
