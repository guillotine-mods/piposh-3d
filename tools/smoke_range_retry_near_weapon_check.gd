extends SceneTree
## GB-9 continued: "after retry... we see the gun and the hand in front
## of us instead of first person POV like before the retry." Confirms
## the Handgun view-model's near-pull re-applies after a retry reset,
## not just at initial level load.
##
## Run: godot --headless --path . -s res://tools/smoke_range_retry_near_weapon_check.gd

const LEVEL := "Range"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)

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
	for i in 15:
		await process_frame

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var handgun: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "Handgun":
			handgun = n
			break
	if handgun == null:
		print("FAIL: no Handgun entity found")
		quit(1)
		return

	var cam: Camera3D = get_root().get_viewport().get_camera_3d()
	var spawn_pos: Vector3 = handgun.get_meta("wdl_spawn_position", Vector3.ZERO)
	var dist_before: float = cam.global_position.distance_to(handgun.global_position)
	var spawn_dist: float = cam.global_position.distance_to(spawn_pos)
	print("before retry: handgun pos=%s dist_from_cam=%.2f (raw spawn dist=%.2f, wdl_near_applied=%s)" % [
		handgun.global_position, dist_before, spawn_dist, handgun.get_meta("wdl_near_applied", false),
	])

	# Die -> pRIP shows -> click Retry for real (fRIP1: HideRIP(); main();
	# -- HideRIP() is what triggers _reset_all_entities_to_spawn()).
	interp.call("_set_var", "Health", 0.0, null)
	for i in 15:
		await process_frame
	interp.call("invoke_event", null, "fRIP1")
	for i in 15:
		await process_frame

	var dist_right_after_reset: float = cam.global_position.distance_to(handgun.global_position)
	print("right after retry (before Handgun's own next pan/roll tick lands): dist_from_cam=%.2f wdl_near_applied=%s" % [
		dist_right_after_reset, handgun.get_meta("wdl_near_applied", false),
	])

	for i in 10:
		await process_frame

	var dist_after: float = cam.global_position.distance_to(handgun.global_position)
	print("after retry (settled): handgun pos=%s dist_from_cam=%.2f wdl_near_applied=%s" % [
		handgun.global_position, dist_after, handgun.get_meta("wdl_near_applied", false),
	])

	# Should be back close to the SAME pulled-in distance as before retry
	# (~40 units, not the raw ~38-unit spawn distance which is coincidentally
	# similar -- check it's not stuck unpulled by comparing to dist_before,
	# which was already the pulled state).
	var ok: bool = is_equal_approx(dist_after, dist_before) or absf(dist_after - dist_before) < 1.0
	print("OK" if ok else "FAIL: Handgun did not return to its pulled-close distance after retry (dist_before=%.2f dist_after=%.2f)" % [dist_before, dist_after])
	quit(0 if ok else 1)
