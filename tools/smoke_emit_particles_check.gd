extends SceneTree
## Reported live (2026-08-09): "there's no animation of the pee when
## piposh pees" -- `action PipPee` (Smash.wdl) calls Acknex's own
## particle builtin, `emit 2,temp.x,stream;`, previously entirely
## unbridged (no interpreter handling for "emit" at all). Added a
## scoped-down particle system: `emit()` spawns real, physically-
## reasonable fading/scattering sprite particles at the given position
## instead of genuinely interpreting the named particle function's own
## MY_-prefixed-field body (see _do_emit()'s own docstring for why the
## full byte-faithful version is a much larger, separate undertaking).
##
## Verified: forcing Quick2=1 (PipPee's own reveal/emit condition) grows
## the active particle count over time, and stopping it (Quick2=0) lets
## every particle age out and get cleaned up, with no leaked nodes.
##
## Run: godot --headless --path . -s res://tools/smoke_emit_particles_check.gd

const LEVEL := "Smash"


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

	interp.call("_set_var", "Quick2", 1.0, null)
	for i in 60:
		await process_frame

	var particles: Array = interp.get("_particles")
	var grew: bool = particles.size() > 0
	print("particles after 60 frames of emitting=%d (expect > 0)" % particles.size())

	interp.call("_set_var", "Quick2", 0.0, null)
	for i in 120:
		await process_frame

	particles = interp.get("_particles")
	var cleaned_up: bool = particles.size() == 0
	print("particles after stopping + 120 frames=%d (expect 0 -- all aged out)" % particles.size())

	var ok: bool = grew and cleaned_up
	print("OK" if ok else "FAIL")
	quit(0 if ok else 1)
