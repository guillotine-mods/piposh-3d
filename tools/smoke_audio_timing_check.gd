extends SceneTree
## One-off check: does headless Godot actually advance AudioStreamPlayer
## playback / fire `finished` without a real audio device? Needed to know
## whether GetPosition(Voice) will ever report "done" for a real WAV in
## headless mode, or hang forever, after fixing sound-variable resolution
## (docs/SESSION_LOG.md 2026-07-30).
##
## Run: godot --headless --path . -s res://tools/smoke_audio_timing_check.gd


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var audio_channels := root.get_node("AudioChannels")
	audio_channels.call("rebuild_index")
	print("Playing SHK019.WAV via AudioChannels.play_voice()...")
	audio_channels.call("play_voice", "SHK019.WAV")
	for i in 300:
		await process_frame
		var playing: bool = audio_channels.call("is_voice_playing")
		if i % 30 == 0:
			print(
				"frame=%3d is_voice_playing=%s get_voice_progress=%s"
				% [i, playing, audio_channels.call("get_voice_progress")]
			)
		if not playing and i > 0:
			print("\nPlayback reported finished at frame %d." % i)
			quit(0)
			return
	print("\nDid NOT finish within 300 frames (5s @60fps) -- headless audio may not advance/complete.")
	quit(1)
