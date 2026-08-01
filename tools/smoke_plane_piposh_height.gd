extends SceneTree
## Regression check for the 2026-08-01 report: "Piposh enters [Plane] but
## he's lower than he should be, not walking on the plane's height at the
## start of the scene, later on it's fixed." `action PiposhWalk` spawns
## at Godot Y=-39 (raw WED origin) while this level's own computed
## floor_y is 83 -- confirmed via WmbLevelLoader.gd's own load-time log.
## A live per-tick raycast floor-snap was tried and reverted (locked onto
## the wrong collision surface on this exact mesh and climbed away
## instead of settling -- see docs/SESSION_LOG.md). Fixed instead with a
## narrow, one-time spawn correction scoped to this exact entity
## (WmbLevelLoader._spawn_entity()): snap to floor_y at spawn if authored
## more than 40 units below it. Checks Piposh's spawn Y lands close to
## this level's floor_y instead of far below it.
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
	if piposh == null:
		print("FAIL: no PiposhWalk entity found")
		quit(1)
		return

	var start_y := piposh.global_position.y
	var floor_y: float = runner.get("loader").get("floor_y")
	print("spawn Y=%.2f  level floor_y=%.2f" % [start_y, floor_y])

	for i in 120:  # 2s @ 60fps -- just confirm it holds, not a live rise
		await process_frame

	print("final Y=%.2f  (level floor_y=%.2f)" % [piposh.global_position.y, floor_y])
	# The old bug spawned him ~120 units below floor_y (Godot Y=-39 vs
	# floor_y=83); the fix should land him within a sane band of it.
	var ok := absf(start_y - floor_y) < 80.0
	print("OK" if ok else "FAIL: Piposh spawned far from this level's floor_y")
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
