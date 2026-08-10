extends SceneTree
## Diagnostic for the 2026-07-31 report ("coroutines take a lot of time to
## start" + "Ami Studio stays in a loop without moving to the next part")
## around clicking the ShikNote entity (action ShikNote -> event ShikKlik).
## ShikKlik plays 4 voice lines gated by `while (GetPosition(Voice) <
## 1000000) { wait(1); }`, then calls `Run ("Shiks.exe")`. Naknik's action
## ALSO polls `GetPosition(Voice)` every frame in its own outer loop
## (`if (GetPosition(Voice) >= 1000000) { Scene = Scene + 1; SetVoice(); }`)
## for its own, unrelated purpose -- two independent coroutines sharing one
## Voice-finished signal, the same failure class as the Start LookAtMe race
## (docs/SESSION_LOG.md 2026-07-30), just with different entities. Traces
## Talking/Scene/DialogIndex and whether Run() actually fires (LevelRouter
## target / interpreter `_running`) over real time to see exactly where (if
## anywhere) it stalls.
##
## Run: godot --headless --path . -s res://tools/smoke_studio_shikklik.gd

const LEVEL := "Studio"
const FRAMES := 2400  # 40s @ 60fps -- 4 short voice lines plus margin


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

	# Skip the Genia dialogue tree entirely (irrelevant to this bug) -- land
	# straight in Naknik's own steady-state loop, same as real gameplay after
	# the player finishes talking to Ami.
	interp.call("_set_var", "Scene", 3.0, null)
	interp.call("_set_var", "DialogIndex", -1.0, null)
	interp.call("_set_var", "Talking", 0.0, null)
	for i in 5:
		await process_frame

	var shiknote := _find_entity_by_action(runner, "ShikNote")
	if shiknote == null:
		print("FAIL: ShikNote entity not found in Studio")
		quit(1)
		return
	print("ShikNote found: %s" % shiknote.name)

	print("\n-- Invoking ShikKlik (simulated click) --")
	interp.call("invoke_event", shiknote, "ShikKlik")

	var audio := root.get_node("AudioChannels")
	var last_talking: Variant = null
	var last_scene: Variant = null
	var run_fired := false
	var router := root.get_node_or_null("LevelRouter")
	var t0 := Time.get_ticks_msec()
	for i in FRAMES:
		await process_frame
		var talking: Variant = _read_global(interp, "talking")
		var scene: Variant = _read_global(interp, "scene")
		var running: bool = interp.get("_running")
		if talking != last_talking or scene != last_scene:
			var elapsed_ms := Time.get_ticks_msec() - t0
			print(
				"frame=%4d (%.2fs real, %.2fs wall) talking=%s->%s scene=%s->%s voice_playing=%s voice_progress=%s running=%s"
				% [i, i / 60.0, elapsed_ms / 1000.0, last_talking, talking, last_scene, scene,
				   audio.call("is_voice_playing"), audio.call("get_voice_progress"), running]
			)
			last_talking = talking
			last_scene = scene
		if not running:
			print("frame=%d: interpreter _running=false (Run() fired)" % i)
			run_fired = true
			break
		if i % 300 == 0:
			print(
				"  ...heartbeat frame=%4d talking=%s scene=%s voice_playing=%s voice_progress=%s"
				% [i, talking, scene, audio.call("is_voice_playing"), audio.call("get_voice_progress")]
			)

	if router:
		print("LevelRouter present, target-ish state: %s" % [router])
	print("\nrun_fired=%s final talking=%s scene=%s" % [run_fired, last_talking, last_scene])
	print("Done (diagnostic, not pass/fail).")
	quit(0 if run_fired else 1)


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
