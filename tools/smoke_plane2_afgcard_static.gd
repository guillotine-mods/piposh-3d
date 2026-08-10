extends SceneTree
## Regression check for the 2026-08-01 report: Plane2's AFG_Card (flight
## badge collectible, wall-mounted) "is animating instead of being static
## and attached to the wall." `action AFG_Card` (original/piposh3d/WDL/
## Afgan.wdl) never calls ent_frame/ent_cycle at all -- confirmed it
## should be a fixed pose. AFG.MDL has no "Stand" clip, only "Frame",
## which MdlAnimator's fallback used to always loop (correct for
## fan/smoke props, wrong here). Fixed via MdlAnimator.hold_autoplay,
## set for this action in WmbLevelLoader._attach_animator(). Checks the
## animator isn't in a "playing" (looping) state after spawn.
##
## Run: godot --headless --path . -s res://tools/smoke_plane2_afgcard_static.gd

const MdlAnimator = preload("res://scripts/engine/mdl_animator.gd")

const LEVEL := "Plane2"


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

	var card := _find_entity_by_action(runner, "AFG_Card")
	if card == null:
		print("FAIL: no AFG_Card entity found")
		quit(1)
		return

	var anim := card.get_node_or_null("MdlAnimator") as MdlAnimator
	if anim == null:
		print("FAIL: no MdlAnimator on AFG_Card")
		quit(1)
		return

	var playing0: bool = anim.get("_playing")
	var percent0: float = anim.get("_percent")
	print("right after spawn: playing=%s percent=%.2f" % [playing0, percent0])

	for i in 120:  # 2s @ 60fps
		await process_frame

	var playing1: bool = anim.get("_playing")
	var percent1: float = anim.get("_percent")
	print("after 2s: playing=%s percent=%.2f" % [playing1, percent1])

	var ok := not playing1 and absf(percent1 - percent0) < 0.01
	print("OK" if ok else "FAIL: AFG_Card is still animating/looping instead of holding a static frame")
	quit(0 if ok else 1)


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
