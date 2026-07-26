extends Node
## Single on/off switch for the ad-hoc debug prints added while chasing
## playtest-reported bugs (see docs/CONTRACT.md #6, docs/SESSION_LOG.md).
## Flip ENABLED to false (or delete the call sites) once a bug is confirmed
## fixed instead of leaving prints scattered and un-toggleable.

const ENABLED := true


func log_msg(tag: String, msg: String) -> void:
	if ENABLED:
		print("[%s] %s" % [tag, msg])
