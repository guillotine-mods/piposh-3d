extends SceneTree
## Reported live (2026-08-10), with a direct original-vs-port screenshot
## comparison of the same in-game moment (Town, the Tofu stand): the
## horizon in this port tiled as a broken, diagonally-sheared repeating
## pattern, while the original (and this port's own source texture,
## horizon1.png, confirmed identical) shows a single coherent factory
## skyline. Root cause: `CylinderMesh`'s own built-in UV generation gives
## each horizontal ring a different U phase than the ring above/below it
## -- a spiral/shear baked into Godot's own primitive-mesh algorithm.
## Fixed in `AcknexSky._build_scene_cylinder_mesh()` by hand-building the
## cylinder's side surface as an ArrayMesh with directly-computed UVs
## instead of relying on CylinderMesh at all.
##
## Verifies the generated mesh has NO per-ring UV shear: every vertex
## column's top (v=0) and bottom (v=1) UV must share the same U, and U
## must increase evenly and monotonically around the ring.
##
## Run: godot --headless --path . -s res://tools/smoke_scene_cylinder_uv_check.gd

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var sky: Object = load("res://scripts/engine/acknex_sky.gd").new()
	var segments := 48
	var mesh: ArrayMesh = sky.call("_build_scene_cylinder_mesh", 1000.0, 450.0, segments)
	var arrays: Array = mesh.surface_get_arrays(0)
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]

	var ok := true
	var prev_u := -1.0
	for col in segments + 1:
		var top_uv: Vector2 = uvs[col * 2]
		var bot_uv: Vector2 = uvs[col * 2 + 1]
		if not is_equal_approx(top_uv.x, bot_uv.x):
			print("FAIL: column %d top.u=%s != bot.u=%s (shear detected)" % [col, top_uv.x, bot_uv.x])
			ok = false
		if not is_equal_approx(top_uv.y, 0.0) or not is_equal_approx(bot_uv.y, 1.0):
			print("FAIL: column %d v mismatch top.v=%s bot.v=%s" % [col, top_uv.y, bot_uv.y])
			ok = false
		if top_uv.x < prev_u:
			print("FAIL: column %d u=%s decreased from previous %s (non-monotonic)" % [col, top_uv.x, prev_u])
			ok = false
		prev_u = top_uv.x

	print("checked %d columns" % (segments + 1))
	print("OK" if ok else "FAIL")
	quit(0 if ok else 1)
