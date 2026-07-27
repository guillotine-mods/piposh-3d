extends SceneTree
## Floor-snap QA: for each model, renders it BOTH as-authored (RAW, no snap)
## and after applying the exact `_should_feet_snap` / min-Y-to-origin math
## from scripts/engine/wmb_level_loader.gd, side by side with a floor-plane
## reference line at world Y=0. One screenshot answers "does this look right
## floating/hanging (legitimately excluded) or does it look wrong (should be
## snapped but isn't)?" instead of guessing per-model.
##
## Standalone -- does not touch the main game scenes or runtime scripts. The
## snap math below is copy-verified against wmb_level_loader.gd's
## _snap_mesh_feet_to_origin / _should_feet_snap; if that file changes, update
## this to match (this script does not import the real one -- SceneTree
## scripts can't easily reuse a Node-derived class's private funcs headless).
##
## `--headless` alone forces Godot's dummy/null rendering driver, which never
## produces real pixels (Viewport.get_texture() comes back null) -- pass
## --rendering-driver opengl3 alongside it to keep a real (offscreen)
## rasterizer without popping up a window. If that still errors on your
## setup, drop --headless entirely (a window briefly appears, then closes
## itself via quit()).
##
## Usage:
##   godot --headless --rendering-driver opengl3 -s res://tools/gallery_feet_snap.gd -- <Stem1> <Stem2> ...
##   godot --headless --rendering-driver opengl3 -s res://tools/gallery_feet_snap.gd
##     (default set: the 6 flagged-excluded stems + 5 known-good regression
##      guards, so you see both sides of the policy in one image)
##   (fallback if the above errors)  godot -s res://tools/gallery_feet_snap.gd
##
## Excluded-from-snap policy mirrored from _should_feet_snap (stem-based part
## only -- action-based exclusions don't apply to a bare model preview):
##   glass, b747, tv, island, headphone, biplane, biplane2, hanger, towerw,
##   dutyfree, afg, shiknote

const MDL_DIR := "res://assets/converted/mdl/"

const EXCLUDED_STEMS := [
	"glass", "b747", "tv", "island", "headphone",
	"biplane", "biplane2", "hanger", "towerw", "dutyfree", "afg", "shiknote",
]

