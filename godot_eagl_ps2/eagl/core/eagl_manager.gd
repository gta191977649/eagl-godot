extends Node

const EAGLConfigScript := preload("res://eagl/core/eagl_config.gd")
const EAGLRegistryScript := preload("res://eagl/core/registry.gd")
const EAGLTypesScript := preload("res://eagl/core/eagl_types.gd")
const PS2PlatformScript := preload("res://eagl/platforms/ps2/ps2_platform.gd")

var platform = null
var config: EAGLConfig
var registry := EAGLRegistryScript.new()
var last_error := ""


func _ready() -> void:
	_register_builtin_platforms()


func initialize(target_platform: String, game_root: String, options: Dictionary = {}) -> bool:
	_register_builtin_platforms()
	last_error = ""
	var platform_id := EAGLTypesScript.canonical_platform(target_platform)
	config = EAGLConfigScript.new()
	config.target_platform = platform_id
	config.game_root = game_root
	config.options = options.duplicate(true)

	platform = registry.create_platform(platform_id)
	if platform == null:
		last_error = "Unsupported EAGL platform: %s" % target_platform
		push_error(last_error)
		return false

	platform.initialize(config)
	return true


func is_initialized() -> bool:
	return platform != null


func load_track(track_id: String) -> Node3D:
	if platform == null:
		return _error_node("EAGLManager is not initialized")
	return platform.load_track(track_id)


func load_track_asset(track_id: String):
	if platform == null:
		last_error = "EAGLManager is not initialized"
		push_error(last_error)
		return null
	return platform.load_track_asset(track_id)


func load_car(car_id: String) -> Node3D:
	if platform == null:
		return _error_node("EAGLManager is not initialized")
	return platform.load_car(car_id)


func load_car_asset(car_id: String):
	if platform == null:
		last_error = "EAGLManager is not initialized"
		push_error(last_error)
		return null
	return platform.load_car_asset(car_id)


func get_stats() -> Dictionary:
	if platform == null or not platform.has_method("get_stats"):
		return {}
	return platform.get_stats()


func clear_cache() -> void:
	if platform != null and platform.has_method("clear_cache"):
		platform.clear_cache()


func _register_builtin_platforms() -> void:
	if registry.has_platform(EAGLTypesScript.PLATFORM_HOTPUSUIT2_PS2):
		return
	registry.register_platform(EAGLTypesScript.PLATFORM_HOTPUSUIT2_PS2, PS2PlatformScript)
	registry.register_platform(EAGLTypesScript.PLATFORM_HOTPURSUIT2_PS2, PS2PlatformScript)


func _error_node(message: String) -> Node3D:
	last_error = message
	push_error(message)
	var node := Node3D.new()
	node.name = "EAGL_Error"
	node.set_meta("error", message)
	return node
