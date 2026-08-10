extends SceneTree
## GB-7/GB-8: direct, empirical aim-accuracy check. Mathematically
## computes the pan/tilt needed to point the camera EXACTLY at a known
## Terrorist entity's own position (same atan2-based math the camera's
## own _gs_view_forward() convention uses), forces CamTarget's own
## entity to that pan/tilt, fires, and confirms the shot registers as a
## real hit (Terrorists count decrements). Firing is now an instant
## raycast hitscan (see WdlInterpreter._do_spark_hitscan()), not a
## traveling bullet, so this checks the outcome directly rather than
## tracking a bullet's own position over time.
##
## Run: godot --headless --path . -s res://tools/smoke_range_aim_check.gd

const LEVEL := "Range"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	for i in 5:
		await process_frame

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null
	if interp == null:
		print("FAIL: no interpreter")
		quit(1)
		return

	interp.call("_set_var", "MoviePlaying", 0.0, null)
	interp.call("_call", "ShowPanel", [], null)
	for i in 5:
		await process_frame

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var camtarget: Node3D = null
	var terrorist: Node3D = null
	for n in entities.get_children():
		var action := str(n.get_meta("action", ""))
		if action == "CamTarget":
			camtarget = n
		elif action == "Terrorist" and terrorist == null:
			terrorist = n
	if camtarget == null or terrorist == null:
		print("FAIL: missing CamTarget or Terrorist entity")
		quit(1)
		return

	# Force the target into a real "popped up" hittable state at its
	# OWN authored position (no position change -- we aim the camera AT
	# it, not the other way around).
	var type_terrorist = interp.call("_get_var", "typeTerrorist", null)
	interp.call("_set_field", {"t": "id", "name": "my"}, "Type", type_terrorist, terrorist)
	interp.call("_set_field", {"t": "id", "name": "my"}, "Pop", 1.0, terrorist)

	var cam_pos: Vector3 = camtarget.global_position
	var target_pos: Vector3 = terrorist.global_position
	var to_target := target_pos - cam_pos
	print("cam_pos=%s target_pos=%s distance=%.2f" % [cam_pos, target_pos, to_target.length()])

	# Same convention as _gs_view_forward()/_apply_acknex_view(): pan
	# rotates in the XZ-ish (GS XY) plane, tilt is elevation. Solve for
	# the pan/tilt that points EXACTLY at the target using the SAME
	# forward-vector formula _gs_view_forward() itself uses, inverted.
	# _gs_view_forward final Godot vector = (cos(p)*cos(t), sin(t), -sin(p)*cos(t))
	var d := to_target.normalized()
	var tilt_deg := rad_to_deg(asin(clampf(d.y, -1.0, 1.0)))
	var pan_deg := rad_to_deg(atan2(-d.z, d.x))
	print("computed pan=%.3f tilt=%.3f (to aim exactly at target)" % [pan_deg, tilt_deg])

	interp.call("_set_field", {"t": "id", "name": "my"}, "pan", pan_deg, camtarget)
	interp.call("_set_field", {"t": "id", "name": "my"}, "tilt", clampf(tilt_deg, -15.0, 45.0), camtarget)
	for i in 2:
		await process_frame

	var actual_pan = interp.call("_get_field", {"t": "id", "name": "my"}, "pan", camtarget)
	var actual_tilt = interp.call("_get_field", {"t": "id", "name": "my"}, "tilt", camtarget)
	print("actual pan/tilt right before firing: pan=%s tilt=%s (compare to computed pan=%.3f tilt=%.3f -- CamTarget's own [-15,45] tilt clamp may have overwritten it)" % [actual_pan, actual_tilt, pan_deg, tilt_deg])

	var terr_before: float = interp.call("_get_var", "Terrorists", null)

	# Simulate a real click, same proven mechanism as smoke_range_shoot.gd
	# (on_mouse_left = Fire; -> action Fire -> CreateSpark() -> hitscan).
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.parse_input_event(click)
	for i in 3:
		await process_frame

	var terr_after: float = interp.call("_get_var", "Terrorists", null)
	print("Terrorists before=%s after=%s (15=no hit registered, 14=direct hit)" % [terr_before, terr_after])
	var ok: bool = terr_after < terr_before
	print("OK" if ok else "FAIL: shot didn't register as a hit")
	quit(0 if ok else 1)
