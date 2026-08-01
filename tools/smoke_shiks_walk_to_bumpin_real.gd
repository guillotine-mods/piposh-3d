extends SceneTree
## The definitive end-to-end test for "after the first dialogue choice it
## just continues in a loop" (2026-08-01): unlike
## smoke_shiks_bumpin_proximity.gd (which manually walked Piposh2 in a
## straight line to isolate/confirm the proximity-detection mechanism
## itself), this drives the ACTUAL reported flow -- open DialogIndex=1,
## repeatedly pick choice 3 (the only choice that sets `my.skill20=1`,
## which is what makes `actor_move()` actually move Piposh2, in
## whatever direction its own `my.pan` already points, no steering
## logic of its own) -- and lets the real `actor_move()` bridge do the
## walking, at its real speed, in its real (WED-authored) direction.
## Confirms whether the natural walk ever actually reaches Bumpin/Snail,
## not just whether the collision mechanism fires when placed there
## manually.
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_walk_to_bumpin_real.gd

const LEVEL := "Shiks"
const MAX_ROUNDS := 15


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

	var piposh2 := _find_entity_by_action(runner, "Piposh2")
	var bumpin := _find_entity_by_action(runner, "Bumpin")
	if piposh2 == null or bumpin == null:
		print("FAIL: piposh2=%s bumpin=%s" % [piposh2, bumpin])
		quit(1)
		return

	print("Piposh2 pan meta=%s (0 = +Godot-X, matches WED angle_gs)" % piposh2.get_meta("pan", 0.0))
	print("Piposh2 pos=%s Bumpin pos=%s initial distance=%.1f" % [
		piposh2.global_position, bumpin.global_position,
		piposh2.global_position.distance_to(bumpin.global_position)
	])

	# Skip Scene==1's walk-to-StandHerePoint (irrelevant to this test,
	# just real-time cost) -- land exactly where a real player would be
	# right after that phase ends: Scene=2, first dialogue prompt open.
	interp.call("_set_var", "Scene", 2.0, null)
	interp.call("_set_var", "DialogIndex", 1.0, null)
	interp.call("_call", "ShowDialog", [], null)
	for i in 5:
		await process_frame

	var router := root.get_node_or_null("LevelRouter")
	var bumped := false
	var round_num := 0
	while round_num < MAX_ROUNDS and not bumped:
		round_num += 1
		var dist_before: float = piposh2.global_position.distance_to(bumpin.global_position)
		print("\n-- Round %d: picking choice 3 (dist to Bumpin=%.1f) --" % [round_num, dist_before])
		hud.call("hide_dialog")
		hud.dialog_choice.emit(3)

		# Wait for this round's response (SHK007.WAV, or the Bumped ->
		# MyCamera scripted-flight -> DialogIndex=2 handoff) to run its
		# course -- generous real-time budget per round. Success is
		# Piposh.skill2 reaching 2 (Bumped fired), not Run() firing --
		# that needs a *different* dialogue choice once DialogIndex==2,
		# out of scope for this test.
		for i in 600:  # 10s @ 60fps
			await process_frame
			if _skill2(piposh2) == 2.0 or _skill2(piposh2) == 4.0:
				bumped = true
				break
			var running: bool = interp.get("_running")
			if not running:
				break
		var dist_after: float = piposh2.global_position.distance_to(bumpin.global_position)
		print("   after round %d: pos=%s dist to Bumpin=%.1f (moved %.1f) skill2=%s running=%s" % [
			round_num, piposh2.global_position, dist_after, dist_before - dist_after,
			_skill2(piposh2), interp.get("_running")
		])
		if bumped:
			break
		# Wait for the dialogue panel to actually reopen before the next
		# round -- matches a real player waiting for the prompt.
		for i in 300:
			await process_frame
			if hud.call("is_dialog_open"):
				break

	# Give the MyCamera scripted flight (skill1 < 7 waypoint loop) real
	# time to finish and flip DialogIndex to 2 before final reporting.
	if bumped:
		for i in 300:  # 5s @ 60fps
			await process_frame
			if _skill2(piposh2) == 4.0:
				break

	print("\nbumped=%s after %d round(s)" % [bumped, round_num])
	print("final Piposh.skill2=%s final DialogIndex=%s final distance=%.1f" % [
		_skill2(piposh2), interp.call("_get_var", "DialogIndex", null),
		piposh2.global_position.distance_to(bumpin.global_position)
	])
	print("OK" if bumped else "FAIL: Piposh never bumped into Bumpin via the real dialogue-choice flow")
	quit(0 if bumped else 1)


func _skill2(node: Node3D) -> Variant:
	var arr: Array = node.get_meta("wdl_skills", [])
	if arr.size() < 2:
		return 0.0
	return arr[1]


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
