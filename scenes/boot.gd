extends Control

@onready var splash: TextureRect = $Splash
@onready var status: Label = $Status


func _ready() -> void:
	var splash_path := "res://assets/converted/gfx/A5.png"
	if ResourceLoader.exists(splash_path):
		splash.texture = load(splash_path)
	status.text = "Piposh 3D — Godot port"
	await get_tree().create_timer(1.5).timeout
	if GameState.skip_intro_movies:
		LevelRouter.goto_level("Menu")
	else:
		LevelRouter.goto_level("Start")
