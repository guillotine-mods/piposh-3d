extends SceneTree
## Batch facing check: lays out many MDL->GLB models in a grid, each with a
## bright reference arrow at its feet pointing toward world +X (the
## "authored forward" direction the whole pipeline assumes). One screenshot
## shows many models at once instead of testing one at a time via
## smoke_orient.gd -- for spotting facing outliers across the roster.
##
## Standalone -- does not touch the main game scenes or runtime scripts.
##
## `--headless` alone forces Godot's dummy/null rendering driver, which never
## produces real pixels (Viewport.get_texture() comes back null) -- pass
## --rendering-driver opengl3 alongside it to keep a real (offscreen)
## rasterizer without popping up a window. If that still errors on your
## setup, drop --headless entirely (a window briefly appears, then closes
## itself via quit()).
##
## Usage:
##   godot --headless --rendering-driver opengl3 -s res://tools/gallery_facing.gd -- <Stem1> <Stem2> ...
##   godot --headless --rendering-driver opengl3 -s res://tools/gallery_facing.gd -- --all
##   godot --headless --rendering-driver opengl3 -s res://tools/gallery_facing.gd -- --page 0 --page-size 36
##   (fallback if the above errors)  godot -s res://tools/gallery_facing.gd -- Yachdal Crowd Crowd2 Genia
##
## With --all (or no args), auto-discovers every model with a .mdlanim
## sidecar (the "character" roster: has Walk/Stand/Talk-style animation) and
## paginates into --page-size (default 36) per image, writing
## user://facing_gallery_<page>.png. Pass explicit stems to check a specific
## set (e.g. everything used in one level) in a single image instead.

const MDL_DIR := "res://assets/converted/mdl/"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var page := 0
	var page_size := 36
	var explicit: Array[String] = []
	var want_all := argv.is_empty()
	var i := 0
	while i < argv.size():
		var a := str(argv[i])
		if a == "--all":
			want_all = true
		elif a == "--page" and i + 1 < argv.size():
			page = int(argv[i + 1])
			i += 1
		elif a == "--page-size" and i + 1 < argv.size():
			page_size = int(argv[i + 1])
			i += 1
		else:
			explicit.append(a)
		i += 1

	var stems: Array[String] = explicit
	if want_all:
		stems = _discover_character_stems()
		print("Discovered %d character models (have a .mdlanim sidecar)." % stems.size())
		var start := page * page_size
		if start >= stems.size():
			print("Page %d is empty (only %d models total, page-size %d)." % [page, stems.size(), page_size])
			quit(1)
			return
		stems = stems.slice(start, mini(start + page_size, stems.size()))
		print("Rendering page %d: models %d..%d" % [page, start, start + stems.size() - 1])

	if stems.is_empty():
		print("No stems to render. Pass explicit names or --all.")
		quit(1)
		return

	var host := Node3D.new()
	root.add_child(host)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.1, 0.1, 0.12)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 1.1
	we.environment = env
	host.add_child(we)

	var cols := int(ceil(sqrt(float(stems.size()))))
	var loaded := 0
	var missing: Array[String] = []

	# Pass 1: load + instantiate everything first and measure each model's
	# own AABB (models vary wildly in size -- e.g. Genia's max extent is
	# ~573 units vs. Yachdal's ~223 -- a fixed cell size either crams small
	# models into nothing or lets one big model overflow into its neighbors
	# and swamp the whole shot, which is exactly what happened the first
	# time this ran). Cell size is derived from the actual batch, not a
	# guessed constant.
	var insts: Array[Node3D] = []
	var sizes: Array[Vector3] = []
	var kept_stems: Array[String] = []
	var max_extent := 1.0
	for stem in stems:
		var path := MDL_DIR + stem + ".glb"
		if not ResourceLoader.exists(path):
			missing.append(stem)
			continue
		var packed := load(path)
		if not (packed is PackedScene):
			missing.append(stem)
			continue
		var inst: Node3D = (packed as PackedScene).instantiate()
		host.add_child(inst)
		var aabb := _mesh_aabb_local(inst, Transform3D.IDENTITY, true)
		insts.append(inst)
		sizes.append(aabb.size)
		kept_stems.append(stem)
		max_extent = maxf(max_extent, maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z)))
		loaded += 1

	if missing.size() > 0:
		print("MISSING (no .glb, skipped): ", missing)

	var cell: float = max_extent * 1.6

	# Pass 2: position each model in its grid cell now that cell size is known.
	for idx in insts.size():
		var stem: String = kept_stems[idx]
		var col := idx % cols
		var row := idx / cols
		var origin := Vector3(float(col) * cell, 0.0, float(row) * cell)
		insts[idx].position = origin
		var model_h: float = sizes[idx].y

		# Reference arrow: a thin bar from the model's feet pointing +X, the
		# "authored forward" direction. Compare each character's own facing
		# (head/chest direction) against its own arrow.
		var arrow := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(cell * 0.55, 2.0, 4.0)
		arrow.mesh = box
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.15, 0.15)
		arrow.material_override = mat
		arrow.position = origin + Vector3(box.size.x * 0.5, 1.0, 0.0)
		host.add_child(arrow)

		var label := Label3D.new()
		label.text = stem
		label.font_size = 28
		label.pixel_size = 0.35
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.position = origin + Vector3(0.0, model_h + 30.0, 0.0)
		host.add_child(label)

	var grid_w: float = float(cols) * cell
	var rows := int(ceil(float(insts.size()) / float(cols)))
	var grid_h: float = float(rows) * cell
	var center := Vector3(grid_w * 0.5, 0.0, grid_h * 0.5)

	var cam := Camera3D.new()
	host.add_child(cam)
	cam.current = true
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = maxf(grid_w, grid_h) * 1.15
	cam.far = 20000.0
	# Straight overhead: +X reads left-to-right identically in every cell,
	# so a wrongly-facing character's silhouette visibly disagrees with its
	# own red reference arrow. Must add_child() before global_position/
	# look_at() -- both require the node to already be inside the tree
	# (need a parent transform to resolve "global").
	cam.global_position = center + Vector3(0.0, 3000.0, 0.0)
	cam.look_at(center, Vector3.BACK)

	for _i in 8:
		await process_frame
	var vp := root.get_viewport()
	var vp_h := 2000
	if grid_w > 0.0:
		vp_h = int(2000.0 * grid_h / grid_w)
	vp.size = Vector2i(2000, vp_h)
	await process_frame
	await process_frame

	var img: Image = vp.get_texture().get_image()
	var out := "user://facing_gallery_%d.png" % page
	img.save_png(out)
	print("Wrote ", ProjectSettings.globalize_path(out))
	print("Loaded %d/%d models. Compare each character's facing to its red arrow (+X)." % [loaded, stems.size()])
	quit(0)


func _discover_character_stems() -> Array[String]:
	var stems: Array[String] = []
	var dir := DirAccess.open(MDL_DIR)
	if dir == null:
		return stems
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if fn.ends_with(".mdlanim"):
			stems.append(fn.get_basename())
		fn = dir.get_next()
	stems.sort()
	return stems


func _mesh_aabb_local(node: Node, parent_xf: Transform3D, skip_node_xf: bool) -> AABB:
	## Local (untransformed-by-tree) AABB -- works before the node has a
	## global transform, i.e. before it's positioned in the grid.
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
