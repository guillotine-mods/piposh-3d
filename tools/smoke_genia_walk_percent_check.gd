extends SceneTree
## Reported live (2026-08-09, follow-up): "still the animation of genia
## is not walking." `action WalkGeniaWalk` calls `Blink()` (->
## `ent_frame("Stand",0)` -> `play_frame()`, which unconditionally sets
## `_current_clip="Stand"`, `_playing=false`) every tick, immediately
## before its own `ent_cycle("Walk", my.skill1)` -- defeating
## `play_cycle()`'s own "already playing this clip, leave _process()'s
## natural per-frame advance alone" guard every single time. `my.skill1`
## is a plain, ever-growing accumulator with no wrap-around of its own
## (the standard corpus idiom, matching every other `ent_cycle(name,
## my.skillN)` caller) -- `clampf(percent, 0, 100)` meant once it first
## exceeded 100 (well under a second), every further tick force-reset
## `_percent` to exactly 100.0, freezing the pose for the rest of the
## walk. Fixed at the real source: `MdlAnimator.play_cycle()` now wraps
## via `fposmod` instead of clamping, so this (and any other corpus
## action with the same "another ent_frame call interleaved every tick"
## shape) animates continuously instead of freezing at the boundary.
##
## Run: godot --headless --path . -s res://tools/smoke_genia_walk_percent_check.gd

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

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var genia: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")).to_lower() == "walkgeniawalk":
			genia = n
			break
	if genia == null:
		print("FAIL: Genia entity not found")
		quit(1)
		return

	var anim = genia.get_node_or_null("MdlAnimator")
	if anim == null:
		print("FAIL: no MdlAnimator on Genia")
		quit(1)
		return

	var saw_wrap := false
	var last_percent := -1.0
	for i in 40:
		await process_frame
		var p: float = anim.get("_percent")
		if last_percent >= 0.0 and p < last_percent - 50.0:
			saw_wrap = true
		last_percent = p

	print("saw_wrap=%s last_percent=%s (expect wrap seen -- was frozen at 100.0 before the fix)" % [saw_wrap, last_percent])
	print("OK" if saw_wrap else "FAIL")
	quit(0 if saw_wrap else 1)
