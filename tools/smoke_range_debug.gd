extends SceneTree
## Investigates the 2026-08-01 report: the Range level "stops"/errors
## right when it starts. Loads it for real and logs everything relevant
## (dispatch result, interpreter running state, errors, entity/action
## counts, camera state) over several seconds to see exactly where it
## breaks.
##
## Run: godot --headless --path . -s res://tools/smoke_range_debug.gd

const LEVEL := "Range"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	await process_frame
	await process_frame
	await process_frame

	var loader: Node = runner.get("loader")
	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null

	print("== Range level load report ==")
	print("loader last_level_data has 'script'=%s" % (loader.last_level_data.get("script", "?") if loader else "no loader"))
	print("interp=%s" % interp)
	if interp == null:
		print("FAIL: no interpreter -- level did not dispatch to the interpreter at all")
		quit(1)
		return

	print("interp._running=%s" % interp.get("_running"))
	var entities := loader.get_node_or_null("Entities")
	print("entity count=%d" % (entities.get_child_count() if entities else -1))

	for i in 900:  # 15s @ 60fps
		await process_frame
		if i % 60 == 0:
			print("t=%.1fs interp._running=%s impact_zones=%d" % [
				i / 60.0, interp.get("_running"), (interp.get("_impact_zones") as Array).size()
			])

	print("\nfinal interp._running=%s" % interp.get("_running"))
	quit(0)
