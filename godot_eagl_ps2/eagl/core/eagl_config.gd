class_name EAGLConfig
extends Resource

@export var target_platform := ""
@export_global_dir var game_root := ""
@export var debug_enabled := true
@export var cache_enabled := true

var options: Dictionary = {}


func duplicate_config() -> EAGLConfig:
	var out := EAGLConfig.new()
	out.target_platform = target_platform
	out.game_root = game_root
	out.debug_enabled = debug_enabled
	out.cache_enabled = cache_enabled
	out.options = options.duplicate(true)
	return out
