extends SceneTree
## GB-6 regression check: user reported a visible, non-colliding, non-
## clickable "Piposh" character in Plane2 (a first-person level where the
## player IS Piposh). Root cause: WDL/move.wdl's real `player_move2()`
## (called every tick from `ACTION player_walk2`) has `if (MY.CLIENT==0)
## { player = ME; }` as its own first statement -- a genuine, intentional
## binding of the WDL `player` global to the first-person proxy entity,
## matching real Acknex's own built-in `player` pointer. Plane2.wdl's
## `action A1` (a Piposh stand-in for a specific third-person cutscene)
## writes `player.invisible = off;` in its own default/non-cutscene
## branch every tick -- harmless in the original engine (first-person
## rendering never draws the player's own body regardless of that flag),
## but in this port `invisible` is the ONLY thing keeping the FP body
## hidden (`_hide_meshes()`, spawn-time only), so that write directly
## un-hid it every tick. Fixed in `WdlInterpreter._set_field()`'s
## "invisible" case: skip the mesh-visibility toggle entirely when the
## write target is the first-person proxy node -- its visibility is a
## fixed, port-owned invariant once first-person is active.
##
## Run: godot --headless --path . -s res://tools/smoke_plane2_fpiposh_check.gd

const LEVEL := "Plane2"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)

	for i in 10:
		await process_frame
	await physics_frame
	await physics_frame

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var fp_proxy: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")).to_lower() == "player_walk2":
			fp_proxy = n
			break
	if fp_proxy == null:
		print("FAIL: no player_walk2 (first-person proxy) entity found")
		quit(1)
		return

	# Let action A1's own coroutine tick several times (it writes
	# `player.invisible = off;` every tick in its default branch) --
	# the bug only shows up after this has had a chance to run.
	for i in 30:
		await process_frame

	var mesh_visible := false
	for c in fp_proxy.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).visible:
			mesh_visible = true
		for gc in c.get_children():
			if gc is MeshInstance3D and (gc as MeshInstance3D).visible:
				mesh_visible = true

	print("fp_proxy=%s mesh_visible=%s" % [fp_proxy.name, mesh_visible])
	print("FAIL: first-person proxy mesh is visible" if mesh_visible else "OK")
	quit(1 if mesh_visible else 0)
