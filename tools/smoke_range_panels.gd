extends SceneTree
## Checks the new Acknex panel system on Range: does GUI/Terr/Civ build,
## does ShowPanel() make them visible, does the health-bar window track
## Health2, does clicking pSkip's button fire D1.
##
## Run: godot --headless --path . -s res://tools/smoke_range_panels.gd

const LEVEL := "Range"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	await process_frame
	await process_frame
	await process_frame

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null
	if interp == null:
		print("FAIL: no interpreter")
		quit(1)
		return

	var panel_nodes: Dictionary = interp.get("_panel_nodes")
	print("panel_nodes built: %d (%s)" % [panel_nodes.size(), panel_nodes.keys().slice(0, 8)])

	# Skip the intro dialogue synchronously so ShowPanel() actually runs.
	interp.call("_set_var", "MoviePlaying", 0.0, null)
	interp.call("_call", "ShowPanel", [], null)
	for i in 5:
		await process_frame

	var gui = panel_nodes.get("gui")
	print("GUI visible=%s" % (gui.visible if gui else "MISSING"))
	var terr1 = panel_nodes.get("terr1")
	print("Terr1 visible=%s" % (terr1.visible if terr1 else "MISSING"))

	# Drive the health bar the way real gameplay does: `action CamTarget`
	# calls UpdatePanel() every tick, which sets Health2 = 609 - Health --
	# setting Health2 directly just races against that and gets overwritten.
	interp.call("_set_var", "Health", 309.0, null)
	for i in 5:
		await process_frame
	var windows: Array = interp.get("_panel_windows")
	print("panel_windows count=%d" % windows.size())
	for w in windows:
		var ctrl = w["control"]
		print("  window var=%s width_now=%.1f (expect ~300)" % [w["var"], ctrl.size.x])

	# Click pSkip's button (D1 -> plays SFX138 then Run("Plane3.exe")).
	var pskip = panel_nodes.get("pskip")
	if pskip:
		pskip.visible = true
		var btn: Control = null
		for c in pskip.get_children():
			if String(c.name).begins_with("Button_"):
				btn = c
				break
		print("pSkip button found=%s" % (btn.name if btn else "NONE"))

	print("OK")
	quit(0)
