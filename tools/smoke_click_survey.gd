extends SceneTree
## Broad-corpus verification of the 2026-07-30 enable_click/.event fix.
## smoke_click_event.gd proved the mechanism on one entity (Plane2's
## HeadPhone); this exercises every level in the corpus that actually uses
## `enable_click` (16 levels, found via `grep -rl enable_click
## original/piposh3d/*.wdl`), finds every entity that ends up with a
## captured `wdl_event`, simulates a click on each, and reports pass/fail
## with real console output.
##
## Clicking an entity can free it (some WDL actions call remove(my) on
## click, e.g. AFG card pickups) -- so every entity reference is only ever
## used once, immediately, and results are captured as plain strings up
## front rather than re-touching Node3D references after further clicks
## may have invalidated them. A first version kept Node3D references
## around across the whole per-level loop and crashed the engine (SIGSEGV)
## touching a freed one after a later click removed it.
##
## Run: godot --headless --path . -s res://tools/smoke_click_survey.gd

const LEVELS: Array[String] = [
	"AsyAct1", "AsyAct2", "AsyAct3", "Cardgame", "Dutyfree", "InShrine",
	"Inn", "Intro2", "MOI", "Mansion", "Olympic", "Plane2", "Studio",
	"Taxi", "Temple", "Town",
]


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var game_state := root.get_node("Piposh3DState")
	var packed: PackedScene = load("res://scenes/level_runner.tscn")

	var total_entities := 0
	var level_results: Array[String] = []

	for level in LEVELS:
		game_state.set("current_level", level)
		var runner: Node = packed.instantiate()
		root.add_child(runner)
		await process_frame
		await process_frame
		await process_frame

		var director: Node = runner.get("_director")
		var interp: Node = director.get("_wdl_interp") if director != null else null
		var loader: Node = runner.get("loader")

		if interp == null:
			level_results.append("%-10s SKIP (not interpreted -- hand-ported or no AST)" % level)
			runner.queue_free()
			await process_frame
			continue

		# Snapshot (name, action, event) as plain strings *before* clicking
		# anything -- clicking can free nodes (see header), so nothing here
		# holds a Node3D reference past the click that might invalidate it.
		var snapshot := _snapshot_wdl_event_entities(loader)
		if snapshot.is_empty():
			level_results.append(
				"%-10s WARN 0 entities captured wdl_event (enable_click used in source but nothing fired -- check unmatched_actions)"
				% level
			)
			runner.queue_free()
			await process_frame
			continue

		var event_targets: Array[String] = []
		for row in snapshot:
			var node_name: String = row["name"]
			var action: String = row["action"]
			var event_name: String = row["event"]
			event_targets.append(event_name)
			var entity: Node3D = loader.get_node_or_null("Entities/" + node_name) if loader else null
			if entity == null or not is_instance_valid(entity):
				print("SKIP CLICK level=%s entity=%s (already freed before its turn)" % [level, node_name])
				continue
			print("CLICKING level=%s entity=%s action=%s event=%s" % [level, node_name, action, event_name])
			director.call("_handle_click_action", action, entity)
			await process_frame
			total_entities += 1

		level_results.append(
			"%-10s OK %d clickable entities exercised (event targets: %s)"
			% [level, snapshot.size(), ", ".join(event_targets)]
		)
		runner.queue_free()
		await process_frame

	print("\n=== enable_click/.event corpus survey ===")
	for line in level_results:
		print(line)
	print("\n%d level(s) checked, %d clickable entities exercised total." % [LEVELS.size(), total_entities])
	print("Grep this run's stderr for 'SCRIPT ERROR' to check for real failures -- not tracked in-script.")
	quit(0)


func _snapshot_wdl_event_entities(loader: Node) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if loader == null:
		return out
	var entities := loader.get_node_or_null("Entities")
	if entities == null:
		return out
	for n in entities.get_children():
		if n is Node3D and n.has_meta("wdl_event"):
			out.append({
				"name": str(n.name),
				"action": str(n.get_meta("action", "")),
				"event": str(n.get_meta("wdl_event")),
			})
	return out
