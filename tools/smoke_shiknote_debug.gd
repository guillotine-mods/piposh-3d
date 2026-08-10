extends SceneTree

const LEVEL := "Studio"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	await process_frame
	await process_frame
	await process_frame

	var loader: Node = runner.get("loader")
	var entities := loader.get_node_or_null("Entities")
	var shiknote: Node3D = null
	for n in entities.get_children():
		if n is Node3D and str(n.get_meta("action", "")) == "ShikNote":
			shiknote = n
			break
	if shiknote == null:
		print("FAIL: ShikNote not found")
		quit(1)
		return

	print("ShikNote node=%s pos=%s" % [shiknote.name, shiknote.global_position])
	_dump(shiknote, 0)
	quit(0)


func _dump(n: Node, depth: int) -> void:
	var indent := "  ".repeat(depth)
	var extra := ""
	if n is MeshInstance3D:
		extra = " aabb=%s local_pos=%s" % [(n as MeshInstance3D).get_aabb(), (n as Node3D).position]
	print("%s- %s (%s)%s" % [indent, n.name, n.get_class(), extra])
	for c in n.get_children():
		_dump(c, depth + 1)
