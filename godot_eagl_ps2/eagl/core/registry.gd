class_name EAGLRegistry
extends RefCounted

var _platforms: Dictionary = {}


func register_platform(platform_id: String, script: Script) -> void:
	_platforms[platform_id] = script


func has_platform(platform_id: String) -> bool:
	return _platforms.has(platform_id)


func create_platform(platform_id: String):
	if not _platforms.has(platform_id):
		return null
	return _platforms[platform_id].new()


func platform_ids() -> Array:
	return _platforms.keys()
