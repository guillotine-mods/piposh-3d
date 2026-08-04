extends SceneTree
## GB-5 continued: "after dying and retrying, the game doesn't let you die
## again even though you got fully hit." `Death` only ever resets to 0 once,
## at action CamTarget's initial coroutine start -- never again -- so
## Restart()'s own `if (Death==0)` guard permanently blocked any death
## after the first. Fixed by implementing `level_load()` (called by every
## level's own main(), including Range's retry path `fRIP1 { HideRIP();
## main(); }`) to reset `Death` specifically.
##
## Take two, narrower than the original fix: resetting ALL declared
## globals (mirroring setup()'s own init loop) was confirmed live too
## broad -- `var MoviePlaying = 1;` is Range's own declared default, only
## ever set to 0 once the intro dialogue finishes, so a blanket reset
## re-triggered the WHOLE intro dialogue on every retry, rendered on top
## of the still-running shooting-gallery view underneath. This test now
## also checks MoviePlaying stays untouched by the reset.
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

	# Match a real playthrough: intro dialogue already finished, so
	# MoviePlaying is 0 (not its declared default of 1) by the time the
	# player is actually shooting and can die.
	interp.call("_set_var", "MoviePlaying", 0.0, null)

	# First death.
	interp.call("_set_var", "Health", 0.0, null)
	for i in 15:
		await process_frame
	print("first death: Death=%s frozen=%s" % [interp.call("_get_var", "Death", null), interp.get("_frozen")])

	# Simulate clicking "retry" for real (fRIP1: HideRIP(); main();).
	interp.call("invoke_event", null, "fRIP1")
	for i in 30:
		await process_frame
	print("after retry: Death=%s Health=%s Terrorists=%s Civilians=%s frozen=%s MoviePlaying=%s (expect 0, NOT its declared default of 1 -- see GB-5 take-two)" % [
		interp.call("_get_var", "Death", null),
		interp.call("_get_var", "Health", null),
		interp.call("_get_var", "Terrorists", null),
		interp.call("_get_var", "Civilians", null),
		interp.get("_frozen"),
		interp.call("_get_var", "MoviePlaying", null),
	])

	# Second death -- should show RIP again now.
	interp.call("_set_var", "Health", 0.0, null)
	for i in 15:
		await process_frame
	print("second death: Death=%s frozen=%s" % [interp.call("_get_var", "Death", null), interp.get("_frozen")])

	var panel_nodes: Dictionary = interp.get("_panel_nodes")
	var prip = panel_nodes.get("prip")
	print("pRIP visible on second death=%s" % (prip.visible if prip else "MISSING"))

	var movie_playing_after_retry: float = interp.call("_get_var", "MoviePlaying", null)
	var ok: bool = (
		interp.call("_get_var", "Death", null) == 1.0
		and prip != null and prip.visible
		and movie_playing_after_retry == 0.0
	)
	print("OK" if ok else "FAIL: second death didn't show RIP again, or MoviePlaying got reset")
	quit(0 if ok else 1)
