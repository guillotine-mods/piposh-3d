extends SceneTree
## PORTING_MANUAL.md Phase 1 gate: "every playable level either runs a
## hand-port or starts the interpreter. Zero levels reach the inert else.
## Print a per-level table proving it." Actually instantiates
## WmbLevelLoader + WdlDirector per level and reports the real dispatch
## outcome from each one's own setup() -- not a read of the code that
## decides it.
##
## Defaults to a targeted roster: the 7 levels formerly gated behind
## HAND_PORTS_ENABLED (Start/Studio/Town/Shiks/Plane/Plane2/Range) plus the
## 13 levels PORTING_MANUAL.md §3.1 names as having a parsed AST but no
## camera-action entity (previously guaranteed-inert). That's the exact
## defect this change targets, without paying for a full ~55-level batch
## (each level does a real WmbLevelLoader.load_level() + fires off the
## interpreter's coroutines -- expensive and, per one frame yield per
## level below, was observed to run long enough to be worth bounding
## rather than defaulting to "everything").
##
## Run: godot --headless --path . -s res://tools/smoke_dispatch.gd
## Run: godot --headless --path . -s res://tools/smoke_dispatch.gd -- --all

## Authoritative "does this level have a script at all" source, independent of
## whether the offline AST happens to exist on disk.
const WdlCache = preload("res://scripts/engine/wdl_cache.gd")

const TARGET_ROSTER: Array[String] = [
	"Start", "Studio", "Town", "Shiks", "Plane", "Plane2", "Range",
	"AsyAct2", "AsyAct3", "Desert", "Final", "InShrine", "Inn", "Map",
	"Mine", "Mount", "Olympic", "Race", "Shooter",
]


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	# Loaded here (not as a static WmbLevelLoader/WdlDirector reference at
	# the top of the file) so GDScript doesn't compile these classes -- and
	# transitively the Piposh3DState/AudioBus/PiposhDebug autoloads they
	# reference -- until after this script's own SceneTree has finished
	# registering autoloads. A static reference hit "Identifier not found:
	# Piposh3DState" at parse time; no existing tools/smoke_*.gd script
	# instantiates WmbLevelLoader/WdlDirector, so this ordering issue had
	# never been exercised before.
	var loader_script: GDScript = load("res://scripts/engine/wmb_level_loader.gd")
	var director_script: GDScript = load("res://scripts/engine/wdl_director.gd")
	var roster := TARGET_ROSTER
	if "--all" in OS.get_cmdline_user_args():
		roster = _load_full_roster()
	print("Testing %d level(s)\n" % roster.size())
	print("%-10s %-5s %-7s %-11s %-14s %s" % [
		"Level", "fp", "has_ast", "interpreted", "scripted_cam", "outcome"
	])

	var inert_with_ast: Array[String] = []
	var script_but_no_ast: Array[String] = []
	var missing_json: Array[String] = []
	var ok_count := 0

	for level in roster:
		var loader: Node = loader_script.new()
		loader.name = "Loader_%s" % level
		root.add_child(loader)
		var loaded: bool = loader.load_level(level)
		if not loaded:
			missing_json.append(level)
			loader.queue_free()
			await process_frame
			continue

		var cam := Camera3D.new()
		root.add_child(cam)

		var director: Node = director_script.new()
		director.name = "Director_%s" % level
		root.add_child(director)
		director.setup(loader, cam, loader.last_level_data)

		var fp: bool = loader.has_first_person()
		var has_ast: bool = director._has_wdl_ast()
		var interpreted: bool = director._wdl_interp != null
		var scripted: bool = director.scripted_camera

		# Mirrors setup()'s own branch order (2026-07-30: no more hand-port
		# opt-out -- every level with a parsed AST goes through the
		# interpreter): the interpreter running means the level's script is
		# live; the generic scripted fallback is legitimate too. Only the
		# true bottom "else" is inert.
		var inert := not fp and not interpreted and not scripted

		var outcome := "?"
		if fp and interpreted:
			outcome = "fp + interpreted"
		elif fp:
			outcome = "fp only"
		elif interpreted:
			outcome = "interpreted"
		elif scripted:
			outcome = "generic scripted"
		else:
			outcome = "INERT (free camera)"

		if inert and has_ast:
			inert_with_ast.append(level)

		# A level whose .wdl exists but which reports has_ast=false is a
		# SEPARATE and worse failure than "inert with an AST", and the check
		# above cannot see it: with has_ast false everywhere, "zero levels with
		# an AST reached the inert branch" is trivially true and this test goes
		# green while the whole game runs as inert scenery.
		#
		# That is exactly what happened on 2026-08-10 with the runtime WDL flag
		# on: wdl_director._wdl_ast_stem() probed assets/converted/wdl_ast/,
		# which no longer existed, so every level reported "no script" and the
		# suite still passed. Ask the authoritative question instead -- does a
		# source exist for this level -- and fail loudly when one does but the
		# director cannot see it.
		if not has_ast and WdlCache.source_path(level) != "":
			script_but_no_ast.append(level)

		print("%-10s %-5s %-7s %-11s %-14s %s" % [
			level, fp, has_ast, interpreted, scripted, outcome
		])
		ok_count += 1

		# Yield a couple of frames before freeing so this level's
		# fire-and-forget coroutines (if any got started) actually get
		# torn down before the next level piles more on top -- running the
		# whole roster with zero yields is what made the first version of
		# this script look hung (all deferred frees + all interpreter
		# coroutines queued up with no chance to run or clean up).
		director.queue_free()
		cam.queue_free()
		loader.queue_free()
		await process_frame
		await process_frame

	print("\n%d/%d levels dispatched." % [ok_count, roster.size()])
	if not missing_json.is_empty():
		print("SKIPPED (no level JSON): %s" % ", ".join(missing_json))
	if not script_but_no_ast.is_empty():
		print(
			"\nFAIL: %d level(s) have a .wdl source but the director reports NO AST: %s"
			% [script_but_no_ast.size(), ", ".join(script_but_no_ast)]
		)
		print(
			"      These run as inert scenery -- geometry renders, no camera, no sound, no logic."
			+ " The old 'zero levels with an AST reached the inert branch' check CANNOT see this,"
			+ " because with has_ast false everywhere it is trivially satisfied."
		)
		quit(1)
	elif not inert_with_ast.is_empty():
		print(
			"\nFAIL: %d level(s) have a parsed WDL AST but reached the inert free-camera branch: %s"
			% [inert_with_ast.size(), ", ".join(inert_with_ast)]
		)
		quit(1)
	else:
		print("\nOK: zero levels with an AST reached the inert branch, and every level with a .wdl source has one.")
		quit(0)


func _load_full_roster() -> Array[String]:
	var path := "res://assets/converted/levels.json"
	var txt := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(txt)
	var names: Array[String] = []
	if typeof(data) != TYPE_DICTIONARY:
		return names
	var levels: Dictionary = data.get("levels", {})
	for k in levels.keys():
		names.append(str(k))
	names.sort()
	return names
