extends SceneTree
## Regression check for the 2026-07-30 report ("after talking ends the game
## doesn't move to the next level," "no text-choosing on screen"):
## `ShowDialog()` was completely unbridged, so the choice panel never
## appeared and `DialogChoice` could never be set by a click -- every
## `while (DialogIndex==X) { if (DialogChoice==1) {...} }` polling loop in
## the game spun forever. Directly exercises the two halves of the fix:
## WdlInterpreter._do_show_dialog() (via the "ShowDialog" builtin) opens
## GameHud's real dialog panel, and clicking an option
## (GameHud.dialog_choice.emit) correctly lands back in the interpreter's
## `DialogChoice` global via WdlInterpreter._on_dialog_choice().
##
## Run: godot --headless --path . -s res://tools/smoke_dialog_choice.gd

const LEVEL := "Studio"


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
	if hud == null:
		print("FAIL: no GameHud on LevelRunner")
		quit(1)
		return

	print("Before: is_dialog_open=%s" % hud.call("is_dialog_open"))
	_set_global(interp, "DialogIndex", 2.0)
	interp.call("_call", "ShowDialog", [], null)
	var open_after: bool = hud.call("is_dialog_open")
	print("After ShowDialog(): is_dialog_open=%s" % open_after)
	if not open_after:
		print("\nFAIL: ShowDialog() did not open GameHud's dialog panel.")
		quit(1)
		return

	var dc_before: Variant = _read_global(interp, "DialogChoice")
	print("DialogChoice before click=%s" % dc_before)
	hud.dialog_choice.emit(2)
	await process_frame
	var dc_after: Variant = _read_global(interp, "DialogChoice")
	print("DialogChoice after clicking option 2=%s" % dc_after)
	if float(dc_after) != 2.0:
		print("\nFAIL: clicking a dialog option did not set DialogChoice=2 in the interpreter.")
		quit(1)
		return

	print("\nOK: ShowDialog() opens the real panel, and a click correctly sets DialogChoice.")
	quit(0)


func _set_global(interp: Node, name: String, value: float) -> void:
	interp.call("_set_var", name, value, null)


func _read_global(interp: Node, name: String) -> Variant:
	var globals: Dictionary = interp.get("_globals")
	var lower: Dictionary = interp.get("_globals_lower")
	var canonical := name
	if lower.has(name):
		canonical = str(lower[name])
	if not globals.has(canonical):
		return null
	return globals[canonical].get("value")
