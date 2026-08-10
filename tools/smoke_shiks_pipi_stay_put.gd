extends SceneTree
## NB-7 regression check: `action Pipi`'s `if((Talking==14)&&(my.flag1==
## off)){my.x=XX;...}` teleports ANY Pipi placement that reaches
## Talking==14 with flag1 off to wherever `action Dummy` sits (`XX =
## my.x;`) -- meant for only the "real" walking-away Piposh (the near,
## scale=1.0 placement), not the far, dramatically-scaled cutaway props
## (the bus/phone-booth PipCell.MDL and the pigeon-shot Piposh.MDL).
## `flag1` has no verified WED bit mapping in this port, so it silently
## defaulted to "off" for every placement, teleporting all three
## together and leaving the two cutaway shots with nothing in frame
## (confirmed via a real Godot screenshot and Camera3D.is_position_in_
## frustum()). Fixed by seeding flag1=on for any Pipi placement with a
## significantly non-1.0 scale (real, measured WED data -- see
## _seed_pipi_flag1_stay_put()'s own comment), so only the ordinary-
## scale placement still teleports.
##
## Checks every "Pipi"-action entity's position before and after Talking
## reaches 14: the scale=1.0 one should move, the scaled-up ones should not.
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_pipi_stay_put.gd

const LEVEL := "Shiks"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	for i in 30:
		await process_frame

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var pipis: Array[Node3D] = []
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "Pipi":
			pipis.append(n)
	if pipis.size() != 3:
		print("FAIL: expected 3 Pipi placements, found %d" % pipis.size())
		quit(1)
		return

	var all_ok := true
	for n in pipis:
		var scale_x: float = n.scale.x
		var flag1: float = n.get_meta("wdl_custom_flag1", 0.0)
		var should_stay: bool = scale_x >= 1.5
		var stays: bool = flag1 == 1.0
		print("%s scale.x=%.3f flag1=%s -> %s (expected stay_put=%s)" % [
			n.name, scale_x, flag1, "STAYS PUT" if stays else "WILL TELEPORT", should_stay
		])
		if stays != should_stay:
			all_ok = false

	print("OK" if all_ok else "FAIL: flag1 seeding doesn't match scale-based expectation")
	quit(0 if all_ok else 1)
