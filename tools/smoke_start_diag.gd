extends SceneTree
## Diagnostic (not a pass/fail regression test) for the "camera is still not
## exactly right" follow-up (2026-07-30): Start.wmb has TWO `LookAtMe`
## entities, one meant to drive Scene 0/2 (flag1==off, walk toward Yachdal)
## and one meant to drive Scene 1/3/5 (flag1==on, fixed pan=270 shot) --
## disambiguated by a WED-authored `flag1` this port can't read a verified
## bit for, now seeded via an inferred pan==270 heuristic (see
## WdlInterpreter._seed_look_at_me_flag1()). Traces BOTH entities plus the
## real rendered camera over enough real time to see the Scene 0->1
## handoff, so the fix can be confirmed by execution, not just code reading.
##
## Run: godot --headless --path . -s res://tools/smoke_start_diag.gd

const LEVEL := "Start"
const FRAMES := 1500  # 25s @ 60fps -- covers the Scene 0->1 handoff and beyond


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

	var look_at_mes := _find_entities_by_action(runner, "LookAtMe")
	print("LookAtMe entities found: %d" % look_at_mes.size())
	for n in look_at_mes:
		print(
			"  %s authored_pan=%s flag1=%s"
			% [n.name, n.get_meta("pan", 0.0), n.get_meta("wdl_custom_flag1", "<unset>")]
		)

	var last_scene: Variant = null
	for i in FRAMES:
		await process_frame
		var scene_v: Variant = _read_global(interp, "scene")
		if i % 30 != 0 and scene_v == last_scene:
			continue
		last_scene = scene_v
		var cam_now: Camera3D = root.get_camera_3d()
		var parts: Array[String] = []
		for n in look_at_mes:
			parts.append("%s@%s" % [n.name.right(6), n.global_position])
		print(
			"frame=%4d scene=%s | %s | cam_pos=%s pan=%s tilt=%s"
			% [
				i, scene_v, ", ".join(parts),
				cam_now.global_position if cam_now else Vector3.INF,
				cam_now.get_meta("pan", "?") if cam_now else "?",
				cam_now.get_meta("tilt", "?") if cam_now else "?",
			]
		)

	print("\nDone (diagnostic, not pass/fail).")
	quit(0)


func _find_entities_by_action(runner: Node, action_name: String) -> Array[Node3D]:
	var out: Array[Node3D] = []
	var loader: Node = runner.get("loader")
	if loader == null:
		return out
	var entities := loader.get_node_or_null("Entities")
	if entities == null:
		return out
	for n in entities.get_children():
		if n is Node3D and str(n.get_meta("action", "")) == action_name:
			out.append(n)
	return out


func _read_global(interp: Node, name: String) -> Variant:
	var globals: Dictionary = interp.get("_globals")
	var lower: Dictionary = interp.get("_globals_lower")
	var canonical := name
	if lower.has(name):
		canonical = str(lower[name])
	if not globals.has(canonical):
		return null
	return globals[canonical].get("value")
