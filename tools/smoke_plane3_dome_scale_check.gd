extends SceneTree
## Reported live (2026-08-08): "the next stage [Plane3] is stuck --
## level loads but nothing moves/progresses." Root cause: Plane3's own
## `action Dome` (`BackDome.MDL`, scale 95.36) is the ONLY entity that
## polls `GetPosition(Voice)` and advances the `Scene` global every
## camera cut/dialogue/character state in the level gates on -- but
## `WmbLevelLoader._spawn_entity()`'s own `MAX_UNIFORM_SCALE` cap (64.0,
## meant to reject decorative skybox junk) silently rejected this
## entity before it ever spawned, so its coroutine never started and
## Scene sat frozen at 0 forever. Raised the cap to 100.0 (a corpus-wide
## survey found only one other placement above the old cap -- Mount's
## own BackDome at 197.82, `action=null`, unused by any script -- so
## this doesn't change that level's behavior at all).
##
## Confirms both halves: the Dome entity actually spawns now, and Scene
## genuinely advances past its stuck-at-0 starting value within a real
## simulated window.
##
## Run: godot --headless --path . -s res://tools/smoke_plane3_dome_scale_check.gd

const LEVEL := "Plane3"


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
	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	if interp == null:
		print("FAIL: no interpreter")
		quit(1)
		return

	var dome: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")).to_lower() == "dome":
			dome = n
			break
	if dome == null:
		print("FAIL: action Dome entity never spawned (MAX_UNIFORM_SCALE regression?)")
		quit(1)
		return
	print("Dome entity spawned: %s" % dome.name)

	var scene_before: float = interp.call("_get_var", "Scene", null)
	for i in 200:  # a bit over 3s @ 60fps -- Wait.wav is a few ms long
		await process_frame
	var scene_after: float = interp.call("_get_var", "Scene", null)
	print("Scene before=%.1f after=%.1f (expect after > 0, was stuck at 0 forever pre-fix)" % [scene_before, scene_after])

	var ok: bool = scene_after > 0.0
	print("OK" if ok else "FAIL: Scene never advanced -- Plane3's cutscene is still stuck")
	quit(0 if ok else 1)
