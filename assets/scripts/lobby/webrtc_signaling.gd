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
	# Connect our data_received callback.
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

# Use send_text() to send JSON data as text.
func send_data(data: Dictionary):
	if websocket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		websocket.send_text(JSON.stringify(data))
	else:
		print("send_data: WebSocket not open")

func _on_data():
	var packet = websocket.get_packet()
	var parsed = JSON.parse_string(packet.get_string_from_utf8())
	if parsed.error == OK:
		var data = parsed.result
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
	else:
		print("Error parsing incoming packet")

func _handle_open():
	while websocket.get_available_packet_count() > 0:
		_on_data()

func _handle_closed():
	print("WebSocket closed: %s" % websocket.get_close_reason())

# Instead of using put_packet(), we now use send_text() once the connection is open.
func create_lobby():
	if websocket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		websocket.send_text(JSON.stringify({"action": "create_lobby"}))
	else:
		print("create_lobby: WebSocket not open yet!")

func join_lobby(code: String):
	if websocket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		websocket.send_text(JSON.stringify({"action": "join_lobby", "code": code}))
	else:
		print("join_lobby: WebSocket not open yet!")

func send_offer(code: String, offer: Dictionary):
	if websocket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		websocket.send_text(JSON.stringify({
			"type": "offer",
			"code": code,
			"offer": offer
		}))
	else:
		print("send_offer: WebSocket not open yet!")

func send_answer(code: String, answer: Dictionary):
	if websocket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		websocket.send_text(JSON.stringify({
			"type": "answer",
			"code": code,
			"answer": answer
		}))
	else:
		print("send_answer: WebSocket not open yet!")

func send_ice_candidate(code: String, candidate: Dictionary):
	if websocket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		websocket.send_text(JSON.stringify({
			"type": "ice",
			"code": code,
			"candidate": candidate
		}))
	else:
		print("send_ice_candidate: WebSocket not open yet!")

func _on_connected(proto: String):
	connected = true
	print("Connected to signaling server")

func _on_disconnected():
	connected = false
	print("Disconnected from signaling server")
