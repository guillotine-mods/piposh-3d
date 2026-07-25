extends SceneTree
func _init():
	call_deferred("r")
func r():
	var s = load("res://scenes/level_runner.tscn")
	var m = load("res://scenes/main_menu.tscn")
	print("level_runner ", s != null, " menu ", m != null)
	var h = load("res://scripts/ui/game_hud.gd")
	print("hud script ", h != null)
	quit(0)
