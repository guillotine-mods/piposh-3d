extends SceneTree
## Headless: spawn Studio/Start/Town and verify MdlAnimator attachment.
## godot --headless --path . -s res://tools/smoke_anim.gd


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures := 0
	for level in ["Studio", "Start", "Town"]:
		var host := Node3D.new()
		root.add_child(host)
		var loader := WmbLevelLoader.new()
		host.add_child(loader)
		await process_frame
		var ok := loader.load_level(level)
		if not ok:
			print("FAIL load ", level)
			failures += 1
			host.queue_free()
			continue
		var ents := loader.get_node("Entities")
		var anim_count := 0
		var checked := {}
		for n in ents.get_children():
			var action := str(n.get_meta("action", ""))
			if action in ["Ami", "Naknik", "DefineYachdel", "Crowd", "Cow", "PatrolCity"]:
				var anim := n.get_node_or_null("MdlAnimator")
				var key := action
				if not checked.has(key):
					checked[key] = true
					if anim == null:
						print("FAIL %s missing animator on %s (%s)" % [level, n.name, action])
						failures += 1
					else:
						print("OK %s animator on %s action=%s" % [level, n.name, action])
						anim_count += 1
		# Verify mdlanim readable for Ami
		if level == "Studio":
			if not FileAccess.file_exists("res://assets/converted/mdl/Ami.mdlanim"):
				print("FAIL Ami.mdlanim missing")
				failures += 1
			else:
				print("OK Ami.mdlanim present")
		print("OK %s load animators_checked=%d" % [level, anim_count])
		host.queue_free()
		await process_frame

	print("Anim smoke done failures=%d" % failures)
	quit(1 if failures > 0 else 0)
