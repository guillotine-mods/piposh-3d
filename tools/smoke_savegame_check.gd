extends SceneTree
## GB-54: `str_cpy`/`str_cat` were ordinary value-returning builtins, but
## WDL calls them by reference (`str_cpy(StageToSave,"Game.tmp");` is a
## bare statement) -- same shape of bug vec_set/vec_sub/vec_to_angle were
## already special-cased for. This silently broke `IO.wdl`'s corpus-wide
## save/load system (`WriteGameData`/`RefreshState`, called from 30+ level
## scripts): `StageToSave` never actually got set, so `file_open_read`
## opened an empty path and every region-progress/inventory/one-time-flag
## read back as a fresh-game default on every single level transition.
##
## Plants a real save file under user://Game.tmp with distinct marker
## values, loads Town, and confirms those markers survive the real
## Initialize() -> RefreshState(0) -> str_cpy(StageToSave,"Game.tmp") ->
## file_open_read/file_asc_read chain -- not just that array declarations
## default correctly (which would pass even if the whole chain were dead).
##
## Run: godot --headless --path . -s res://tools/smoke_savegame_check.gd

const LEVEL := "Town"
const USER_SAVE_PATH := "user://Game.tmp"

func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_plant_save_file()

	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)
	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	for i in 20:
		await process_frame

	var director: Node = runner.get("_director")
	var interp = director.get("_wdl_interp") if director else null
	if interp == null:
		print("FAIL: no interpreter found")
		_cleanup()
		quit(1)
		return

	var globals: Dictionary = interp.get("_globals")
	var village: Array = globals.get("Village", {}).get("value", [])
	var has_id: float = float(globals.get("HasID", {}).get("value", -1.0))

	var ok := village.size() >= 1 and absf(float(village[0]) - 7.0) < 0.01 and absf(has_id - 1.0) < 0.01
	print("Village[0]=", village[0] if village.size() > 0 else "?", " (expect 7.0)")
	print("HasID=", has_id, " (expect 1.0)")
	print("OK" if ok else "FAIL")
	_cleanup()
	quit(0 if ok else 1)


func _plant_save_file() -> void:
	var lines: Array[String] = []
	for i in 5: lines.append("0")                       # Piece[0..4]
	lines.append_array(["7", "0", "0", "0", "0"])        # Village[0..4], Village[0]=7 marker
	for i in 5: lines.append("0")                        # Volcano[0..4]
	for i in 4: lines.append("0")                        # Olympic[0..3]
	for i in 3: lines.append("0")                        # Mansion[0..2]
	for i in 3: lines.append("0")                        # Asylum[0..2]
	for i in 5: lines.append("0")                        # flag_first_Village..Asylum
	lines.append_array(["0", "1", "0", "0"])              # varPhotoID, HasID=1 marker, varNewMap, TalkedOnce
	for i in 32: lines.append("0")                        # AFG[0..31]
	var f := FileAccess.open(USER_SAVE_PATH, FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()


func _cleanup() -> void:
	if FileAccess.file_exists(USER_SAVE_PATH):
		DirAccess.remove_absolute(USER_SAVE_PATH)
