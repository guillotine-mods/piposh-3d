extends SceneTree
## GB-2 investigation: "Piposh walks in on the floor under the plane
## instead of the plane's own floor." The spawn-height fix
## (_snap_piposh_walk_to_pip, previously _snap_piposh_walk_to_krupnik)
## sets Piposh's height at spawn -- this tracks Y over the actual walk to
## see if it drifts away from that afterward, since _do_actor_move() is
## X/Z-only by design and shouldn't touch it, but something else might.
##
## Run: godot --headless --path . -s res://tools/smoke_plane_walk_height.gd

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
	var krup: Node3D = null
	for n in entities.get_children():
		var action := str(n.get_meta("action", ""))
		if action == "PiposhWalk":
			piposh = n
		elif action == "Krup" or action == "ThePlaneMovie":
			krup = n
	if piposh == null:
		print("FAIL: no PiposhWalk entity found")
		quit(1)
		return

	print("floor_y=%s Krupnik Y=%s" % [loader.get("floor_y"), krup.global_position.y if krup else "n/a"])
	var last_y := piposh.global_position.y
	for i in 300:  # 5s
		await process_frame
		var y := piposh.global_position.y
		if absf(y - last_y) > 0.01:
			print("t=%.2fs Y changed: %.3f -> %.3f  pos=%s" % [i / 60.0, last_y, y, piposh.global_position])
			last_y = y
		if i % 60 == 0:
			print("t=%.1fs pos=%s" % [i / 60.0, piposh.global_position])

	print("Done. final pos=%s" % piposh.global_position)
	quit(0)
