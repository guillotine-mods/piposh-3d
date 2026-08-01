extends SceneTree

const LEVEL := "Shiks"


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

	var loader: Node = runner.get("loader")
	var entities := loader.get_node_or_null("Entities")
	var node: Node3D = null
	for n in entities.get_children():
		if n is Node3D and str(n.get_meta("action", "")) == "Bumpin":
			node = n
			break
	if node == null:
		print("FAIL: not found")
		quit(1)
		return
	print("node=%s pos=%s" % [node.name, node.global_position])
	_dump(node, 0)
	quit(0)


func _dump(n: Node, depth: int) -> void:
	var indent := "  ".repeat(depth)
	var extra := ""
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		extra = " aabb=%s local_pos=%s global_pos=%s" % [mi.get_aabb(), mi.position, mi.global_position]
	print("%s- %s (%s)%s" % [indent, n.name, n.get_class(), extra])
	for c in n.get_children():
		_dump(c, depth + 1)
