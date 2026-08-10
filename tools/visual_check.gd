extends SceneTree
## Non-headless visual verification. Pass level name via `--` args, and
## optionally "hidesky" or "hidecyl" as a 2nd arg to isolate which sky
## layer is producing a given artifact.

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var level := args[0] if args.size() > 0 else "Town"
	var mode := args[1] if args.size() > 1 else ""
	root.get_node("GameState").set("current_level", level)
	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	for i in 20:
		await process_frame

	var acknex_sky := runner.get_node_or_null("AcknexSky")
	if mode == "hidecyl" and acknex_sky:
		var sm := acknex_sky.get_node_or_null("SceneMap")
		if sm:
			sm.visible = false
			print("hid SceneMap")
	elif mode == "hidesky" and runner:
		var we := runner.get_node_or_null("WorldEnvironment") as WorldEnvironment
		if we and we.environment:
			we.environment.background_mode = Environment.BG_COLOR
			we.environment.background_color = Color(0.05, 0.05, 0.05)
			print("forced flat background")

	print("Loaded level=%s mode=%s, staying open for screenshot..." % [level, mode])
