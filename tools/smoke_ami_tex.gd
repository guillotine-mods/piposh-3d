extends SceneTree
func _init():
	print("Ami.skins exists=", FileAccess.file_exists("res://assets/converted/mdl/Ami.skins"))
	print("Ami.glb exists=", FileAccess.file_exists("res://assets/converted/mdl/Ami.glb"))
	var packed = load("res://assets/converted/mdl/Ami.glb") as PackedScene
	var inst = packed.instantiate()
	var mi = _find(inst)
	var mat = mi.get_active_material(0)
	print("mat=", mat)
	if mat is BaseMaterial3D:
		var bm = mat as BaseMaterial3D
		print("albedo_tex=", bm.albedo_texture)
		print("transparency=", bm.transparency)
		if bm.albedo_texture:
			var img = bm.albedo_texture.get_image()
			if img:
				print("tex size=", img.get_width(), "x", img.get_height(), " format=", img.get_format())
				# sample center-ish face pixel
				var c = img.get_pixel(80, 40)
				print("pixel(80,40)=", c)
				img.save_png("res://tools/_godot_ami_tex.png")
				print("saved godot tex")
	quit()
func _find(n):
	if n is MeshInstance3D: return n
	for c in n.get_children():
		var m = _find(c)
		if m: return m
	return null
