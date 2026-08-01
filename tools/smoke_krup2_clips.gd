extends SceneTree
## Checks whether Krup2.MDL (Plane2's Krupnik) has a "Hammer" animation
## clip, and watches Krupnik during real play -- investigating the
## 2026-08-01 report "make the hammer animation in the place that it
## should be."
##
## Run: godot --headless --path . -s res://tools/smoke_krup2_clips.gd

const LEVEL := "Plane2"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	await process_frame
	await process_frame
	await process_frame

	var krup := _find_entity_by_action(runner, "Krupnik")
	if krup == null:
		print("FAIL: no Krupnik entity found")
		quit(1)
		return

	var anim := krup.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim == null:
		print("FAIL: no MdlAnimator on Krupnik")
		quit(1)
		return

	print("clips=%s" % [anim.get("_clips").keys()])
	print("Krupnik pos=%s pan_meta=%s" % [krup.global_position, krup.get_meta("pan", 0.0)])

	for i in 600:  # 10s @ 60fps -- long enough for the ~1-in-40/tick RNG trigger
		await process_frame
		var skill10 = krup.get_meta("wdl_skills", [])
		if skill10.size() > 9 and float(skill10[9]) > 0.0:
			print("t=%.2fs skill10=%.2f pos=%s pan_meta=%s" % [
				i / 60.0, skill10[9], krup.global_position, krup.get_meta("pan", 0.0)
			])

	quit(0)


func _find_entity_by_action(runner: Node, action_name: String) -> Node3D:
	var loader: Node = runner.get("loader")
	if loader == null:
		return null
	var entities := loader.get_node_or_null("Entities")
	if entities == null:
		return null
	for n in entities.get_children():
		if n is Node3D and str(n.get_meta("action", "")) == action_name:
			return n
	return null
