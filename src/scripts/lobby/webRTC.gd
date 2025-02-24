extends BaseLobby
class_name WebRTCLobby

const SIGNALING_SERVER = "wss://thirsty-cherice-macyou-8179e8d5.koyeb.app/"
const ICE_SERVERS = [
	# STUN
	{"urls": ["stun:stun.l.google.com:19302"]},
	
	# TURN
	{
		"urls": [
			"turn:openrelay.metered.ca:80",
			"turn:openrelay.metered.ca:443",
			"turn:openrelay.metered.ca:443?transport=tcp"
		],
		"username": "openrelayproject",
		"credential": "openrelayproject"
	}
]
const DATA_CHANNEL_ID = 1
const LOBBY_TIMEOUT = 60.0
const PING_TIMEOUT = 60.0

var players_node: Node3D
var player_scene = preload("res://src/scenes/game/player.tscn")
var peer: WebRTCPeerConnection
var signaling: WebSocketPeer
var lobby_code := ""
var is_host := false
var data_channel: WebRTCDataChannel
var channel_ready := false
var connection_timer: Timer
var ping := {"last_ping": 0.0, "last_pong": 0.0}
var signaling_queue: Array = []
var pending_ice_candidates: Array = []
var next_player_id := 2

func _ready() -> void:
	print("[WebRTC] Initializing lobby...")
	super._ready()
	local_player_id = ""
	players_node = get_node("World/Players")
	init_network()
	init_ui()
	setup_connection_timer()
	set_process(true)
	
	create_lobby()

func _exit_tree() -> void:
	cleanup_connections()

var connection_states = [
	"STATE_NEW",
	"STATE_CONNECTING",
	"STATE_CONNECTED",
	"STATE_DISCONNECTED",
	"STATE_FAILED",
	"STATE_CLOSED"
]
var _last_peer_state
var _last_ws_state = -1

func _process(delta: float) -> void:
	if peer:
		var state = peer.get_connection_state()
		if state != _last_peer_state:
			print("[WebRTC] State changed: ", connection_states[state])
			_last_peer_state = state
	var ws_state = signaling.get_ready_state()
	if ws_state != _last_ws_state:
		print("[WebSocket] State changed: ", 
			["Closed", "Connecting", "Open", "Closing"][ws_state])
		_last_ws_state = ws_state
	
	handle_signaling_io()
	process_peer_connection()
	process_data_channel()

#region Initialization
func init_network() -> void:
	print("[Signaling] Connecting to server: ", SIGNALING_SERVER)
	signaling = WebSocketPeer.new()
	var err = signaling.connect_to_url(SIGNALING_SERVER)
	if err != OK:
		show_error("Connection failed: %d" % err)
	else:
		print("[Signaling] Connection initiated successfully")

func init_ui() -> void:
	print("[UI] Initializing interface components")
	var ui = $UI/WebRTCUI
	ui.get_node("NameInput").text = SettingsManager.player_name
	ui.get_node("NameInput").text_changed.connect(_on_name_changed)
	ui.get_node("CodeInput").text_changed.connect(_validate_lobby_code)
	ui.get_node("ConnectButton").pressed.connect(join_lobby)
	ui.get_node("ReadyButton").pressed.connect(_on_ready_pressed)
	ui.get_node("LeaveButton").pressed.connect(_on_leave_pressed)
	update_ui_state()

func setup_connection_timer() -> void:
	print("[Timer] Setting up connection timeout (", LOBBY_TIMEOUT, "s)")
	connection_timer = Timer.new()
	connection_timer.wait_time = LOBBY_TIMEOUT
	connection_timer.one_shot = true
	connection_timer.timeout.connect(_on_connection_timeout)
	add_child(connection_timer)
#endregion

#region Connection Management
func _on_connection_timeout() -> void:
	print("[Timeout] Connection attempt timed out")
	show_error("Connection timed out")
	cleanup_connections()
	update_ui_state(false)

