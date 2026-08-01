extends SceneTree
## NB-7 follow-up: real Godot screenshots confirm Piposh is completely
## absent during the bus and pigeon shots in THIS port (not just too
## close/cropped -- genuinely not rendering at all), while the original
## game shows him in an intentional extreme close-up there. Drives the
## real sequence to CamShow==7 (pigeon) and checks the far "Pipi"-action
## Piposh.MDL entity's actual position against the real _script_cam's
## own frustum planes (Camera3D.is_position_in_frustum(), not manual
## trig) at that exact moment, plus its distance from the camera and
## whether it's in front of or behind the near/far clip planes.
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_pigeon_frustum.gd

const LEVEL := "Shiks"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)

	var interp: Node = null
	var hud: Node = null
	for i in 5:
		await process_frame
		var director: Node = runner.get("_director")
		if director:
			interp = director.get("_wdl_interp")
			hud = director.get("_hud")
		if interp:
			break
	if interp == null:
		print("FAIL: no interpreter for %s" % LEVEL)
		quit(1)
		return

	for i in 30:
		await process_frame

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var target: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "Pipi" and bool(n.get_meta("invisible", false)):
			# There are two flag-invisible Pipi placements (PipCell + far
			# Piposh); pick the far Piposh.MDL one specifically.
			for c in n.get_children():
				if str(c.name).to_lower().begins_with("piposh"):
					target = n
					break
		if target:
			break
	if target == null:
		print("FAIL: no far Piposh Pipi entity found")
		quit(1)
		return
	print("Target entity: %s" % target.name)

	# --- Dialogue 1 (choice 3) ---
	interp.call("_set_var", "Scene", 2.0, null)
	interp.call("_set_var", "DialogIndex", 1.0, null)
	interp.call("_call", "showdialog", [], null)
	for i in 10:
		await process_frame
	hud.call("_emit_choice", 3)

	# --- Real chase trigger for dialogue 2 ---
	var piposh2: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "Piposh2":
			piposh2 = n
			break
	var skills: Array = piposh2.get_meta("wdl_skills", [])
	while skills.size() <= 1:
		skills.append(0.0)
	skills[1] = 2.0
	piposh2.set_meta("wdl_skills", skills)

	var got_dialog2 := false
	for i in 1200:
		await process_frame
		if bool(hud.call("is_dialog_open")) and float(interp.call("_get_var", "DialogIndex", null)) == 2.0:
			got_dialog2 = true
			break
	if not got_dialog2:
		print("FAIL: never reached dialogue 2")
		quit(1)
		return
	for i in 5:
		await process_frame
	hud.call("_emit_choice", 2)
	print("Clicked choice 2 -- waiting for CamShow==7 (pigeon)")

	var cam: Camera3D = runner.get("_script_cam")
	var reached_7 := false
	for i in 7200:
		await process_frame
		var camshow := float(interp.call("_get_var", "CamShow", null))
		if camshow == 7.0:
			reached_7 = true
			for j in 5:  # let the camera settle a couple frames
				await process_frame
			break
	if not reached_7:
		print("FAIL: never reached CamShow==7")
		quit(1)
		return

	print("=== At CamShow==7 ===")
	print("camera.global_position=%s camera.global_rotation_degrees=%s" % [
		cam.global_position, cam.global_rotation_degrees
	])
	print("camera.near=%s far=%s fov=%s" % [cam.near, cam.far, cam.fov])
	print("target.global_position=%s target.visible=%s" % [target.global_position, target.visible])
	var dist := cam.global_position.distance_to(target.global_position)
	print("distance camera<->target=%.2f" % dist)
	var in_frustum := cam.is_position_in_frustum(target.global_position)
	print("is_position_in_frustum(target)=%s" % in_frustum)
	# Also check the mesh's own AABB corners in case the origin itself is
	# borderline but the mesh extends into frame.
	var mesh: MeshInstance3D = _find_mesh(target)
	if mesh:
		var aabb := mesh.global_transform * mesh.get_aabb()
		print("mesh global aabb: pos=%s size=%s" % [aabb.position, aabb.size])
		var any_corner_in := false
		for corner_idx in 8:
			var corner: Vector3 = aabb.position + Vector3(
				aabb.size.x * (corner_idx & 1),
				aabb.size.y * ((corner_idx >> 1) & 1),
				aabb.size.z * ((corner_idx >> 2) & 1)
			)
			if cam.is_position_in_frustum(corner):
				any_corner_in = true
		print("any AABB corner in frustum=%s" % any_corner_in)

	quit(0)


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var r := _find_mesh(c)
		if r:
			return r
	return null
