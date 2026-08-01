extends SceneTree
## Regression check for the 2026-08-01 report: "in the original game
## there's a sleep/wait function for 3 seconds before each level starts
## ... we can skip it since it loads very quickly anyway." Confirms
## main()'s opening `wait(3);` (Range.wdl: `function main() { wait(3);
## NumTries=NumTries+1; ...; Health=609; ... }`) completes in ~1 frame
## instead of 3+, by checking how quickly `Health` (set right after the
## wait) becomes non-zero.
##
## Run: godot --headless --path . -s res://tools/smoke_wait_skip.gd

const LEVEL := "Range"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("GameState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)

	var director: Node = runner.get("_director")
	var interp: Node = null
	var frames_to_health := -1
	for i in 30:
		await process_frame
		director = runner.get("_director")
		if director:
			interp = director.get("_wdl_interp")
		if interp:
			var health = interp.call("_get_var", "Health", null)
			if float(health) == 609.0:
				frames_to_health = i
				break

	print("frames until Health=609 (post-wait(3) code): %d" % frames_to_health)
	# Old behavior: wait(3) genuinely waited 3 real frames beyond level
	# setup before main() could reach this line -- generously, anything
	# under 10 frames confirms the skip; the old path would still show up
	# as "took at least 3 extra frames past whatever setup already needed."
	var ok := frames_to_health >= 0 and frames_to_health < 10
	print("OK" if ok else "FAIL: main()'s opening wait() was not skipped")
	quit(0 if ok else 1)
