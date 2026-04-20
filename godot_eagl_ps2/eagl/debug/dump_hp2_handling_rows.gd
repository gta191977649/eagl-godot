extends SceneTree

const ConfigScript := preload("res://eagl/core/eagl_config.gd")
const PlatformScript := preload("res://eagl/platforms/ps2/ps2_platform.gd")

const DEFAULT_GAME_ROOT := "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA"
const SAMPLE_CARS := ["MCLAREN", "F50", "911TURBO", "MURCIELAGO", "BUS"]


func _init() -> void:
	var game_root := OS.get_environment("EAGL_HP2_GAME_ROOT")
	if game_root == "":
		game_root = DEFAULT_GAME_ROOT

	var config = ConfigScript.new()
	config.target_platform = "EAGL_HOTPUSUIT2_PS2"
	config.game_root = game_root
	config.cache_enabled = false

	var platform = PlatformScript.new()
	platform.initialize(config)
	for car_id in SAMPLE_CARS:
		var asset = platform.load_car_asset(car_id)
		if asset == null:
			push_error("HANDLING_DUMP failed to load %s" % car_id)
			continue
		_dump_car(asset)
	platform.clear_cache()
	quit(0)


func _dump_car(asset) -> void:
	var handling: Dictionary = asset.handling_data
	var row: Dictionary = handling.get("globalb_row", {})
	var tuning: Dictionary = handling.get("handling", {})
	var dimensions: Dictionary = handling.get("vehicle_dimensions", {})
	print("HANDLING_DUMP %s row=%s offset=0x%X status=%s" % [
		asset.car_id,
		row.get("row_index", -1),
		int(row.get("row_offset", -1)),
		handling.get("exact_handling_status", ""),
	])
	print("  dimensions wheelbase=%.3f front_track=%.3f rear_track=%.3f" % [
		_field_value(dimensions.get("wheelbase", {})),
		_field_value(dimensions.get("front_track", {})),
		_field_value(dimensions.get("rear_track", {})),
	])
	print("  tuning mass=%.1f max=%.1f reverse=%.1f engine_accel=%.1f brake=%.1f grip=%.2f drag=%.4f" % [
		float(tuning.get("mass", 0.0)),
		float(tuning.get("max_forward_speed", 0.0)),
		float(tuning.get("max_reverse_speed", 0.0)),
		float(tuning.get("engine_accel", 0.0)),
		float(tuning.get("brake_accel", 0.0)),
		float(tuning.get("lateral_grip", 0.0)),
		float(tuning.get("linear_drag", 0.0)),
	])
	for slot in row.get("wheel_slots", []):
		var dict: Dictionary = slot
		var p: Vector3 = dict.get("position_ps2", Vector3.ZERO)
		print("  wheel %s ps2=(%.3f, %.3f, %.3f) radius=%.3f offset=0x%03X" % [
			dict.get("slot_id", ""),
			p.x,
			p.y,
			p.z,
			float(dict.get("wheel_radius", 0.0)),
			int(dict.get("runtime_vector_offset", 0)),
		])


func _field_value(field) -> float:
	if field is Dictionary:
		return float((field as Dictionary).get("value", 0.0))
	return 0.0