func update_ui_state(connecting: bool = false) -> void:
	print("[UI] Updating interface state (connecting: ", connecting, ")")
	var ui = $UI/WebRTCUI
	ui.get_node("ConnectButton").disabled = connecting
	ui.get_node("ConnectButton").text = "Connect" if not connecting else "Connecting..."
	ui.get_node("LeaveButton").visible = not connecting

func _validate_lobby_code(code: String) -> bool:
	var clean_code = code.strip_edges().to_upper()
	var valid = clean_code.length() == 6 and clean_code.is_valid_filename()
	print("[Validation] Lobby code '", clean_code, "' valid: ", valid)
	return valid
#endregion

#region Lobby Management
func create_lobby() -> void:
	cleanup_previous_connection()
	is_host = true
	
	$UI/WebRTCUI/LobbyCode.text = "Generating code..."
	await yield_until_signaling_open()
	generate_lobby_code()
	setup_peer()
	update_player_list()

func join_lobby() -> void:
	var code = $UI/WebRTCUI/CodeInput.text.strip_edges().to_upper()
	print("[Lobby] Attempting to join: ", code)
	
	if not _validate_lobby_code(code):
		show_error("Invalid code format")
		return
		
	cleanup_previous_connection()
	is_host = false
	
	print("[Network] Initializing fresh connection...")
	init_network()
	
	print("[Signaling] Waiting for connection...")
	await yield_until_signaling_open()
	
	print("[Signaling] Sending join request...")
	send_signaling_message(JSON.stringify({
		"type": "join",
		"code": code,
	}))
	
	connection_timer.start()
	print("[Timer] Join timeout started")

func cleanup_previous_connection() -> void:
	print("[Cleanup] Resetting connection state")
	if is_host && lobby_code != "":
		send_signaling_message(JSON.stringify({
			"type": "unregister",
			"code": lobby_code
		}))
	if peer:
		peer.close()
		peer = null
	if data_channel:
		data_channel.close()
		data_channel = null
	for player_id in players.keys():
		remove_player(player_id)
	lobby_code = ""
	channel_ready = false
	pending_ice_candidates.clear()
	local_player_id = ""
	is_host = false

func cleanup_connections() -> void:
	cleanup_previous_connection()
	if signaling.get_ready_state() == WebSocketPeer.STATE_OPEN:
		signaling.close()
		
func spawn_player(player_id: String, is_local: bool = false):
	if players_node.has_node(player_id) or player_id == "":
		return
	
	var new_player = player_scene.instantiate()
	new_player.name = player_id
	new_player.is_local = is_local
	new_player.global_transform.origin = Vector3(
		randf_range(-4,4),
		4.0,
		randf_range(-4,4)
	)
	players_node.add_child(new_player)
	
	if is_local:
		local_player = new_player
		print("Spawned local player: ", player_id)

func despawn_player(player_id: String):
	if not players_node.has_node(player_id) or player_id == "":
		return
	var player = players_node.get_node_or_null(player_id)
	if player:
		player.queue_free()
		print("Despawned player: ", player_id)
#endregion

#region Player Management
func add_new_player(player_id: String) -> void:
	print("[Player] Adding new player: ", player_id)
	if not players.has(player_id):
		players[player_id] = {"name": player_id, "ready": false}
		update_player_list()
		spawn_player(player_id)
		send_data_channel_message({
			"type": "spawn_player",
			"player_id": player_id
		})

func remove_player(player_id: String) -> void:
	print("[Player] Removing player: ", player_id)
	if players.has(player_id):
		players.erase(player_id)
		update_player_list()
		if is_host:
			send_data_channel_message({
				"type": "despawn_player",
				"player_id": player_id
			})
		despawn_player(player_id)

func handle_new_host(player_id: String) -> void:
	print("[Host] New host assigned: ", player_id)
	if player_id == local_player_id:
		print("[Host] You are now the new host!")
		is_host = true
		update_player_list()

