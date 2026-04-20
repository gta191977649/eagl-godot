class_name PS2Platform
extends "res://eagl/platforms/base_platform.gd"

const PS2AssetResolverScript := preload("res://eagl/platforms/ps2/ps2_asset_resolver.gd")
const TrackLoaderScript := preload("res://eagl/assets/track/track_loader.gd")
const CarLoaderScript := preload("res://eagl/assets/car/car_loader.gd")

var resolver
var track_loader
var car_loader


func initialize(_config) -> void:
	super.initialize(_config)
	resolver = PS2AssetResolverScript.new(_config)
	track_loader = TrackLoaderScript.new(resolver)
	car_loader = CarLoaderScript.new(resolver)


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


func load_car(car_id: String) -> Node3D:
	if car_loader == null:
		return _error_node("PS2Platform is not initialized")
	return car_loader.load(car_id)


func load_car_asset(car_id: String):
	if car_loader == null:
		last_error = "PS2Platform is not initialized"
		push_error(last_error)
		return null
	return car_loader.load_asset(car_id)


func clear_cache() -> void:
	if track_loader != null:
		track_loader.clear_cache()
	if car_loader != null:
		car_loader.clear_cache()


func get_stats() -> Dictionary:
	var out: Dictionary = track_loader.get_stats() if track_loader != null else {}
	if track_loader != null:
		out["track_stats"] = track_loader.get_stats()
	if car_loader != null:
		out["car"] = car_loader.get_stats()
	return out
