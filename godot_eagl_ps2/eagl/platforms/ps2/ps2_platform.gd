class_name PS2Platform
extends "res://eagl/platforms/base_platform.gd"

const PS2AssetResolverScript := preload("res://eagl/platforms/ps2/ps2_asset_resolver.gd")
const TrackLoaderScript := preload("res://eagl/assets/track/track_loader.gd")

var resolver
var track_loader


func initialize(_config) -> void:
	super.initialize(_config)
	resolver = PS2AssetResolverScript.new(_config)
	track_loader = TrackLoaderScript.new(resolver)


func load_track(track_id: String) -> Node3D:
	if track_loader == null:
		return _error_node("PS2Platform is not initialized")
	return track_loader.load(track_id)


func load_track_asset(track_id: String):
	if track_loader == null:
		last_error = "PS2Platform is not initialized"
		push_error(last_error)
		return null
	return track_loader.load_asset(track_id)


func clear_cache() -> void:
	if track_loader != null:
		track_loader.clear_cache()


func get_stats() -> Dictionary:
	if track_loader == null:
		return {}
	return track_loader.get_stats()
