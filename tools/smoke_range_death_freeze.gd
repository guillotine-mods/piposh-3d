extends SceneTree
## GB-5 verification: once the pRIP death screen shows, gameplay
## coroutines should genuinely stop progressing (targets stop popping
## up/going down, updatepanel() stops running) -- only resuming once
## pRIP is hidden again (matching HideRIP()'s own `pRIP.visible = off;`).
## Drives a real fRIP1 retry (not a direct pRIP.visible poke) so the
## camera-pose reset added for GB-7 continued (2026-08-04) -- which fires
## from the same "visible" write path -- gets exercised too.
##
## Run: godot --headless --path . -s res://tools/smoke_range_death_freeze.gd

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
	var terrorist: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "Terrorist":
			terrorist = n
			break

	# Force one target into a live "going up" animation so we have a real,
	# actively-changing value (my.z) to check against.
	var type_terrorist = interp.call("_get_var", "typeTerrorist", null)
	interp.call("_set_field", {"t": "id", "name": "my"}, "Type", type_terrorist, terrorist)
	interp.call("_set_field", {"t": "id", "name": "my"}, "GoingUp", 1.0, terrorist)
	for i in 5:
		await process_frame
	var z_before_death: float = interp.call("_get_field", {"t": "id", "name": "my"}, "z", terrorist)

	print("frozen before death=%s" % interp.get("_frozen"))

	interp.call("_set_var", "Health", 0.0, null)
	for i in 20:
		await process_frame

	print("frozen after death=%s" % interp.get("_frozen"))
	var z_at_death: float = interp.call("_get_field", {"t": "id", "name": "my"}, "z", terrorist)

	# Let many more frames pass -- if truly frozen, z should not move at all.
	for i in 60:
		await process_frame
	var z_after_wait: float = interp.call("_get_field", {"t": "id", "name": "my"}, "z", terrorist)
	print("z: before_death=%.3f at_death=%.3f after_60_more_frames=%.3f" % [z_before_death, z_at_death, z_after_wait])

	# Simulate clicking "retry" for real (fRIP1: HideRIP(); main();) --
	# should unfreeze immediately and let things move again.
	interp.call("_set_var", "MoviePlaying", 0.0, null)
	interp.call("invoke_event", null, "fRIP1")
	for i in 30:
		await process_frame
	print("frozen after unfreeze=%s" % interp.get("_frozen"))
	var z_after_unfreeze: float = interp.call("_get_field", {"t": "id", "name": "my"}, "z", terrorist)
	print("z after unfreeze + 10 frames=%.3f" % z_after_unfreeze)

	var froze_correctly: bool = is_equal_approx(z_at_death, z_after_wait)
	var resumed_correctly: bool = not is_equal_approx(z_after_wait, z_after_unfreeze)
	print("froze_correctly=%s resumed_correctly=%s" % [froze_correctly, resumed_correctly])
	var ok := froze_correctly and resumed_correctly
	print("OK" if ok else "FAIL")
	quit(0 if ok else 1)
