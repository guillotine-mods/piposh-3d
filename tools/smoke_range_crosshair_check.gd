extends SceneTree
## GB-7 continued: `screen_size` was entirely unresolved (silently read
## back as (0,0)), so `WDL/weapons.wdl`'s real, portable `pan_cross_show()`
## (called by Range/Final/Shooter right where they switch into
## scripted-camera mouse-look aiming) positioned its `cross_pan` panel at
## (-7,-7) instead of screen-center -- clipped almost entirely off the
## top-left corner. Combined with the mouse-capture fix hiding the OS
## cursor, the player had no on-screen aim reference at all. Verifies
## `cross_pan` ends up visible and centered once `screen_size` resolves
## correctly.
##
## Run: godot --headless --path . -s res://tools/smoke_range_crosshair_check.gd

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

	var screen_size: Vector3 = interp.call("_vec_get", {"t": "id", "name": "screen_size"}, null)
	print("screen_size=%s (expect 640,480,0)" % screen_size)

	interp.call("_set_var", "MoviePlaying", 0.0, null)
	interp.call("_call", "ShowPanel", [], null)
	for i in 15:
		await process_frame

	var panel_nodes: Dictionary = interp.get("_panel_nodes")
	var cross: Control = panel_nodes.get("cross_pan", null)
	if cross == null:
		print("FAIL: cross_pan panel never built (weapons.wdl not merged, or pan_cross_show() never reached)")
		quit(1)
		return

	print("cross_pan visible=%s position=%s size=%s (design center=320,240)" % [
		cross.visible, cross.position, cross.size,
	])

	var near_center := (
		absf(cross.position.x + cross.size.x * 0.5 - 320.0) < 10.0
		and absf(cross.position.y + cross.size.y * 0.5 - 240.0) < 10.0
	)
	var ok: bool = cross.visible and near_center
	print("OK" if ok else "FAIL: cross_pan not shown or not centered")
	quit(0 if ok else 1)
