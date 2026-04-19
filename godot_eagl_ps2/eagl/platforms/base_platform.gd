class_name BasePlatform
extends RefCounted

var config
var last_error := ""


func initialize(_config) -> void:
	config = _config


func load_track(_track_id: String) -> Node3D:
	return _error_node("load_track is not implemented for this platform")


func load_track_asset(_track_id: String):
	last_error = "load_track_asset is not implemented for this platform"
	push_error(last_error)
	return null


func clear_cache() -> void:
	pass


func get_stats() -> Dictionary:
	return {}


func _error_node(message: String) -> Node3D:
	last_error = message
	push_error(message)
	var node := Node3D.new()
	node.name = "EAGL_Platform_Error"
	node.set_meta("error", message)
	return node
