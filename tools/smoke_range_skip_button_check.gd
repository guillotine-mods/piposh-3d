extends SceneTree
## Reported live (2026-08-08): "the skip [battle button that appears
## after 3 times you die] doesn't pass us to the next level." Confirmed
## the click DOES register (D1's own `sPlay("SFX138.WAV")` fires) but
## D1 never reaches `Run("Plane3.exe")` when clicked WHILE still on the
## death screen (pRIP visible, `_frozen == true`) -- the real reported
## scenario, and the whole point of a Skip button that's an alternative
## to Retry, not something that requires closing the death screen first.
##
## Root cause: the blanket `while (_frozen and _running) { wait a
## frame; }` gate on every `wait()` statement (added for GB-5 to pause
## WORLD entity coroutines while pRIP is up) also blocked D1's own
## `wait(1)` inside `while (GetPosition(Voice) < 1000000) { wait(1); }`
## -- and unlike Retry (fRIP1: HideRIP() clears `_frozen` synchronously
## before main()'s own first wait), nothing about clicking Skip ever
## unfreezes anything, so D1 deadlocked forever on its own first wait.
## Fixed by exempting bare (`my == null`) coroutines -- every panel-
## button-invoked function, never a world entity -- from the freeze
## gate, the same way main()'s own `my == null` wait already gets
## special-cased just above it.
##
## Run: godot --headless --path . -s res://tools/smoke_range_skip_button_check.gd

const LEVEL := "Range"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)

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
	for i in 10:
		await process_frame

	interp.call("_set_var", "NumTries", 4.0, null)

	# Die for real -> pRIP shows -> _frozen becomes true. Click Skip
	# WITHOUT clicking Retry first, same as the real reported scenario.
	interp.call("_set_var", "Health", 0.0, null)
	for i in 15:
		await process_frame
	var frozen_before: bool = interp.get("_frozen")

	interp.call("invoke_event", null, "D1")

	var reached_next_level := false
	for i in 300:  # 5s -- D1 blocks on a real voice line finishing first
		await process_frame
		if root.get_node("GameState").current_level != LEVEL:
			reached_next_level = true
			break

	print("frozen while clicking=%s (expect true -- still on the death screen)" % [frozen_before])
	print("GameState.current_level after=%s (expect Plane3)" % [root.get_node("GameState").current_level])

	var ok: bool = frozen_before and reached_next_level
	print("OK" if ok else "FAIL: Skip button deadlocked instead of reaching the next level")
	quit(0 if ok else 1)
