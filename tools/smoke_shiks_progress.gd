extends SceneTree
## Regression check for the 2026-07-30 "one correct vocal, then stuck in a
## loop" report on Shiks: Piposh2's own action walks forward
## (`actor_move()`) until `my.x > StandHerePoint`, then advances `Scene`
## from 1 to 2 and opens a dialogue choice. `actor_move()` being an
## unresolved-builtin no-op meant `my.x` never moved, so `Scene` never
## advanced. Checks Piposh2's actual x position and the `Scene` global over
## real time -- NOT camera position, which correctly stays static through
## this whole phase (MyCamera only starts flying once a later, still-
## unbridged WMB collision trigger fires -- a separate, bigger gap).
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_progress.gd

const LEVEL := "Shiks"
const FRAMES := 600  # 10s @ 60fps


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	await process_frame
	await process_frame
	await process_frame

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null
	if interp == null:
		print("FAIL: %s did not start the interpreter" % LEVEL)
		quit(1)
		return

	var piposh2 := _find_entity_by_action(runner, "Piposh2")
	if piposh2 == null:
		print("FAIL: no Piposh2 entity found in %s" % LEVEL)
		quit(1)
		return

	var x0 := piposh2.global_position.x
	var scene0: Variant = _read_global(interp, "scene")
	print("Initial: Piposh2.x=%.2f scene=%s" % [x0, scene0])

	var moved := false
	var advanced := false
	for i in FRAMES:
		await process_frame
		var x_now := piposh2.global_position.x
		var scene_now: Variant = _read_global(interp, "scene")
		if not moved and absf(x_now - x0) > 1.0:
			moved = true
			print("frame=%d: Piposh2.x=%.2f (moving)" % [i, x_now])
		if float(scene_now) != float(scene0):
			print("frame=%d: scene=%s (advanced from %s)" % [i, scene_now, scene0])
			advanced = true
			break

	if not moved:
		print("\nFAIL: Piposh2 never moved from its spawn x position -- actor_move() still not taking effect.")
		quit(1)
		return
	if not advanced:
		print(
			(
				"\nPARTIAL: Piposh2 is moving but Scene never advanced within %d frames -- "
				+ "may just need more time/distance, or a different blocker remains."
			) % FRAMES
		)
		quit(1)
		return

	print("\nOK: Piposh2 walked and Scene advanced -- dialogue progression is running.")
	quit(0)


func _find_entity_by_action(runner: Node, action_name: String) -> Node3D:
	var loader: Node = runner.get("loader")
	if loader == null:
		return null
	var entities := loader.get_node_or_null("Entities")
	if entities == null:
		return null
	for n in entities.get_children():
		if n is Node3D and str(n.get_meta("action", "")) == action_name:
			return n
	return null


func _read_global(interp: Node, name: String) -> Variant:
	var globals: Dictionary = interp.get("_globals")
	var lower: Dictionary = interp.get("_globals_lower")
	var canonical := name
	if lower.has(name):
		canonical = str(lower[name])
	if not globals.has(canonical):
		return null
	return globals[canonical].get("value")
