extends SceneTree
## Verify imported Ami verts remap cleanly to mdlanim bind pose.


const MdlAnimator = preload("res://scripts/engine/mdl_animator.gd")

func _init() -> void:
	var packed := load("res://assets/converted/mdl/Ami.glb") as PackedScene
	var host := Node3D.new()
	host.add_child(packed.instantiate())
	var anim := MdlAnimator.new()
	host.add_child(anim)
	var ok := anim.setup_from_stem("Ami", host)
	print("setup_ok=", ok)
	var mi := _find_mesh(host)
	var verts: PackedVector3Array = (mi.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	# After setup bind-pose apply, verts should match mdlanim frame0 (via remap).
	var f := FileAccess.open("res://assets/converted/mdl/Ami.mdlanim", FileAccess.READ)
	f.get_buffer(4)
	f.get_32()
	var av := int(f.get_32())
	var fc := int(f.get_32())
	for _i in fc:
		f.get_buffer(16)
	var pbuf := f.get_buffer(av * 12)
	var max_d := 0.0
	var matched := 0
	for i in verts.size():
		var best := INF
		for j in av:
			var q := Vector3(
				pbuf.decode_float(j * 12),
				pbuf.decode_float(j * 12 + 4),
				pbuf.decode_float(j * 12 + 8)
			)
			best = minf(best, verts[i].distance_to(q))
		if best < 0.05:
			matched += 1
		max_d = maxf(max_d, best)
	print("mesh_verts=", verts.size(), " anim_verts=", av, " matched=", matched, " max_nearest=", max_d)
	quit(0 if matched == verts.size() and max_d < 0.05 else 1)


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var m := _find_mesh(c)
		if m:
			return m
	return null
