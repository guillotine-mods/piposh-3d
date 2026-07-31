extends SceneTree
## Diagnostic for the 2026-07-31 report ("after choosing, the talk isn't
## starting" in Shiks): `action Piposh2`'s Scene==2 branch opens with
## `while (Dialog.visible == on) { Talking = 0; Blink(); wait(1); }` --
## `Dialog` was a genuinely-unresolved PANEL identifier (no generic PANEL
## support), so this always read 0.0/off and the loop never actually
## gated anything, meaning the script re-called `ShowDialog()` (which
## resets DialogChoice to 0) every single frame with nothing blocking it
## long enough for a real click to register before being reset again.
## Fixed by bridging `Dialog.visible` to the real HUD panel state.
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_dialog_choice.gd

const LEVEL := "Shiks"
const FRAMES := 900  # 15s @ 60fps


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

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null
	if interp == null:
		print("FAIL: %s did not start the interpreter" % LEVEL)
		quit(1)
		return
	var hud: Node = runner.get("_game_hud")

	# Fast-forward past Piposh2's walk-to-StandHere phase, straight to the
	# real DialogIndex=1 choice prompt, same technique as
	# smoke_studio_camswitch.gd (force state + call the real ShowDialog()).
	interp.call("_set_var", "Scene", 2.0, null)
	interp.call("_set_var", "DialogIndex", 1.0, null)
	interp.call("_call", "ShowDialog", [], null)
	for i in 5:
		await process_frame

	print("Before click: DialogIndex=%s DialogChoice=%s dialog_open=%s" % [
		_read_global(interp, "DialogIndex"), _read_global(interp, "DialogChoice"), hud.call("is_dialog_open")
	])

	print("\n-- Clicking dialogue option 1 (should sPlay PIP012.WAV, not reset) --")
	# Real clicks go through GameHud._emit_choice(), which calls
	# hide_dialog() BEFORE emitting -- do the same here instead of emitting
	# the signal directly, or Dialog.visible legitimately still reads
	# "open" per this test's own construction, not a real bug.
	hud.call("hide_dialog")
	hud.dialog_choice.emit(1)

	var audio := root.get_node("AudioChannels")
	var saw_voice_playing := false
	var last_choice: Variant = null
	for i in FRAMES:
		await process_frame
		var choice: Variant = _read_global(interp, "DialogChoice")
		var playing: bool = audio.call("is_voice_playing")
		if playing:
			saw_voice_playing = true
		if choice != last_choice:
			print("frame=%d DialogChoice: %s -> %s (voice_playing=%s)" % [i, last_choice, choice, playing])
			last_choice = choice
		if i == 60:
			print("  ...frame=60 DialogChoice=%s voice_playing=%s dialog_open=%s" % [choice, playing, hud.call("is_dialog_open")])

	print("\nsaw_voice_playing=%s (should be true -- PIP012.WAV should have played at some point)" % saw_voice_playing)
	print("OK" if saw_voice_playing else "FAIL: voice never played after the click -- choice was likely reset before being acted on")
	quit(0 if saw_voice_playing else 1)


func _read_global(interp: Node, name: String) -> Variant:
	var globals: Dictionary = interp.get("_globals")
	var lower: Dictionary = interp.get("_globals_lower")
	var canonical := name
	if lower.has(name):
		canonical = str(lower[name])
	if not globals.has(canonical):
		return null
	return globals[canonical].get("value")
