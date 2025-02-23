extends Node3D
class_name BaseLobby

# Common lobby functionality signals.
signal player_list_updated
signal game_started

var players := {}      # Dictionary to keep track of player nodes.
var local_player: Node3D
var lobby_ui: CanvasLayer
var local_player_id := ""

func _ready() -> void:
	# Initialize network (overridden in child classes if needed)
	initialize_network()
	# Create and register the local player
	create_local_player()
	# Set up the lobby UI (which is assumed to be already instanced in the scene under the "UI" node)
	setup_ui()
	# Connect to the global signal to start the game when everyone is ready.
	GameManager.all_players_ready.connect(_on_all_players_ready)
	# NEW: Set the active lobby reference in GameManager.
	GameManager.lobby = self

# Creates the local player and registers it with the GameManager.
func create_local_player() -> void:
	if local_player_id != "":
		GameManager.local_player_id = local_player_id
		GameManager.register_player(GameManager.local_player_id, {
			"name": get_player_name(),
			"position": local_player.global_transform.origin,
			"ready": false
		})

# Loads the UI (assumed to be already instanced in the scene under the "UI" node).
func setup_ui() -> void:
	lobby_ui = get_node("UI")
	if lobby_ui.has_method("setup"):
		lobby_ui.setup(self)

# Called when all players are ready; transitions to the game.
func _on_all_players_ready():
	start_game()

# Starts the game (for example, transitions to a game scene).
func start_game() -> void:
	emit_signal("game_started")
	GameManager.transition_to_game()

# Update a player’s position.
func update_player_position(id: int, position: Vector3) -> void:
	if players.has(id):
		players[id].global_transform.origin = position


# Returns the player name (override as needed).
func get_player_name() -> String:
	return "Player"

# Initialize network specifics (override in child classes such as SteamLobby or WebRTCLobby).
func initialize_network() -> void:
	pass

# Send the local player’s state over the network.
func send_player_state() -> void:
	pass

# Optional stub for create_lobby() so child classes can call super.create_lobby().
func create_lobby() -> void:
	pass
