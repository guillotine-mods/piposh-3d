extends SceneTree
## Verify Ami feet land on Y=0 after snap helper logic.


func _init() -> void:
	var packed := load("res://assets/converted/mdl/Ami.glb") as PackedScene
	var root := Node3D.new()
	root.scale = Vector3(0.45, 0.45, 0.45)
	root.rotation_degrees = Vector3(0, -90, 0)
	root.position = Vector3(17, 0, 413)
	var inst: Node = packed.instantiate()
	root.add_child(inst)
	var aabb := _mesh_aabb_local(root, Transform3D.IDENTITY, true)
	print("aabb minY=", aabb.position.y, " sizeY=", aabb.size.y)
	root.position.y -= aabb.position.y * root.scale.y
	print("snapped origin Y=", root.position.y)
	var feet_world := root.position.y + aabb.position.y * root.scale.y
	print("feet world Y=", feet_world)
	quit(0 if absf(feet_world) < 0.5 else 1)


func _mesh_aabb_local(node: Node, parent_xf: Transform3D, skip_node_xf: bool) -> AABB:
	var xf := parent_xf
	if node is Node3D and not skip_node_xf:
		xf = parent_xf * (node as Node3D).transform
	var acc := AABB()
	var has := false
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			acc = xf * mi.mesh.get_aabb()
			has = true
	for c in node.get_children():
		var ca := _mesh_aabb_local(c, xf, false)
		if ca.size.x <= 0.0 and ca.size.y <= 0.0 and ca.size.z <= 0.0:
			continue
		if not has:
			acc = ca
			has = true
		else:
			acc = acc.merge(ca)
	return acc if has else AABB()
