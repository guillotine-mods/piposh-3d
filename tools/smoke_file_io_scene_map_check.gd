extends SceneTree
## Reported live (2026-08-09): "some of the world backgrounds are not
## correct still." `assets/converted/wdl_meta.json`'s own static
## scene_map extraction picks whichever `scene_map = X;` assignment
## appears textually LAST in a level's own source -- wrong for
## Desert.wdl, whose real `main()` reads `Stage` from a save file
## ("Arrive.dat", written by Map.wdl's own LocationGo()) and picks one
## of six horizon textures based on it. `file_open_write`/
## `file_open_read`/`file_asc_write`/`file_asc_read`/`file_close` were
## entirely unbridged (zero matches anywhere in wdl_interpreter.gd
## before this), so `Stage` silently stayed at its own declared default
## regardless of which destination was actually chosen. Added a real,
## if scoped-down (plain-number only, not the by-reference string
## variant), file I/O bridge under user://, plus a bounded polling
## window in level_runner.gd so the live scene_map value (only
## available a few real frames after level load, once main()'s own
## opening wait(3) resolves) can override the static guess once it's
## actually known.
##
## Verifies the file I/O round-trip directly: write a value via
## file_open_write/file_asc_write/file_close, then read it back via
## file_open_read/file_asc_read/file_close through the WDL interpreter
## itself (not a Godot-side shortcut).
##
## Run: godot --headless --path . -s res://tools/smoke_file_io_scene_map_check.gd


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	root.get_node("GameState").set("current_level", "Plane3")
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

	# WRITE: filehandle = file_open_write("smoke_test.dat");
	#        file_asc_write(filehandle, 42); file_close(filehandle);
	var write_handle = interp.call("_call", "file_open_write", [{"t": "str", "v": "smoke_test.dat"}], null)
	var write_ok: bool = write_handle > 0.0
	interp.call("_call", "file_asc_write", [{"t": "num", "v": write_handle}, {"t": "num", "v": 42.0}], null)
	interp.call("_call", "file_close", [{"t": "num", "v": write_handle}], null)

	# READ it back through a fresh handle.
	var read_handle = interp.call("_call", "file_open_read", [{"t": "str", "v": "smoke_test.dat"}], null)
	var read_ok: bool = read_handle > 0.0
	var value = interp.call("_call", "file_asc_read", [{"t": "num", "v": read_handle}], null)
	interp.call("_call", "file_close", [{"t": "num", "v": read_handle}], null)

	print("write_handle=%s read_handle=%s value=%s (expect 42.0)" % [write_handle, read_handle, value])

	var ok: bool = write_ok and read_ok and value == 42.0
	print("OK" if ok else "FAIL")

	# Clean up the test file.
	var f := FileAccess.open("user://smoke_test.dat", FileAccess.WRITE)
	if f:
		f.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://smoke_test.dat"))

	quit(0 if ok else 1)
