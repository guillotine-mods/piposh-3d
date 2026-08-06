extends SceneTree
## "restarting the stage after dying should reset the enemies on screen
## as well." Forces a Terrorist into a live "hit and popped up" state
## (position moved, tilt/roll set, Pop=true), retries for real, and
## confirms the entity lands back at its exact spawn position/
## orientation with Pop/skin back to their spawn-time (unset) defaults.
##
## Run: godot --headless --path . -s res://tools/smoke_range_retry_entity_reset_check.gd

const LEVEL := "Range"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	for i in 5:
		await process_frame

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null
	if interp == null:
		print("FAIL: no interpreter")
		quit(1)
		return

	interp.call("_set_var", "MoviePlaying", 0.0, null)
	interp.call("_call", "ShowPanel", [], null)
	for i in 10:
		await process_frame

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var terrorist: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "Terrorist":
			terrorist = n
			break
	if terrorist == null:
		print("FAIL: no Terrorist entity")
		quit(1)
		return

	var spawn_pos: Vector3 = terrorist.get_meta("wdl_spawn_position", Vector3.INF)

	# Force it into a live "hit and popped up, mid-animation" state --
	# freeze first (pRIP visible) so the real coroutine can't race ahead
	# and overwrite these before the retry happens.
	interp.call("_set_field", {"t": "id", "name": "pRIP"}, "visible", 1.0, null)
	var type_terrorist = interp.call("_get_var", "typeTerrorist", null)
	interp.call("_set_field", {"t": "id", "name": "my"}, "Type", type_terrorist, terrorist)
	interp.call("_set_field", {"t": "id", "name": "my"}, "Pop", 1.0, terrorist)
	interp.call("_set_field", {"t": "id", "name": "my"}, "z", terrorist.global_position.z + 200.0, terrorist)
	interp.call("_set_field", {"t": "id", "name": "my"}, "tilt", 20.0, terrorist)
	interp.call("_set_field", {"t": "id", "name": "my"}, "roll", -20.0, terrorist)
	interp.call("_set_field", {"t": "id", "name": "my"}, "skin", 5.0, terrorist)
	for i in 3:
		await process_frame

	print("before retry: pos=%s tilt=%s Pop=%s skin=%s" % [
		terrorist.global_position,
		interp.call("_get_field", {"t": "id", "name": "my"}, "tilt", terrorist),
		interp.call("_get_field", {"t": "id", "name": "my"}, "Pop", terrorist),
		interp.call("_get_field", {"t": "id", "name": "my"}, "skin", terrorist),
	])

	# Retry for real (pRIP is already showing from the manual freeze above
	# -- HideRIP()'s own pRIP.visible=off is what triggers the reset).
	interp.call("_set_var", "MoviePlaying", 0.0, null)
	interp.call("invoke_event", null, "fRIP1")
	await process_frame

	var pos_after: Vector3 = terrorist.global_position
	var tilt_after = interp.call("_get_field", {"t": "id", "name": "my"}, "tilt", terrorist)
	var pop_after = interp.call("_get_field", {"t": "id", "name": "my"}, "Pop", terrorist)
	var skin_after = interp.call("_get_field", {"t": "id", "name": "my"}, "skin", terrorist)
	print("after retry: pos=%s tilt=%s Pop=%s skin=%s" % [pos_after, tilt_after, pop_after, skin_after])

	var ok: bool = (
		pos_after.is_equal_approx(spawn_pos)
		and is_equal_approx(float(tilt_after), 0.0)
		and float(pop_after) == 0.0
		and is_equal_approx(float(skin_after), 1.0)
	)
	print("OK" if ok else "FAIL: entity state didn't reset to spawn on retry")
	quit(0 if ok else 1)
