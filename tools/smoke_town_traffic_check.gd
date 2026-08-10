extends SceneTree
## Reported live (2026-08-10): "there are no running cars." Traced to two
## independent bugs: (1) Town.wdl's own `action SportCar` never set
## `_MOVEMODE` to a positive value anywhere in its own script (unlike
## every other scan_path() caller in the corpus, which all set `my.
## _movemode=1;` explicitly before their own call) -- fixed by having
## `_do_scan_path()` set it on success, matching real Acknex's own
## scan_path() contract; (2) the generic `move(ENT,dist,absdist)` bridge
## only ever applied `absdist` (world-space, used for gravity/jump),
## silently dropping `dist` (entity-local, used for ordinary forward
## walking/driving) -- fixed in `_do_move_call()` to rotate `dist` into
## world space via the entity's own pan/tilt/roll and apply both. A third,
## deeper bug fed into the same symptom: `force = my.skill1;` (a bare
## scalar assign) and `force.x`/`.y`/`.z` (read by move_gravity2()) lived
## in two disconnected storage locations (_globals vs _vectors) -- fixed
## in `_set_var()` to mirror a scalar write into the vector store's own
## `.x`, matching real Acknex's "VECTOR = SCALAR sets .x" idiom.
##
## Verifies a real Town.wdl traffic car (spawned at runtime via `action
## MakeCars`' own `create()` calls) both spawns AND actually drives along
## its bound path, not just sitting at its spawn point.
##
## Run: godot --headless --path . -s res://tools/smoke_town_traffic_check.gd

const LEVEL := "Town"
const CAR_NAMES := ["towncar", "cityoil", "cityjeep", "bus3", "busicar", "townvesp"]

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)
	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)

	# Give MakeCars' own 300-frame spawn timer room to fire at least once.
	for i in 400:
		await process_frame

	var loader := runner.get_node_or_null("WmbLevelLoader")
	var entities := loader.get_node_or_null("Entities") if loader else null
	var car: Node3D = null
	if entities:
		for c in entities.get_children():
			var n: String = String(c.name).to_lower()
			for cn in CAR_NAMES:
				if cn in n:
					car = c
					break
			if car:
				break

	if car == null:
		print("FAIL: no traffic car spawned by frame 400")
		quit(1)
		return

	var p0: Vector3 = car.global_position
	for i in 120:
		await process_frame
	var p1: Vector3 = car.global_position
	var moved := p0.distance_to(p1)
	print("car=%s moved=%.1f over 120 frames" % [car.name, moved])

	var ok: bool = moved > 20.0
	print("OK" if ok else "FAIL")
	quit(0 if ok else 1)
