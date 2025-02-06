extends BaseLobby
class_name WebRTCLobby

var peer := WebRTCPeerConnection.new()
var data_channel: WebRTCDataChannel
var websocket := WebSocketPeer.new()
var lobby_code := ""

func _ready():
	super()
	peer.ice_candidate_created.connect(_on_ice_candidate)
	peer.session_description_created.connect(_on_session_description)
	
	if OS.has_feature('web'):
		peer.initialize({"iceServers": [{"urls": ["stun:stun.l.google.com:19302"]}]})
	else:
		peer.initialize()

func create_lobby():
	data_channel = peer.create_data_channel("game", {"id": 1, "negotiated": true})
	data_channel.message_received.connect(_on_data_received)
	lobby_code = _generate_lobby_code()
	_update_web_ui()

func join_lobby(code: String):
	lobby_code = code
	# Implement signaling server connection here

func _generate_lobby_code() -> String:
	return str(randi() % 10000).pad_zeros(4)

func _on_ice_candidate(mid: String, index: int, sdp: String):
	# Send ICE candidate through signaling
	pass

func _on_session_description(type: String, sdp: String):
	# Handle session description
	pass

func _on_data_received(message: PackedByteArray):
	var position = bytes_to_var(message)
	# Handle received position data

func _update_web_ui():
	# Implement WebRTC-specific UI updates
	pass
