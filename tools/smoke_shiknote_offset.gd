extends SceneTree
## Quantifies the 2026-07-31 "poster is a bit lower" fix: prints how far
## ShikNote's clickable Area3D center is being nudged from the raw entity
## origin, to confirm there really was a meaningful mismatch.
##
## Run: godot --headless --path . -s res://tools/smoke_shiknote_offset.gd

const LEVEL := "Studio"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	await process_frame
	await process_frame
	await process_frame

	var loader: Node = runner.get("loader")
	var entities := loader.get_node_or_null("Entities")
	var shiknote: Node3D = null
	for n in entities.get_children():
		if n is Node3D and str(n.get_meta("action", "")) == "ShikNote":
			shiknote = n
			break
	if shiknote == null:
		print("FAIL: ShikNote not found")
		quit(1)
		return

	var area: Area3D = null
	for c in shiknote.get_children():
		if c is Area3D:
			area = c
			break
	if area == null:
		print("FAIL: no click area on ShikNote")
		quit(1)
		return
	var cs: CollisionShape3D = area.get_child(0)
	print("ShikNote origin=%s click-sphere local offset=%s (world=%s)" % [
		shiknote.global_position, cs.position, shiknote.to_global(cs.position)
	])
	print("Offset magnitude: %.2f units" % cs.position.length())
	quit(0)
