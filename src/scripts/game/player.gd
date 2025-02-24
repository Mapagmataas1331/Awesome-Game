extends CharacterBody3D

@export var move_speed: float = 7.5
@export var jump_force: float = 5.0
@export var rotate_speed: float = 1.0

var target_position: Vector3
var target_rotation: Vector3
var update_interval := 0.1
var is_local := false
var last_update := 0.0
var last_key_event := 0.0

func _ready():
	target_position = global_transform.origin
	target_rotation = rotation
	$Camera3D.current = is_local
	
	if is_local:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		set_process_input(false)

func _input(event):
	if is_local and event is InputEventKey:
		var now = Time.get_unix_time_from_system()
		if now - last_key_event >= 0.25:
			if event.keycode == KEY_ESCAPE or event.keycode == KEY_TAB:
				if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
					Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				else:
					Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			last_key_event = now

func _physics_process(delta):
	if is_local:
		handle_local_input(delta)
		send_state_update()
	else:
		interpolate_state(delta)

func handle_local_input(delta):
	# Keyboard movement
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	var additional_speed = 0.0
	if !is_on_floor(): additional_speed += move_speed / 10
	
	if direction:
		velocity.x = direction.x * (move_speed + additional_speed)
		velocity.z = direction.z * (move_speed + additional_speed)
	else:
		velocity.x = move_toward(velocity.x, 0, move_speed + additional_speed)
		velocity.z = move_toward(velocity.z, 0, move_speed + additional_speed)

	# Jumping
	if is_on_floor() and Input.is_action_just_pressed("move_up"):
		velocity.y = jump_force

	# Apply gravity
	if not is_on_floor():
		velocity.y -= GameManager.gravity * delta

	move_and_slide()

	# Mouse look
	var mouse_input = Input.get_last_mouse_velocity() * SettingsManager.mouse_sensitivity / 1000000
	rotate_y(-mouse_input.x * rotate_speed)
	$Camera3D.rotate_x(-mouse_input.y * rotate_speed)
	$Camera3D.rotation.x = clamp($Camera3D.rotation.x, -PI/4, PI/4)

func interpolate_state(delta):
	global_transform.origin = global_transform.origin.lerp(target_position, delta * 20.0)
	rotation = rotation.lerp(target_rotation, delta * 20.0)

func send_state_update():
	var now = Time.get_unix_time_from_system()
	if now - last_update >= update_interval and GameManager.lobby:
		GameManager.lobby.send_data_channel_message({
			"type": "player_state",
			"player_id": GameManager.local_player_id,
			"position": {
				"x": global_transform.origin.x,
				"y": global_transform.origin.y,
				"z": global_transform.origin.z
			},
			"rotation": {
				"x": rotation.x,
				"y": rotation.y,
				"z": rotation.z
			}
		})
		last_update = now

func update_network_state(new_position: Vector3, new_rotation: Vector3):
	target_position = new_position
	target_rotation = new_rotation
