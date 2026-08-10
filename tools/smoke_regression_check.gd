extends SceneTree
## Investigates the 2026-08-01 report: "the last commit made all levels
## stuck now." Loads a level and watches _total_frames/real elapsed time
## over a longer window than smoke_dispatch.gd's quick pass, watching for
## busy-loop warnings (a bare-call-now-runs-forever regression from the
## async expr_stmt dispatch / action-as-function fallback added this
## session) and confirming the process itself stays responsive.
##
## Run: godot --headless --path . -s res://tools/smoke_regression_check.gd -- LEVEL

const DEFAULT_LEVEL := "Start"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var level := DEFAULT_LEVEL
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		level = args[0]
	root.get_node("Piposh3DState").set("current_level", level)
	print("Loading level: %s" % level)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	var t_start := Time.get_ticks_msec()
	root.add_child(runner)
	await process_frame
	await process_frame
	await process_frame
	print("Initial 3 frames took %dms" % (Time.get_ticks_msec() - t_start))

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null
	if interp == null:
		print("FAIL: no interpreter for %s" % level)
		quit(1)
		return

	for i in 600:  # 10s @ 60fps of real wall-clock, watching for a stall
		var frame_start := Time.get_ticks_msec()
		await process_frame
		var frame_ms := Time.get_ticks_msec() - frame_start
		if frame_ms > 500:
			print("SLOW FRAME at i=%d: %dms (real time between process_frame yields)" % [i, frame_ms])
		if i % 60 == 0:
			print("t=%.1fs total_frames=%s running=%s" % [
				i / 60.0, interp.get("_total_frames"), interp.get("_running")
			])

	print("Done. Final total_frames=%s running=%s" % [interp.get("_total_frames"), interp.get("_running")])
	print("OK")
	quit(0)
