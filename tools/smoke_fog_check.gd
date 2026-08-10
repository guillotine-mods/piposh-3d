extends SceneTree
## Reported live (2026-08-10): "when Piposh falls there's fog... that
## don't exist in the current graphics." `camera.fog = N;` (11 corpus
## levels) was entirely unbridged -- `_set_camera_field()` had no "fog"
## case at all, silently no-op. Fixed by storing it as camera meta and
## polling it live in level_runner.gd's `_apply_wdl_fog()`, applying real
## Environment depth fog.
##
## Verifies Plane3 (`main()`: `fog_color=1; camera.fog=10;`) ends up with
## real fog enabled on its own WorldEnvironment.
##
## Run: godot --headless --path . -s res://tools/smoke_fog_check.gd

const LEVEL := "Plane3"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)
	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	for i in 15:
		await process_frame

	var we := runner.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we == null or we.environment == null:
		print("FAIL: no WorldEnvironment")
		quit(1)
		return

	var env := we.environment
	print("fog_enabled=%s fog_depth_end=%s fog_light_color=%s" % [env.fog_enabled, env.fog_depth_end, env.fog_light_color])

	# Plane3's own main() sets fog_color=1; -- per the "VECTOR=SCALAR sets
	# only .x" idiom this session established, that's (1,0,0) in Acknex's
	# roughly-0-255 color scale, i.e. very close to black.
	var color_ok: bool = env.fog_light_color.r < 0.05 and env.fog_light_color.g < 0.01 and env.fog_light_color.b < 0.01
	var ok: bool = env.fog_enabled and env.fog_depth_end > 0.0 and color_ok
	print("OK" if ok else "FAIL")
	quit(0 if ok else 1)
