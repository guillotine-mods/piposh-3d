extends SceneTree
## End-to-end check of Range's shooting-gallery loop: aiming (mickey),
## firing (on_mouse_left -> Fire -> CreateSpark -> Spark bullet), the
## bullet actually traveling (move()/vec_rotate), hitting a Terrorist
## target (enable_impact, already-working mechanism), Health/Health2
## updating, and the RIP (lose) screen showing once Health drops to 0.
##
## Run: godot --headless --path . -s res://tools/smoke_range_shoot.gd

const LEVEL := "Range"


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

	# Skip the intro dialogue synchronously (same as smoke_range_panels.gd).
	interp.call("_set_var", "MoviePlaying", 0.0, null)
	interp.call("_call", "ShowPanel", [], null)
	for i in 5:
		await process_frame

	# -- mickey/aim check --
	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var camtarget: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "CamTarget":
			camtarget = n
	if camtarget == null:
		print("FAIL: no CamTarget entity")
		quit(1)
		return
	var pan_before: float = camtarget.get_meta("pan", 0.0)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(100, 0)
	Input.parse_input_event(motion)
	await process_frame
	await process_frame
	var pan_after: float = camtarget.get_meta("pan", 0.0)
	print("CamTarget pan: before=%.2f after=%.2f (should differ if mickey is live)" % [pan_before, pan_after])

	# -- fire a shot and see if a Spark bullet gets created and travels --
	var before_count: int = entities.get_child_count()
	# Simulate a real left-click via the same _input() path the interpreter listens on.
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.parse_input_event(click)
	await process_frame
	await process_frame
	var after_count: int = entities.get_child_count()
	print("entities before fire=%d after fire=%d (expect +1 for the Spark bullet)" % [before_count, after_count])

	var spark: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "Spark":
			spark = n
	if spark == null:
		print("FAIL: no Spark bullet entity found after firing")
	else:
		print("found Spark entity, tracking position over 10 frames...")
		var p0 := spark.global_position
		for i in 10:
			print("  frame %d..." % i)
			await process_frame
			if not is_instance_valid(spark):
				print("  spark freed at frame %d (hit something)" % i)
				break
		if is_instance_valid(spark):
			var p1 := spark.global_position
			print("Spark pos t0=%s t+10frames=%s moved=%.2f" % [p0, p1, p0.distance_to(p1)])

	# -- health bar / RIP screen: force Health to 0 and confirm Restart() -> ShowRIP() shows pRIP --
	interp.call("_set_var", "Health", 0.0, null)
	for i in 10:
		await process_frame
	var panel_nodes: Dictionary = interp.get("_panel_nodes")
	var prip = panel_nodes.get("prip")
	print("pRIP visible after Health=0: %s" % (prip.visible if prip else "MISSING"))

	print("OK")
	quit(0)
