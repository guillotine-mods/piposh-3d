extends SceneTree
## NB-7 investigation: "Piposh is not shown in 2 frames after the
## dialogue where the camera switches locations multiple times." Shiks'
## post-dialogue-2 choice-2 sequence uses a "stunt double" entity
## (`action Piposh3`, a separate placement of Piposh.MDL from
## `action Piposh2`'s own entity) plus `morph()` calls and several
## invisible-toggling props (Pipi, Weasel) driven off `CamShow`/`Talking`.
##
## Drives the REAL trigger chain throughout (forces dialogue 1's own
## Scene/DialogIndex/ShowDialog, matching real WDL's own line 234, then
## triggers action MyCamera's real chase via Piposh.skill2=2 and waits
## for its real ShowDialog(2) instead of forcing DialogIndex itself --
## avoids this script's own state-forcing racing against Piposh2's own
## coroutine, which the first version of this test did). Logs every
## visibility transition for Piposh2/Piposh3/Pipi/Weasel, plus
## CamShow/Talking at each change.
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_camshow.gd

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
	var watched: Array[Node3D] = []
	var piposh2: Node3D = null
	for n in entities.get_children():
		var action := str(n.get_meta("action", ""))
		if action in ["Piposh2", "Piposh3", "Pipi", "Weasel"]:
			watched.append(n)
			print("Watching %s action=%s" % [n.name, action])
			if action == "Piposh2":
				piposh2 = n

	# --- Dialogue 1: matches Piposh2's own line 234 exactly ---
	interp.call("_set_var", "Scene", 2.0, null)
	interp.call("_set_var", "DialogIndex", 1.0, null)
	interp.call("_call", "showdialog", [], null)
	for i in 10:
		await process_frame
	hud.call("_emit_choice", 3)
	print("Clicked choice 3 for dialogue 1")

	# --- Real trigger for dialogue 2: matches action Bumped's own effect ---
	var skills: Array = piposh2.get_meta("wdl_skills", [])
	while skills.size() <= 1:
		skills.append(0.0)
	skills[1] = 2.0  # skill2 (1-indexed) -> index 1
	piposh2.set_meta("wdl_skills", skills)
	print("Set Piposh.skill2=2 (matching action Bumped) -- waiting for the real chase")

	var got_dialog2 := false
	for i in 1200:  # 20s
		await process_frame
		if bool(hud.call("is_dialog_open")) and float(interp.call("_get_var", "DialogIndex", null)) == 2.0:
			got_dialog2 = true
			print("Real DialogIndex=2 dialog opened at t=%.1fs" % (i / 60.0))
			break
	if not got_dialog2:
		print("FAIL: never reached the real dialogue-2 box")
		quit(1)
		return

	for i in 5:
		await process_frame
	hud.call("_emit_choice", 2)
	print("Clicked choice 2 -- watching the full CamShow sequence now")

	var last_visible := {}
	var last_mesh_visible := {}
	for n in watched:
		last_visible[n] = n.visible
		last_mesh_visible[n] = _find_mesh_visible(n)
	for i in 7200:  # 120s @ 60fps -- the full chain is long, headless audio timing varies
		await process_frame
		var camshow = interp.call("_get_var", "CamShow", null)
		var talking = interp.call("_get_var", "Talking", null)
		for n in watched:
			if not is_instance_valid(n):
				continue
			var mesh_vis: Variant = _find_mesh_visible(n)
			if n.visible != last_visible.get(n, n.visible) or mesh_vis != last_mesh_visible.get(n):
				print("t=%.2fs %s visible: %s -> %s  MESH: %s -> %s  (CamShow=%s Talking=%s)" % [
					i / 60.0, n.name, last_visible.get(n), n.visible,
					last_mesh_visible.get(n), mesh_vis, camshow, talking
				])
				last_visible[n] = n.visible
				last_mesh_visible[n] = mesh_vis
		if not interp.get("_running"):
			print("interpreter stopped (Run() fired) at t=%.2fs" % (i / 60.0))
			break

	print("Done.")
	quit(0)


func _find_mesh_visible(n: Node) -> Variant:
	if n is MeshInstance3D:
		return (n as MeshInstance3D).visible
	for c in n.get_children():
		var r = _find_mesh_visible(c)
		if r != null:
			return r
	return null
