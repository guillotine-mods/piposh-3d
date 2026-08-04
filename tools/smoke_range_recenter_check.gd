extends SceneTree
## QOL: Space recenters the aim (and clears any in-flight mouse delta) on
## scripted-camera-aiming levels, without needing to die and retry first.
##
## Run: godot --headless --path . -s res://tools/smoke_range_recenter_check.gd

const LEVEL := "Range"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)

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
	for i in 10:
		await process_frame

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var camtarget: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "CamTarget":
			camtarget = n
			break
	if camtarget == null:
		print("FAIL: no CamTarget entity")
		quit(1)
		return

	var spawn_pan: float = float(camtarget.get_meta("wdl_spawn_pan", 0.0))
	var spawn_tilt: float = float(camtarget.get_meta("wdl_spawn_tilt", 0.0))

	# Aim away from spawn, as if mid-game (no death involved).
	interp.call("_set_field", {"t": "id", "name": "my"}, "pan", spawn_pan + 60.0, camtarget)
	interp.call("_set_field", {"t": "id", "name": "my"}, "tilt", -10.0, camtarget)
	for i in 3:
		await process_frame

	var pan_before: float = float(camtarget.get_meta("pan", -9999.0))
	print("pan before recenter=%.3f (expect spawn+60=%.3f)" % [pan_before, spawn_pan + 60.0])

	# Space -> level_runner._try_recenter_aim() -> interp.recenter_aim().
	var key := InputEventKey.new()
	key.keycode = KEY_SPACE
	key.pressed = true
	runner.call("_unhandled_input", key)
	for i in 3:
		await process_frame

	var pan_after: float = float(camtarget.get_meta("pan", -9999.0))
	var tilt_after: float = float(camtarget.get_meta("tilt", -9999.0))
	print("after Space: pan=%.3f tilt=%.3f (expect spawn pan=%.3f tilt=%.3f)" % [
		pan_after, tilt_after, spawn_pan, spawn_tilt,
	])

	var ok: bool = is_equal_approx(pan_after, spawn_pan) and is_equal_approx(tilt_after, spawn_tilt)
	print("OK" if ok else "FAIL: Space didn't recenter aim to spawn pose")
	quit(0 if ok else 1)
