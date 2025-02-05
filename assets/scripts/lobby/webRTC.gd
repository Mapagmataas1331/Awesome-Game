extends Node


var peer = WebRTCPeerConnection.new()

func _ready():
	if OS.has_feature('web'):
		peer.initialize({"iceServers": [{"urls": ["stun:stun.l.google.com:19302"]}]})
	else:
		peer.initialize()
