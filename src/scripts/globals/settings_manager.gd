extends Node

# Resolution options with label/actual value pairs
var resolution_presets = {
	"640x360": Vector2i(640, 360),
	"854x480": Vector2i(854, 480),
	"960x540": Vector2i(960, 540),
	"1024x576": Vector2i(1024, 576),
	"1152x648": Vector2i(1152, 648),
	"1280x720": Vector2i(1280, 720),
	"1366x768": Vector2i(1366, 768),
	"1600x900": Vector2i(1600, 900),
	"1920x1080": Vector2i(1920, 1080),
	"2560x1440": Vector2i(2560, 1440),
	"3840x2160": Vector2i(3840, 2160)
}

# Default settings
var master_volume: float = 1.0
var fullscreen: bool = false
var vsync: bool = true
var resolution: Vector2i = Vector2i(1024, 576)
var mouse_sensitivity: float = 0.1
var player_name: String = "Player"

func _ready():
	load_settings()
	apply_settings()

func save_settings():
	if OS.has_feature('web'):
		JavaScriptBridge.eval("""
			localStorage.setItem('settings', JSON.stringify({
				master_volume: %s,
				fullscreen: %s,
				vsync: %s,
				resolution_x: %s,
				resolution_y: %s,
				mouse_sensitivity: %s,
				player_name: "%s"
			}))
		""" % [
			str(master_volume), 
			str(fullscreen).to_lower(), 
			str(vsync).to_lower(),
			str(resolution.x),
			str(resolution.y),
			str(mouse_sensitivity),
			str(player_name)
		])
	else:
		var config = ConfigFile.new()
		config.set_value("audio", "master_volume", master_volume)
		config.set_value("graphics", "fullscreen", fullscreen)
		config.set_value("graphics", "vsync", vsync)
		config.set_value("graphics", "resolution", resolution)
		config.set_value("controls", "mouse_sensitivity", mouse_sensitivity)
		config.set_value("game", "player_name", player_name)
		config.save("user://settings.cfg")
	
	apply_settings()

func load_settings():
	if OS.has_feature('web'):
		var settings_json = JavaScriptBridge.eval("localStorage.getItem('settings')")
		var settings = JSON.parse_string(settings_json)
		if settings:
			master_volume = settings.get("master_volume", 1.0)
			fullscreen = settings.get("fullscreen", true)
			vsync = settings.get("vsync", true)
			resolution = Vector2i(
				int(settings.get("resolution_x", 1152)),
				int(settings.get("resolution_y", 648))
			)
			mouse_sensitivity = settings.get("mouse_sensitivity", 0.1)
			player_name = settings.get("player_name", "Player")
		else:
			# Apply defaults if no settings found
			master_volume = 1.0
			fullscreen = true
			vsync = true
			resolution = Vector2i(1152, 648)
			mouse_sensitivity = 0.1
			player_name = "Player"
	else:
		var config = ConfigFile.new()
		if config.load("user://settings.cfg") == OK:
			master_volume = config.get_value("audio", "master_volume", 1.0)
			fullscreen = config.get_value("graphics", "fullscreen", true)
			vsync = config.get_value("graphics", "vsync", true)
			resolution = config.get_value("graphics", "resolution", Vector2i(1152, 648))
			mouse_sensitivity = config.get_value("controls", "mouse_sensitivity", 0.1)
			player_name = config.get_value("game", "player_name", "Player")
	
	# Clamp resolution to valid values
	resolution.x = clamp(resolution.x, 640, 3840)
	resolution.y = clamp(resolution.y, 360, 2160)

func apply_settings():
	var window = get_window()
	
	# Desktop-specific settings
	if not OS.has_feature('web'):
		var previous_mode = window.mode
		window.mode = Window.MODE_FULLSCREEN if fullscreen else Window.MODE_WINDOWED
		
		if !fullscreen:
			var current_size = window.size
			if current_size != resolution:
				window.size = resolution
				
				var screen_index = DisplayServer.window_get_current_screen()
				var screen_position = DisplayServer.screen_get_position(screen_index)
				var screen_size = DisplayServer.screen_get_size(screen_index)
				
				var new_position = screen_position + (screen_size / 2) - (resolution / 2)
				window.position = new_position
		
		# Apply VSync setting
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)

	# Web-specific settings
	else:
		if fullscreen:
			JavaScriptBridge.eval("if (!(document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement)) document.documentElement.requestFullscreen()")
		else:
			JavaScriptBridge.eval("if (document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement) document.exitFullscreen()")
	
	# Audio settings
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), linear_to_db(master_volume))
