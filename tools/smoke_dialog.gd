extends SceneTree
func _init():
	call_deferred("r")
func r():
	var hud_scr = load("res://scripts/ui/game_hud.gd")
	var hud = hud_scr.new()
	root.add_child(hud)
	await process_frame
	hud.show_dialog(0)
	assert hud.is_dialog_open()
	var got = [-1]
	hud.dialog_choice.connect(func(c): got[0]=c)
	hud._emit_choice(2)
	assert got[0]==2
	assert not hud.is_dialog_open()
	print("OK dialog choice emit")
	# Ami.mdlanim exists after reconvert
	assert FileAccess.file_exists("res://assets/converted/mdl/Ami.mdlanim")
	assert FileAccess.file_exists("res://assets/converted/mdl/Ami.glb")
	print("OK Ami assets")
	quit(0)
