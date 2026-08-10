extends SceneTree
## Regression check for two stacked reports on the same symptom:
## 2026-08-01: "Piposh ... there's no walking animation when he enters
## the frame and walks" -- Plane.wdl's `action PiposhWalk` calls
## `actor_move()` but never `ent_frame`/`ent_cycle` itself, and
## `_seed_static_pose_if_never_animated()` used to freeze him to a
## static pose the instant his coroutine started. Fixed by auto-driving
## a "Walk" cycle from inside `_do_actor_move()` itself.
## 2026-08-02: SAME visible symptom returned after the GB-2 height fix
## made him fully visible again -- turned out to be a second, real,
## unrelated bug the first fix's own state-only checks never caught:
## `_do_actor_move()`'s walk-cycle phase accumulated distance UNBOUNDED
## and `MdlAnimator.play_cycle()` only clamps `_percent` to [0,100]
## (never wraps), so once accumulated phase passed 100 (~100 units of
## walking, a small fraction of the ~300-unit walk to Krupnik) the pose
## froze on the cycle's last frame for the rest of the walk while
## `current_clip`/`playing` state still looked perfectly normal. Fixed
## by wrapping the phase with `fmod(..., 100.0)`. Confirmed via a real
## `[mdl-anim]` log captured from an actual play session, not just
## headless simulation -- this test now checks the same thing the state-
## only version missed: does `_percent` keep CYCLING (not just
## "playing"), and specifically only while he's still actually moving
## (a stand-still hold once he legitimately arrives and dialogue opens
## is correct behavior, not a bug).
##
## Run: godot --headless --path . -s res://tools/smoke_plane_walk_anim.gd

const LEVEL := "Plane"


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

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var piposh: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "PiposhWalk":
			piposh = n
			break
	if piposh == null:
		print("FAIL: no PiposhWalk entity found")
		quit(1)
		return

	print("wdl_auto_walk_anim meta=%s" % piposh.get_meta("wdl_auto_walk_anim", "NOT SET"))
	var anim0: Node = piposh.get_node_or_null("MdlAnimator")
	print("MdlAnimator=%s current_clip=%s playing=%s" % [
		anim0, anim0.get("_current_clip") if anim0 else "n/a", anim0.get("_playing") if anim0 else "n/a"
	])
	var start_pos: Vector3 = piposh.global_position
	var last_pos: Vector3 = start_pos
	var saw_walk_clip := false
	var last_percent := -1.0
	var stuck_while_moving_frames := 0
	var max_stuck_while_moving := 0
	var worst_stuck_at := -1
	for i in 720:  # 12s -- the full walk-to-Krupnik duration, not just a slice
		await process_frame
		var anim: Node = piposh.get_node_or_null("MdlAnimator")
		var cur_pos: Vector3 = piposh.global_position
		var still_moving := not cur_pos.is_equal_approx(last_pos)
		last_pos = cur_pos
		if anim and str(anim.get("_current_clip")).to_lower() == "walk":
			saw_walk_clip = true
		if anim:
			var p: float = anim.get("_percent")
			if is_equal_approx(p, last_percent) and still_moving:
				stuck_while_moving_frames += 1
				if stuck_while_moving_frames > max_stuck_while_moving:
					max_stuck_while_moving = stuck_while_moving_frames
					worst_stuck_at = i
			else:
				stuck_while_moving_frames = 0
			last_percent = p
	var moved := start_pos.distance_to(piposh.global_position)

	# >30 frames (~0.5s) with zero pose change WHILE HE'S STILL PHYSICALLY
	# MOVING is a real stall. A hold once he's stopped (arrived, dialogue
	# open) is correct and deliberately excluded here.
	print("moved=%.2f saw_walk_clip=%s max_stuck_while_moving=%d (~%.2fs) at frame=%d" % [
		moved, saw_walk_clip, max_stuck_while_moving, max_stuck_while_moving / 60.0, worst_stuck_at
	])
	var ok := moved > 1.0 and saw_walk_clip and max_stuck_while_moving < 30
	print("OK" if ok else "FAIL: Piposh's walk pose stalled while he was still physically moving")
	quit(0 if ok else 1)
