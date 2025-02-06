extends Control

func _update_ui():
	$SteamUI/LobbyTittle.text = Steam.getLobbyData(lobby_id, "name")
	_clear_friend_list()
	
	var friend_count = Steam.getFriendCount(Steam.FRIEND_FLAG_IMMEDIATE)
	for i in friend_count:
		var friend_id = Steam.getFriendByIndex(i, Steam.FRIEND_FLAG_IMMEDIATE)
		var friend_name = Steam.getFriendPersonaName(friend_id)
		_add_friend_entry(friend_name)

func _clear_friend_list():
	for child in $SteamUI/ScrollContainer/FriendList.get_children():
		child.queue_free()

func _add_friend_entry(name: String):
	var label = Label.new()
	label.text = name
	$SteamUI/ScrollContainer/FriendList.add_child(label)
