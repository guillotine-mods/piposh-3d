extends SceneTree
## Non-headless visual check: boots straight into Studio and just sits
## there so an external screenshot tool can capture the real window while
## it's open. Headless mode in this environment always falls back to the
## dummy rendering driver (confirmed 2026-07-31), so this is the only way
## to get real pixels.
##
## Run WITHOUT --headless: godot --path . -s res://tools/smoke_visual_studio.gd

const LEVEL := "Studio"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)

	# Sit and do nothing for a while so an external screenshot can catch it
	# mid-crawl. Does NOT quit on its own -- caller kills the process after
	# screenshotting.
	for i in 100000:
		await process_frame
