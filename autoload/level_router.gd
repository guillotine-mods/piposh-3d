extends Node
## Maps original EXE/level names (Run "Studio.exe") to Godot scenes / WMB JSON.

const LEVEL_SCENE := "res://scenes/level_runner.tscn"
const MENU_SCENE := "res://scenes/main_menu.tscn"
const BOOT_SCENE := "res://scenes/boot.tscn"

## Original chain: Start → Menu → Studio → Map / locations…
var aliases := {
	"Start": "Start",
	"Menu": "Menu",
	"Studio": "Studio",
	"Map": "Map",
	"Town": "Town",
	"Travel": "Travel",
	"Credits": "Credits",
	"Desert": "Desert",
	"Mansion": "Mansion",
	"Olympic": "Olympic",
	"Inn": "Inn",
	"MOI": "MOI",
	"Taxi": "Taxi",
	"Mine": "Mine",
	"Temple": "Temple",
	"Fight": "Fight",
	"Race": "Race",
	"Golf": "Golf",
	"Cardgame": "Cardgame",
	"Ending": "Ending",
	"Final": "Final",
	"Outro": "Outro",
}


func goto_level(level_name: String) -> void:
	var key := level_name.replace(".exe", "").replace(".EXE", "").strip_edges()
	if key.ends_with(".wdl") or key.ends_with(".WDL"):
		key = key.get_basename()
	key = aliases.get(key, key)
	GameState.current_level = key
	if key.to_lower() == "menu":
		get_tree().change_scene_to_file(MENU_SCENE)
		return
	get_tree().change_scene_to_file(LEVEL_SCENE)


func level_json_path(level_name: String) -> String:
	return "res://assets/converted/levels/%s.json" % level_name


func has_level_data(level_name: String) -> bool:
	return ResourceLoader.exists(level_json_path(level_name))
