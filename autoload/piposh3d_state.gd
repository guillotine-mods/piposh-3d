extends Node
## Mirrors save/progress flags from original IO.wdl

const SAVE_DIR := "user://saves"

var piece: Array[int] = [0, 0, 0, 0, 0]
var village: Array[int] = [0, 0, 0, 0, 0]
var volcano: Array[int] = [0, 0, 0, 0, 0]
var olympic: Array[int] = [0, 0, 0, 0]
var mansion: Array[int] = [0, 0, 0]
var asylum: Array[int] = [0, 0, 0]
## Afgan.wdl `var AFG[32]` — collectible card set, index = my.skill1.
var afg: Array[int] = [
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
]

var flag_first_village := 0
var flag_first_asylum := 0
var flag_first_mansion := 0
var flag_first_volcano := 0
var flag_first_olympic := 0

var var_photo_id := 0
var has_id := 0
var var_new_map := 0
var game_score := 0
	## false → boot loads Start cinematic before Menu
var skip_intro_movies := false
var current_level := "Start"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)


func reset_new_game() -> void:
	piece = [0, 0, 0, 0, 0]
	village = [0, 0, 0, 0, 0]
	volcano = [0, 0, 0, 0, 0]
	olympic = [0, 0, 0, 0]
	mansion = [0, 0, 0]
	asylum = [0, 0, 0]
	afg = _to_int_array([], 32)
	flag_first_village = 0
	flag_first_asylum = 0
	flag_first_mansion = 0
	flag_first_volcano = 0
	flag_first_olympic = 0
	var_photo_id = 0
	has_id = 0
	var_new_map = 0
	game_score = 0


func to_dict() -> Dictionary:
	return {
		"piece": piece.duplicate(),
		"village": village.duplicate(),
		"volcano": volcano.duplicate(),
		"olympic": olympic.duplicate(),
		"mansion": mansion.duplicate(),
		"asylum": asylum.duplicate(),
		"afg": afg.duplicate(),
		"flag_first_village": flag_first_village,
		"flag_first_asylum": flag_first_asylum,
		"flag_first_mansion": flag_first_mansion,
		"flag_first_volcano": flag_first_volcano,
		"flag_first_olympic": flag_first_olympic,
		"var_photo_id": var_photo_id,
		"has_id": has_id,
		"var_new_map": var_new_map,
		"game_score": game_score,
		"current_level": current_level,
	}


func from_dict(d: Dictionary) -> void:
	piece = _to_int_array(d.get("piece", piece), 5)
	village = _to_int_array(d.get("village", village), 5)
	volcano = _to_int_array(d.get("volcano", volcano), 5)
	olympic = _to_int_array(d.get("olympic", olympic), 4)
	mansion = _to_int_array(d.get("mansion", mansion), 3)
	asylum = _to_int_array(d.get("asylum", asylum), 3)
	afg = _to_int_array(d.get("afg", afg), 32)
	flag_first_village = int(d.get("flag_first_village", 0))
	flag_first_asylum = int(d.get("flag_first_asylum", 0))
	flag_first_mansion = int(d.get("flag_first_mansion", 0))
	flag_first_volcano = int(d.get("flag_first_volcano", 0))
	flag_first_olympic = int(d.get("flag_first_olympic", 0))
	var_photo_id = int(d.get("var_photo_id", 0))
	has_id = int(d.get("has_id", 0))
	var_new_map = int(d.get("var_new_map", 0))
	game_score = int(d.get("game_score", 0))
	current_level = str(d.get("current_level", current_level))


func save_slot(slot: int) -> void:
	var path := "%s/game_%d.json" % [SAVE_DIR, slot]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("Cannot save %s" % path)
		return
	f.store_string(JSON.stringify(to_dict(), "\t"))


func load_slot(slot: int) -> bool:
	var path := "%s/game_%d.json" % [SAVE_DIR, slot]
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if typeof(data) != TYPE_DICTIONARY:
		return false
	from_dict(data)
	return true


func _to_int_array(v: Variant, size: int) -> Array[int]:
	var out: Array[int] = []
	out.resize(size)
	out.fill(0)
	if v is Array:
		for i in mini(size, v.size()):
			out[i] = int(v[i])
	return out
