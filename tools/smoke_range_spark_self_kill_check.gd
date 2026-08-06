extends SceneTree
## GB-8: "none of my shots were triggered even when they were accurate."
## Root cause: `action Spark` enables impact detection as its own very
## first statement, before it has moved -- and bullets spawn AT the
## shooter's own position, so the shooter (and a nearby, unmatched
## "CameraEngine" placeholder sharing the same Cam.MDL spot) registered
## as an immediate "impact" before the bullet ever traveled anywhere.
## Verifies directly: a freshly created Spark's impact zone does NOT
## fire against the entity it spawned on top of, and does not treat a
## `wdl_non_physical`-flagged marker as a valid impact target either.
##
## Run: godot --headless --path . -s res://tools/smoke_range_spark_self_kill_check.gd

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
	for i in 5:
		await process_frame

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var camtarget: Node3D = null
	var cam_engine: Node3D = null
	for n in entities.get_children():
		var a := str(n.get_meta("action", ""))
		if a == "CamTarget":
			camtarget = n
		elif a == "CameraEngine":
			cam_engine = n
	if camtarget == null:
		print("FAIL: no CamTarget entity")
		quit(1)
		return

	print("CameraEngine found=%s wdl_non_physical=%s" % [
		cam_engine != null,
		cam_engine.get_meta("wdl_non_physical", false) if cam_engine else "<n/a>",
	])

	# Spawn a Spark right on top of CamTarget, same as CreateSpark() does
	# (create(<UziBul.mdl>, player.x, Spark)).
	var spark: Node3D = interp.call("_do_create", ["UziBul.mdl", camtarget, "Spark"], null)
	if spark == null:
		print("FAIL: Spark didn't spawn")
		quit(1)
		return
	for i in 3:
		await process_frame

	var alive := is_instance_valid(spark)
	print("spark alive after 3 frames (spawned on top of its own shooter)=%s" % alive)
	print("OK" if alive else "FAIL: Spark self-killed against its own shooter on spawn")
	quit(0 if alive else 1)
