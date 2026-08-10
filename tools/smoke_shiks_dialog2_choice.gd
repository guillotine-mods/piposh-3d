extends SceneTree
## Follow-up to smoke_shiks_dialog_choice.gd: verifies the SAME
## Dialog.visible fix also unblocks DialogIndex==2 / DialogChoice==2, the
## "Piposh moving inside the house... camera moves through the window...
## another part of dialogue" sequence reported 2026-07-31 (CamShow 3->4->5
## in `action Piposh2`, ending in `Run ("Plane.exe")`).
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_dialog2_choice.gd

const LEVEL := "Shiks"
const FRAMES := 3600  # 60s @ 60fps -- several real voice lines back to back


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
	var hud: Node = runner.get("_game_hud")

	# Skip straight to the second choice prompt (DialogIndex=2), matching
	# what `action MyCamera` does once the fly-through sequence completes.
	interp.call("_set_var", "Scene", 2.0, null)
	interp.call("_set_var", "DialogIndex", 2.0, null)
	interp.call("_call", "ShowDialog", [], null)
	for i in 5:
		await process_frame

	print("Before click: DialogIndex=%s dialog_open=%s" % [
		_read_global(interp, "DialogIndex"), hud.call("is_dialog_open")
	])
	print("-- Clicking option 2 (the window/camera-away sequence, ends in Run(\"Plane.exe\")) --")
	hud.call("hide_dialog")
	hud.dialog_choice.emit(2)

	var router := root.get_node_or_null("LevelRouter")
	var last_talking: Variant = null
	var last_camshow: Variant = null
	var run_fired := false
	for i in FRAMES:
		await process_frame
		var talking: Variant = _read_global(interp, "talking")
		var camshow: Variant = _read_global(interp, "camshow")
		var running: bool = interp.get("_running")
		if talking != last_talking or camshow != last_camshow:
			print("frame=%4d (%.1fs) talking=%s->%s camshow=%s->%s running=%s" % [
				i, i / 60.0, last_talking, talking, last_camshow, camshow, running
			])
			last_talking = talking
			last_camshow = camshow
		if not running:
			print("frame=%d: interpreter _running=false (Run(\"Plane.exe\") fired)" % i)
			run_fired = true
			break

	print("\nrun_fired=%s final talking=%s camshow=%s" % [run_fired, last_talking, last_camshow])
	print("OK" if run_fired else "FAIL: never reached Run(\"Plane.exe\") -- window/camera sequence stalled")
	quit(0 if run_fired else 1)


func _read_global(interp: Node, name: String) -> Variant:
	var globals: Dictionary = interp.get("_globals")
	var lower: Dictionary = interp.get("_globals_lower")
	var canonical := name
	if lower.has(name):
		canonical = str(lower[name])
	if not globals.has(canonical):
		return null
	return globals[canonical].get("value")
