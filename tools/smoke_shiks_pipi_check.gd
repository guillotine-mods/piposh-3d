extends SceneTree
## NB-7 investigation: the bearing math checks out (CamShow=7's camera
## points almost dead-on at the far "Pipi"-action Piposh.MDL placement,
## matching Weasel's own near-perfect alignment for its own shot), and
## the WDL-level visibility trace shows it correctly becoming visible=true
## at CamShow==3 and staying that way. So if it's still not rendering for
## the pigeon shot, something at the mesh/spawn level must be wrong.
## Dumps mesh child count, scale, and hide-related meta for every "Pipi"
## placement right after spawn.
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_pipi_check.gd

const LEVEL := "Shiks"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var loader_script: GDScript = load("res://scripts/engine/wmb_level_loader.gd")
	var loader: Node = loader_script.new()
	root.add_child(loader)
	var ok: bool = loader.load_level(LEVEL)
	if not ok:
		print("FAIL: could not load %s" % LEVEL)
		quit(1)
		return

	var entities: Node = loader.get_node("Entities")
	for n in entities.get_children():
		var action := str(n.get_meta("action", ""))
		if action.to_lower() != "pipi":
			continue
		print("=== %s ===" % n.name)
		print("  global_position=%s scale=%s node.visible=%s" % [n.global_position, n.scale, n.visible])
		print("  flags=%s invisible_meta=%s passable_meta=%s" % [
			n.get_meta("flags", "?"), n.get_meta("invisible", "?"), n.get_meta("passable", "?")
		])
		print("  child_count=%d children=%s" % [n.get_child_count(), n.get_children()])
		for c in n.get_children():
			if c is MeshInstance3D:
				var mi := c as MeshInstance3D
				print("    MeshInstance3D visible=%s mesh=%s aabb=%s" % [mi.visible, mi.mesh, mi.get_aabb() if mi.mesh else "n/a"])
			for gc in c.get_children():
				if gc is MeshInstance3D:
					var mi2 := gc as MeshInstance3D
					print("    (nested) MeshInstance3D visible=%s mesh=%s aabb=%s" % [mi2.visible, mi2.mesh, mi2.get_aabb() if mi2.mesh else "n/a"])

	quit(0)
