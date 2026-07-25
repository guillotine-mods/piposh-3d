extends SceneTree
## Headless smoke test: load Menu + Studio JSON paths and print results.
## Run: godot --headless --path . -s res://tools/smoke_test.gd


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var levels := ["Menu", "Studio", "Start", "Town", "Credits", "Map"]
	var ok_count := 0
	for level in levels:
		var path := "res://assets/converted/levels/%s.json" % level
		if not FileAccess.file_exists(path):
			# case fallback
			var found := false
			var dir := DirAccess.open("res://assets/converted/levels/")
			if dir:
				dir.list_dir_begin()
				var fn := dir.get_next()
				while fn != "":
					if fn.to_lower() == (level.to_lower() + ".json"):
						path = "res://assets/converted/levels/" + fn
						found = true
						break
					fn = dir.get_next()
			if not found:
				print("FAIL missing json: ", level)
				continue
		var txt := FileAccess.get_file_as_string(path)
		var data = JSON.parse_string(txt)
		if typeof(data) != TYPE_DICTIONARY:
			print("FAIL bad json: ", level)
			continue
		var ents: Array = []
		for o in data.get("objects", []):
			if typeof(o) == TYPE_DICTIONARY and o.get("type") == "entity":
				ents.append(o)
		var missing := 0
		for o in ents:
			var file := str(o.get("file", ""))
			if file.to_lower().ends_with(".wmb"):
				continue
			var stem := file.get_file().get_basename().to_lower()
			var glb := "res://assets/converted/mdl/%s.glb" % o.get("file", "").get_file().get_basename()
			if not ResourceLoader.exists(glb):
				# case scan
				var found_glb := false
				var d2 := DirAccess.open("res://assets/converted/mdl/")
				if d2:
					d2.list_dir_begin()
					var g := d2.get_next()
					while g != "":
						if g.to_lower() == stem + ".glb":
							found_glb = true
							break
						g = d2.get_next()
				if not found_glb:
					missing += 1
		print(
			"OK %s entities=%d missing_mdl=%d spawn=%s"
			% [level, ents.size(), missing, str(data.get("spawn", []))]
		)
		ok_count += 1

	# Autoload / scene existence
	for scene in [
		"res://scenes/boot.tscn",
		"res://scenes/main_menu.tscn",
		"res://scenes/level_runner.tscn",
	]:
		print(("OK scene " if ResourceLoader.exists(scene) else "FAIL scene "), scene)

	print("Smoke done: %d/%d levels" % [ok_count, levels.size()])
	quit(0 if ok_count == levels.size() else 1)
