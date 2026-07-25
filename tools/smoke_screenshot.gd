extends SceneTree
## Load Studio, snap camera, write a PNG for visual QA.


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Node3D.new()
	root.add_child(host)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.15, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 1.0
	we.environment = env
	host.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 0.8
	host.add_child(sun)

	var loader_scr: GDScript = load("res://scripts/engine/wmb_level_loader.gd")
	var loader: Node = loader_scr.new()
	host.add_child(loader)
	await process_frame
	loader.call("load_level", "Studio")

	var cam := Camera3D.new()
	cam.current = true
	cam.far = 12000
	cam.fov = 60
	host.add_child(cam)

	# Use TheCam2 pose from level if present
	var ents: Node = loader.get_node("Entities")
	var the_cam2: Node3D = null
	var ami: Node3D = null
	for n in ents.get_children():
		var a := str(n.get_meta("action", ""))
		if a == "TheCam2":
			the_cam2 = n
		elif a == "Ami":
			ami = n
	if the_cam2:
		cam.global_transform = the_cam2.global_transform
	elif ami:
		cam.global_position = ami.global_position + Vector3(0, 80, 200)
		cam.look_at(ami.global_position + Vector3(0, 40, 0), Vector3.UP)

	# Let animator settle one frame
	for _i in 8:
		await process_frame

	var vp := root.get_viewport()
	vp.size = Vector2i(1280, 720)
	await process_frame
	await process_frame
	var img: Image = vp.get_texture().get_image()
	var out := "res://tools/studio_shot.png"
	# user:// is safer for write
	var path := "user://studio_shot.png"
	img.save_png(path)
	var abs_path := ProjectSettings.globalize_path(path)
	# also copy beside tools
	var dest := "e:/development/piposh_remasters/piposh_3d_alpha_godot/tools/studio_shot.png"
	img.save_png(dest)
	print("Wrote screenshot ", dest, " ami=", ami != null, " cam2=", the_cam2 != null)
	if ami:
		print("  ami pos=", ami.global_position, " scale=", ami.scale, " rot=", ami.rotation_degrees)
		var mi := _find_mesh(ami)
		if mi:
			print("  mesh aabb=", mi.get_aabb(), " global=", mi.global_transform.origin)
	quit(0)


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var m := _find_mesh(c)
		if m:
			return m
	return null