func broadcast_player_update() -> void:
	if is_host && peer.get_connection_state() == WebRTCPeerConnection.STATE_CONNECTED:
		print("[Host] Broadcasting full player state")
		send_data_channel_message({
			"type": "full_update",
			"players": players.duplicate(true)
		})
		update_player_list()
#endregion

#region WebRTC Handling
func setup_peer() -> void:
	print("[WebRTC] Peer connection initializing...")
	if peer:
		peer.close()
		peer = null
		
	peer = WebRTCPeerConnection.new()
	peer.initialize({"iceServers": ICE_SERVERS})
	
	data_channel = peer.create_data_channel("game", {
		"id": DATA_CHANNEL_ID,
		"negotiated": true,
		"ordered": true,
		"maxRetransmits": 0
	})
	data_channel.write_mode = WebRTCDataChannel.WRITE_MODE_TEXT
	
	if not is_host:
		peer.data_channel_received.connect(_on_data_channel_received)
	
	peer.ice_candidate_created.connect(_on_ice_candidate)
	peer.session_description_created.connect(_on_session_description)
	print("[WebRTC] Peer connection initialized")

func handle_signaling_io() -> void:
	signaling.poll()
	
	if signaling.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if Time.get_unix_time_from_system() - ping.last_ping > PING_TIMEOUT:
			ping.last_ping = Time.get_unix_time_from_system()
			signaling.send_text(JSON.stringify({"type": "ping"}))
			print("[PING] Sent ping")
			
		while signaling.get_available_packet_count() > 0:
			var packet = signaling.get_packet()
			var msg = packet.get_string_from_utf8()
			_handle_signaling_message(msg)
		
		for msg in signaling_queue:
			signaling.send_text(msg)
		signaling_queue.clear()

func process_peer_connection() -> void:
	if peer:
		peer.poll()
		process_pending_ice_candidates()

func process_data_channel() -> void:
	if data_channel:
		var state = data_channel.get_ready_state()
		if state == WebRTCDataChannel.STATE_OPEN && !channel_ready:
			_on_data_channel_open()
		if state == WebRTCDataChannel.STATE_OPEN:
			while data_channel.get_available_packet_count() > 0:
				var packet = data_channel.get_packet()
				var packet_string = packet.get_string_from_utf8()
				# print("[DataChannel] recieved: ", packet, packet_string)
				_on_data_received(packet_string)
#endregion

#region Signaling Message Handling
func _handle_signaling_message(message: String) -> void:
	print("[Signaling] Raw message: ", message)
	var data = JSON.parse_string(message)
	if data == null or !data.has("type"):
		print("[Signaling] Invalid message format")
		return
	
	match data.type:
		"pong":
			handle_ping() 
		"offer":
			handle_offer(data)
		"answer":
			handle_answer(data)
		"ice":
			handle_ice_candidate(data)
		"lobby_created":
			handle_lobby_created(data)
		"error":
			show_error(data.message)
		"lobby_joined":
			handle_lobby_joined(data)
		"system":
			handle_system_message(data)

func handle_ping() -> void:
	ping.last_pong = Time.get_unix_time_from_system()
	if ping.last_ping != 0 and ping.last_pong != 0:
		print("[PONG] got ", ping.last_pong - ping.last_ping)

func handle_offer(data: Dictionary) -> void:
	if not peer:
		print("[ERROR] Received offer before peer initialization")
		return
		
	if not data.has("sdp"):
		print("[ERROR] Offer missing SDP")
		return

	var error = peer.set_remote_description("offer", data.sdp)
	if error != OK:
		print("[ERROR] set_remote_description failed:", error)
		return

func handle_answer(data: Dictionary) -> void:
	peer.set_remote_description("answer", data.sdp)
	connection_timer.stop()

