extends SceneTree
## GB-1 reproduction attempt: the user's real session picked choice 3 for
## dialogue 1 (not choice 1, which smoke_shiks_dialog2.gd already covers
## and which works fine), then choice 2 for dialogue 2 -- and got
## permanently stuck with `Piposh_mdl_001`'s voice-poll heartbeat frozen
## on the OLD generation (SHK007.WAV) the whole time, never reaching the
## DialogIndex==2 response code at all. Choice 3 uniquely sets
## `my.skill20 = 1`, which changes the shared post-response tail loop's
## behavior (drives a walk-away animation via actor_move()) -- this test
## checks whether that specific path is what breaks the voice-generation
## handoff into dialogue 2.
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_dialog2_choice3.gd

const LEVEL := "Shiks"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)

	var interp: Node = null
	var hud: Node = null
	for i in 5:
		await process_frame
		var director: Node = runner.get("_director")
		if director:
			interp = director.get("_wdl_interp")
			hud = director.get("_hud")
		if interp:
			break
	if interp == null:
		print("FAIL: no interpreter for %s" % LEVEL)
		quit(1)
		return

	for i in 30:
		await process_frame

	# --- Dialogue 1: Scene=2, DialogIndex=1, choice 3 (the walk-away branch) ---
	interp.call("_set_var", "Scene", 2.0, null)
	interp.call("_set_var", "DialogIndex", 1.0, null)
	interp.call("_call", "showdialog", [], null)
	for i in 10:
		await process_frame
	hud.call("_emit_choice", 3)
	print("Clicked choice 3 for dialogue 1")

	var audio: Node = root.get_node("AudioChannels")
	for i in 900:  # up to 15s -- both SHK007 and the tail loop need to clear
		await process_frame
		if i % 60 == 0:
			print("t=%.1fs progress=%.3f is_playing=%s" % [
				i / 60.0, audio.call("get_voice_progress"), audio.call("is_voice_playing")
			])

	# --- Now transition to dialogue 2 the way action MyCamera really does ---
	interp.call("_set_var", "DialogIndex", 2.0, null)
	interp.call("_call", "showdialog", [], null)
	for i in 10:
		await process_frame
	print("is_dialog_open before click 2: %s" % hud.call("is_dialog_open"))
	hud.call("_emit_choice", 2)
	print("Clicked choice 2 for dialogue 2 (PIP019.WAV)")

	for i in 300:  # 5s
		await process_frame
		if i % 30 == 0:
			print("t2=%.1fs progress=%.3f is_playing=%s dialog_open=%s" % [
				i / 60.0, audio.call("get_voice_progress"), audio.call("is_voice_playing"),
				hud.call("is_dialog_open"),
			])

	print("Done.")
	quit(0)
