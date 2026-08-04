extends SceneTree

const LEVEL := "Range"


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

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null
	if interp == null:
		print("FAIL: no interpreter")
		quit(1)
		return

	interp.call("_ensure_panels_built")
	var pskip: Control = interp.call("_resolve_panel_node", "pSkip") if interp.has_method("_resolve_panel_node") else null
	var panel_nodes: Dictionary = interp.get("_panel_nodes")
	print("panel_nodes keys=%s" % [panel_nodes.keys()])
	var skip_node: Control = panel_nodes.get("pskip", null)
	var rip_node: Control = panel_nodes.get("prip", null)
	if skip_node == null or rip_node == null:
		print("FAIL: missing pSkip=%s or pRIP=%s node" % [skip_node, rip_node])
		quit(1)
		return
	print("pSkip z_index=%d parent=%s index_in_parent=%d" % [skip_node.z_index, skip_node.get_parent().name, skip_node.get_index()])
	print("pRIP z_index=%d parent=%s index_in_parent=%d" % [rip_node.z_index, rip_node.get_parent().name, rip_node.get_index()])

	interp.call("_set_var", "NumTries", 4.0, null)
	skip_node.visible = true
	rip_node.visible = true
	for i in 3:
		await process_frame
	print("after show: pSkip.visible=%s pRIP.visible=%s pSkip.z=%d pRIP.z=%d" % [skip_node.visible, rip_node.visible, skip_node.z_index, rip_node.z_index])
	quit(0)
