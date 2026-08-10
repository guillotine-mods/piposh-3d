extends SceneTree
## Follow-up diagnostic for "character models not facing correctly" and
## "scene doesn't move to the next one, stays in a loop" (2026-07-30).
## Traces Scene over a MUCH longer window (90s) to find the actual stuck
## point (if any), and prints Crowd/Yachdal/Grandma's authored vs.
## currently-live `pan` meta to check whether anything is rewriting their
## facing at runtime (none of their WDL actions should).
##
## Run: godot --headless --path . -s res://tools/smoke_start_diag2.gd

const LEVEL := "Start"
const FRAMES := 4200  # 70s @ 60fps -- covers the full Scene 0->6 sequence with margin


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

	var yachdal := _find_entity_by_action(runner, "DefineYachdel")
	var crowds := _find_entities_by_action(runner, "Crowd")
	var grandma := _find_entity_by_action(runner, "Grandma")
	print("Yachdal found=%s pan=%s" % [yachdal != null, yachdal.get_meta("pan", "?") if yachdal else "?"])
	print("Crowd count=%d" % crowds.size())
	for c in crowds:
		print("  %s pan=%s invisible=%s visible=%s" % [c.name, c.get_meta("pan", "?"), c.get_meta("invisible", "?"), c.visible])
	print("Grandma found=%s pan=%s" % [grandma != null, grandma.get_meta("pan", "?") if grandma else "?"])

	var last_scene: Variant = null
	var stuck_since := 0
	var stuck_frames := 0
	for i in FRAMES:
		await process_frame
		var scene_v: Variant = _read_global(interp, "scene")
		var delay_v: Variant = _read_global(interp, "delay")
		if scene_v != last_scene:
			print(
				"frame=%4d (%.1fs) scene changed: %s -> %s (delay=%s)"
				% [i, i / 60.0, last_scene, scene_v, delay_v]
			)
			last_scene = scene_v
			stuck_since = i
		stuck_frames = i - stuck_since
		if i % 300 == 0:
			print(
				"  ...heartbeat frame=%4d (%.1fs) scene=%s delay=%s stuck_for=%.1fs"
				% [i, i / 60.0, scene_v, delay_v, stuck_frames / 60.0]
			)

	print("\nFinal: scene=%s after %.1fs total." % [last_scene, FRAMES / 60.0])
	print("Yachdal live pan=%s" % (yachdal.get_meta("pan", "?") if yachdal else "?"))
	for c in crowds:
		print("Crowd %s live pan=%s" % [c.name, c.get_meta("pan", "?")])
	print("\nDone (diagnostic, not pass/fail).")
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
