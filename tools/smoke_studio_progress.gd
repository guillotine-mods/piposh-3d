extends SceneTree
## Regression check for the 2026-07-30 report ("Ami studio" vocals not
## played, camera stuck): Studio.wdl defines its own `function SetVoice`
## (dialogue/scene-boot sequencer), which was being force-routed to this
## interpreter's harmless audio-primitive no-op stub instead of resolving
## as a real user function -- see BRIDGE_OVER_SHARED_FUNCTIONS' "SetVoice"
## comment in wdl_interpreter.gd. Checks Scene/Talking actually advance past
## their initial boot values within a few real seconds.
##
## Run: godot --headless --path . -s res://tools/smoke_studio_progress.gd

const LEVEL := "Studio"
const FRAMES := 1500  # 25s @ 60fps -- Scene 1's SNG010.WAV song is ~15.7s long


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	await process_frame
	await process_frame
	await process_frame

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null
	if interp == null:
		print("FAIL: %s did not start the interpreter" % LEVEL)
		quit(1)
		return

	var scene0: Variant = _read_global(interp, "scene")
	var talking0: Variant = _read_global(interp, "talking")
	var audio := root.get_node("AudioChannels")
	print("Initial: scene=%s talking=%s voice_playing=%s voice_progress=%s" % [
		scene0, talking0, audio.call("is_voice_playing"), audio.call("get_voice_progress")
	])

	var advanced := false
	for i in FRAMES:
		await process_frame
		var scene_now: Variant = _read_global(interp, "scene")
		var talking_now: Variant = _read_global(interp, "talking")
		if i % 30 == 0:
			print(
				"frame=%d: scene=%s talking=%s voice_playing=%s voice_progress=%s"
				% [i, scene_now, talking_now, audio.call("is_voice_playing"), audio.call("get_voice_progress")]
			)
		if float(scene_now) != float(scene0) or (
			float(talking_now) != float(talking0) and float(talking_now) != 0.0
		):
			print("frame=%d: scene=%s talking=%s (changed from initial)" % [i, scene_now, talking_now])
			advanced = true
			break

	if not advanced:
		print("\nFAIL: scene/talking never changed within %d frames." % FRAMES)
		quit(1)
		return

	print("\nOK: Studio's Scene/Talking state advanced past its initial boot values.")
	quit(0)


func _read_global(interp: Node, name: String) -> Variant:
	var globals: Dictionary = interp.get("_globals")
	var lower: Dictionary = interp.get("_globals_lower")
	var canonical := name
	if lower.has(name):
		canonical = str(lower[name])
	if not globals.has(canonical):
		return null
	return globals[canonical].get("value")