func handle_ice_candidate(data: Dictionary) -> void:
	if not data.has("candidate"):
		print("[ERROR] ICE message missing candidate field")
		return
		
	var cand = data.candidate
	if not cand.has_all(["mid", "index", "sdp"]):
		print("[ERROR] Invalid ICE candidate format")
		return

	print("[ICE] Received candidate for ", cand.mid)
	if peer:
		var err = peer.add_ice_candidate(cand.mid, cand.index, cand.sdp)
		print("[ICE] Add result: ", "OK" if err == OK else "Error ", err)
	else:
		print("[ICE] Queueing candidate (no peer)")
		pending_ice_candidates.append(cand)

func handle_lobby_created(data: Dictionary) -> void:
	lobby_code = data.code
	local_player_id = str(data.id)
	GameManager.local_player_id = local_player_id
	players = {local_player_id: {"name": SettingsManager.player_name, "ready": false}}
	update_code_display()
	update_player_list()
	spawn_player(local_player_id, true)

func handle_lobby_joined(data: Dictionary) -> void:
	lobby_code = data.code
	local_player_id = str(data.id)
	GameManager.local_player_id = local_player_id
	var new_name = SettingsManager.player_name
	
	players[local_player_id] = {
		"name": new_name,
		"ready": false
	}
	
	send_data_channel_message({
		"type": "player_update",
		"player_id": local_player_id,
		"state": {
			"name": new_name,
			"ready": false
		}
	})
	
	update_code_display()
	connection_timer.stop()
	setup_peer()
	send_signaling_message(JSON.stringify({
		"type": "request_offer"
	}))
	spawn_player(local_player_id, true)

func handle_system_message(data: Dictionary) -> void:
	match data.subtype:
		"player_joined":
			var player_id = str(data.content)
			if is_host:
				players[player_id] = {
					"name": player_id,
					"ready": false
				}
				broadcast_player_update()
				update_player_list()
				peer.create_offer()
			add_new_player(player_id)
		"player_left":
			remove_player(str(data.content))
		"new_host":
			handle_new_host(str(data.content))
#endregion

#region Data Channel Handling
func _on_data_channel_open() -> void:
	channel_ready = true
	connection_timer.stop()
	if is_host:
		broadcast_player_update()

func _on_data_channel_received(channel: WebRTCDataChannel) -> void:
	print("[DataChannel] Received new data channel from peer")
	data_channel = channel
	if data_channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		_on_data_channel_open()

func update_code_display() -> void:
	print("[UI] Updating lobby code display: ", lobby_code)
	$UI/WebRTCUI/LobbyCode.text = lobby_code

func _on_data_received(message: String) -> void:
	print("[DataChannel] Data received: ", message)
	var data = JSON.parse_string(message)
	match data.type:
		"full_update":
			print("[DataChannel] Received full_update")
			if players[local_player_id].name != data.players[local_player_id].name or players[local_player_id].ready != data.players[local_player_id].ready:
				print("[DataChannel] Self data incorrect, sending correction")
				send_data_channel_message({
					"type": "player_update",
					"player_id": local_player_id,
					"state": {
						"name": players[local_player_id].name,
						"ready": players[local_player_id].ready
					}
				})
			var save_local = players[local_player_id]
			players = data.players
			players[local_player_id] = save_local
			update_player_list()
		"player_update":
			print("[DataChannel] Received player_update")
			var player_id = data.player_id
			if is_host:
				players[player_id] = data.state
				broadcast_player_update()
				update_player_list()
			else:
				if player_id == local_player_id:
					if players[local_player_id].name != data.state.name or players[local_player_id].ready != data.state.ready:
						print("[DataChannel] Self data incorrect, sending correction")
						send_data_channel_message({
							"type": "player_update",
							"player_id": local_player_id,
							"state": {
								"name": players[local_player_id].name,
								"ready": players[local_player_id].ready
							}
						})
				else:
					players[player_id] = data.state
					update_player_list()
		"player_spawn":
			spawn_player(str(data.player_id))
		"player_despawn":
			despawn_player(str(data.player_id))
		"player_state":
			var player_id = str(data.player_id)
			if player_id != local_player_id:
				var player = players_node.get_node_or_null(player_id)
				if player:
					var pos = data.position
					var rot = data.rotation
					player.update_network_state(
						Vector3(pos.x, pos.y, pos.z),
						Vector3(rot.x, rot.y, rot.z)
					)
				else:
					spawn_player(player_id)

