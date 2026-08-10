extends Control

@onready var splash: TextureRect = $Splash
@onready var status: Label = $Status


func _ready() -> void:
	var splash_path := "res://assets/converted/gfx/A5.png"
	if ResourceLoader.exists(splash_path):
		splash.texture = load(splash_path)
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
