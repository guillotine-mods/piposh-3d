extends SceneTree
## Diagnostic for "in ami studio the camera doesn't jump well when the Shik
## talk happens": Studio.wdl's `TheCam`/`TheCam2` actions already implement
## a real camera cut keyed on `Talking` (TheCam when Talking==1, TheCam2
## when Talking==2 or 0) -- no special director logic should be needed.
## Fast-forwards past the boot sequence directly (real boot takes ~20s+ of
## real audio), opens the dialogue panel, clicks option 1, and traces
## Talking + the actually-rendered camera position/orientation to see
## whether the TheCam<->TheCam2 cut really happens.
##
## Run: godot --headless --path . -s res://tools/smoke_studio_camswitch.gd

const LEVEL := "Studio"


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

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null
	if interp == null:
		print("FAIL: %s did not start the interpreter" % LEVEL)
		quit(1)
		return
	var hud: Node = runner.get("_game_hud")

	# Fast-forward: skip the real ~16s boot song/lines by directly forcing
	# Scene=3 and calling SetVoice(), matching what Naknik's own loop would
	# eventually do on its own -- same technique as smoke_dialog_choice.gd.
	interp.call("_set_var", "Scene", 3.0, null)
	interp.call("_call", "SetVoice", [], null)
	await process_frame
	await process_frame

	print("DialogIndex=%s is_dialog_open=%s" % [_read_global(interp, "DialogIndex"), hud.call("is_dialog_open")])

	for i in 5:
		await process_frame

	var the_cam := _find_entity_by_action(runner, "TheCam")
	var the_cam2 := _find_entity_by_action(runner, "TheCam2")
	print("TheCam found=%s pos=%s" % [the_cam != null, the_cam.global_position if the_cam else null])
	print("TheCam2 found=%s pos=%s" % [the_cam2 != null, the_cam2.global_position if the_cam2 else null])

	print("\n-- Clicking dialogue option 1 (should set Talking=1, cut to TheCam) --")
	hud.dialog_choice.emit(1)
	for i in 10:
		await process_frame
		var talking: Variant = _read_global(interp, "talking")
		var cam := root.get_camera_3d()
		print(
			"frame=%d talking=%s active_cam_pos=%s"
			% [i, talking, cam.global_position if cam else null]
		)

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


func _read_global(interp: Node, name: String) -> Variant:
	var globals: Dictionary = interp.get("_globals")
	var lower: Dictionary = interp.get("_globals_lower")
	var canonical := name
	if lower.has(name):
		canonical = str(lower[name])
	if not globals.has(canonical):
		return null
	return globals[canonical].get("value")
