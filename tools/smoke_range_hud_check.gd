extends SceneTree
## GB-4 investigation: "shooting a terrorist or civilian doesn't update the
## HUD hurt count, so we can't win." Isolates the hit -> counter -> panel
## pipeline from aiming/bullet-travel (already covered by
## smoke_range_shoot.gd): force one Terrorist-action entity into a hittable
## state matching a real "pop up" (my.Pop = True, my.Type = typeTerrorist),
## call action TargetHit directly on it, then check whether (a) the
## `Terrorists` global actually decremented and (b) the Terr1 panel's real
## displayed texture actually changed to bTerrHit.
##
## Run: godot --headless --path . -s res://tools/smoke_range_hud_check.gd

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

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var terrorist: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "Terrorist":
			terrorist = n
			break
	if terrorist == null:
		print("FAIL: no Terrorist entity found")
		quit(1)
		return

	var terr_before: float = interp.call("_get_var", "Terrorists", null)
	var civ_before: float = interp.call("_get_var", "Civilians", null)
	print("before: Terrorists=%s Civilians=%s" % [terr_before, civ_before])

	# Match a REAL "pop up" (action Terrorist's own while(1) loop, lines
	# 705-727): both my.Type and my.Pop get set together there. Setting
	# only Pop (as an earlier version of this test did) leaves my.Type at
	# its action-entry default (typeCivilian, line 679) -- action
	# TargetHit then correctly decrements Civilians, not Terrorists. Not
	# a bug; a test mistake, caught by checking both counters here.
	var type_terrorist = interp.call("_get_var", "typeTerrorist", null)
	interp.call("_set_field", {"t": "id", "name": "my"}, "Type", type_terrorist, terrorist)
	interp.call("_set_field", {"t": "id", "name": "my"}, "Pop", 1.0, terrorist)
	interp.call("invoke_event", terrorist, "TargetHit")
	for i in 10:
		await process_frame

	var terr_after: float = interp.call("_get_var", "Terrorists", null)
	var civ_after: float = interp.call("_get_var", "Civilians", null)
	print("after: Terrorists=%s Civilians=%s (expect Terrorists one less, Civilians unchanged)" % [terr_after, civ_after])

	# Let action CamTarget's own while(1) loop call updatepanel() a few more
	# times (it already runs every tick once CamTarget's coroutine starts).
	for i in 10:
		await process_frame

	# Direct, isolated check of the assignment mechanism itself, bypassing
	# UpdatePanel() entirely: does `Terr15.bmap = bTerrHit;`, invoked
	# exactly the way the interpreter would from that WDL line, actually
	# change the rendered texture?
	var bterrhit_val = interp.call("_get_var", "bTerrHit", null)
	print("bTerrHit global value=%s" % bterrhit_val)
	interp.call("_set_field", {"t": "id", "name": "Terr15"}, "bmap", bterrhit_val, null)
	var panel_nodes_direct: Dictionary = interp.get("_panel_nodes")
	var terr15_direct = panel_nodes_direct.get("terr15")
	var tr_direct: TextureRect = terr15_direct.get_meta("wdl_bmap_rect", null) if terr15_direct else null
	var tex_direct := str(tr_direct.texture.resource_path) if (tr_direct and tr_direct.texture) else "n/a"
	print("DIRECT _set_field bmap write -> Terr15 texture=%s" % tex_direct)

	# UpdatePanel() marks panels in REVERSE: `if (Terrorists<15){Terr15...}`
	# down to `if (Terrorists<1){Terr1...}` -- Terr15 is the one that
	# should change after just this one kill, not Terr1.
	var panel_nodes: Dictionary = interp.get("_panel_nodes")
	var terr15 = panel_nodes.get("terr15")
	if terr15 == null:
		print("FAIL: Terr15 panel node missing")
		quit(1)
		return
	var tr: TextureRect = terr15.get_meta("wdl_bmap_rect", null)
	var tex_path := str(tr.texture.resource_path) if (tr and tr.texture) else "n/a"
	print("Terr15 texture path=%s (expect .../Hit2.png once Terrorists<15)" % tex_path)

	var counter_ok := terr_after < terr_before and civ_after == civ_before
	var panel_ok := tex_path.contains("Hit2")
	print("counter_ok=%s panel_ok=%s" % [counter_ok, panel_ok])
	var ok := counter_ok and panel_ok
	print("OK" if ok else "FAIL")
	quit(0 if ok else 1)
