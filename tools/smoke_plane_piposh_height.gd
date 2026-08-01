extends SceneTree
## Regression check for the 2026-08-01 reports about `action PiposhWalk`'s
## spawn height in Plane. First report: "Piposh enters lower than he
## should be" (Godot Y=-39, raw WED origin) -- fixed by snapping to this
## level's `floor_y` (83). Second report, after that fix shipped: "he's
## too high over the plane's ground, he should walk in and be the same
## height as Krupnik that's already there" -- `floor_y` turned out to be a
## different deck of the plane entirely; the cabin Piposh actually walks
## into sits at ~Y=34-35 (Pip/Krup/Dummy's own placements), not 83.
## Re-fixed to snap to Y=34 (Piposh's own "Pip" resting placement in this
## same level) instead. Checks Piposh's spawn Y lands close to Krupnik's,
## not this level's unrelated floor_y.
##
## Run: godot --headless --path . -s res://tools/smoke_plane_piposh_height.gd

const LEVEL := "Plane"


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

	var piposh := _find_entity_by_action(runner, "PiposhWalk")
	var krup := _find_entity_by_action(runner, "Krup")
	if krup == null:
		krup = _find_entity_by_action(runner, "ThePlaneMovie")
	if piposh == null or krup == null:
		print("FAIL: PiposhWalk=%s Krup/ThePlaneMovie=%s" % [piposh, krup])
		quit(1)
		return

	var piposh_y := piposh.global_position.y
	var krup_y := krup.global_position.y
	print("PiposhWalk spawn Y=%.2f  Krupnik Y=%.2f" % [piposh_y, krup_y])

	var ok := absf(piposh_y - krup_y) < 5.0
	print("OK" if ok else "FAIL: Piposh not near Krupnik's height")
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
