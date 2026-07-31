extends SceneTree
## Verifies the 2026-07-31 fix for "dialogue looping on the first part":
## `action Bumpin`'s `my.enable_entity/enable_push/enable_impact = on` used
## to be a total no-op (no entity-collision trigger existed at all), so
## `action Bumped` (which sets `Piposh.skill2 = 2`, the ONLY way
## `action Piposh2`'s state machine ever leaves its first dialogue prompt)
## could never fire through normal gameplay. Confirms the entity now has a
## real impact-trigger Area3D, and that simulating the player entering it
## correctly invokes `Bumped` and sets `Piposh.skill2 = 2`.
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_bumpin.gd

const LEVEL := "Shiks"


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

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null
	if interp == null:
		print("FAIL: %s did not start the interpreter" % LEVEL)
		quit(1)
		return
	var player: Node3D = runner.get("player")
	if player == null:
		print("FAIL: no player node")
		quit(1)
		return
	print("player in group 'player': %s" % player.is_in_group("player"))

	var bumpin := _find_entity_by_action(runner, "Bumpin")
	if bumpin == null:
		print("FAIL: no 'Bumpin' entity found in Shiks")
		quit(1)
		return
	print("Bumpin entity: %s pos=%s" % [bumpin.name, bumpin.global_position])

	print("wdl_impact_area meta=%s children=%s" % [
		bumpin.has_meta("wdl_impact_area"),
		bumpin.get_children().map(func(c): return "%s(%s)" % [c.name, c.get_class()]),
	])
	var area: Node3D = null
	for c in bumpin.get_children():
		if c is Area3D:
			area = c
			break
	print("has impact area=%s" % (area != null))
	if area == null:
		print("FAIL: no impact-trigger Area3D was created")
		quit(1)
		return

	print("Piposh.skill2 before: %s" % _read_entity_skill2(interp, runner))

	print("-- Simulating player walking into Bumpin's trigger area --")
	interp.call("_on_impact_body_entered", player, bumpin)
	await process_frame
	await process_frame

	var skill2_after: Variant = _read_entity_skill2(interp, runner)
	print("Piposh.skill2 after: %s" % skill2_after)
	var ok: bool = skill2_after == 2.0
	print("OK" if ok else "FAIL: Piposh.skill2 never became 2 -- Bumped didn't fire")
	quit(0 if ok else 1)


func _read_entity_skill2(interp: Node, runner: Node) -> Variant:
	var piposh := _find_entity_by_action(runner, "Piposh2")
	if piposh == null:
		return null
	var arr: Array = piposh.get_meta("wdl_skills", [])
	if arr.size() < 2:
		return 0.0
	return arr[1]


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
