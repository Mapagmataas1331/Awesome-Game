extends Control

@onready var tab_container = $TabContainer
@onready var graphics_tab = $TabContainer/Graphics
@onready var audio_tab = $TabContainer/Audio
@onready var controls_tab = $TabContainer/Controls
@onready var resolution_options = $TabContainer/Graphics/ResolutionOptions

func _ready():
	_init_resolution_options()
	load_current_settings()
	
	graphics_tab.find_child("FullscreenCheck").toggled.connect(_on_fullscreen_toggled)
	graphics_tab.find_child("VSyncCheck").toggled.connect(_on_vsync_toggled)
	audio_tab.find_child("VolumeSlider").value_changed.connect(_on_volume_changed)
	controls_tab.find_child("SensitivitySlider").value_changed.connect(_on_sensitivity_changed)
	$BackButton.pressed.connect(_on_back_pressed)
	$SaveButton.pressed.connect(_on_save_pressed)

func _init_resolution_options():
	resolution_options.clear()
	
	if OS.has_feature("web"):
		resolution_options.add_item("not applicable");
	
	else:
		# Add presets
		for label in SettingsManager.resolution_presets:
			resolution_options.add_item(label)
		
		var current_label = "%dx%d" % [SettingsManager.resolution.x, SettingsManager.resolution.y]
		var found = false
		
		for i in resolution_options.item_count:
			if resolution_options.get_item_text(i) == current_label:
				found = true
				break
		
		if not found:
			resolution_options.add_item(current_label)
		
		resolution_options.item_selected.connect(_on_resolution_selected)

func load_current_settings():
	# Graphics
	graphics_tab.find_child("FullscreenCheck").button_pressed = SettingsManager.fullscreen
	graphics_tab.find_child("VSyncCheck").button_pressed = SettingsManager.vsync
	
	# Resolution
	if not OS.has_feature("web"):
		var current_label = "%dx%d" % [SettingsManager.resolution.x, SettingsManager.resolution.y]
		for i in resolution_options.item_count:
			if resolution_options.get_item_text(i) == current_label:
				resolution_options.selected = i
				break
	
	# Audio
	audio_tab.find_child("VolumeSlider").value = SettingsManager.master_volume
	
	# Controls
	controls_tab.find_child("SensitivitySlider").value = SettingsManager.mouse_sensitivity

func _on_resolution_selected(index: int):
	var selected_text = resolution_options.get_item_text(index)
	var res = SettingsManager.resolution_presets.get(selected_text, SettingsManager.resolution)
	SettingsManager.resolution = res
	SettingsManager.apply_settings()

func _on_fullscreen_toggled(value: bool):
	SettingsManager.fullscreen = value
	SettingsManager.apply_settings()

func _on_vsync_toggled(value: bool):
	SettingsManager.vsync = value
	SettingsManager.apply_settings()

func _on_volume_changed(value: float):
	SettingsManager.master_volume = value
	SettingsManager.apply_settings()

func _on_sensitivity_changed(value: float):
	SettingsManager.mouse_sensitivity = value
	SettingsManager.apply_settings()

func _on_back_pressed():
	SettingsManager.load_settings()
	SettingsManager.apply_settings()
	get_tree().change_scene_to_file("res://src/scenes/ui/main_menu.tscn")

func _on_save_pressed():
	SettingsManager.save_settings()
	get_tree().change_scene_to_file("res://src/scenes/ui/main_menu.tscn")
