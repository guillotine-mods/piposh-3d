extends SceneTree
## Verifies the 2026-07-30 fix for `my.enable_click`/`my.event` (previously
## a silent no-op in WdlInterpreter, so every click-driven entity in every
## interpreted level was permanently unresponsive). Loads Plane2, lets its
## entities' own action coroutines run (HeadPhone sets
## `my.enable_click=on; my.event=HP;` with no wait(), so it's done after
## one frame), confirms the interpreter captured event="HP" as a string
## (not a mis-evaluated 0.0), then simulates a click on the HeadPhone
## entity and confirms the HP action actually started (Scene/MoviePlaying
## set) *and* is still genuinely in progress rather than racing to
## completion -- also doubles as a regression test for the separate
## sound-variable-resolution fix (see the comment above the assertion).
##
## Run: godot --headless --path . -s res://tools/smoke_click_event.gd

const LEVEL := "Plane2"


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
	if director == null:
		print("FAIL: no _director on LevelRunner")
		quit(1)
		return
	var interp: Node = director.get("_wdl_interp")
	if interp == null:
		print("FAIL: level did not start the interpreter (interpreted=false)")
		quit(1)
		return

	var headphone := _find_entity_by_action(runner, "HeadPhone")
	if headphone == null:
		print("FAIL: no entity with action=HeadPhone found in Plane2")
		quit(1)
		return

	var event_val = headphone.get_meta("wdl_event", "")
	print("HeadPhone entity found: %s, wdl_event meta = '%s'" % [headphone.name, str(event_val)])
	print("interp has_method(invoke_event) = %s" % interp.has_method("invoke_event"))
	print("director has_method(_handle_click_action) = %s" % director.has_method("_handle_click_action"))
	if str(event_val) != "HP":
		print("FAIL: expected wdl_event == 'HP', got '%s' (the bare-identifier capture fix didn't take)" % str(event_val))
		quit(1)
		return

	var goal_before = _read_global(interp, "goal_headphones")
	print("Before click: Goal_Headphones=%s" % goal_before)

	director.call("_handle_click_action", "HeadPhone", headphone)
	await process_frame
	await process_frame

	# action HP's first two statements (Scene=1; MoviePlaying=1;) run
	# synchronously before its first sPlay()+GetPosition(Voice) wait, so
	# these should already be set two frames after the click.
	#
	# 2026-07-30 update: earlier this checked the *final* state
	# (Goal_Headphones==1, everything back to 0) two frames after the
	# click, because a separate bug -- `sound Cockpit = <SFX089.WAV>;`
	# declarations were parsed but never resolved by _get_var(), so
	# Plane2's `action Dummy` ambiance loop's `play_entsound(my, cockpit,
	# 300)` silently failed every tick and kept force-clearing AudioBus's
	# *shared* voice-finished flag -- made every GetPosition(Voice) wait in
	# the whole game resolve instantly regardless of real audio duration.
	# Fixed (see CONTRACT.md §5); confirmed via tools/smoke_audio_timing_check.gd
	# that a real dialogue line now genuinely takes several real seconds to
	# finish in headless mode too. So HP's full 5-line sequence no longer
	# completes in two frames -- checking that it *doesn't* is now part of
	# proving the audio-timing fix actually took effect, not a regression.
	var scene_mid = _read_global(interp, "scene")
	var movie_mid = _read_global(interp, "movieplaying")
	print("2 frames after click: scene=%s movieplaying=%s" % [scene_mid, movie_mid])
	if not (float(scene_mid) == 1.0 and float(movie_mid) == 1.0):
		print("\nFAIL: click did not start action HP (Scene/MoviePlaying should be 1 immediately).")
		quit(1)
		return

	var goal_mid = _read_global(interp, "goal_headphones")
	if float(goal_mid) == 1.0:
		print("\nFAIL: Goal_Headphones already 1 after 2 frames -- dialogue completed")
		print("instantly, meaning real audio timing is NOT in effect (the bug this")
		print("guards against is back).")
		quit(1)
		return

	print("\nOK: click started action HP (Scene/MoviePlaying set), and the dialogue")
	print("sequence is correctly still in progress rather than racing to completion --")
	print("real audio timing confirmed active, not the pre-fix instant-finish bug.")
	quit(0)


func _find_entity_by_action(runner: Node, action_name: String) -> Node3D:
	var loader: Node = runner.get("loader")
	if loader == null:
		return null
	var entities := loader.get_node_or_null("Entities")
	if entities == null:
		return null
	for n in entities.get_children():
		if n is Node3D and str(n.get_meta("action", "")) == action_name:
			return n
	return null


func _read_global(interp: Node, name: String) -> Variant:
	var globals: Dictionary = interp.get("_globals")
	var lower: Dictionary = interp.get("_globals_lower")
	var canonical := name
	if lower.has(name):
		canonical = str(lower[name])
	if not globals.has(canonical):
		return null
	return globals[canonical].get("value")
