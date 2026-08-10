extends SceneTree
## Reported live (2026-08-10): "the pee animation is still not working
## right." The emit() bridge (see wdl_interpreter.gd's own docstring on
## _do_emit) worked functionally but rendered every particle effect
## corpus-wide with the same generic bluish soft-dot sprite, since
## genuinely interpreting a particle function's own per-particle WDL body
## is out of scope. Fixed by statically reading the particle action's own
## `MY_MAP = <bmap>;` assignment off its AST (not executing it) and
## resolving that bitmap through the same `_resolve_bmap_texture()` every
## panel/HUD bitmap already uses -- see
## _get_particle_texture_for_action()'s own docstring.
##
## Verifies Smash's own `stream()` (Piposh's pee particle function) now
## resolves to the real Pee.png bitmap instead of the generic fallback dot.
##
## Run: godot --headless --path . -s res://tools/smoke_particle_texture_check.gd

const LEVEL := "Smash"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)
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

	var tex: Texture2D = interp.call("_get_particle_texture_for_action", "stream")
	var generic: Texture2D = interp.call("_get_particle_texture")
	var is_real := tex != null and tex != generic
	var path_ok := is_real and String(tex.resource_path).to_lower().ends_with("pee.png")
	print("resolved=%s path=%s" % [is_real, tex.resource_path if tex else "<null>"])

	# An action with no MY_MAP assignment (or an unresolvable one) must
	# still fall back to the generic dot, never null/crash.
	var fallback: Texture2D = interp.call("_get_particle_texture_for_action", "no_such_particle_fn")
	var fallback_ok := fallback == generic

	var ok: bool = path_ok and fallback_ok
	print("OK" if ok else "FAIL")
	quit(0 if ok else 1)
