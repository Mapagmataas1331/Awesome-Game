extends BaseLobby
class_name SteamLobby

var lobby_id: int = 0
var steam_peers := {}

func _ready():
	super()
	if Steam.steamInit():
		Steam.lobby_created.connect(_on_lobby_created)
		Steam.lobby_joined.connect(_on_lobby_joined)
		Steam.p2p_session_request.connect(_on_p2p_request)
		Steam.p2p_session_connect_fail.connect(_on_p2p_fail)

func create_lobby():
	Steam.createLobby(Steam.LOBBY_TYPE_FRIENDS_ONLY, 4)

func _on_lobby_created(result: int, new_lobby_id: int):
	if result == 1:
		lobby_id = new_lobby_id
		Steam.setLobbyData(lobby_id, "name", "Steam Lobby")
		_update_ui()

func _on_lobby_joined(new_lobby_id: int):
	lobby_id = new_lobby_id
	var members = Steam.getNumLobbyMembers() getLobbyMembers(lobby_id)
	for member in members:
		_add_steam_peer(member)
	_update_ui()

func _add_steam_peer(steam_id: int):
	Steam.acceptP2PSessionWithUser(steam_id)
	steam_peers[steam_id] = {"connected": true}

func _on_p2p_request(remote_steam_id: int):
	Steam.acceptP2PSessionWithUser(remote_steam_id)

func _on_p2p_fail(steam_id: int, session_error: int):
	print("P2P failed with ", steam_id, " error: ", session_error)

func _update_ui():
	# Implement your Steam-specific UI updates here
	pass
