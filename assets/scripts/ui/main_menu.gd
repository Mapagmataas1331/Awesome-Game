extends Control

func _ready():
	if OS.has_feature('web'):
		$VBoxContainer/SteamButton.disabled = true;
	else:
		$VBoxContainer/SteamButton.connect("pressed", _on_steam_pressed)
		
	$VBoxContainer/WebRTCButton.connect("pressed", _on_webrtc_pressed)
	$VBoxContainer/SettingsButton.connect("pressed", _on_settings_pressed)
	$VBoxContainer/ExitButton.connect("pressed", _on_exit_pressed)

func _on_steam_pressed():
	get_tree().change_scene_to_file("res://assets/scenes/lobby/steam.tscn")

func _on_webrtc_pressed():
	get_tree().change_scene_to_file("res://assets/scenes/lobby/webRTC.tscn")

func _on_settings_pressed():
	get_tree().change_scene_to_file("res://assets/scenes/ui/settings_menu.tscn")

func _on_exit_pressed():
	if not OS.has_feature('web'):
		get_tree().quit()
	else:
		JavaScriptBridge.eval("window.location.href = '/'")
