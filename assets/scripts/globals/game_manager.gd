extends Node

signal all_players_ready
signal player_joined(player_info)
signal player_left(player_id)

var players := {}
var local_player_id: int
var lobby: BaseLobby
var network_mode: String = "offline"  # steam|webrtc|offline

func register_player(player_id: int, player_data: Dictionary):
	players[player_id] = player_data
	emit_signal("player_joined", player_data)
	check_all_ready()

func remove_player(player_id: int):
	if players.has(player_id):
		players.erase(player_id)
		emit_signal("player_left", player_id)
		check_all_ready()

func check_all_ready():
	for player in players.values():
		if not player.get("ready", false):
			return
	all_players_ready.emit()

func transition_to_game():
	if network_mode == "steam":
		Steam.setLobbyJoinable(lobby.lobby_id, false)
	get_tree().change_scene_to_file("res://assets/scenes/game/world.tscn")

func send_player_state():
	if lobby:
		lobby.send_player_state()

func leave_lobby():
	if lobby:
		if lobby is SteamLobby:
			Steam.leaveLobby(lobby.lobby_id)
		elif lobby is WebRTCLobby:
			lobby.peer.close()
		lobby.queue_free()
		lobby = null
	players.clear()
