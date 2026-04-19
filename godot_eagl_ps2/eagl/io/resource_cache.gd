class_name EAGLResourceCache
extends RefCounted

var _items: Dictionary = {}


func has(key: String) -> bool:
	return _items.has(key)


func get_item(key: String):
	return _items.get(key)


func set_item(key: String, value) -> void:
	_items[key] = value


func erase(key: String) -> void:
	_items.erase(key)


func clear() -> void:
	_items.clear()


func size() -> int:
	return _items.size()
