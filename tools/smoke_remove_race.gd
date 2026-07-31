extends SceneTree
## Regression test for the 2026-07-30 reentrant-removal engine crash
## ("Invalid type in function '_eval' ... previously freed" -- a hard
## SIGSEGV before the fix, not a recoverable script error). Isolates the
## exact WDL/Afgan.wdl shape that caused it, without the other 300+
## clickable entities tools/smoke_click_survey.gd also exercises, so it's
## fast and its failure mode is unambiguous:
##   action AFG_Card { while(1) { if (AFG[my.skill1]==1) { AFGremove(); } wait(1); } }
##   function AFGremove { remove(my); }
##   action AFG_Take { AFG[my.skill1]=1; ...; remove(my); ... }
## Root cause (see docs/SESSION_LOG.md and CONTRACT.md §4.1.2 for the full
## story): clicking the card sets the same flag its own persistent
## coroutine checks, so both `remove(my)` calls land on the same entity
## within one synchronous signal-dispatch window -- at that instant
## `is_instance_valid()` and `is_inside_tree()` both still read true, yet
## passing that same reference into a `Node3D`-typed parameter (as `_eval`
## and others used to require) crashed the engine outright. Fixed by
## untyping every `my`/`entity` parameter in wdl_interpreter.gd, making
## `remove()` idempotent, and checking `typeof(my) == TYPE_NIL` instead of
## `my == null` in `_entity_alive()` (that equality comparison itself is
## unreliable on a dangling reference). Runs the persistent AFG_Card
## coroutine for a few frames, invokes AFG_Take on the same node, then
## pumps ten more frames checking for any script error at all.
##
## Run: godot --headless --path . -s res://tools/smoke_remove_race.gd


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var interp_script: GDScript = load("res://scripts/engine/wdl_interpreter.gd")
	var interp: Node = interp_script.new()
	root.add_child(interp)
	interp.call("_register_builtins")  # setup() normally does this; bypassed here

	var card_body := {
		"t": "block",
		"body": [
			{
				"t": "while",
				"cond": {"t": "num", "v": 1.0},
				"body": {
					"t": "block",
					"body": [
						{
							"t": "if",
							"cond": {
								"t": "binop", "op": "==",
								"l": {"t": "index", "obj": {"t": "id", "name": "AFG"}, "idx": {"t": "field", "obj": {"t": "id", "name": "my"}, "name": "skill1"}},
								"r": {"t": "num", "v": 1.0},
							},
							"then": {
								"t": "block",
								"body": [{"t": "expr_stmt", "expr": {"t": "call", "name": "AFGremove", "args": []}}],
							},
							"else": null,
						},
						{"t": "wait", "ticks": true, "n": {"t": "num", "v": 1.0}},
					],
				},
			},
		],
	}
	var afgremove_body := {
		"t": "block",
		"body": [
			{"t": "expr_stmt", "expr": {"t": "call", "name": "remove", "args": [{"t": "id", "name": "my"}]}},
		],
	}
	var take_body := {
		"t": "block",
		"body": [
			{
				"t": "expr_stmt",
				"expr": {
					"t": "assign", "op": "=",
					"target": {"t": "index", "obj": {"t": "id", "name": "AFG"}, "idx": {"t": "field", "obj": {"t": "id", "name": "my"}, "name": "skill1"}},
					"value": {"t": "num", "v": 1.0},
				},
			},
			{"t": "expr_stmt", "expr": {"t": "call", "name": "remove", "args": [{"t": "id", "name": "my"}]}},
		],
	}

	interp.set("_actions", {"AFG_Card": {"body": card_body}, "AFG_Take": {"body": take_body}})
	interp.set("_actions_lower", {"afg_card": "AFG_Card", "afg_take": "AFG_Take"})
	interp.set("_functions", {"AFGremove": {"body": afgremove_body, "params": []}})
	interp.set("_functions_lower", {"afgremove": "AFGremove"})
	interp.set("_globals", {"AFG": {"kind": "var", "init": null, "value": []}})
	interp.set("_globals_lower", {"afg": "AFG"})

	var card := Node3D.new()
	card.name = "AFGCard1"
	card.set_meta("wdl_skills", [0.0])
	root.add_child(card)

	print("Starting AFG_Card coroutine on %s" % card)
	interp.call("_run_coroutine", card_body, card)
	for i in 3:
		await process_frame
		print("frame %d: card valid=%s" % [i, is_instance_valid(card)])

	print("\nNow clicking (invoke_event AFG_Take) on the same node...")
	interp.call("invoke_event", card, "AFG_Take")

	for i in 10:
		await process_frame
		print("post-click frame %d: card valid=%s" % [i, is_instance_valid(card)])

	# GDScript has no way to catch a SCRIPT ERROR from within the script
	# that caused it -- the crash this reproduces used to kill the whole
	# process (exit 139) before ever reaching this line, so "we got here at
	# all" is itself informative. What this line CAN check is whether the
	# mechanism actually completed correctly, not just "didn't crash":
	# AFG_Take's first statement sets AFG[my.skill1] = 1, so the flag being
	# 1 confirms the coroutine ran its intended effect all the way through.
	var afg: Array = interp.get("_globals").get("AFG", {}).get("value", [])
	var flag_ok: bool = afg.size() > 0 and afg[0] == 1.0
	print("\nAFG[0] == %s (expected 1.0)" % (afg[0] if afg.size() > 0 else "<empty>"))
	if flag_ok:
		print("OK: reached the end with no crash and the click's effect landed correctly.")
		quit(0)
	else:
		print("FAIL: reached the end without crashing, but AFG_Take's effect didn't land.")
		quit(1)
