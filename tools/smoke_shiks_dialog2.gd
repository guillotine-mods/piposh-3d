extends SceneTree
## Regression check for the 2026-08-01 report: "the 2nd dialogue in Shiks
## level doesn't play, doesn't matter what I choose" (user-confirmed
## symptom: "choice box closes but total silence, nothing else happens").
## Drives dialogue 1 to completion FIRST (choice 1, the short single-line
## SHK004.WAV branch), matching the real game's sequencing, THEN
## transitions to dialogue 2 the same way `action MyCamera` really does
## (Piposh.skill2=4; DialogIndex=2; ShowDialog();) and clicks a choice.
##
## Investigated extensively (this test, smoke_shiks_chase.gd driving the
## real Bumped->waypoint-chase precondition chain, and the pre-existing
## smoke_shiks_dialog2_choice.gd covering the longer 8-line choice-2
## chain) without reproducing the reported silence: in every headless
## run, DialogIndex correctly reaches 2, the dialog box opens and closes
## correctly on click, and AudioChannels.get_voice_progress() climbs
## normally for the chosen line. Kept as permanent regression coverage
## for this exact sequencing (dialogue 1 -> dialogue 2), not as a
## reproduction of the original report.
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_dialog2.gd

const LEVEL := "Shiks"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)

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

	# --- Dialogue 1: Scene=2, DialogIndex=1, choice 1 (SHK004.WAV, single line) ---
	interp.call("_set_var", "Scene", 2.0, null)
	interp.call("_set_var", "DialogIndex", 1.0, null)
	interp.call("_call", "showdialog", [], null)
	for i in 10:
		await process_frame
	print("Dialogue 1: is_dialog_open=%s" % hud.call("is_dialog_open"))
	hud.call("_emit_choice", 1)
	print("Dialogue 1: clicked choice 1 (SHK004.WAV)")

	var audio: Node = root.get_node("AudioChannels")
	var finished := false
	for i in 900:  # up to 15s
		await process_frame
		if float(audio.call("get_voice_progress")) >= 1.0:
			finished = true
			print("Dialogue 1 line finished at frame %d" % i)
			break
	if not finished:
		print("Dialogue 1 line never finished in 15s (unexpected -- was fine standalone)")

	for i in 30:
		await process_frame
	print("After dialogue 1: DialogIndex=%s Scene=%s dialog_open=%s" % [
		interp.call("_get_var", "DialogIndex", null),
		interp.call("_get_var", "Scene", null),
		hud.call("is_dialog_open"),
	])

	# --- Now transition to dialogue 2 the way action MyCamera really does ---
	interp.call("_set_var", "DialogIndex", 2.0, null)
	interp.call("_call", "showdialog", [], null)
	for i in 10:
		await process_frame
	print("Dialogue 2: is_dialog_open=%s" % hud.call("is_dialog_open"))
	hud.call("_emit_choice", 1)
	print("Dialogue 2: clicked choice 1 (PIP017.WAV)")

	for i in 300:  # 5s
		await process_frame
		if i % 30 == 0:
			print("t=%.1fs Talking=%s progress=%s is_playing=%s generation=%s dialog_open=%s" % [
				i / 60.0,
				interp.call("_get_var", "Talking", null),
				audio.call("get_voice_progress"),
				audio.call("is_voice_playing"),
				audio.call("get_voice_generation"),
				hud.call("is_dialog_open"),
			])

	print("Done.")
	quit(0)
