extends SceneTree
## Reported live (2026-08-10): "the Smash level still has the weird cloud
## artifacts" / Town's sky rendered as a flat wall of color instead of the
## real starry gradient. Root-caused (via direct isolation of AcknexSky's
## own cylinder/panorama, then a physics raycast fanned out from the live
## camera, then a corpus scan of every level's own `_brush.glb` materials)
## to `WmbLevelLoader._force_unshaded_if_needed()` rendering WMB brush
## surfaces that are meant to be an infinite-distance backdrop as ordinary
## opaque geometry. Three real, corpus-confirmed naming conventions mark
## such a surface in the original WMB/WED data: "sky*"/"z*SKY*" (skywhite,
## skyblue, zSKYNEW), French "ciel" ("sky"/"ceiling": CIEL, CIELIN,
## mansion_ciel), and a literal blank texture name in the source WMB
## texture lump (Godot's glTF importer labels the resulting anonymous
## material "#default" -- Town/Desert/MOI all have exactly this, always as
## a face sealing the level from above). This test checks that a live
## Town level -- which has both a "skywhite" surface and a blank-name
## "#default" ceiling surface -- gets a fully transparent override
## material on both, so AcknexSky's own procedural sky can show through.
##
## Run: godot --headless --path . -s res://tools/smoke_sky_brush_transparency_check.gd

const LEVEL := "Town"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)
	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	for i in 20:
		await process_frame

	var brush_node := runner.get_node_or_null("WmbLevelLoader/Geometry/Brush/Town") as MeshInstance3D
	if brush_node == null or brush_node.mesh == null:
		print("FAIL: Town brush MeshInstance3D not found")
		quit(1)
		return

	var checked := 0
	var failed := 0
	for i in brush_node.mesh.get_surface_count():
		# Look at the ORIGINAL glTF material's own name to decide whether
		# this surface SHOULD have been made transparent, independent of
		# whatever override is currently applied.
		var base_mat := brush_node.mesh.surface_get_material(i)
		var base_name := (base_mat.resource_name.to_lower() if base_mat else "")
		var should_be_sky := base_name.contains("sky") or base_name.contains("ciel") \
			or base_name == "" or base_name == "#default"
		if not should_be_sky:
			continue
		checked += 1
		var override := brush_node.get_surface_override_material(i)
		var ok := override != null and override is BaseMaterial3D \
			and (override as BaseMaterial3D).albedo_color.a < 0.01
		print("surf=%d base_name='%s' override=%s -> %s" % [i, base_name, override, ("OK" if ok else "FAIL")])
		if not ok:
			failed += 1

	print("checked=%d failed=%d" % [checked, failed])
	var pass_ok: bool = checked >= 2 and failed == 0
	print("OK" if pass_ok else "FAIL")
	quit(0 if pass_ok else 1)
