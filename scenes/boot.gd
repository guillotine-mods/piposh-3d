extends Control

## Single GFX seam (0-py migration) — see `GfxBitmap.USE_RUNTIME_GFX`. Loads the
## converted PNG while that flag is false (the default), the original PCX/BMP
## when it is true. Deliberately NO `class_name` anywhere in this project
## (commit 5c0adfa: a global class inside a mounted .pck never resolves), so it
## is reached by preload only.
const GfxBitmap = preload("res://scripts/engine/gfx_bitmap.gd")

@onready var splash: TextureRect = $Splash
@onready var status: Label = $Status


func _ready() -> void:
	var splash_tex := GfxBitmap.get_texture("A5.png")
	if splash_tex != null:
		splash.texture = splash_tex
	status.text = "Piposh 3D — Godot port"

	# Restore the persisted skip-intro preference. It is deliberately NOT part
	# of Piposh3DState.to_dict()/from_dict() -- it is a preference rather than
	# game state -- so it lives in user://settings.cfg and is read here, before
	# the routing decision below.
	Piposh3DState.skip_intro_movies = bool(
			AudioChannels.get_setting("game", "skip_intro_movies", false))

	await get_tree().create_timer(1.5).timeout
	if Piposh3DState.skip_intro_movies:
		LevelRouter.goto_level("Menu")
	else:
		LevelRouter.goto_level("Start")
