extends BaseLobby
class_name WebRTCLobby

const SIGNALING_SERVER = "ws://thirsty-cherice-macyou-8179e8d5.koyeb.app/"
const ICE_SERVERS = [{"urls": ["stun:stun.l.google.com:19302"]}]

var peer: WebRTCPeerConnection
var signaling: WebSocketPeer
var lobby_code := ""
var is_host := false
var data_channel: WebRTCDataChannel
var channel_opened = false

var player_names := {}
var signaling_queue: Array = []
var pending_ice_candidates: Array = []

func _ready():
	print("DEBUG: WebRTCLobby _ready()")
	super._ready()
	var local_id = multiplayer.get_unique_id()
	players[local_id] = {"name": SettingsManager.player_name, "ready": false}
	update_player_list()
	
	var name_input = $UI/WebRTCUI/NameInput
	name_input.text = SettingsManager.player_name
	name_input.text_changed.connect(func(new_name):
		players[local_id]["name"] = new_name
		SettingsManager.player_name = new_name
		SettingsManager.save_settings()
		broadcast_player_update()
	)
	
	init_network()
	init_ui()
	set_process(true)

func init_network():
	print("DEBUG: init_network() - Connecting to signaling server")
	signaling = WebSocketPeer.new()
	signaling.connect_to_url(SIGNALING_SERVER)
	create_lobby()

func init_ui():
	var ui = $UI/WebRTCUI
	ui.get_node("ConnectButton").pressed.connect(join_lobby)
	ui.get_node("LeaveButton").pressed.connect(_on_leave_pressed)
	update_code_display()

func create_lobby() -> void:
	print("DEBUG: Creating lobby")
	yield_until_signaling_open()
	
	peer = WebRTCPeerConnection.new()
	peer.initialize({"iceServers": ICE_SERVERS})
	peer.ice_candidate_created.connect(_on_ice_candidate)
	peer.session_description_created.connect(_on_session_description)
	
	data_channel = peer.create_data_channel("game", {"id": 1, "negotiated": true})
	
	is_host = true
	generate_lobby_code()
	peer.create_offer()

func join_lobby() -> void:
	print("DEBUG: Joining lobby")
	yield_until_signaling_open()
	
	var code = $UI/WebRTCUI/CodeInput.text.strip_edges()
	if code.length() != 6:
		print("ERROR: Invalid lobby code")
		return
	
	peer = WebRTCPeerConnection.new()
	peer.initialize({"iceServers": ICE_SERVERS})
	peer.ice_candidate_created.connect(_on_ice_candidate)
	peer.session_description_created.connect(_on_session_description)
	peer.data_channel_received.connect(_on_data_channel_received)
	
	send_signaling_message(JSON.stringify({
		"type": "join",
		"code": code
	}))

func _process(delta):
	signaling.poll()
	
	if signaling.get_ready_state() == WebSocketPeer.STATE_OPEN:
		while signaling.get_available_packet_count() > 0:
			var packet = signaling.get_packet()
			var message = packet.get_string_from_utf8()
			_handle_signaling_message(message)
	
	if signaling.get_ready_state() == WebSocketPeer.STATE_OPEN && !signaling_queue.is_empty():
		for msg in signaling_queue:
			signaling.send_text(msg)
		signaling_queue.clear()
	
	if peer:
		peer.poll()
		process_pending_ice_candidates()
	
	if data_channel:
		process_data_channel()

func _handle_signaling_message(message: String):
	print("DEBUG: Received signaling message: ", message)
	var data = JSON.parse_string(message)
	if typeof(data) != TYPE_DICTIONARY or not data.has("type"):
		return
	
	match data.type:
		"offer":
			handle_offer(data)
		"answer":
			handle_answer(data)
		"ice":
			handle_ice_candidate(data)
		"peer_joined":
			handle_peer_joined(data)
		"error":
			print("ERROR: ", data.message)

func handle_offer(data):
	print("DEBUG: Received offer")
	peer.set_remote_description("offer", data.sdp)
	peer.create_answer_async()

func handle_answer(data):
	print("DEBUG: Received answer")
	peer.set_remote_description("answer", data.sdp)
	process_pending_ice_candidates()

func handle_ice_candidate(data):
	print("DEBUG: Received ICE candidate")
	if peer:
		peer.add_ice_candidate(data.candidate.mid, data.candidate.index, data.candidate.sdp)
	else:
		pending_ice_candidates.append(data.candidate)

func handle_peer_joined(data):
	print("DEBUG: New peer joined lobby")
	if is_host:
		send_signaling_message(JSON.stringify({
			"type": "offer",
			"code": lobby_code,
			"sdp": peer.get_local_description().sdp
		}))

func process_pending_ice_candidates():
	while !pending_ice_candidates.is_empty():
		var candidate = pending_ice_candidates.pop_front()
		peer.add_ice_candidate(candidate.mid, candidate.index, candidate.sdp)

func process_data_channel():
	if data_channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		if !channel_opened:
			channel_opened = true
			_on_data_channel_open()
		
		while data_channel.get_available_packet_count() > 0:
			var packet = data_channel.get_packet()
			_on_data_received(packet.get_string_from_utf8())

func _on_data_channel_open():
	print("DEBUG: Data channel opened")
	broadcast_player_update()

func broadcast_player_update():
	var local_id = multiplayer.get_unique_id()
	var player_data = {
		"type": "player_update",
		"player_id": local_id,
		"name": players[local_id]["name"],
		"ready": players[local_id]["ready"]
	}
	send_data_channel_message(player_data)
	update_player_list()

