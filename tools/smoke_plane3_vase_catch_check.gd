extends SceneTree
## Reported live (2026-08-08): "after the 2nd dialogue choice ... he's
## getting stuck mid flight where the vase is and the game is stuck" --
## Plane3's "bird catches the vase" cutscene (action BadBird, after
## DialogIndex 6) never reached Run("Smash.exe"). Root-caused to THREE
## separate, real interpreter bugs, all fixed here:
##
## 1. GetPosition(Voice) debounce collision within a SINGLE entity's own
##    coroutine: `action Dome`'s Scene-poll and BadBird2/BadBird's own
##    dialogue-wait loop shared one (caller, generation) debounce key,
##    so one starved the other. Fixed via per-(caller, call-site,
##    generation) keying (_call_site_id()).
## 2. `_do_create()` never checked `_functions` for create()'s own 3rd
##    (initial-action) argument -- only `_actions` -- so
##    `create(<gibbit.mdl>, MY.POS, _gib_action)` (WDL/war.wdl's `_gib()`,
##    called by BadBird right before the vase catch) spawned 20 debris
##    entities with an action tag but no coroutine ever started. Fixed
##    via a _resolve_function() fallback.
## 3. The big one: `my = X;` (WDL's reassignable MY/ME pointer register)
##    was a silent no-op -- `_get_var("my")` always returned the real
##    per-coroutine `my` parameter, but `_set_var("my", ...)` wrote to a
##    dead, never-read global. `action BadBird`'s own
##    `my = TheVase; _gib(20); actor_explode(); my = Birdy;` therefore
##    ran `ACTION actor_explode` (WDL/weapons.wdl, ends with
##    `remove(ME);`) against BadBird itself instead of TheVase --
##    removing BadBird mid-script, which silently halts ALL of its own
##    further execution (see _entity_alive()) and with it the level's
##    only path to Run("Smash.exe"). Fixed by having exec_block()/
##    _exec_block_sync() track and thread a rebindable `current_my`
##    through a block's own sibling statements.
##
## Confirms the full chain end-to-end: forces the level straight to the
## post-choice, Yoyo>40 catch-the-vase moment (skipping the ~15s of real
## voice lines/climbing this doesn't need to re-verify -- those are
## already covered by smoke_plane3_dome_scale_check.gd /
## smoke_dialog_text_check.gd) and confirms BadBird survives the catch
## and the level actually transitions to Smash.
##
## Run: godot --headless --path . -s res://tools/smoke_plane3_vase_catch_check.gd

const LEVEL := "Plane3"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	root.get_node("Piposh3DState").set("current_level", LEVEL)

	var packed: PackedScene = load("res://scenes/level_runner.tscn")
	var runner: Node = packed.instantiate()
	root.add_child(runner)
	for i in 10:
		await process_frame

	var director: Node = runner.get("_director")
	var interp: Node = director.get("_wdl_interp") if director else null
	if interp == null:
		print("FAIL: no interpreter")
		quit(1)
		return

	# Skip straight to "choice made, dialogue resolved" -- the voice-line
	# climb itself is covered by other smoke tests.
	interp.call("_set_var", "Stage", 2.0, null)
	interp.call("_set_var", "Scene", 9.0, null)
	interp.call("_call", "SetVoice", [], null)
	for i in 5:
		await process_frame
	var hud: Node = runner.get("_game_hud")
	hud.call("hide_dialog")
	hud.dialog_choice.emit(2)

	for i in 400:
		await process_frame
		if interp.call("_get_var", "Dude", null) == 2.0:
			break

	for i in 400:
		await process_frame
		var player_ref = interp.call("_get_var", "player", null)
		if player_ref != null and float(interp.call("_get_field", {"t": "id", "name": "player"}, "skill5", null)) == 1.0:
			break

	var loader: Node = runner.get("loader")
	var entities: Node = loader.get_node("Entities")
	var badbird: Node3D = null
	for n in entities.get_children():
		if str(n.get_meta("action", "")) == "BadBird":
			badbird = n
			break
	if badbird == null:
		print("FAIL: BadBird entity never spawned")
		quit(1)
		return

	# Skip the ~13s Yoyo climb -- force straight to the catch threshold.
	interp.call("_set_var", "Yoyo", 41.0, null)

	var reached_smash := false
	for i in 300:
		await process_frame
		if not is_instance_valid(badbird):
			print("FAIL: BadBird was removed (my=TheVase/actor_explode() misfire) at frame=%d" % i)
			quit(1)
			return
		if root.get_node("Piposh3DState").current_level != LEVEL:
			reached_smash = true
			break

	print("BadBird alive=%s current_level=%s" % [is_instance_valid(badbird), root.get_node("Piposh3DState").current_level])
	var ok: bool = reached_smash and is_instance_valid(badbird)
	print("OK" if ok else "FAIL: never reached Run(Smash.exe)")
	quit(0 if ok else 1)
