extends SceneTree
## "without clicking all the victims get 'hit' when they go up." Lets
## Range run for real (real coroutines, real random pop-up timing, no
## forced state) for many frames WITHOUT ever firing a shot, and
## confirms Terrorists/Civilians never drop -- targets popping up and
## down on their own must never register as a scored "hit" by
## themselves. Health IS expected to drop on its own -- action
## Terrorist's own `if (my.Delay < 0) { ...; Health = Health - DMG; }`
## ("terrorist shooting") is a real, intentional mechanic in the
## original script: a terrorist left un-shot for too long shoots back.
## Not what this test is checking.
##
## Run: godot --headless --path . -s res://tools/smoke_range_no_self_trigger_check.gd

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
	for i in 10:
		await process_frame

	var health_before: float = interp.call("_get_var", "Health", null)
	var terr_before: float = interp.call("_get_var", "Terrorists", null)
	var civ_before: float = interp.call("_get_var", "Civilians", null)
	print("before: Health=%s Terrorists=%s Civilians=%s" % [health_before, terr_before, civ_before])

	for i in 300:
		await process_frame

	var health_after: float = interp.call("_get_var", "Health", null)
	var terr_after: float = interp.call("_get_var", "Terrorists", null)
	var civ_after: float = interp.call("_get_var", "Civilians", null)
	print("after 300 frames (no shots fired): Health=%s Terrorists=%s Civilians=%s" % [
		health_after, terr_after, civ_after,
	])

	var ok: bool = (
		is_equal_approx(terr_after, terr_before)
		and is_equal_approx(civ_after, civ_before)
	)
	print("OK" if ok else "FAIL: a target registered as a scored hit without any shot being fired")
	quit(0 if ok else 1)
