extends SceneTree
## Compare imported GLB vertex count vs .mdlanim for character models.

func _init() -> void:
	var stems := ["Ami", "Piposh", "PipDog", "Yachdal", "Naknik", "Dummy", "StudioL", "Curtain"]
	for stem in stems:
		var glb := _find("res://assets/converted/mdl/", stem + ".glb")
		var anim := _find("res://assets/converted/mdl/", stem + ".mdlanim")
		if glb == "":
			print("MISSING_GLB ", stem)
			continue
		var packed = load(glb)
		if packed == null or not (packed is PackedScene):
			print("FAIL_LOAD ", stem)
			continue
		var inst: Node = (packed as PackedScene).instantiate()
		var mi := _find_mesh(inst)
		if mi == null or mi.mesh == null:
			print("NO_MESH ", stem)
			continue
		var am := mi.mesh as ArrayMesh
		var arr_count := 0
		if am and am.get_surface_count() > 0:
			var arrays := am.surface_get_arrays(0)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			arr_count = verts.size()
		var anim_verts := -1
		if anim != "":
			var f := FileAccess.open(anim, FileAccess.READ)
			if f:
				f.get_buffer(4)
				f.get_32()
				anim_verts = int(f.get_32())
		var surf := am.get_surface_count() if am else 0
		var mark := "OK" if arr_count == anim_verts or anim_verts < 0 else "MISMATCH"
		print("%s %s glb_arrays=%d mdlanim=%d surfaces=%d aabb=%s" % [
			mark, stem, arr_count, anim_verts, surf, mi.get_aabb().size
		])
	quit(0)


func _find(dir_path: String, name: String) -> String:
	var direct := dir_path + name
	if FileAccess.file_exists(direct):
		return direct
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return ""
	var want := name.to_lower()
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if fn.to_lower() == want:
			return dir_path + fn
		fn = dir.get_next()
	return ""


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var m := _find_mesh(c)
		if m:
			return m
	return null
