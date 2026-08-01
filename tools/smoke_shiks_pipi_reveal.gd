extends SceneTree
## NB-7 regression check: an entity WED-authored with the invisible flag
## (hidden at spawn via WmbLevelLoader._hide_meshes(), which hides the
## child MeshInstance3D directly) must actually become visible on screen
## when WDL writes `my.invisible = off;` -- not just toggle its own root
## node's `visible` while the mesh underneath stays hidden. Reproduces
## directly against Shiks' far "Pipi"-action Piposh.MDL placement
## (confirmed via tools/smoke_shiks_pipi_check.gd: spawns with
## invisible_meta=true and its MeshInstance3D at visible=false).
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_pipi_reveal.gd

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
	for i in 5:
		await process_frame
		var director: Node = runner.get("_director")
		if director:
			interp = director.get("_wdl_interp")
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
			target = n
			break
	if target == null:
		print("FAIL: no flag-invisible Pipi entity found")
		quit(1)
		return

	var mesh_before: Variant = _find_mesh_visible(target)
	print("Before reveal: node.visible=%s mesh_visible=%s" % [target.visible, mesh_before])

	interp.call("_set_field", {"t": "id", "name": "my"}, "invisible", 0.0, target)
	for i in 3:
		await process_frame

	var mesh_after: Variant = _find_mesh_visible(target)
	print("After my.invisible=off: node.visible=%s mesh_visible=%s" % [target.visible, mesh_after])

	var ok: bool = (mesh_after == true)
	print("OK" if ok else "FAIL: mesh still hidden after invisible=off")
	quit(0 if ok else 1)


func _find_mesh_visible(n: Node) -> Variant:
	if n is MeshInstance3D:
		return (n as MeshInstance3D).visible
	for c in n.get_children():
		var r = _find_mesh_visible(c)
		if r != null:
			return r
	return null
