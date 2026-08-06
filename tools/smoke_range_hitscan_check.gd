extends SceneTree
## Verifies the new instant-raycast hitscan replacement for Range's
## bullet-travel model: firing resolves immediately (no lingering Spark
## entity), a precisely-aimed shot registers a real hit, and firing
## doesn't self-hit the shooter's own position.
##
## Run: godot --headless --path . -s res://tools/smoke_range_hitscan_check.gd

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

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var camtarget: Node3D = null
	var candidates: Array = []
	for n in entities.get_children():
		var a := str(n.get_meta("action", ""))
		if a == "CamTarget":
			camtarget = n
		elif a == "Terrorist":
			candidates.append(n)
	# Pick the farthest target with an achievable (non-clamped) tilt.
	var terrorist: Node3D = null
	var best_dist := -1.0
	for n in candidates:
		var dd: Vector3 = (n.global_position - camtarget.global_position)
		var tt := rad_to_deg(asin(clampf(dd.normalized().y, -1.0, 1.0)))
		if tt >= -15.0 and tt <= 45.0:
			var dist := camtarget.global_position.distance_to(n.global_position)
			if dist > best_dist:
				best_dist = dist
				terrorist = n
	if camtarget == null or terrorist == null:
		print("FAIL: missing CamTarget or Terrorist")
		quit(1)
		return

	var type_terrorist = interp.call("_get_var", "typeTerrorist", null)
	for c in candidates:
		interp.call("_set_field", {"t": "id", "name": "my"}, "Type", type_terrorist, c)
		interp.call("_set_field", {"t": "id", "name": "my"}, "Pop", 1.0, c)

	var cam_pos: Vector3 = camtarget.global_position
	var target_pos: Vector3 = terrorist.global_position
	var d: Vector3 = (target_pos - cam_pos).normalized()
	var tilt_deg := rad_to_deg(asin(clampf(d.y, -1.0, 1.0)))
	var pan_deg := rad_to_deg(atan2(-d.z, d.x))
	interp.call("_set_field", {"t": "id", "name": "my"}, "pan", pan_deg, camtarget)
	interp.call("_set_field", {"t": "id", "name": "my"}, "tilt", clampf(tilt_deg, -15.0, 45.0), camtarget)
	for i in 2:
		await process_frame

	var before_count: int = entities.get_child_count()
	var before_terr: float = interp.call("_get_var", "Terrorists", null)

	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.parse_input_event(click)
	for i in 3:
		await process_frame

	var after_count: int = entities.get_child_count()
	var after_terr: float = interp.call("_get_var", "Terrorists", null)
	print("entities before=%d after=%d (expect equal -- no lingering Spark)" % [before_count, after_count])
	print("Terrorists before=%s after=%s (expect after < before -- a real hit)" % [before_terr, after_terr])

	var no_lingering_spark := after_count == before_count
	var hit := after_terr < before_terr
	var ok := no_lingering_spark and hit
	print("OK" if ok else "FAIL: no_lingering_spark=%s hit=%s" % [no_lingering_spark, hit])
	quit(0 if ok else 1)
