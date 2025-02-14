extends Node
class_name WebRTCSignaling

signal lobby_created(code)
signal player_joined(id)
signal offer_received(offer)
signal answer_received(answer)
signal ice_received(candidate)

var websocket: WebSocketPeer
var connected := false

func _ready():
	websocket = WebSocketPeer.new()
	websocket.connect("data_received", Callable(self, "_on_data"))
	set_process(true)

func _process(delta):
	websocket.poll()
	match websocket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			_handle_open()
		WebSocketPeer.STATE_CLOSED:
			_handle_closed()

func connect_to_server(url: String):
	websocket.connect_to_url(url)

func send_data(data: Dictionary):
	websocket.send_text(JSON.stringify(data))

func _on_data():
	var packet = websocket.get_packet()
	var data = JSON.parse_string(packet.get_string_from_utf8())
	if data:
		match data.type:
			"lobby_created":
				emit_signal("lobby_created", data.code)
			"offer":
				emit_signal("offer_received", data.offer)
			"answer":
				emit_signal("answer_received", data.answer)
			"ice":
				emit_signal("ice_received", data.candidate)
			"player_joined":
				emit_signal("player_joined", data.player_id)

func _handle_open():
	while websocket.get_available_packet_count() > 0:
		_on_data()

func _handle_closed():
	print("WebSocket closed: %s" % websocket.get_close_reason())

func create_lobby():
	websocket.get_peer(1).put_packet(JSON.stringify({
		"action": "create_lobby"
	}).to_utf8_buffer())

func join_lobby(code: String):
	websocket.get_peer(1).put_packet(JSON.stringify({
		"action": "join_lobby",
		"code": code
	}).to_utf8_buffer())

func send_offer(code: String, offer: Dictionary):
	websocket.get_peer(1).put_packet(JSON.stringify({
		"type": "offer",
		"code": code,
		"offer": offer
	}).to_utf8_buffer())

func send_answer(code: String, answer: Dictionary):
	websocket.get_peer(1).put_packet(JSON.stringify({
		"type": "answer",
		"code": code,
		"answer": answer
	}).to_utf8_buffer())

func send_ice_candidate(code: String, candidate: Dictionary):
	websocket.get_peer(1).put_packet(JSON.stringify({
		"type": "ice",
		"code": code,
		"candidate": candidate
	}).to_utf8_buffer())

func _on_connected(proto: String):
	connected = true
	print("Connected to signaling server")

func _on_disconnected():
	connected = false
	print("Disconnected from signaling server")
