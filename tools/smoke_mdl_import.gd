extends SceneTree
## Headless: print imported Ami mesh vertex counts vs mdlanim.

func _init() -> void:
	var packed := load("res://assets/converted/mdl/Ami.glb") as PackedScene
	if packed == null:
		print("FAIL: Ami.glb load")
		quit(1)
		return
	var inst := packed.instantiate()
	var mi := _find_mesh(inst)
	if mi == null or mi.mesh == null:
		print("FAIL: no mesh")
		quit(1)
		return
	var am := mi.mesh as ArrayMesh
	print("surfaces=", am.get_surface_count())
	for s in am.get_surface_count():
		var arr := am.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx = arr[Mesh.ARRAY_INDEX]
		var uvs = arr[Mesh.ARRAY_TEX_UV]
		var idx_n := 0
		if idx is PackedInt32Array:
			idx_n = (idx as PackedInt32Array).size()
		elif idx is PackedInt64Array:
			idx_n = (idx as PackedInt64Array).size()
		print(
			"surf%d verts=%d idx=%d uvs=%s format=%s"
			% [s, verts.size(), idx_n, typeof(uvs), am.surface_get_format(s)]
		)
	# PipDog too
	packed = load("res://assets/converted/mdl/PipDog.glb") as PackedScene
	inst = packed.instantiate()
	mi = _find_mesh(inst)
	am = mi.mesh as ArrayMesh
	var arr2 := am.surface_get_arrays(0)
	print("PipDog verts=", (arr2[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
	quit(0)


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var m := _find_mesh(c)
		if m:
			return m
	return null
