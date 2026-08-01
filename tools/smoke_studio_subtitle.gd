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
	if not ok:
		print("FAIL: subtitle crawl not active for Studio")
		quit(1)
		return

	# Timing check (2026-08-01 fix): the horizontal slide (223 -(-310) =
	# 533 units at 8*16=128 units/sec -> ~4.16s) must finish, then the
	# line must HOLD in place for ~3.75s (my.skill34>60 in the source)
	# before any downward scroll starts -- total ~7.9s before movement
	# resumes. Previously missing, so the line started sliding away
	# within under 2s of finishing its reveal. Check partway into the
	# hold (6.5s -- comfortably past the slide, comfortably short of the
	# ~7.9s scroll-start, avoiding a flaky right-at-the-boundary check)
	# and confirm Y hasn't moved from its base yet.
	var base_y: float = p_som.position.y
	for i in 390:  # 6.5s @ 60fps
		await process_frame
	var y_after_hold_window: float = p_som.position.y
	print("pSom.position.y: base=%.2f after~6.5s=%.2f" % [base_y, y_after_hold_window])
	var held: bool = absf(y_after_hold_window - base_y) < 1.0
	print("OK" if held else "FAIL: subtitle scrolled away before the ~3.75s hold finished")
	quit(0 if held else 1)
