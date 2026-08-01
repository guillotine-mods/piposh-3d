extends SceneTree
## Dumps Krup2.glb's scene tree to find a possible separate "stars"
## impact-effect mesh -- investigating the 2026-08-01 report that a
## "stars" effect during Krupnik's hammer animation renders "a bit
## behind him instead of where the hammer animation happens."
##
## Run: godot --headless --path . -s res://tools/smoke_krup2_mesh_dump.gd

func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var packed: PackedScene = load("res://assets/converted/mdl/Krup2.glb")
	if packed == null:
		print("FAIL: could not load Krup2.glb")
		quit(1)
		return
	var inst: Node = packed.instantiate()
	root.add_child(inst)
	_dump(inst, 0)
	quit(0)


func _dump(n: Node, depth: int) -> void:
	var indent := "  ".repeat(depth)
	var extra := ""
	if n is Node3D:
		extra = " pos=%s" % (n as Node3D).position
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		extra += " mesh=%s skeleton_path=%s skin=%s" % [
			(mi.mesh.resource_path if mi.mesh else "null"), mi.skeleton, mi.skin
		]
	print("%s%s (%s)%s" % [indent, n.name, n.get_class(), extra])
	for c in n.get_children():
		_dump(c, depth + 1)
