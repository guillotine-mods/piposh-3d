extends SceneTree
## Regression check for the 2026-08-01 report: "the last commit made all
## levels stuck now". Root cause: `WDL/IO.wdl`'s `function Initialize()`
## (called by virtually every level's main()) unconditionally tail-calls
## `StartSaveLoad()`, a genuine `function StartSaveLoad { while(1) {...
## wait(1);} }` background loop for a save/load menu this port doesn't
## implement. Once bare top-level function calls could really suspend
## (this session's async-dispatch fix), that forever loop permanently
## absorbed `Initialize()` -- and everything after it in `main()`
## (hiding the splash screen, playing the intro movies, `Start = 1;`) --
## for every level, since every level includes IO.wdl and calls
## `Initialize()` near the top. Fixed by bridging `startsaveload` to a
## no-op, same precedent as `perform_handle`. Confirms Start.wdl's own
## `main()` actually reaches `Start = 1;` within a couple of seconds
## instead of hanging forever.
##
## Run: godot --headless --path . -s res://tools/smoke_start_stuck.gd

const LEVEL := "Start"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)

	var interp: Node = null
	for i in 5:
		await process_frame
		var director: Node = runner.get("_director")
		if director:
			interp = director.get("_wdl_interp")
		if interp:
			break

	if interp == null:
		print("FAIL: no interpreter for %s" % LEVEL)
		quit(1)
		return

	var frames_to_start := -1
	for i in 300:  # 5s @ 60fps
		await process_frame
		var start_v = interp.call("_get_var", "Start", null)
		if float(start_v) == 1.0:
			frames_to_start = i
			break

	print("frames until Start=1 (main() past Initialize()/StartSaveLoad): %d" % frames_to_start)
	var ok := frames_to_start >= 0
	print("OK" if ok else "FAIL: main() never reached Start=1 -- Initialize()/StartSaveLoad still absorbing it")
	quit(0 if ok else 1)