# Left group: currently excluded from feet-snap (RAW==SNAPPED, since policy
# skips them) -- eyeball whether that's actually correct for each.
# Right group: known-good regression guards that DO get snapped -- shows the
# snap transform working correctly, for comparison.
const DEFAULT_STEMS := [
	"B747", "Tv", "Biplane", "Biplane2", "Hanger", "Towerw",
	"Sfan", "Curtain", "StudioL", "Shtomba", "Cockpit",
]


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var stems: Array[String] = []
	for a in argv:
		stems.append(str(a))
	if stems.is_empty():
		for s in DEFAULT_STEMS:
			stems.append(str(s))

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

	var cell := 260.0
	var loaded := 0
	var missing: Array[String] = []
	var report: Array[String] = []

	for idx in stems.size():
		var stem: String = stems[idx]
		var col := float(idx) * cell
		var path := MDL_DIR + stem + ".glb"
		if not ResourceLoader.exists(path):
			missing.append(stem)
			continue
		var packed := load(path)
		if not (packed is PackedScene):
			missing.append(stem)
			continue

		var excluded := stem.to_lower() in EXCLUDED_STEMS

		# RAW instance (front row, z=0) -- as-authored, no snap.
		var raw_inst: Node3D = (packed as PackedScene).instantiate()
		host.add_child(raw_inst)
		raw_inst.position = Vector3(col, 0.0, 0.0)

		var min_y := _compute_min_y(raw_inst)

		# SNAPPED instance (back row, z=cell) -- lift by -min_y like
		# _snap_mesh_feet_to_origin does, UNLESS the real policy would
		# exclude it, in which case draw it at the same raw position so the
		# two rows visibly match (this IS the current excluded behavior).
		var snap_inst: Node3D = (packed as PackedScene).instantiate()
		host.add_child(snap_inst)
		var snapped_y := 0.0 if excluded else -min_y
		snap_inst.position = Vector3(col, snapped_y, cell)

		report.append(
			"%s: min_y=%.2f excluded=%s -> %s"
			% [
				stem, min_y, excluded,
				("stays at raw Y (policy skips snap)" if excluded
					else "lifted %.2f to sit on floor" % (-min_y)),
			]
		)
		loaded += 1

		var label := Label3D.new()
		label.text = "%s\n%s" % [stem, "EXCLUDED" if excluded else "snapped"]
		label.font_size = 26
		label.pixel_size = 0.4
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.modulate = Color(1.0, 0.55, 0.2) if excluded else Color(0.4, 1.0, 0.5)
		label.position = Vector3(col, 140.0, 0.0)
		host.add_child(label)

	if missing.size() > 0:
		print("MISSING (no .glb, skipped): ", missing)

	# Floor plane reference at world Y=0, spanning both rows, so
	# above/below-floor is unambiguous in the render.
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	var width: float = maxf(cell * float(stems.size()), cell)
	plane.size = Vector2(width + cell, cell * 2.6)
	floor_mesh.mesh = plane
	var floor_mat := StandardMaterial3D.new()
	floor_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	floor_mat.albedo_color = Color(0.3, 0.35, 0.9, 0.35)
	floor_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	floor_mesh.material_override = floor_mat
	floor_mesh.position = Vector3(width * 0.5 - cell * 0.5, 0.0, cell * 0.5)
	host.add_child(floor_mesh)

	print("--- feet-snap gallery report ---")
	for line in report:
		print(line)
	print(
		"Front row (z=0) = RAW as-authored. Back row (z=%.0f) = what the real"
		% cell
	)
	print(
		"_should_feet_snap policy currently produces (orange label=excluded,"
		+ " stays raw; green label=snapped to blue floor plane)."
	)
	print(
		"Look for: an ORANGE model hanging visibly below/through the blue"
		+ " floor (wrongly excluded, like Cockpit used to be) vs sitting"
		+ " naturally on/above it (correctly excluded, e.g. a flying plane)."
	)

	var center_x := width * 0.5 - cell * 0.5
	var cam := Camera3D.new()
	host.add_child(cam)
	cam.current = true
	cam.far = 20000.0
	# Elevated 3/4 side view: vertical (Y) position relative to the floor
	# plane is the whole point, so keep tilt shallow rather than top-down.
	# Must add_child() before global_position/look_at() -- both require the
	# node already inside the tree (need a parent transform to resolve
	# "global").
	cam.global_position = Vector3(center_x, 260.0, -width * 0.55 - 400.0)
	cam.look_at(Vector3(center_x, 20.0, cell * 0.5), Vector3.UP)

	for _i in 8:
		await process_frame
	var vp := root.get_viewport()
	vp.size = Vector2i(2200, 1000)
	await process_frame
	await process_frame

	var img: Image = vp.get_texture().get_image()
	var out := "user://feet_snap_gallery.png"
	img.save_png(out)
	print("Wrote ", ProjectSettings.globalize_path(out))
	print("Loaded %d/%d models." % [loaded, stems.size()])
	quit(0)


func _compute_min_y(node_root: Node3D) -> float:
	## Mirrors wmb_level_loader.gd's _mesh_aabb_local + the min-corner-Y loop
	## in _snap_mesh_feet_to_origin, at identity root basis (pan/tilt/roll=0
	## for these bare model previews, matching how models spawn before any
	## WED per-entity rotation is applied).
	var aabb := _mesh_aabb_local(node_root, Transform3D.IDENTITY, true)
	if aabb.size.y <= 0.001:
		return 0.0
	var min_y := INF
	for i in 8:
		var corner := Vector3(
			aabb.position.x if (i & 1) == 0 else aabb.position.x + aabb.size.x,
			aabb.position.y if (i & 2) == 0 else aabb.position.y + aabb.size.y,
			aabb.position.z if (i & 4) == 0 else aabb.position.z + aabb.size.z
		)
		min_y = minf(min_y, corner.y)
	return 0.0 if min_y == INF else min_y


func _mesh_aabb_local(node: Node, parent_xf: Transform3D, skip_node_xf: bool) -> AABB:
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
