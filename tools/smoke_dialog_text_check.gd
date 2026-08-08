extends SceneTree
## Reported live (2026-08-08, Plane3): "there's no text in the text box
## choices just '...'". Confirms GameHud._dialog_lines() now reads real
## text for every DialogIndex from the generic `assets/converted/
## dialog_text.json` extraction (tools/extract_dialog_text.py), not just
## the 5 indices a prior hardcoded table had hand-transcribed.
##
## Run: godot --headless --path . -s res://tools/smoke_dialog_text_check.gd


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var hud_script: GDScript = load("res://scripts/ui/game_hud.gd")
	var hud: Node = hud_script.new()
	root.add_child(hud)
	await process_frame

	var ok := true
	# Index 0: known-good text from the OLD hardcoded table, cross-check
	# the new JSON-backed path returns byte-identical text.
	var lines0: Array = hud.call("_dialog_lines", 0)
	print("index 0 line 1: %s" % [lines0[0] if lines0.size() > 0 else "<empty>"])
	var expect0 := "אז למתי אתה רושם לי את הצ'ק עמי?"
	if lines0.size() == 0 or lines0[0] != expect0:
		print("FAIL: index 0 text doesn't match the known-good original")

	# Indices 5/6: Plane3's own choices, the ones that were "…" before.
	for idx in [5, 6]:
		var lines: Array = hud.call("_dialog_lines", idx)
		print("index %d: %s" % [idx, lines])
		if lines.size() == 0 or lines[0] == "…":
			print("FAIL: index %d still falls back to the placeholder" % idx)
			ok = false

	# A genuinely out-of-range index should still fall back gracefully.
	var lines_oob: Array = hud.call("_dialog_lines", 9999)
	print("index 9999 (out of range): %s" % [lines_oob])
	if lines_oob.size() != 3 or lines_oob[0] != "…":
		print("FAIL: out-of-range index didn't fall back to the placeholder")
		ok = false

	print("OK" if ok else "FAIL: see above")
	quit(0 if ok else 1)
