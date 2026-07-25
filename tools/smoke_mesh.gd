extends SceneTree
## Compare imported GLB mesh vs .mdlanim vertex counts / UV sanity.


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var fails := 0
	for stem in ["Ami", "PipDog", "Yachdal", "Cow"]:
		var glb := "res://assets/converted/mdl/%s.glb" % stem
		var anim := "res://assets/converted/mdl/%s.mdlanim" % stem
		if not ResourceLoader.exists(glb):
			print("FAIL missing glb ", stem)
			fails += 1
			continue
		var packed: PackedScene = load(glb)
		var inst := packed.instantiate()
		var mi := _find_mesh(inst)
		if mi == null or mi.mesh == null:
			print("FAIL no mesh ", stem)
			fails += 1
			continue
		var am := mi.mesh as ArrayMesh
		var arrays := am.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		print(
			"%s glb_verts=%d uvs=%d idx=%d mat=%s"
			% [stem, verts.size(), uvs.size(), idx.size(), str(mi.get_active_material(0) != null)]
		)
		if FileAccess.file_exists(anim):
			var f := FileAccess.open(anim, FileAccess.READ)
			f.get_buffer(4)
			f.get_32()
			var av := int(f.get_32())
			var af := int(f.get_32())
			print("  mdlanim verts=%d frames=%d match=%s" % [av, af, str(av == verts.size())])
			if av != verts.size():
				print("FAIL vertex count mismatch ", stem)
				fails += 1
		# UV range
		var umin := Vector2(999, 999)
		var umax := Vector2(-999, -999)
		for u in uvs:
			umin.x = minf(umin.x, u.x)
			umin.y = minf(umin.y, u.y)
			umax.x = maxf(umax.x, u.x)
			umax.y = maxf(umax.y, u.y)
		print("  uv range ", umin, " .. ", umax)
		inst.free()
	print("Mesh smoke failures=", fails)
	quit(1 if fails else 0)


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var m := _find_mesh(c)
		if m:
			return m
	return null