func send_data_channel_message(data: Dictionary):
	if data_channel and data_channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		data_channel.put_packet(JSON.stringify(data).to_utf8_buffer())

func _on_data_received(message: String):
	var data = JSON.parse_string(message)
	if typeof(data) != TYPE_DICTIONARY:
		print("DEBUG: Failed to parse JSON from data channel: ", message)
		return
	
	match data.type:
		"player_update":
			handle_player_update(data)
		"init":
			handle_init_data(data)

func handle_player_update(data):
	var player_id = data.player_id
	if not players.has(player_id):
		players[player_id] = {}
	
	players[player_id]["name"] = data.name
	players[player_id]["ready"] = data.ready
	update_player_list()

func handle_init_data(data):
	var player_id = data.player_id
	players[player_id] = {
		"name": data.name,
		"ready": false,
		"position": data.position
	}
	update_player_list()
	broadcast_player_update()

func update_player_list():
	var list_node = $UI/WebRTCUI/PlayerList
	for child in list_node.get_children():
		list_node.remove_child(child)
		child.queue_free()
	
	for player_id in players:
		var player = players[player_id]
		var label = Label.new()
		label.text = "%s (%s)" % [player.name, "READY" if player.ready else "NOT READY"]
		list_node.add_child(label)

func _on_data_channel_received(channel: WebRTCDataChannel):
	print("DEBUG: Data channel received from remote peer.")
	data_channel = channel
	data_channel.open.connect(_on_data_channel_open)
	if data_channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		_on_data_channel_open()
		
func yield_until_signaling_open() -> void:
	print("DEBUG: Waiting for signaling connection to be open...")
	while signaling.get_ready_state() != WebSocketPeer.STATE_OPEN:
		print("DEBUG: Signaling ready state: %s" % signaling.get_ready_state())
		await get_tree().create_timer(0.1).timeout
	print("DEBUG: Signaling connection is now open.")

func _on_ice_candidate(mid, index, sdp):
	var ice_msg = JSON.stringify({
		"type": "ice",
		"code": lobby_code,
		"candidate": {"mid": mid, "index": index, "sdp": sdp}
	})
	print("DEBUG: ICE candidate created: %s (length: %d)" % [ice_msg, ice_msg.length()])
	send_signaling_message(ice_msg)

func _on_session_description(type, sdp):
	var sdp_msg = JSON.stringify({
		"type": type,
		"code": lobby_code,
		"sdp": sdp
	})
	print("DEBUG: Session description created: %s (length: %d)" % [sdp_msg, sdp_msg.length()])
	send_signaling_message(sdp_msg)
	peer.set_local_description(type, sdp)
	print("DEBUG: Local description set: %s" % sdp)

	if signaling.get_ready_state() == WebSocketPeer.STATE_OPEN and signaling_queue.size() > 0:
		for msg in signaling_queue:
			print("DEBUG: Sending queued signaling message: %s (length: %d)" % [msg, msg.length()])
			signaling.send_text(msg)
		signaling_queue.clear()
	
	if peer:
		peer.poll()
	
	if data_channel and data_channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		while data_channel.get_available_packet_count() > 0:
			var packet = data_channel.get_packet()
			var message = packet.get_string_from_utf8()
			print("DEBUG: Received data channel message: %s" % message)
			_on_data_received(message)
	
	if data_channel and not channel_opened:
		if data_channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			channel_opened = true
			print("DEBUG: Data channel open detected in _process().")
			_on_data_channel_open()

func generate_lobby_code() -> void:
	randomize()
	lobby_code = "%06d" % (randi() % 1000000)
	var reg_msg = JSON.stringify({
		"type": "register",
		"code": lobby_code
	})
	print("DEBUG: Generated lobby code: %s" % lobby_code)
	send_signaling_message(reg_msg)
	update_code_display()

func update_code_display() -> void:
	$UI/WebRTCUI/LobbyCode.text = lobby_code
	print("DEBUG: Updated lobby code display: %s" % lobby_code)

func _on_leave_pressed() -> void:
	print("DEBUG: Leave button pressed. Closing connections.")
	if peer:
		peer.close()
		print("DEBUG: Peer connection closed.")
	if signaling.get_ready_state() == WebSocketPeer.STATE_OPEN:
		signaling.close()
		print("DEBUG: Signaling connection closed.")
	signaling = null
	get_tree().change_scene_to_file("res://assets/scenes/ui/main_menu.tscn")
	print("DEBUG: Scene changed to main_menu.tscn.")

func handle_remote_state(player_id: int, state: Dictionary):
	if state.has("name"):
		player_names[player_id] = state.name
		if not players.has(player_id):
			players[player_id] = {"name": state.name, "ready": false}
		update_player_list()
		print("DEBUG: Updated player_names: %s" % player_names)
	if players.has(player_id):
		players[player_id].update_state(
			Vector3(state.position.x, state.position.y, state.position.z),
			Vector3(state.rotation.x, state.rotation.y, state.rotation.z)
		)
		print("DEBUG: Updated state for player %d" % player_id)

func send_signaling_message(message: String) -> void:
	print("DEBUG: Preparing to send signaling message: %s (length: %d)" % [message, message.length()])
	if signaling.get_ready_state() == WebSocketPeer.STATE_OPEN:
		signaling.send_text(message)
		print("DEBUG: Sent signaling message: %s" % message)
	else:
		signaling_queue.append(message)
		print("DEBUG: Signaling not open; queued message: %s" % message)
