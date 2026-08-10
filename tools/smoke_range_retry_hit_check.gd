extends SceneTree
## GB-5 continued: "when shooting them there's no hit so we can't beat
## the stage" -- reported alongside "dying is starting the dialogue
## again". Both trace to the SAME bug: action Terrorist's own coroutine
## has `while (MoviePlaying == 1) { wait(1); }` before its "pop up" loop,
## same as action CamTarget. The original (too-broad) level_load() fix
## reset MoviePlaying back to its declared default (1) on every retry,
## re-blocking every Terrorist entity on that gate forever (MoviePlaying
## only returns to 0 once the re-triggered intro dialogue completes,
## which the player never sees happen since it's rendered on top of the
## already-running shooting view). Confirms the narrowed fix (Death only)
## leaves Terrorists able to pop up and register a hit after a real retry.
##
## Run: godot --headless --path . -s res://tools/smoke_range_retry_hit_check.gd

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

	# First death, then retry -- matching the exact user-reported sequence.
	interp.call("_set_var", "Health", 0.0, null)
	for i in 15:
		await process_frame
	interp.call("invoke_event", null, "fRIP1")
	for i in 30:
		await process_frame

	print("after retry: MoviePlaying=%s Death=%s frozen=%s" % [
		interp.call("_get_var", "MoviePlaying", null),
		interp.call("_get_var", "Death", null),
		interp.get("_frozen"),
	])

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var terrorist: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "Terrorist":
			terrorist = n
			break
	if terrorist == null:
		print("FAIL: no Terrorist entity found")
		quit(1)
		return

	var terr_before: float = interp.call("_get_var", "Terrorists", null)
	var type_terrorist = interp.call("_get_var", "typeTerrorist", null)
	interp.call("_set_field", {"t": "id", "name": "my"}, "Type", type_terrorist, terrorist)
	interp.call("_set_field", {"t": "id", "name": "my"}, "Pop", 1.0, terrorist)
	interp.call("invoke_event", terrorist, "TargetHit")
	for i in 10:
		await process_frame
	var terr_after: float = interp.call("_get_var", "Terrorists", null)
	print("Terrorists before=%s after=%s (expect one less -- a hit registered after retry)" % [terr_before, terr_after])

	var ok := terr_after < terr_before
	print("OK" if ok else "FAIL: hit did not register after retry")
	quit(0 if ok else 1)
