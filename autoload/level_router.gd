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
	"Shiks": "Shiks",
	"Plane": "Plane",
	"Plane2": "Plane2",
	"Plane3": "Plane3",
	"Smash": "Smash",
}


var _last_switch_ms := -100000


func goto_level(level_name: String) -> void:
	# Re-entrancy guard: levels were observed loading twice back-to-back —
	# confirmed on both an interpreted level (Intro2) and a hand-ported one
	# (Plane: "WmbLevelLoader: Plane spawned=23..." and "[plane] begin:"
	# each printed twice with byte-identical data), so this is a general
	# double-invocation of goto_level(), not anything specific to the new
	# interpreter. A same-frame-only guard (the first attempt at this fix)
	# did not fully catch it, meaning the two calls can land a few frames
	# apart (e.g. a click's press/release each independently reaching the
	# handler) -- a short real-time cooldown is more robust than a single
	# process_frame flag. No legitimate `Run()`/`Load_level()` transition in
	# any real WDL script happens within a fraction of a second of the
	# previous one, so this cannot suppress a real transition.
	var now := Time.get_ticks_msec()
	if now - _last_switch_ms < 500:
		push_warning("[level_router] dropped duplicate goto_level(%s) %dms after the previous switch" % [level_name, now - _last_switch_ms])
		return
	_last_switch_ms = now

	var key := level_name.replace(".exe", "").replace(".EXE", "").strip_edges()
	if key.ends_with(".wdl") or key.ends_with(".WDL"):
		key = key.get_basename()
	key = aliases.get(key, key)
	Piposh3DState.current_level = key
	if key.to_lower() == "menu":
		print("[level] switching scene: %s (level=%s)" % [MENU_SCENE, key])
		get_tree().change_scene_to_file(MENU_SCENE)
		return
	print("[level] switching scene: %s (level=%s)" % [LEVEL_SCENE, key])
	get_tree().change_scene_to_file(LEVEL_SCENE)


func level_json_path(level_name: String) -> String:
	return "res://assets/converted/levels/%s.json" % level_name


func has_level_data(level_name: String) -> bool:
	return ResourceLoader.exists(level_json_path(level_name))
