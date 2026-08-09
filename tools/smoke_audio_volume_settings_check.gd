extends SceneTree
## Reported live (2026-08-09, mid-playtest): "there's a very high volume
## of cars honking that shouldn't be so loud (lets have an FX / voice
## volume control in settings?)" -- also QOL-6's long-standing backlog
## ask. Added: Voice/SFX/Music AudioServer buses (autoload/
## audio_channels.gd), each channel's own player(s) routed to its bus,
## get/set volume methods persisted to user://audio_settings.cfg, and a
## SettingsPanel (scripts/ui/settings_panel.gd) with one slider per
## channel, toggled via F9 in both level_runner.gd and main_menu.gd.
## Separately trimmed Smash's own Honk1/2/3 (SFX007/008/009.wav) in
## SFX_VOLUME_TRIM_DB, matching the existing sHammer/Jet precedent, for
## the specific reported loudness (car honks stacking/overlapping, not a
## mislabeled-range issue).
##
## Verifies the SettingsPanel toggles and that adjusting SFX volume
## actually reaches the real AudioServer bus (the only way a slider can
## affect sounds already playing, not just future play() calls).
##
## Run: godot --headless --path . -s res://tools/smoke_audio_volume_settings_check.gd

const LEVEL := "Plane3"


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

	var settings: Node = runner.get_node_or_null("SettingsPanel")
	if settings == null:
		print("FAIL: no SettingsPanel node")
		quit(1)
		return

	var was_visible: bool = settings.visible
	settings.call("toggle_visible")
	var toggled_ok: bool = settings.visible != was_visible
	print("settings toggle: %s -> %s (expect flipped)" % [was_visible, settings.visible])

	var audio: Node = root.get_node("AudioChannels")
	var before_db: float = AudioServer.get_bus_volume_db(AudioServer.get_bus_index("SFX"))
	audio.call("set_sfx_volume", 0.3)
	var after_db: float = AudioServer.get_bus_volume_db(AudioServer.get_bus_index("SFX"))
	var vol_ok: bool = audio.call("get_sfx_volume") == 0.3 and after_db < before_db
	print("SFX bus db: %s -> %s after set_sfx_volume(0.3) (expect lower)" % [before_db, after_db])

	var buses_exist: bool = (
		AudioServer.get_bus_index("Voice") != -1
		and AudioServer.get_bus_index("SFX") != -1
		and AudioServer.get_bus_index("Music") != -1
	)
	print("buses exist=%s" % buses_exist)

	var ok: bool = toggled_ok and vol_ok and buses_exist
	print("OK" if ok else "FAIL")
	quit(0 if ok else 1)
