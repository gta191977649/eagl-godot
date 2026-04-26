class_name TrackLoader
extends RefCounted

const TrackParserPS2Script := preload("res://eagl/assets/track/track_parser_ps2.gd")
const SceneBuilderScript := preload("res://eagl/rendering/scene_builder.gd")
const ResourceCacheScript := preload("res://eagl/io/resource_cache.gd")
const PS2TextureBankScript := preload("res://eagl/assets/texture/ps2_texture_bank.gd")

var resolver
var parser := TrackParserPS2Script.new()
var scene_builder := SceneBuilderScript.new()
var cache := ResourceCacheScript.new()
var last_error := ""
var stats: Dictionary = {}


func _init(_resolver = null) -> void:
	resolver = _resolver


func load(track_id: String) -> Node3D:
	var asset = load_asset(track_id)
	if asset == null:
		return _error_node(last_error)
	var options := {}
	if resolver != null and resolver.config != null:
		options = resolver.config.options
	var was_from_cache := bool(stats.get("from_cache", false))
	var node := scene_builder.build_track_scene(asset, options)
	stats = asset.summary()
	stats["from_cache"] = was_from_cache
	stats["rendered_object_count"] = node.get_meta("eagl_rendered_object_count", 0)
	stats["placed_scenery_instance_count"] = node.get_meta("eagl_placed_scenery_instance_count", 0)
	stats["scenery_multimesh_count"] = node.get_meta("eagl_scenery_multimesh_count", 0)
	stats["environment_object_count"] = node.get_meta("eagl_environment_object_count", 0)
	stats["track_marker_count"] = node.get_meta("eagl_track_marker_count", 0)
	stats["skipped"] = node.get_meta("eagl_skipped", {})
	stats["textured_surface_count"] = node.get_meta("eagl_textured_surface_count", 0)
	stats["fallback_surface_count"] = node.get_meta("eagl_fallback_surface_count", 0)
	stats["uv_surface_count"] = node.get_meta("eagl_uv_surface_count", 0)
	stats["textured_missing_uv_surface_count"] = node.get_meta("eagl_textured_missing_uv_surface_count", 0)
	stats["lod_surface_count"] = node.get_meta("eagl_lod_surface_count", 0)
	stats["shadow_texture_visibility_count"] = node.get_meta("eagl_shadow_texture_visibility_count", 0)
	stats["collision_stats"] = node.get_meta("eagl_collision_stats", {})
	stats["collision_body_count"] = node.get_meta("eagl_collision_body_count", 0)
	stats["collision_shape_count"] = node.get_meta("eagl_collision_shape_count", 0)
	stats["collision_surface_count"] = node.get_meta("eagl_collision_surface_count", 0)
	stats["collision_triangle_count"] = node.get_meta("eagl_collision_triangle_count", 0)
	stats["route_stats"] = node.get_meta("eagl_route_stats", {})
	stats["route_point_count"] = node.get_meta("eagl_route_point_count", 0)
	return node


func load_asset(track_id: String):
	last_error = ""
	if resolver == null:
		last_error = "TrackLoader has no asset resolver"
		push_error(last_error)
		return null
	var files: Dictionary = resolver.resolve_track(track_id)
	if files.is_empty():
		last_error = resolver.last_error
		return null
	var cache_key := "track:%s:%s" % [files.get("track_id", track_id), files.get("model", "")]
	if _cache_enabled() and cache.has(cache_key):
		var cached = cache.get_item(cache_key)
		stats = cached.summary()
		stats["from_cache"] = true
		return cached

	var asset = parser.parse(files)
	asset.texture_bank = PS2TextureBankScript.new()
	asset.texture_bank.load_for_track(files)
	for message in asset.texture_bank.errors:
		asset.add_warning(message)
	stats = asset.summary()
	stats["from_cache"] = false
	if _cache_enabled():
		cache.set_item(cache_key, asset)
	return asset


func clear_cache() -> void:
	cache.clear()


func get_stats() -> Dictionary:
	return stats.duplicate(true)


func _cache_enabled() -> bool:
	return resolver != null and resolver.config != null and bool(resolver.config.cache_enabled)


func _error_node(message: String) -> Node3D:
	var node := Node3D.new()
	node.name = "EAGL_Track_Load_Error"
	node.set_meta("error", message)
	return node
