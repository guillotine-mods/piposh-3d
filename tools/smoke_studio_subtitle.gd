extends SceneTree
## Verifies the 2026-07-31 "green text not showing" fix: Studio's
## `action Ami` should trigger GameHud.setup_studio_subtitles() at level
## start, which was defined but never wired to anything (git log -S showed
## zero call sites since the initial commit).
##
## Run: godot --headless --path . -s res://tools/smoke_studio_subtitle.gd

const LEVEL := "Studio"


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
	await process_frame
	await process_frame

	var hud: Node = runner.get("_game_hud")
	if hud == null:
		print("FAIL: no GameHud")
		quit(1)
		return

	var p_som: TextureRect = hud.get_node_or_null("DesignRoot/pSom")
	var p_ovr: TextureRect = hud.get_node_or_null("DesignRoot/pOvr")
	var crawl_active: bool = hud.get("_crawl_active")
	var kind: String = hud.get("_subtitle_kind")
	var som_visible := p_som != null and p_som.visible
	var ovr_visible := p_ovr != null and p_ovr.visible
	var som_has_tex := p_som != null and p_som.texture != null
	print(
		"crawl_active=%s kind=%s pSom_visible=%s pOvr_visible=%s pSom_tex=%s"
		% [crawl_active, kind, som_visible, ovr_visible, som_has_tex]
	)

	var ok: bool = crawl_active and kind == "studio" and som_visible and ovr_visible
	print("OK" if ok else "FAIL: subtitle crawl not active for Studio")
	quit(0 if ok else 1)
