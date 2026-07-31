extends SceneTree
## Isolated unit test for the 2026-07-30 `.event`/`enable_click` fix,
## bypassing the full level (14 concurrent always-on Plane2 coroutines made
## tracing smoke_click_event.gd's output unreadable). Builds a WdlInterpreter
## directly with a synthetic two-statement action body -- no file I/O, no
## other entities, no other coroutines -- so the only thing that can produce
## output is the exact mechanism being tested.
##
## Run: godot --headless --path . -s res://tools/smoke_event_unit.gd


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var interp_script: GDScript = load("res://scripts/engine/wdl_interpreter.gd")
	var interp: Node = interp_script.new()
	root.add_child(interp)

	# Synthetic AST: action HP { Scene = 1; } -- exactly the shape
	# tools/parse_wdl.py produces, minus everything not needed for this test.
	var hp_body := {
		"t": "block",
		"body": [
			{
				"t": "expr_stmt",
				"expr": {
					"t": "assign", "op": "=",
					"target": {"t": "id", "name": "Scene"},
					"value": {"t": "num", "v": 1.0},
				},
			},
		],
	}
	interp.set("_actions", {"HP": {"body": hp_body}})
	interp.set("_globals", {"Scene": {"kind": "var", "init": null, "value": 0.0}})
	interp.set("_globals_lower", {"scene": "Scene"})

	print("Scene before invoke_event: %s" % interp.get("_globals")["Scene"]["value"])
	interp.call("invoke_event", null, "HP")
	print("Scene after invoke_event:  %s" % interp.get("_globals")["Scene"]["value"])

	if float(interp.get("_globals")["Scene"]["value"]) == 1.0:
		print("\nOK: invoke_event('HP') ran action HP's body and mutated Scene.")
		quit(0)
	else:
		print("\nFAIL: invoke_event did not run the action body.")
		quit(1)
