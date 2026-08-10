extends SceneTree
## GB-5 investigation: "after Piposh dies, animations keep playing instead
## of stopping, and the retry/skip buttons that should appear don't show."
## Checks the pRIP death screen specifically: does it become visible (already
## confirmed by smoke_range_shoot.gd), do its own BUTTON children (fRIP1
## "retry"/fRIP2 "map") get created, and do THEIR icons actually have a
## real texture -- likely affected by the same bmap-resolution gap as GB-4
## (`BUTTON 020,380,bRIPb1,bRIPb3,bRIPb1,fRIP1,NULL,NULL;` references bmap-
## declared icons the same way `Terr15.bmap = bTerrHit;` did).
##
## Run: godot --headless --path . -s res://tools/smoke_range_rip_check.gd

const LEVEL := "Range"


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

	interp.call("_set_var", "MoviePlaying", 0.0, null)
	interp.call("_call", "ShowPanel", [], null)
	for i in 5:
		await process_frame

	interp.call("_set_var", "Health", 0.0, null)
	for i in 15:
		await process_frame

	var panel_nodes: Dictionary = interp.get("_panel_nodes")
	var prip = panel_nodes.get("prip")
	if prip == null:
		print("FAIL: pRIP panel missing entirely")
		quit(1)
		return
	print("pRIP visible=%s" % prip.visible)

	var bg_tr: TextureRect = prip.get_meta("wdl_bmap_rect", null)
	var bg_tex := str(bg_tr.texture) if (bg_tr and bg_tr.texture) else "MISSING"
	print("pRIP background texture=%s" % bg_tex)

	var buttons: Array = []
	for c in prip.get_children():
		if String(c.name).begins_with("Button_"):
			buttons.append(c)
	print("pRIP button children found=%d: %s" % [buttons.size(), buttons.map(func(b): return b.name)])
	for b in buttons:
		var vis: bool = b.visible
		var has_tex := false
		for gc in b.get_children():
			if gc is TextureRect and (gc as TextureRect).texture != null:
				has_tex = true
		print("  %s visible=%s has_texture=%s global_rect=%s" % [b.name, vis, has_tex, b.get_global_rect()])

	print("Death global=%s" % interp.call("_get_var", "Death", null))

	quit(0)
