extends BaseLobby
class_name SteamLobby

const STEAM_APP_ID = 480
const DEFAULT_LOBBY_NAME = "Awesome Game Lobby"

var lobby_id: int = 0
var steam_initialized := false

func _ready():
	var initialize_response: Dictionary = Steam.steamInitEx( true, 480 )
	print("Steam successfully initialize with status: %s, Ex %s" % [Steam.steamInit().status, initialize_response.status])
	if Steam.steamInit().status == Steam.RESULT_OK && initialize_response.status == 0:
		steam_initialized = true
		Steam.lobby_joined.connect(_on_lobby_joined)
		Steam.p2p_session_request.connect(_on_p2p_request)
		Steam.p2p_session_connect_fail.connect(_on_p2p_fail)
		Steam.lobby_chat_update.connect(_on_lobby_chat_update)
	else:
		push_error("Steam Failed to initialize with status: %s, Ex %s" % [Steam.steamInit().status, initialize_response.status])
	
	super._ready()
	init_ui()

func init_ui():
	var ui = $UI/SteamUI
	ui.get_node("CreateButton").pressed.connect(create_lobby)
	ui.get_node("ReadyButton").pressed.connect(_on_ready_pressed)
	ui.get_node("LeaveButton").pressed.connect(_on_leave_pressed)

func _on_ready_pressed():
	var local_id = GameManager.local_player_id
	GameManager.players[local_id].ready = !GameManager.players[local_id].ready
	send_player_state()

func create_lobby():
	if steam_initialized:
		var lobby_type = Steam.LOBBY_TYPE_PUBLIC
		var max_members = 4
		Steam.createLobby(lobby_type, max_members)
	else:
		push_error("Steam not initialized!")

func _on_lobby_joined(new_lobby_id: int, permissions: int, locked: bool, response: int):
	lobby_id = new_lobby_id
	Steam.setLobbyData(lobby_id, "name", DEFAULT_LOBBY_NAME)
	Steam.setLobbyJoinable(lobby_id, true)
	
	var member_count = Steam.getNumLobbyMembers(lobby_id)
	for i in range(member_count):
		var member_id = Steam.getLobbyMemberByIndex(lobby_id, i)
		_add_steam_peer(member_id)
	
	update_player_list()
	$UI/SteamUI/LobbyTitle.text = Steam.getLobbyData(lobby_id, "name")

func _add_steam_peer(member_id: int):
	if not players.has(member_id):
		var new_player = preload("res://assets/scenes/game/player.tscn").instantiate()
		$Players.add_child(new_player)
		players[member_id] = new_player
		# Initialize with default position
		new_player.global_transform.origin = Vector3(randf_range(-2,2), 0, randf_range(-2,2))
		GameManager.register_player(member_id, {
			"name": Steam.getFriendPersonaName(member_id),
			"position": new_player.global_transform.origin,
			"ready": false
		})

func update_player_list():
	var members = []
	for i in range(Steam.getNumLobbyMembers(lobby_id)):
		var steam_id = Steam.getLobbyMemberByIndex(lobby_id, i)
		members.append({
			"id": steam_id,
			"name": Steam.getFriendPersonaName(steam_id),
			"ready": GameManager.players[steam_id].ready
		})
	
	var list_node = $UI/SteamUI/PlayerList
	for child in list_node.get_children():
		child.queue_free()
	for member in members:
		var label = Label.new()
		label.text = "%s [%s]" % [member.name, "READY" if member.ready else "NOT READY"]
		list_node.add_child(label)

func _on_p2p_request(remote_steam_id: int):
	Steam.acceptP2PSessionWithUser(remote_steam_id)

func _on_p2p_fail(steam_id: int, session_error: int):
	print("P2P connection failed with %d: error %d" % [steam_id, session_error])
	remove_player(steam_id)

func _on_lobby_chat_update(lobby_id: int, changed_id: int, making_id: int, chat_state: int):
	match chat_state:
		Steam.ChatMemberStateChange.CHAT_MEMBER_STATE_CHANGE_LEFT, Steam.ChatMemberStateChange.CHAT_MEMBER_STATE_CHANGE_KICKED, Steam.ChatMemberStateChange.CHAT_MEMBER_STATE_CHANGE_BANNED:
			remove_player(changed_id)

func remove_player(steam_id: int):
	if players.has(steam_id):
		players[steam_id].queue_free()
		players.erase(steam_id)
	GameManager.players.erase(steam_id)
	update_player_list()

func send_player_state():
	if not steam_initialized:
		return
	
	var state = {
		"ready": GameManager.players[GameManager.local_player_id].ready,
		"position": local_player.global_transform.origin,
		"rotation": local_player.rotation
	}
	
	var json_state = JSON.stringify(state)
	for member_id in players:
		if member_id != GameManager.local_player_id:
			Steam.sendP2PPacket(member_id, json_state.to_utf8_buffer(), Steam.P2P_SEND_RELIABLE)

func _process(delta):
	if steam_initialized:
		Steam.run_callbacks()

func handle_packet(steam_id: int, data: String):
	var json = JSON.new()
	if json.parse(data) == OK:
		var state = json.data
		if players.has(steam_id):
			# Update player state through interpolation
			players[steam_id].update_state(
				Vector3(state.position.x, state.position.y, state.position.z),
				Vector3(state.rotation.x, state.rotation.y, state.rotation.z)
			)
			
			if state.has("ready"):
				GameManager.players[steam_id].ready = state.ready
				update_player_list()

func _on_leave_pressed():
	if steam_initialized && lobby_id != 0:
		Steam.leaveLobby(lobby_id)
	get_tree().change_scene_to_file("res://assets/scenes/ui/main_menu.tscn")
