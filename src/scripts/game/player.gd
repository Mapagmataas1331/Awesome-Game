extends CharacterBody3D

@export var move_speed: float = 5.0
@export var jump_force: float = 2.0
@export var rotate_speed: float = 0.002

var target_position: Vector3
var target_rotation: Vector3

func _ready():
	target_position = global_transform.origin
	target_rotation = rotation

func _physics_process(delta):
	if is_local_player():
		handle_local_input(delta)
	else:
		interpolate_position(delta)

func is_local_player() -> bool:
	return get_instance_id() == GameManager.local_player_id

func handle_local_input(delta):
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var move_dir = Vector3(input_dir.x, 0, input_dir.y).normalized()
	var velocity = move_dir * move_speed * delta
	
	if move_dir.length() > 0:
		global_translate(velocity)
		GameManager.send_player_state()
	
	if Input.is_action_just_pressed("move_up") and is_on_floor():
		velocity.y = jump_force
	
	# Mouse look
	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var mouse_input = Input.get_last_mouse_velocity() * SettingsManager.mouse_sensitivity
		rotate_y(-mouse_input.x * rotate_speed)
		$Camera.rotate_x(-mouse_input.y * rotate_speed)
		$Camera.rotation.x = clamp($Camera.rotation.x, -PI/4, PI/4)
		GameManager.send_player_state()

func interpolate_position(delta):
	global_transform.origin = global_transform.origin.lerp(target_position, delta * 10.0)
	rotation = rotation.lerp(target_rotation, delta * 10.0)

func update_state(new_position: Vector3, new_rotation: Vector3):
	target_position = new_position
	target_rotation = new_rotation
