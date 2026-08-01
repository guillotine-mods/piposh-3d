extends SceneTree
## Checks Sikot.MDL's clips -- reported 2026-08-01: Sikot (Plane2's
## clickable static NPC/prop) "needs to be static... animating instead."
## `action Sikot` (Plane2.wdl) never calls ent_frame/ent_cycle, same
## shape of bug as AFG_Card.
##
## Run: godot --headless --path . -s res://tools/smoke_sikot_clips.gd

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

	var sikot := _find_entity_by_action(runner, "Sikot")
	if sikot == null:
		print("FAIL: no Sikot entity found")
		quit(1)
		return

	var anim := sikot.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim == null:
		print("FAIL: no MdlAnimator on Sikot")
		quit(1)
		return

	print("clips=%s" % [anim.get("_clips").keys()])
	var playing0: bool = anim.get("_playing")
	var percent0: float = anim.get("_percent")
	print("right after spawn: playing=%s percent=%.2f" % [playing0, percent0])

	for i in 120:
		await process_frame

	var playing1: bool = anim.get("_playing")
	var percent1: float = anim.get("_percent")
	print("after 2s: playing=%s percent=%.2f" % [playing1, percent1])
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
