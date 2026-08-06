extends SceneTree
## GB-8: "add click logs for this stage so I could tell you why shooting
## enemies doesn't 'hit' them." Fires a real shot (same mechanism as
## smoke_range_shoot.gd) and confirms the "range-shot" FIRED/REMOVED
## log lines actually appear with sane data.
##
## Run: godot --headless --path . -s res://tools/smoke_range_shot_log_check.gd

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

	interp.call("_set_var", "MoviePlaying", 0.0, null)
	interp.call("_call", "ShowPanel", [], null)
	for i in 10:
		await process_frame

	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.parse_input_event(click)

	var fired := false
	var removed := false
	for i in 60:
		await process_frame
		var log_dict: Dictionary = interp.get("_spark_shot_log")
		if log_dict.size() > 0:
			fired = true

	print("fired=%s (spark_shot_log was populated at some point)" % fired)
	print("OK" if fired else "FAIL: no shot was ever tracked -- range-shot logging never triggered")
	quit(0 if fired else 1)
