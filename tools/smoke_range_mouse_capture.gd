extends SceneTree
## GB-7 verification: "shots don't land where crosshair points." Range is
## a scripted-camera level (action CamTarget drives camera.pan/tilt via
## raw mickey.x/y delta), which never went through _enable_first_person()
## -- so Input.mouse_mode never got captured, leaving the OS cursor
## visible and free-roaming while the actual aim direction is completely
## independent of the cursor's own screen position.
##
## `Input.mouse_mode` assignment is a confirmed no-op in headless mode
## (no real window/cursor to capture -- verified separately), so this
## only checks the detection logic itself: uses_mickey_aiming() true for
## Range, false for a level that doesn't use it (negative control, so
## this isn't just trivially always-true).
##
## Run: godot --headless --path . -s res://tools/smoke_range_mouse_capture.gd

func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var range_ok := await _check("Range", true)
	var control_ok := await _check("Start", false)
	var ok := range_ok and control_ok
	print("OK" if ok else "FAIL")
	quit(0 if ok else 1)


func _check(level: String, expect: bool) -> bool:
	root.get_node("GameState").set("current_level", level)
	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	for i in 8:
		await process_frame

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null
	if interp == null:
		print("%s: FAIL no interpreter" % level)
		runner.queue_free()
		return false

	var got: bool = interp.call("uses_mickey_aiming")
	print("%s: uses_mickey_aiming=%s (expect %s)" % [level, got, expect])
	runner.queue_free()
	await process_frame
	return got == expect