func send_data_channel_message(data: Dictionary) -> void:
	#print("[DataChannel] Sending: ", data)
	if channel_ready:
		data_channel.put_packet(JSON.stringify(data).to_utf8_buffer())
#endregion

#region Server Communication
func generate_lobby_code() -> void:
	send_signaling_message(JSON.stringify({
		"type": "register",
		"code": ""
	}))

func send_signaling_message(message: String) -> void:
	print("[Signaling] Sending: ", message)
	if signaling.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var err = signaling.send_text(message)
		print("[Signaling] Send result: ", "OK" if err == OK else "Error ", err)
	else:
		print("[Signaling] Queueing message (state: ", signaling.get_ready_state(), ")")
		signaling_queue.append(message)
#endregion

#region UI Handling
func update_player_list() -> void:
	var list_node = $UI/WebRTCUI/PlayerList
	for child in list_node.get_children():
		child.queue_free()
	
	for player_id in players:
		var label = Label.new()
		label.text = "%s (%s)" % [players[player_id].name, "READY" if players[player_id].ready else "NOT READY"]
		list_node.add_child(label)

func show_error(message: String) -> void:
	$UI/WebRTCUI/ErrorLabel.text = message
	$UI/WebRTCUI/ErrorLabel.visible = not message.is_empty()
#endregion

#region Signal Handlers
func _on_name_changed(new_name: String) -> void:
	print("[Player] Name changed to: ", new_name)
	SettingsManager.player_name = new_name
	SettingsManager.save_settings()
	
	if local_player_id != "":
		send_data_channel_message({
			"type": "player_update",
			"player_id": local_player_id,
			"state": {
				"name": new_name,
				"ready": players[local_player_id].ready
			}
		})
		players[local_player_id].name = new_name
		update_player_list()

func _on_ready_pressed() -> void:
	print("[Player] Ready button pressed")
	if local_player_id != "":
		var new_state = !players[local_player_id].ready
		send_data_channel_message({
			"type": "player_update",
			"player_id": local_player_id,
			"state": {
				"name": players[local_player_id].name,
				"ready": new_state
			}
		})
		players[local_player_id].ready = new_state
		update_player_list()

func _on_leave_pressed() -> void:
	print("[Lobby] Leave button pressed")
	cleanup_connections()
	get_tree().change_scene_to_file("res://src/scenes/ui/main_menu.tscn")

func _on_ice_candidate(mid: String, index: int, sdp: String) -> void:
	send_signaling_message(JSON.stringify({
		"type": "ice",
		"code": lobby_code,
		"candidate": {"mid": mid, "index": index, "sdp": sdp}
	}))

func _on_session_description(type: String, sdp: String) -> void:
	send_signaling_message(JSON.stringify({
		"type": type,
		"code": lobby_code,
		"sdp": sdp
	}))
	peer.set_local_description(type, sdp)
#endregion

#region Helper Methods
func yield_until_signaling_open() -> void:
	var timeout = 0.0
	while signaling.get_ready_state() != WebSocketPeer.STATE_OPEN:
		await get_tree().create_timer(0.1).timeout
		timeout += 0.1
		if timeout > 5.0:
			show_error("Connection timeout")
			cleanup_connections()
			return
	print("[Signaling] Connection verified open")

func process_pending_ice_candidates() -> void:
	if peer && !pending_ice_candidates.is_empty():
		for candidate in pending_ice_candidates:
			peer.add_ice_candidate(candidate.mid, candidate.index, candidate.sdp)
		pending_ice_candidates.clear()
#endregion
