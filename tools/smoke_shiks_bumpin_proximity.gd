extends SceneTree
## Real end-to-end version of smoke_shiks_bumpin.gd: that test called
## `_on_impact_body_entered` directly, which only proved the event
## *dispatch* worked, not that real NPC movement (Piposh2, a plain Node3D
## moved via `actor_move()`, not a physics body) would ever actually
## trigger it -- confirmed live (2026-08-01) that it doesn't, since
## Area3D.body_entered only fires for real PhysicsBody3D nodes. This test
## moves Piposh2's actual global_position toward Bumpin's entity over
## several frames, the same way `actor_move()` would, and lets
## WdlInterpreter._process()'s own per-frame proximity check (not a test
## shortcut) do the triggering.
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_bumpin_proximity.gd

const LEVEL := "Shiks"


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

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null
	if interp == null:
		print("FAIL: %s did not start the interpreter" % LEVEL)
		quit(1)
		return

	var piposh2 := _find_entity_by_action(runner, "Piposh2")
	var bumpin := _find_entity_by_action(runner, "Bumpin")
	if piposh2 == null or bumpin == null:
		print("FAIL: piposh2=%s bumpin=%s" % [piposh2, bumpin])
		quit(1)
		return

	# Skip Scene==1's own walk-to-StandHerePoint phase -- action Piposh2's
	# own actor_move() calls would otherwise fight this test's manual
	# position writes every frame. Scene==2's own logic only moves Piposh2
	# when my.skill20==1 and only while a voice line plays, so it won't
	# compete here.
	interp.call("_set_var", "Scene", 2.0, null)
	interp.call("_set_var", "DialogIndex", -1.0, null)

	var zones: Array = interp.get("_impact_zones")
	print("impact zones registered: %d -> %s" % [
		zones.size(), zones.map(func(z): return "%s r=%s off=%s" % [z["node"].name, z["radius"], z["offset"]])
	])

	print("Piposh2 start pos=%s, Bumpin pos=%s, distance=%.1f" % [
		piposh2.global_position, bumpin.global_position,
		piposh2.global_position.distance_to(bumpin.global_position)
	])
	print("Piposh.skill2 before: %s" % _skill2(piposh2))

	# Walk Piposh2 toward Bumpin over real frames -- no test shortcut, this
	# is exactly what actor_move() does each tick (moves global_position a
	# small step toward a target).
	var target: Vector3 = bumpin.global_position
	var reached := false
	for i in 600:
		await process_frame
		var pos: Vector3 = piposh2.global_position
		var to_target := target - pos
		var dist := to_target.length()
		if dist > 2.0:
			piposh2.global_position = pos + to_target.normalized() * minf(4.0, dist)
		if float(_skill2(piposh2)) == 2.0:
			reached = true
			print("frame=%d: Piposh.skill2 became 2.0 (distance to Bumpin=%.1f)" % [i, dist])
			break

	print("Piposh2 final pos=%s (distance to Bumpin=%.1f)" % [
		piposh2.global_position, piposh2.global_position.distance_to(target)
	])
	print("Piposh.skill2 after: %s" % _skill2(piposh2))
	print("OK" if reached else "FAIL: walking into Bumpin's range never set Piposh.skill2 = 2")
	quit(0 if reached else 1)


func _skill2(node: Node3D) -> Variant:
	var arr: Array = node.get_meta("wdl_skills", [])
	if arr.size() < 2:
		return 0.0
	return arr[1]


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
