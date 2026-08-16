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
	root.get_node("Piposh3DState").set("current_level", LEVEL)
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
	print("fog_enabled=%s fog_depth_end=%s fog_light_color=%s fog_sky_affect=%s" % [env.fog_enabled, env.fog_depth_end, env.fog_light_color, env.fog_sky_affect])

	# Plane3's own main() sets fog_color=1; -- per the "VECTOR=SCALAR sets
	# only .x" idiom this session established, that's (1,0,0) in Acknex's
	# roughly-0-255 color scale, i.e. very close to black (0.0039 raw).
	# Reported live again (2026-08-16): "the fog/stage of plane3 is still
	# really really dark... it goes for all implementations of light and
	# fog in the game" -- confirmed that literal near-black value really
	# was what the script data said, but rendering it raw reads as near-
	# total information loss, not a moody haze. `_apply_wdl_fog()` now
	# floors each channel at 0.08 so a "near black" script value still
	# shows a dark, readable haze. Updated this assertion to match that
	# deliberate floor instead of the old raw near-zero expectation.
	var color_ok: bool = env.fog_light_color.r >= 0.075 and env.fog_light_color.r <= 0.1 and env.fog_light_color.g >= 0.075 and env.fog_light_color.b >= 0.075
	# Classic DirectX fixed-function fog (what this game's real A5 engine
	# used) never fogs the skybox -- with a near-black fog color, leaving
	# Godot's default fog_sky_affect=1.0 would wash the whole sky/background
	# toward solid black regardless of fog_depth_end, dominating an aerial
	# shot like Plane3's own fall sequence. Must be 0 so only real world
	# geometry gets fogged, matching the original engine's own behavior.
	var sky_ok: bool = env.fog_sky_affect == 0.0
	var ok: bool = env.fog_enabled and env.fog_depth_end > 0.0 and color_ok and sky_ok
	print("OK" if ok else "FAIL")
	quit(0 if ok else 1)
