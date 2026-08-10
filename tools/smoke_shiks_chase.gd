extends SceneTree
## Part of investigating the 2026-08-01 "2nd dialogue in Shiks doesn't
## play" report -- checks whether `action MyCamera`'s real waypoint-chase
## sequence (triggered by Piposh.skill2==2 via `action Bumped`) actually
## completes and sets DialogIndex=2 for real, instead of assuming it via
## forced-state shortcuts (as smoke_shiks_dialog2.gd does). Sets
## Piposh.skill2=2 (matching what a real bump does) and watches
## skill2/DialogIndex/Scene over a real 30s window.
##
## Confirmed working end to end: DialogIndex reaches 1 (~4s, Piposh2's
## own walk-forward crosses StandHerePoint) then 2 (~10s, the chase
## completes), matching real WDL semantics with no shortcuts -- did not
## reproduce the reported silence (see smoke_shiks_dialog2.gd's own
## docstring for the full investigation summary).
##
## Run: godot --headless --path . -s res://tools/smoke_shiks_chase.gd

const LEVEL := "Shiks"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)

	var interp: Node = null
	for i in 5:
		await process_frame
		var director: Node = runner.get("_director")
		if director:
			interp = director.get("_wdl_interp")
		if interp:
			break
	if interp == null:
		print("FAIL: no interpreter for %s" % LEVEL)
		quit(1)
		return

	for i in 30:
		await process_frame

	# Find the Piposh entity and set its skill2 field to 2, matching
	# `action Bumped`'s own effect (`Piposh.skill2 = 2;`) exactly, via
	# the same wdl_skills meta array _set_field()/_get_field() use.
	var loader: Node = runner.get("loader")
	var entities := loader.get_node("Entities")
	var piposh: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "Piposh2":
			piposh = n
			break
	if piposh == null:
		print("FAIL: no Piposh2 entity found")
		quit(1)
		return

	var skills: Array = piposh.get_meta("wdl_skills", [])
	while skills.size() <= 1:
		skills.append(0.0)
	skills[1] = 2.0  # skill2 (1-indexed in WDL) -> index 1
	piposh.set_meta("wdl_skills", skills)
	print("Set Piposh.skill2=2 (matching action Bumped)")

	for i in 1800:  # 30s
		await process_frame
		if i % 60 == 0:
			var sk: Array = piposh.get_meta("wdl_skills", [])
			print("t=%.1fs skill2=%s skill1=%s MOVEMODE=%s DialogIndex=%s Scene=%s" % [
				i / 60.0,
				sk[1] if sk.size() > 1 else 0.0,
				sk[0] if sk.size() > 0 else 0.0,
				piposh.get_meta("wdl_custom__movemode", "n/a"),
				interp.call("_get_var", "DialogIndex", null),
				interp.call("_get_var", "Scene", null),
			])

	print("Done.")
	quit(0)
