extends SceneTree
## GB-5 continued: "after dying and retrying, the game doesn't let you die
## again even though you got fully hit." `Death` only ever resets to 0 once,
## at action CamTarget's initial coroutine start -- never again -- so
## Restart()'s own `if (Death==0)` guard permanently blocked any death
## after the first. Fixed by implementing `level_load()` (called by every
## level's own main(), including Range's retry path `fRIP1 { HideRIP();
## main(); }`) to reset all globals to their declared initial values,
## mirroring setup()'s own one-time init loop.
##
## Run: godot --headless --path . -s res://tools/smoke_range_retry_check.gd

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
	for i in 5:
		await process_frame

	# First death.
	interp.call("_set_var", "Health", 0.0, null)
	for i in 15:
		await process_frame
	print("first death: Death=%s frozen=%s" % [interp.call("_get_var", "Death", null), interp.get("_frozen")])

	# Simulate clicking "retry" for real (fRIP1: HideRIP(); main();).
	interp.call("invoke_event", null, "fRIP1")
	for i in 30:
		await process_frame
	print("after retry: Death=%s Health=%s Terrorists=%s Civilians=%s frozen=%s" % [
		interp.call("_get_var", "Death", null),
		interp.call("_get_var", "Health", null),
		interp.call("_get_var", "Terrorists", null),
		interp.call("_get_var", "Civilians", null),
		interp.get("_frozen"),
	])

	# Second death -- should show RIP again now.
	interp.call("_set_var", "Health", 0.0, null)
	for i in 15:
		await process_frame
	print("second death: Death=%s frozen=%s" % [interp.call("_get_var", "Death", null), interp.get("_frozen")])

	var panel_nodes: Dictionary = interp.get("_panel_nodes")
	var prip = panel_nodes.get("prip")
	print("pRIP visible on second death=%s" % (prip.visible if prip else "MISSING"))

	var ok: bool = interp.call("_get_var", "Death", null) == 1.0 and prip != null and prip.visible
	print("OK" if ok else "FAIL: second death did not show RIP again")
	quit(0 if ok else 1)
