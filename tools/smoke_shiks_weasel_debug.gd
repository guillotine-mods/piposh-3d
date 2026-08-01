extends SceneTree
## Investigates the 2026-08-01 report: "a squirrel [Weasel.MDL] is shown
## during the 2nd dialogue after the first dialogue and the camera
## movement -- this squirrel shouldn't be there according to the game's
## logic." `action Weasel` (Shiks.wdl) only ever does
## `my.invisible = off` when `CamShow == 6`, with NO initializer and NO
## re-hide branch -- so whether it's visible from frame 1 depends entirely
## on the WED-authored flag. Checks that directly, plus where it sits
## relative to Bumpin/the MyCamera flight path, since "shouldn't be
## there" could mean either "visible when it shouldn't be" or "camera
## happens to point at it before its scripted reveal."
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_weasel_debug.gd

const LEVEL := "Shiks"


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

	var interp: Node = runner.get("_director").get("_wdl_interp")
	var weasel := _find_entity_by_action(runner, "Weasel")
	var bumpin := _find_entity_by_action(runner, "Bumpin")
	var piposh2 := _find_entity_by_action(runner, "Piposh2")
	if weasel == null:
		print("FAIL: no Weasel entity found")
		quit(1)
		return

	var mesh := _find_mesh(weasel)
	print("Weasel pos=%s visible(node)=%s mesh_visible=%s meta_invisible=%s flags=%s" % [
		weasel.global_position, weasel.visible,
		(mesh.visible if mesh else "no-mesh"),
		weasel.get_meta("invisible", "?"), weasel.get_meta("flags", "?")
	])
	print("Bumpin pos=%s  Piposh2 pos=%s  dist Weasel-Bumpin=%.1f" % [
		bumpin.global_position, piposh2.global_position,
		weasel.global_position.distance_to(bumpin.global_position)
	])
	print("CamShow=%s at level start" % interp.call("_get_var", "CamShow", null))

	# Drive to Scene=2/DialogIndex=1, choice 3 (SHK007 + walk), long enough
	# for Bumped to fire (per the 2026-08-01 impact fix) and MyCamera's
	# scripted flight (skill2==2 -> 4) to fully complete.
	interp.call("_set_var", "Scene", 2.0, null)
	interp.call("_set_var", "DialogIndex", 1.0, null)
	interp.call("_call", "ShowDialog", [], null)
	for i in 5:
		await process_frame
	var hud: Node = runner.get("_game_hud")
	hud.call("hide_dialog")
	hud.dialog_choice.emit(3)

	for i in 900:  # 15s @ 60fps -- covers SHK007 + the waypoint flight
		await process_frame
		var skill2 = _skill2(piposh2)
		if int(i) % 120 == 0:
			print("t=%.1fs skill2=%s CamShow=%s Weasel visible(node)=%s mesh_visible=%s cam_active=%s" % [
				i / 60.0, skill2, interp.call("_get_var", "CamShow", null),
				weasel.visible, (mesh.visible if mesh else "no-mesh"),
				root.get_camera_3d()
			])
		if skill2 == 4.0:
			break

	print("\n-- final state --")
	print("Piposh.skill2=%s CamShow=%s DialogIndex=%s" % [
		_skill2(piposh2), interp.call("_get_var", "CamShow", null),
		interp.call("_get_var", "DialogIndex", null)
	])
	var cam := root.get_camera_3d()
	if cam:
		print("active camera pos=%s (global)  looking dir=%s" % [
			cam.global_position, -cam.global_transform.basis.z
		])
	print("Weasel visible(node)=%s mesh_visible=%s pos=%s" % [
		weasel.visible, (mesh.visible if mesh else "no-mesh"), weasel.global_position
	])
	quit(0)


func _skill2(node: Node3D) -> Variant:
	var arr: Array = node.get_meta("wdl_skills", [])
	if arr.size() < 2:
		return 0.0
	return arr[1]


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var found := _find_mesh(c)
		if found:
			return found
	return null


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
