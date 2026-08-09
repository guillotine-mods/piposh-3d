extends SceneTree
## Reported live (2026-08-09, Smash playtest):
## 1. "standing Piposh... appears both falling and on the floor when the
##    game starts" -- action PipTalk (WED-authored visible, flags=256)
##    only ever revealed itself when MoviePhase==1||3 and only ever hid
##    itself when Ride>0 -- two independent, non-exhaustive conditions,
##    both false at level start, leaving WED's own raw "visible" flag in
##    effect the whole time action PiposhFall is also visible and
##    falling. Fixed by generalizing _seed_reveal_only_hidden()'s own
##    detection (_has_exhaustive_invisible_toggle() /
##    _has_unconditional_leading_invisible_set()) to recognize this
##    "staged reveal with a gap" shape, not just the original "never
##    hides at all" one.
## 2. "The Genia model is walking to the correct direction but facing
##    the wrong way" -- action WalkGeniaWalk moves via direct position
##    writes and never touches my.pan; WED authored angle_gs=[0,0,0],
##    which (per _do_actor_move()'s own pan convention) faces +Godot X,
##    not the character's own +Godot Z direction of travel. Fixed via a
##    targeted _seed_genia_facing() spawn-time correction (pan -= 90).
##
## Run: godot --headless --path . -s res://tools/smoke_smash_visuals_check.gd

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

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var piposhfall: Node3D = null
	var piptalk: Node3D = null
	var genia: Node3D = null
	for n in entities.get_children():
		var act := str(n.get_meta("action", "")).to_lower()
		if act == "piposhfall":
			piposhfall = n
		elif act == "piptalk":
			piptalk = n
		elif act == "walkgeniawalk":
			genia = n

	var ok := true

	if piposhfall == null or piptalk == null or genia == null:
		print("FAIL: expected entities not found (piposhfall=%s piptalk=%s genia=%s)" % [piposhfall, piptalk, genia])
		quit(1)
		return

	print("piposhfall visible=%s (expect true)" % piposhfall.visible)
	print("piptalk visible=%s (expect false -- was true before the fix)" % piptalk.visible)
	if not piposhfall.visible or piptalk.visible:
		ok = false

	var genia_pan: float = genia.get_meta("pan", 0.0)
	print("genia pan=%s (expect -90 -- was 0 before the fix)" % genia_pan)
	if absf(genia_pan - (-90.0)) > 0.01:
		ok = false

	print("OK" if ok else "FAIL")
	quit(0 if ok else 1)
