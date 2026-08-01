extends SceneTree
## Regression check for the 2026-08-01 "a weird noise that plays in the
## background non stop" report in Shiks. Root cause was a leftover
## hand-ported branch in wdl_director.gd's setup() duplicating what
## Shiks.wdl's own `action Watrfall`/`action WaterWheel`/`action Bus`
## already do (play_entsound + snd_playing ambiance loops) -- the
## duplicate play_music() call corrupted the shared AudioStreamWAV
## resource's loop region (_enable_loop() set loop_mode without
## loop_end), which made the SFX pool's own playback of the same file
## unable to sustain `.playing == true`, retriggering up to ~140x/sec
## instead of once per its own ~3s length. See autoload/audio_channels.gd
## _enable_loop()/play_sfx() docstrings for the full story.
##
## Runs Shiks for a fixed number of frames and checks the total play_sfx
## call count stays in a sane range -- comfortably above the ~3 legitimate
## ambiance loops' natural retrigger count, comfortably below where the
## old bug put it (1000+ in a real-time-equivalent window).
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_sfx_debug.gd

const LEVEL := "Shiks"
const FRAMES := 720  # not wall-clock-real-time-equivalent in headless mode -- see below
const MAX_SANE_CALLS := 200  # old bug: 1679 calls/12s real-time. Fixed: ~25.


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

	var audio := root.get_node("/root/AudioChannels")
	var start_total := _sum(audio.get("_sfx_generation"))
	for i in FRAMES:
		await process_frame
	var end_total := _sum(audio.get("_sfx_generation"))

	var calls := end_total - start_total
	print("play_sfx calls over %d frames: %d" % [FRAMES, calls])
	var ok := calls < MAX_SANE_CALLS
	print("OK" if ok else "FAIL: SFX pool thrashing regression (%d calls, expected < %d)" % [calls, MAX_SANE_CALLS])
	quit(0 if ok else 1)


func _sum(arr: Array) -> int:
	var total := 0
	for g in arr:
		total += int(g)
	return total
