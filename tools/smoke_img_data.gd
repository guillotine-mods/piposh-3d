extends SceneTree
func _init():
	var img = Image.create(2,2,false,Image.FORMAT_RGBA8)
	print("has get_data=", img.has_method("get_data"))
	print("has get_data2=", "get_data" in img.get_method_list().map(func(m): return m.name) if false else true)
	var d = img.get_data()
	print("data size", d.size())
	quit()
