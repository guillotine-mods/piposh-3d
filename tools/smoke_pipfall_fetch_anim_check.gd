extends SceneTree
## Reported live (2026-08-08, follow-up to GB-15): "piposh character's
## animation to move isn't correct it looks like he's walking" during
## Plane3's vase-catch flight. Root cause: `action PipFall`'s own script
## calls `ent_frame("Fetch", my.skill1)` (the correct reach pose) and,
## the same tick, `actor_move()` -- whose generic `wdl_auto_walk_anim`
## fallback (added for Plane's own PiposhWalk, GB unnumbered 2026-08-01)
## unconditionally overwrote it with a "Walk" cycle every tick.
##
## Fixed by excluding "Stand" (the corpus-wide idle/default reset pose,
## confirmed via a corpus grep as the single most common ent_frame
## target -- every Blink() variant that touches animation uses exactly
## this name) from counting as a "real" pose for fallback-suppression
## purposes, while any OTHER named pose (this test's own "Fetch") still
## correctly suppresses the generic walk fallback. Verified this doesn't
## regress the ORIGINAL case this fallback exists for via
## smoke_plane_walk_anim.gd (Plane's own PiposhWalk, whose Blink() calls
## ent_frame("Stand",0) unconditionally every tick) -- both must pass.
##
## Run: godot --headless --path . -s res://tools/smoke_pipfall_fetch_anim_check.gd

const LEVEL := "Plane3"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)

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
	var pipfall: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "PipFall":
			pipfall = n
			break
	if pipfall == null:
		print("FAIL: PipFall entity never spawned")
		quit(1)
		return

	# Let Yoyo climb naturally so we sample the real, sustained
	# "flying toward the vase" window (skill5==1, TheVase!=null, Stage<4).
	var saw_fetch := false
	var saw_walk := false
	for i in 900:
		await process_frame
		if not is_instance_valid(pipfall):
			break
		var anim = pipfall.get_node_or_null("MdlAnimator")
		var clip: String = str(anim.get("_current_clip")) if anim else ""
		if clip.to_lower() == "fetch":
			saw_fetch = true
		if clip.to_lower() == "walk":
			saw_walk = true
		if root.get_node("GameState").current_level != LEVEL:
			break

	print("saw_fetch=%s saw_walk=%s" % [saw_fetch, saw_walk])
	var ok: bool = saw_fetch and not saw_walk
	print("OK" if ok else "FAIL: expected Fetch pose during the flight, never a Walk cycle")
	quit(0 if ok else 1)
