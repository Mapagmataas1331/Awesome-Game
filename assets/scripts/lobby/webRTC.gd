extends BaseLobby
class_name WebRTCLobby

const SIGNALING_SERVER = "ws://thirsty-cherice-macyou-8179e8d5.koyeb.app/"
const ICE_SERVERS = [{"urls": ["stun:stun.l.google.com:19302"]}]

var peer: WebRTCPeerConnection
var signaling: WebSocketPeer
var lobby_code := ""
var is_host := false

func _ready():
	super._ready()
	init_network()
	init_ui()
	set_process(true)

func _process(delta):
	signaling.poll()
	match signaling.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			_handle_open_connection()
		WebSocketPeer.STATE_CLOSED:
			_handle_closed_connection()

func init_network():
	signaling = WebSocketPeer.new()
	# REMOVE THE DATA_RECEIVED SIGNAL CONNECTION
	signaling.connect_to_url(SIGNALING_SERVER)

func init_ui():
	var ui = $UI/WebRTCUI
	ui.get_node("CreateButton").pressed.connect(create_lobby)
	ui.get_node("ConnectButton").pressed.connect(join_lobby)
	ui.get_node("ReadyButton").pressed.connect(_on_ready_pressed)
	ui.get_node("LeaveButton").pressed.connect(_on_leave_pressed)
	update_code_display()

func _handle_open_connection():
	while signaling.get_available_packet_count() > 0:
		var packet = signaling.get_packet()
		var data = JSON.parse_string(packet.get_string_from_utf8())
		if data:
			match data.type:
				"offer":
					peer.set_remote_description("offer", data.sdp)
					peer.create_answer()
				"answer":
					peer.set_remote_description("answer", data.sdp)
				"ice":
					peer.add_ice_candidate(data.candidate.mid, data.candidate.index, data.candidate.sdp)
				"code":
					lobby_code = data.code
					update_code_display()

func _on_ready_pressed():
	var local_id = GameManager.local_player_id
	GameManager.players[local_id].ready = !GameManager.players[local_id].ready
	send_player_state()

func create_lobby():
	peer = WebRTCPeerConnection.new()
	peer.initialize({"iceServers": ICE_SERVERS})
	peer.ice_candidate_created.connect(_on_ice_candidate)
	peer.session_description_created.connect(_on_session_description)
	
	var data_channel = peer.create_data_channel("game", {"id": 1, "negotiated": true})
	data_channel.message_received.connect(_on_data_received)
	
	is_host = true
	generate_lobby_code()
	peer.create_offer()

func join_lobby():
	var code = $UI/WebRTCUI/LineEdit.text.strip_edges()
	if code.length() != 6:
		return
	
	peer = WebRTCPeerConnection.new()
	peer.initialize({"iceServers": ICE_SERVERS})
	peer.ice_candidate_created.connect(_on_ice_candidate)
	peer.session_description_created.connect(_on_session_description)
	
	signaling.send_text(JSON.stringify({
		"type": "join",
		"code": code
	}))

func _on_ice_candidate(mid, index, sdp):
	signaling.send_text(JSON.stringify({
		"type": "ice",
		"code": lobby_code,
		"candidate": {"mid": mid, "index": index, "sdp": sdp}
	}))

func _on_session_description(type, sdp):
	signaling.send_text(JSON.stringify({
		"type": type,
		"code": lobby_code,
		"sdp": sdp
	}))

func _on_signaling_data():
	var packet = signaling.get_packet()
	var data = JSON.parse_string(packet.get_string_from_utf8())
	if data:
		match data.type:
			"offer":
				peer.set_remote_description("offer", data.sdp)
				peer.create_answer()
			"answer":
				peer.set_remote_description("answer", data.sdp)
			"ice":
				peer.add_ice_candidate(data.candidate.mid, data.candidate.index, data.candidate.sdp)
			"code":
				lobby_code = data.code
				update_code_display()

func _handle_closed_connection():
	print("Connection closed: Code %d, Reason: %s" % [
		signaling.get_close_code(),
		signaling.get_close_reason()
	])

func _on_data_received(message):
	var json = JSON.parse_string(message)
	if json:
		handle_remote_state(json.id, json)

func handle_remote_state(player_id: int, state: Dictionary):
	if not players.has(player_id):
		var new_player = preload("res://assets/scenes/game/player.tscn").instantiate()
		$Players.add_child(new_player)
		players[player_id] = new_player
		GameManager.register_player(player_id, {
			"name": "Player %d" % player_id,
			"position": Vector3.ZERO,
			"ready": false
		})
	
	if state.has("position"):
		players[player_id].global_transform.origin = Vector3(
			state.position.x,
			state.position.y,
			state.position.z
		)
	
	if state.has("ready"):
		GameManager.players[player_id].ready = state.ready
		update_player_list()

func send_player_state():
	if peer && peer.get_connection_state() == WebRTCPeerConnection.STATE_CONNECTED:
		var state = {
			"id": GameManager.local_player_id,
			"ready": GameManager.players[GameManager.local_player_id].ready,
			"position": local_player.global_transform.origin,
			"rotation": local_player.rotation
		}
		peer.get_data_channel(1).send_message(JSON.stringify(state))

func generate_lobby_code():
	randomize()
	lobby_code = "%06d" % randi() % 1000000
	signaling.get_peer(1).put_packet(JSON.stringify({
		"type": "register",
		"code": lobby_code
	}).to_utf8_buffer())
	update_code_display()

func update_code_display():
	$UI/WebRTCUI/LobbyCode.text = lobby_code

func _on_leave_pressed():
	if peer:
		peer.close()
	get_tree().change_scene_to_file("res://assets/scenes/ui/main_menu.tscn")

func update_player_list():
	var list_node = $UI/WebRTCUI/PlayerList
	list_node.clear()
	for id in GameManager.players:
		var player = GameManager.players[id]
		var label = Label.new()
		label.text = "%s [%s]" % [player.name, "READY" if player.ready else "NOT READY"]
		list_node.add_child(label)
