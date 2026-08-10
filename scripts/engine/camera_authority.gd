extends RefCounted
## Formalizes the camera-authority arbitration between the native FP
## controller's own Camera3D and the WDL-driven script Camera3D.
##
## Real Acknex has exactly one camera: whichever code last wrote camera.x/y/z
## /pan/tilt/roll this tick owns what's rendered. Godot has two separate
## Camera3D nodes (player's own vs. the level's script camera), so this
## object is the single place that decides which one has `.current = true`
## on any given frame, instead of that decision being split across
## LevelRunner and WdlInterpreter fields (see docs/CONTRACT.md §4.1.1).
##
## Non-fp levels (scripted or free-roam) pick their camera once at setup and
## never contend for it, so this only needs to arbitrate per-frame in FP mode.

enum State { PLAYER_FP, SCRIPT }

var _state: State = State.PLAYER_FP
var _player_cam: Camera3D
var _script_cam: Camera3D
var _interp: Object
## Reported live (2026-08-11), Inn: "there's no Piposh character in the
## Inn level... a black ball floating statically instead" (the black-ball
## half is a separate, real Dummy.MDL-hiding bug, fixed in
## WmbLevelLoader). The "no Piposh" half is this: `_spawn_entity()`'s own
## `move_view_1st GENIUS -- don't draw the player body in FP` hides the
## WED-placed body ONCE, at spawn, unconditionally, for every level with a
## `player_walk*` action -- correct for genuine first-person gameplay, but
## Inn (like several other FP levels) also has a real, scripted THIRD-
## PERSON establishing shot before/around normal walking (`action Watch`,
## a fixed external camera-marker entity watching the room) -- during
## that shot the render camera is external, not the player's own eyes, so
## hiding the body was backwards for exactly that moment: there's nothing
## wrong to look at from outside if the body is always hidden regardless
## of which camera is actually active. Now toggled dynamically in lockstep
## with the same script/FP authority switch already computed every frame
## below, instead of being a permanent one-time decision made at spawn.
var _fp_body: Node3D


func configure(player_cam: Camera3D, script_cam: Camera3D, interp: Object, fp_body: Node3D = null) -> void:
	_player_cam = player_cam
	_script_cam = script_cam
	_interp = interp
	_fp_body = fp_body
	_state = State.PLAYER_FP


## Call once per frame while the level is in fp mode. No-op otherwise (fixed
## camera-mode levels never call this at all).
func update() -> void:
	if _player_cam == null or _script_cam == null or _interp == null:
		return
	var script_driving: bool = _interp.call("is_driving_camera_this_frame")
	var wanted := State.SCRIPT if script_driving else State.PLAYER_FP
	if wanted == _state:
		return
	_state = wanted
	_script_cam.current = wanted == State.SCRIPT
	_player_cam.current = wanted == State.PLAYER_FP
	if _fp_body:
		# `_hide_meshes()` (WmbLevelLoader) hides each MeshInstance3D's own
		# `visible`, not just the shared parent's -- toggling the parent
		# alone wouldn't undo that, so mirror it with an equivalent
		# recursive per-mesh set here.
		_set_meshes_visible(_fp_body, wanted == State.SCRIPT)


func _set_meshes_visible(node: Node, vis: bool) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).visible = vis
	for c in node.get_children():
		_set_meshes_visible(c, vis)
