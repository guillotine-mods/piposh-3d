extends SceneTree
## Regression check for the 2026-08-01 report: "The height change also
## broke plane2 where now the character is lower than the plane so we
## can't move." Turned out to be two separate, unrelated bugs, both real:
## (1) `snap_to_floor()`'s 400-unit search range found a wrong lower deck
## at this exact spawn point (fixed: level_runner.gd now passes a tight
## 40-unit max_drop); (2) `player_move2()`'s own per-tick `Move_view_1st()`
## call permanently locked CameraAuthority into script mode (writing
## camera.* every frame from a stationary WDL-side entity), which zeroed
## the native controller's velocity every physics tick since its movement
## gate requires `camera.current == true` (fixed: move_view_1st/3rd/3rd_2
## bridged to no-ops in wdl_interpreter.gd, the native controller's own
## Camera3D is the sole FP camera authority in this port).
##
## Loads Plane2 for real (level_runner.tscn, same as a real level
## transition -- Run("Plane2.exe") does a full scene reload via
## LevelRouter, so a fresh direct load is representative), waits for
## first-person setup + snap_to_floor() to finish, then simulates a real
## forward-move input and checks whether the player's position actually
## changes (stuck-in-collision, or camera never gaining authority, both
## show as near-zero net movement despite input).
##
## Run: godot --headless --path . -s res://tools/smoke_plane2_move.gd

const LEVEL := "Plane2"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)

	for i in 30:
		await process_frame

	var player: Node3D = runner.get("player")
	if player == null:
		print("FAIL: no player node")
		quit(1)
		return

	print("player.global_position after setup: %s" % player.global_position)
	print("player collision_layer=%s collision_mask=%s" % [player.get("collision_layer"), player.get("collision_mask")])
	var pcam: Camera3D = player.get_node_or_null("Camera3D")
	print("player camera current=%s  viewport get_camera_3d=%s" % [
		pcam.current if pcam else "no cam", root.get_viewport().get_camera_3d()
	])

	var start_pos: Vector3 = player.global_position
	# Simulate holding "forward" for 2 real seconds.
	Input.action_press("move_forward")
	for i in 120:
		await process_frame
	Input.action_release("move_forward")

	var end_pos: Vector3 = player.global_position
	var moved := start_pos.distance_to(end_pos)
	print("start=%s end=%s moved=%.3f" % [start_pos, end_pos, moved])
	var ok := moved > 5.0
	print("OK" if ok else "FAIL: player barely moved despite 2s of forward input -- likely stuck")
	quit(0 if ok else 1)
