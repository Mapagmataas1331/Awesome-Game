extends Node3D
class_name BaseLobby

var local_player: Node3D
var players := {}

func _ready():
	# Common initialization
	load_world()
	spawn_local_player()
	setup_controls()

func load_world():
	# Load 3D environment
	pass

func spawn_local_player():
	var player_scene = preload("res://assets/scenes/characters/player.tscn")
	local_player = player_scene.instantiate()
	$Players.add_child(local_player)

func setup_controls():
	# Common movement controls
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func update_player_position(id: int, position: Vector3):
	if players.has(id):
		players[id].global_transform.origin = position

# Network abstraction methods (to be implemented per provider)
func create_lobby(): pass
func join_lobby(lobby_id: String): pass
func send_player_state(): pass
