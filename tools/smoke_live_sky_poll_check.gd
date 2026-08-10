extends SceneTree
## Reported live (2026-08-10): "vastly different background and sky for
## scenes and images that are not seen in the back that should be." Traced
## to `level_runner.gd` only ever live-polling `scene_map`, and only for a
## short (300-frame) window right after level load -- `sky_map`/
## `cloud_map` were NEVER polled at all, at any point, so real WDL effects
## that change them mid-level (Ziggy's own per-wave `SetWeather()`,
## Desert's Mansion-stage storm, Intro3's storm, Mount's snow -- all
## genuine, ongoing `WDL/Weather.wdl`-driven effects the interpreter
## computes correctly) never reached the actual rendered sky. Fixed by
## generalizing the scene_map poll into `_live_bmap_file(var_name)`, used
## continuously (for the whole level, not just a post-load window) for
## all three of scene_map/sky_map/cloud_map.
##
## Verifies the live-poll path end to end: forces `sky_map`/`cloud_map` to
## a different real bmap symbol partway through a level's own runtime
## (simulating what `WDL/Weather.wdl`'s own functions do) and confirms
## `LevelRunner` picks up the change on a later frame, not just at load.
##
## Run: godot --headless --path . -s res://tools/smoke_live_sky_poll_check.gd

const LEVEL := "Smash"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)
	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	for i in 10:
		await process_frame

	var interp: Node = runner.get("_director").get("_wdl_interp")
	if interp == null:
		print("FAIL: no interpreter")
		quit(1)
		return

	var before: String = runner.get("_last_applied_sky_map")
	print("before=%s" % before)

	# Simulate a mid-level weather change (what storm()/lightning()/
	# SetWeather() do): reassign sky_map/cloud_map to different real bmap
	# symbols, well after level load has already settled.
	interp.call("_set_var", "sky_map", "bmapback2", null)
	interp.call("_set_var", "cloud_map", "bmapback3", null)

	for i in 5:
		await process_frame

	var after: String = runner.get("_last_applied_sky_map")
	var after_cloud: String = runner.get("_last_applied_cloud_map")
	print("after=%s after_cloud=%s" % [after, after_cloud])

	var ok: bool = after == "Horizon2.pcx" and after_cloud == "Horizon3.pcx" and after != before
	print("OK" if ok else "FAIL")
	quit(0 if ok else 1)
