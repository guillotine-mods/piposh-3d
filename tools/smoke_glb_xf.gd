extends SceneTree
func _init():
	var packed = load("res://assets/converted/mdl/Ami.glb") as PackedScene
	var inst = packed.instantiate()
	_dump(inst, "")
	# Also PipDog
	packed = load("res://assets/converted/mdl/PipDog.glb") as PackedScene
	inst = packed.instantiate()
	print("--- PipDog ---")
	_dump(inst, "")
	quit()
func _dump(n, ind):
	if n is Node3D:
		var n3 = n as Node3D
		print(ind, n.name, " pos=", n3.position, " rot=", n3.rotation_degrees, " scale=", n3.scale)
	else:
		print(ind, n.name, " (", n.get_class(), ")")
	for c in n.get_children():
		_dump(c, ind + "  ")
