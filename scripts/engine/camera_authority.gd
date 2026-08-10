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


func configure(player_cam: Camera3D, script_cam: Camera3D, interp: Object) -> void:
	_player_cam = player_cam
	_script_cam = script_cam
	_interp = interp
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
