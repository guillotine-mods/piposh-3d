extends SceneTree
## Regression test for the 2026-07-30 "stuck on the first frame" report
## (Start/Shiks/Town/Plane all affected): `scan_path()` being an unresolved
## builtin (0.0 fallback) made every level using the standard
## `result = scan_path(...); if (result==0) { my._MOVEMODE = 0; }` idiom
## permanently zero `_MOVEMODE`, which also gates unrelated dialogue-scene
## advancement coupled into the same `while (my._MOVEMODE > 0) { ... }` loop
## in the original scripts -- not just walking. Fixed by making `scan_path`
## return a truthy stub. This checks Plane's `Scene`/`Talking` globals
## actually advance past their initial boot values within a few real
## seconds, proving the gate is open, not just that dispatch succeeded.
##
## Run: godot --headless --path . -s res://tools/smoke_scan_path_gate.gd

const LEVEL := "Plane"
const FRAMES := 600  # 10s @ 60fps -- generous; SetVoice's first line is short


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

	var scene0: Variant = _read_global(interp, "scene")
	var talking0: Variant = _read_global(interp, "talking")
	print("Initial: scene=%s talking=%s" % [scene0, talking0])

	var advanced := false
	for i in FRAMES:
		await process_frame
		var scene_now: Variant = _read_global(interp, "scene")
		var talking_now: Variant = _read_global(interp, "talking")
		if float(scene_now) != float(scene0) or (
			float(talking_now) != float(talking0) and float(talking_now) != 0.0
		):
			print(
				"frame=%d: scene=%s talking=%s (changed from initial)"
				% [i, scene_now, talking_now]
			)
			advanced = true
			break

	if not advanced:
		print(
			(
				"\nFAIL: scene/talking never changed from initial values within %d frames -- "
				+ "the _MOVEMODE gate (or something else) is still stuck."
			) % FRAMES
		)
		quit(1)
		return

	print(
		(
			"\nOK: %s's Scene/Talking state advanced past its initial boot values -- "
			+ "the dialogue-progression loop is running, not gated shut."
		) % LEVEL
	)
	quit(0)


func _read_global(interp: Node, name: String) -> Variant:
	var globals: Dictionary = interp.get("_globals")
	var lower: Dictionary = interp.get("_globals_lower")
	var canonical := name
	if lower.has(name):
		canonical = str(lower[name])
	if not globals.has(canonical):
		return null
	return globals[canonical].get("value")
