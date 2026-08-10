extends SceneTree
## Reported live (2026-08-10): "there's an animation that should run on
## a big screen in the smash WDL that's just a single picture now."
## Traced to Smash.wdl's own wart mini-game: `create(<Wart.pcx>,camera.x,
## Warty);` -- a real, active corpus usage of Acknex's "spawn a billboard
## sprite, not a full 3D model" create() idiom (also used, unreached in
## this game's actual level scripts, by WDL/doors.wdl/venture.wdl/war.wdl)
## -- silently failed every time, since `_do_create()` only ever resolved
## its 1st argument against `assets/converted/mdl/{stem}.glb`. A `.pcx`
## argument with no matching GLB returned null unconditionally, so the
## whole "screen" (really the special camera view this scene cuts to)
## showed nothing moving except the wart-counter panel icon (which
## already worked correctly via the pre-existing panel-bmap bridge).
##
## Verifies `create()` with a bitmap argument spawns a real, visible
## billboard Sprite3D using the resolved texture, and that its own
## `action Warty` coroutine still starts and runs normally (generic
## entity-field writes work the same on a sprite entity as an MDL one).
##
## Run: godot --headless --path . -s res://tools/smoke_bitmap_create_check.gd

const LEVEL := "Smash"

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

	var interp: Node = runner.get("_director").get("_wdl_interp")
	# action Warty's own `while(Warts>0){...} remove(my);` tail means it
	# self-destructs immediately unless Warts is genuinely positive --
	# matching the real script's own `Warts=100;` before it ever calls
	# create() for this action.
	interp.call("_set_var", "Warts", 100.0, null)
	var inst = interp.call("_do_create", ["Wart.pcx", null, "Warty"], null)
	if inst == null:
		print("FAIL: create() with a bitmap argument returned null")
		quit(1)
		return

	var is_sprite := inst is Sprite3D
	var has_tex: bool = is_sprite and (inst as Sprite3D).texture != null
	var is_billboard: bool = is_sprite and (inst as Sprite3D).billboard == BaseMaterial3D.BILLBOARD_ENABLED
	print("inst=%s is_sprite=%s has_tex=%s billboard=%s" % [inst, is_sprite, has_tex, is_billboard])

	# action Warty's own coroutine should have started synchronously (runs
	# up to its own first wait()) and moved the entity off the identity
	# origin via its own my.x/y/z=random(...) init.
	for i in 5:
		await process_frame
	var moved_from_origin: bool = inst.global_position.length() > 0.5
	print("pos=%s moved_from_origin=%s" % [inst.global_position, moved_from_origin])

	var ok: bool = is_sprite and has_tex and is_billboard and moved_from_origin
	print("OK" if ok else "FAIL")
	quit(0 if ok else 1)
