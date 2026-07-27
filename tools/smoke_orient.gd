extends SceneTree
## Orientation QA for ONE model. Converts "eyeball 640 models" into "open 1 png".
##
## `--headless` alone forces Godot's dummy/null rendering driver, which never
## produces real pixels (Viewport.get_texture() comes back null) -- pass
## --rendering-driver opengl3 alongside it to keep a real (offscreen)
## rasterizer without popping up a window. If that still errors on your
## setup, drop --headless entirely (a window briefly appears, then closes
## itself via quit()).
##
## Usage:
##   godot --headless --rendering-driver opengl3 -s res://tools/smoke_orient.gd -- Ami
##   (fallback if the above errors)  godot -s res://tools/smoke_orient.gd -- Ami
## Rebuild MDLs with `python tools/convert_mdl.py --fix-idpo --no-face-orient`,
## run this again, and compare user://orient_<model>.png front/back.
##
## Convention under test: entity local +X is Acknex "forward". The camera below
## sits on +X looking back toward -X, so a correctly-oriented character faces the
## camera. If the model shows its back, the axis map / winding is still wrong.

const MDL_DIR := "res://assets/converted/mdl/"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var model := "Ami"
	var argv := OS.get_cmdline_user_args()
	if argv.size() > 0:
		model = str(argv[0])

	var host := Node3D.new()
	root.add_child(host)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.12, 0.14)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 1.0
	we.environment = env
	host.add_child(we)

	var path := MDL_DIR + model + ".glb"
	if not ResourceLoader.exists(path):
		print("MISSING ", path)
		quit(1)
		return
	var inst: Node = (load(path) as PackedScene).instantiate()
	host.add_child(inst)

	var mi := _find_mesh(inst)
	if mi == null:
		print("NO MESH in ", model)
		quit(1)
		return
	var aabb := mi.get_aabb()
	var c := aabb.position + aabb.size * 0.5

	var cam := Camera3D.new()
	host.add_child(cam)
	cam.current = true
	cam.far = 12000
	# Sit on +X (Acknex forward) looking back at the model. Must add_child()
	# before global_position/look_at() -- both require the node already
	# inside the tree (need a parent transform to resolve "global").
	var dist := maxf(aabb.size.length(), 1.0) * 1.8
	cam.global_position = c + Vector3(dist, aabb.size.y * 0.15, 0)
	cam.look_at(c, Vector3.UP)

	for _i in 6:
		await process_frame
	var vp := root.get_viewport()
	vp.size = Vector2i(720, 720)
	await process_frame
	await process_frame

	var img: Image = vp.get_texture().get_image()
	var out := "user://orient_%s.png" % model
	img.save_png(out)
	print("Wrote ", ProjectSettings.globalize_path(out))
	print("  ", model, " aabb=", aabb, " longest_axis=", _longest_axis(aabb.size))
	print("  camera on +X (forward). Correct = model faces camera.")
	quit(0)


func _longest_axis(s: Vector3) -> String:
	if s.x >= s.y and s.x >= s.z:
		return "X"
	return "Y" if s.y >= s.z else "Z"


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var m := _find_mesh(c)
		if m:
			return m
	return null
