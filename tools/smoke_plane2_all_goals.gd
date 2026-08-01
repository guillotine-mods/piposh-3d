extends SceneTree
## Regression check for the 2026-08-01 report: "After finishing the
## tasks/level quest in Plane2 we need to start the logic that passes us
## to the next part, which currently doesn't trigger." Root cause:
## `action player_move2` (the real Acknex movement builtin body, whose
## per-tick loop is the ONLY place the "all 4 side-quest goals done ->
## Run(Range.exe)" check lives) gates its entire loop on
## `MY._MOVEMODE > 0`, and `_MOVEMODE` gets set from the DEFINE constant
## `_MODE_WALKING` -- which, unresolved, reads 0.0, so the loop's own
## guard was false from the first check and the whole body (goals check
## included) never ran. Fixed by making `tools/parse_wdl.py` actually
## capture `DEFINE` constants instead of discarding them.
##
## Run: godot --headless --path . -s res://tools/smoke_plane2_all_goals.gd

const LEVEL := "Plane2"


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
		print("FAIL: no interpreter")
		quit(1)
		return

	# Confirm the DEFINE fix landed: _MODE_WALKING/_MODE_STILL should no
	# longer read as the generic-undeclared-global 0.0.
	print("_MODE_WALKING=%s _MODE_STILL=%s" % [
		interp.call("_get_var", "_MODE_WALKING", null),
		interp.call("_get_var", "_MODE_STILL", null),
	])

	# Set all 4 side-quest goals done, matching player_move2()'s own
	# check, and watch for Run("Range.exe") via LevelRouter.
	interp.call("_set_var", "Goal_Passanger", 1.0, null)
	interp.call("_set_var", "Goal_TV", 1.0, null)
	interp.call("_set_var", "Goal_Sikot", 1.0, null)
	interp.call("_set_var", "Goal_Headphones", 1.0, null)

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var player_ent: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")).to_lower().begins_with("player_walk"):
			player_ent = n
			print("player entity found: name=%s action=%s" % [n.name, n.get_meta("action", "")])
	if player_ent == null:
		print("NOTE: no player_walk* entity found in Entities -- checking first_person_spawn instead")
		print("has_first_person=%s first_person_spawn=%s" % [loader.call("has_first_person"), loader.get("first_person_spawn")])

	var router := root.get_node_or_null("LevelRouter")
	# Waiting for the actual Run("Range.exe") would mean waiting out
	# KRP009.WAV's real ~32s duration, slower still in headless mode
	# (already-documented: headless audio progresses slower than
	# real-time) -- the milestone that actually answers the report is
	# whether the all-4-goals branch gets ENTERED at all (Scene=2,
	# MoviePlaying=1, Talking=3 all set together, only inside that
	# branch); reaching Run() itself after that point is the same
	# already-established GetPosition(Voice)/sPlay machinery used
	# throughout the rest of the project, not something this report is
	# about.
	var fired := false
	for i in 300:  # 5s @ 60fps
		await process_frame
		var scene := _to_f(interp.call("_get_var", "Scene", null))
		var movie := _to_f(interp.call("_get_var", "MoviePlaying", null))
		var talking := _to_f(interp.call("_get_var", "Talking", null))
		if scene == 2.0 and movie == 1.0 and talking == 3.0:
			fired = true
			break
		if i % 60 == 0:
			var movemode = player_ent.get_meta("wdl_custom__movemode", "?") if player_ent else "no-entity"
			print("t=%.1fs Scene=%s MoviePlaying=%s _movemode=%s TempZ=%s Talking=%s" % [
				i / 60.0, scene, movie, movemode,
				interp.call("_get_var", "TempZ", null), talking,
			])

	print("all-4-goals branch entered=%s" % fired)
	print("OK" if fired else "FAIL: all-goals-complete check never triggered")
	quit(0 if fired else 1)


func _to_f(v: Variant) -> float:
	return float(v) if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) else 0.0
