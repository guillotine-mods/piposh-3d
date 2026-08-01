extends SceneTree
## Regression check for the 2026-08-01 report: "Piposh ... there's no
## walking animation when he enters the frame and walks." Plane.wdl's
## `action PiposhWalk` calls `actor_move()` but never `ent_frame`/
## `ent_cycle` itself -- `_seed_static_pose_if_never_animated()` used to
## freeze him to a static pose the instant his coroutine started (built
## for decorative non-animated props, wrongly also caught this real
## walking character). Fixed: an action that calls actor_move() but no
## animation call of its own now gets an automatic "Walk" cycle driven
## from inside _do_actor_move() itself instead of a freeze. Confirms the
## MdlAnimator's current clip actually becomes "Walk" (not frozen) while
## he's moving.
##
## Run: godot --headless --path . -s res://tools/smoke_plane_walk_anim.gd

const LEVEL := "Plane"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)

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
	var saw_walk_clip := false
	for i in 120:  # 2s
		await process_frame
		var anim: Node = piposh.get_node_or_null("MdlAnimator")
		if anim and str(anim.get("_current_clip")).to_lower() == "walk":
			saw_walk_clip = true
	var moved := start_pos.distance_to(piposh.global_position)

	print("moved=%.2f saw_walk_clip=%s" % [moved, saw_walk_clip])
	var ok := moved > 1.0 and saw_walk_clip
	print("OK" if ok else "FAIL: Piposh moved without ever playing a Walk animation clip")
	quit(0 if ok else 1)
