class_name CarLoader
extends RefCounted

const CarParserPS2Script := preload("res://eagl/assets/car/car_parser_ps2.gd")
const CarSceneBuilderScript := preload("res://eagl/rendering/car_scene_builder.gd")
const ResourceCacheScript := preload("res://eagl/io/resource_cache.gd")
const PS2TextureBankScript := preload("res://eagl/assets/texture/ps2_texture_bank.gd")

var resolver
var parser := CarParserPS2Script.new()
var scene_builder := CarSceneBuilderScript.new()
var cache := ResourceCacheScript.new()
var _texture_bank_cache: Dictionary = {}
var last_error := ""
var stats: Dictionary = {}


func _init(_resolver = null) -> void:
	resolver = _resolver


func load(car_id: String) -> Node3D:
	var asset = load_asset(car_id)
	if asset == null:
		return _error_node(last_error)
	var options := {}
	if resolver != null and resolver.config != null:
		options = resolver.config.options
	var was_from_cache := bool(stats.get("from_cache", false))
	var node := scene_builder.build_car_scene(asset, options)
	stats = asset.summary()
	stats["from_cache"] = was_from_cache
	stats["rendered_object_count"] = node.get_meta("eagl_rendered_object_count", 0)
	stats["hidden_variant_count"] = node.get_meta("eagl_hidden_variant_count", 0)
	stats["textured_surface_count"] = node.get_meta("eagl_textured_surface_count", 0)
	stats["fallback_surface_count"] = node.get_meta("eagl_fallback_surface_count", 0)
	stats["uv_surface_count"] = node.get_meta("eagl_uv_surface_count", 0)
	stats["textured_missing_uv_surface_count"] = node.get_meta("eagl_textured_missing_uv_surface_count", 0)
	stats["lod_surface_count"] = node.get_meta("eagl_lod_surface_count", 0)
	return node


func load_asset(car_id: String):
	last_error = ""
	if resolver == null:
		last_error = "CarLoader has no asset resolver"
		push_error(last_error)
		return null
	var files: Dictionary = resolver.resolve_car(car_id)
	if files.is_empty():
		last_error = resolver.last_error
		return null
	var cache_key := "car:%s:%s:%s" % [files.get("car_id", car_id), files.get("geometry", ""), files.get("dashboard", "")]
	if _cache_enabled() and cache.has(cache_key):
		var cached = cache.get_item(cache_key)
		stats = cached.summary()
		stats["from_cache"] = true
		return cached

	var asset = parser.parse(files)
	asset.texture_bank = _texture_bank_for_files(files)
	for message in asset.texture_bank.errors:
		asset.add_warning(message)
	stats = asset.summary()
	stats["from_cache"] = false
	if _cache_enabled():
		cache.set_item(cache_key, asset)
	return asset


func clear_cache() -> void:
	cache.clear()
	_texture_bank_cache.clear()


func get_stats() -> Dictionary:
	return stats.duplicate(true)


func _cache_enabled() -> bool:
	return resolver != null and resolver.config != null and bool(resolver.config.cache_enabled)


func _texture_bank_for_files(files: Dictionary):
	var texture_path: String = files.get("texture_car", "")
	if _cache_enabled() and texture_path != "" and _texture_bank_cache.has(texture_path):
		return _texture_bank_cache[texture_path]
	var bank = PS2TextureBankScript.new()
	bank.load_for_car(files)
	if _cache_enabled() and texture_path != "":
		_texture_bank_cache[texture_path] = bank
	return bank


func _error_node(message: String) -> Node3D:
	var node := Node3D.new()
	node.name = "EAGL_Car_Load_Error"
	node.set_meta("error", message)
	return node
