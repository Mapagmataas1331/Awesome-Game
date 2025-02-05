extends Control


func _ready():
	$StartButton.connect("pressed", _on_start_pressed)
	
	if OS.has_feature('web'):
		var audio_player = AudioStreamPlayer.new()
		add_child(audio_player)
		audio_player.play()
		audio_player.stop()
		audio_player.queue_free()

func _on_start_pressed():
	get_tree().change_scene_to_file("res://assets/scenes/ui/main_menu.tscn")
