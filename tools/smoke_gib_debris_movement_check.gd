extends SceneTree
## Reported live (2026-08-09): "the animation of the broken vase... is
## still incorrect" -- after GB-15 fixed _gib(20) actually spawning its
## 20 debris entities, they still sat motionless at the vase's exact
## spawn position instead of flying outward, reading as "the vase just
## vanishes" rather than a real explosion.
##
## Root cause: WDL/war.wdl's `_gib_action()` computes its own per-tick
## velocity into a plain array global (`abspeed[0]=...; abspeed[1]=...;
## abspeed[2]=...;`, declared `var abspeed[3];` in WDL/movement.wdl) and
## applies it via `MOVE ME,NULLSKILL,abspeed;`. `_vec_get()` (MOVE's own
## 3rd-argument reader) only ever handled the OTHER Acknex vector
## spelling -- a scratch var's own `.x`/`.y`/`.z` fields (`temp.x = ...`)
## -- so a bare array-style vector like `abspeed` fell through to
## Vector3.ZERO regardless of what the script had written into it.
## Fixed by having `_vec_get()` also check `_get_var()` for a plain
## Array value before giving up. Not gib-specific: this idiom also
## appears in Desert.wdl's own `_gib`-style debris action and
## WDL/auftrag.wdl's own `MY_SPEED`-driven movement.
##
## Verified: 20 gibbit entities spawned by _gib(20) all move a
## meaningful distance from their shared spawn point within a handful
## of frames, instead of staying frozen in place.
##
## Run: godot --headless --path . -s res://tools/smoke_gib_debris_movement_check.gd

const LEVEL := "Plane3"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	for i in 10:
		await process_frame

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null
	if interp == null:
		print("FAIL: no interpreter")
		quit(1)
		return

	interp.call("_set_var", "Stage", 2.0, null)
	interp.call("_set_var", "Scene", 9.0, null)
	interp.call("_call", "SetVoice", [], null)
	for i in 5:
		await process_frame
	var hud: Node = runner.get("_game_hud")
	hud.call("hide_dialog")
	hud.dialog_choice.emit(2)

	for i in 400:
		await process_frame
		if interp.call("_get_var", "Dude", null) == 2.0:
			break
	for i in 400:
		await process_frame
		var player_ref = interp.call("_get_var", "player", null)
		if player_ref != null and float(interp.call("_get_field", {"t": "id", "name": "player"}, "skill5", null)) == 1.0:
			break

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")

	var tracked := {}
	for i in 300:
		await process_frame
		for n in entities.get_children():
			var act := str(n.get_meta("action", ""))
			if act.to_lower() == "_gib_action" and not tracked.has(n.get_instance_id()):
				tracked[n.get_instance_id()] = n.global_position
		if tracked.size() >= 20:
			break

	if tracked.size() < 20:
		print("FAIL: only %d/20 gibbit entities spawned" % tracked.size())
		quit(1)
		return

	for i in 40:
		await process_frame

	var moved := 0
	for id in tracked:
		var n: Node3D = instance_from_id(id)
		if n == null or not is_instance_valid(n):
			continue
		if n.global_position.distance_to(tracked[id]) > 1.0:
			moved += 1

	print("moved=%d/%d" % [moved, tracked.size()])
	var ok: bool = moved >= 18  # allow a small margin for near-zero random velocities
	print("OK" if ok else "FAIL: debris didn't fly outward -- MOVE's own velocity read as zero")
	quit(0 if ok else 1)
