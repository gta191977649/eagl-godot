class_name GlobalBHandlingLoader
extends RefCounted

const CarConfigScript = preload("res://eagl/handling/car_config.gd")
const Binary = preload("res://eagl/platforms/ps2/ps2_binary_reader.gd")


func load_config(json_path: String, car_name: String, duplicate_index: int = 1, drive_type: String = "RWD"):
	var file = FileAccess.open(json_path, FileAccess.READ)
	if file == null:
		push_error("Unable to open handling JSON: %s" % json_path)
		return null

	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Handling JSON did not decode to a dictionary: %s" % json_path)
		return null

	var rows: Array = parsed.get("rows", [])
	var globalb_path := String(parsed.get("inputs", {}).get("globalb_path", ""))
	for row in rows:
		if String(row.get("car_name", "")) != car_name:
			continue
		var row_duplicate = int(row.get("duplicate_index", 1))
		if row_duplicate != duplicate_index:
			continue
		return _config_from_row(row, drive_type, globalb_path)

	push_error("No handling row found for %s duplicate %d" % [car_name, duplicate_index])
	return null


func _config_from_row(row: Dictionary, drive_type: String, globalb_path: String):
	var config: CarConfig = CarConfigScript.new()
	var floats: Dictionary = row.get("inferred_float_fields", {})
	var ints: Dictionary = row.get("inferred_int_fields", {})
	var wheels_by_slot = {}
	var globalb_row := _read_globalb_row(globalb_path, int(row.get("row_offset", -1)))

	config.car_name = String(row.get("car_name", "HP2 Car"))
	config.row_index = int(row.get("row_index", -1))
	config.duplicate_index = int(row.get("duplicate_index", 1))
	config.drive_type = drive_type
	config.mass_kg = _field_value(floats, "mass", config.mass_kg)
	# The 0x0F0..0x0F8 triplet is still not verified against the runtime path. Keep
	# the rigid-body COM neutral until that field is confirmed from the executable.
	config.center_of_mass_ps2 = Vector3.ZERO
	config.body_size_ps2 = Vector3(
		_field_value(floats, "body_length", config.body_size_ps2.x),
		_field_value(floats, "body_width", config.body_size_ps2.y),
		_field_value(floats, "body_height", config.body_size_ps2.z)
	)
	config.physics_origin_offset_ps2 = Vector3(
		_row_float(globalb_row, 0x110, 0.0),
		_row_float(globalb_row, 0x114, 0.0),
		_row_float(globalb_row, 0x118, 0.0)
	)

	for wheel_entry in row.get("wheel_slots", []):
		wheels_by_slot[String(wheel_entry.get("slot_id", ""))] = wheel_entry

	config.wheel_local_positions_ps2.clear()
	var radii: Array[float] = []
	for slot_id in ["FL", "FR", "RL", "RR"]:
		var wheel_entry: Dictionary = wheels_by_slot.get(slot_id, {})
		var position: Dictionary = wheel_entry.get("position_ps2", {})
		config.wheel_local_positions_ps2.append(Vector3(
			float(position.get("x", 0.0)),
			float(position.get("y", 0.0)),
			float(position.get("z", 0.0))
		))
		radii.append(float(wheel_entry.get("wheel_radius", 0.33)))
	config.wheel_radii = PackedFloat32Array(radii)

	config.front_travel_limit = _row_float(globalb_row, 0x1ac, config.front_travel_limit)
	config.front_rest_length = _row_float(globalb_row, 0x1b0, config.front_rest_length)
	config.front_reference_length = _row_float(globalb_row, 0x1b4, config.front_reference_length)
	config.rear_travel_limit = _row_float(globalb_row, 0x1cc, config.rear_travel_limit)
	config.rear_rest_length = _row_float(globalb_row, 0x1d0, config.rear_rest_length)
	config.rear_reference_length = _row_float(globalb_row, 0x1d4, config.rear_reference_length)
	config.front_max_compression = _row_float(globalb_row, 0x244, config.front_max_compression)
	config.front_min_compression = _row_float(globalb_row, 0x248, config.front_min_compression)
	config.rear_max_compression = _row_float(globalb_row, 0x264, config.rear_max_compression)
	config.rear_min_compression = _row_float(globalb_row, 0x268, config.rear_min_compression)
	config.front_progressive_spring_scale = _row_float(globalb_row, 0x230, config.front_progressive_spring_scale)
	config.front_spring_coefficient = _row_float(globalb_row, 0x234, config.front_spring_coefficient)
	config.front_rebound_damping = _row_float(globalb_row, 0x238, config.front_rebound_damping)
	config.front_bump_damping = _row_float(globalb_row, 0x23c, config.front_bump_damping)
	config.front_bump_stop_coefficient = _row_float(globalb_row, 0x240, config.front_bump_stop_coefficient)

	config.rear_progressive_spring_scale = _row_float(globalb_row, 0x250, config.rear_progressive_spring_scale)
	config.rear_spring_coefficient = _row_float(globalb_row, 0x254, config.rear_spring_coefficient)
	config.rear_rebound_damping = _row_float(globalb_row, 0x258, config.rear_rebound_damping)
	config.rear_bump_damping = _row_float(globalb_row, 0x25c, config.rear_bump_damping)
	config.rear_bump_stop_coefficient = _row_float(globalb_row, 0x260, config.rear_bump_stop_coefficient)

	config.steering_response = _field_value(floats, "steering_response", config.steering_response)
	config.steering_return = _field_value(floats, "steering_return", config.steering_return)
	config.steering_lock_scale = _field_value(floats, "steering_lock_scale", config.steering_lock_scale)
	config.rolling_resistance = _field_value(floats, "rolling_resistance", config.rolling_resistance)
	config.aero_drag = _field_value(floats, "aero_drag", config.aero_drag)

	config.final_drive_ratio = _field_value(floats, "final_drive_ratio", config.final_drive_ratio)
	config.reverse_gear_ratio = _field_value(floats, "reverse_gear_ratio", config.reverse_gear_ratio)
	var forward_gears: Array[float] = []
	var gear_count = int(ints.get("gear_count", {}).get("value", config.top_gear()))
	for gear in range(1, gear_count + 1):
		forward_gears.append(_field_value(floats, "gear_ratio_%d" % gear, 1.0))
	config.forward_gears = PackedFloat32Array(forward_gears)

	config.engine_peak_rpm = _field_value(floats, "engine_peak_rpm", config.engine_peak_rpm)
	config.engine_redline_rpm = _field_value(floats, "engine_redline_rpm", config.engine_redline_rpm)
	config.shift_up_rpm = config.engine_redline_rpm * 0.96
	config.shift_down_rpm = maxf(config.idle_rpm * 2.5, config.engine_peak_rpm * 0.55)
	return config


func _field_value(fields: Dictionary, field_name: String, fallback: float) -> float:
	if not fields.has(field_name):
		return fallback
	return float(fields[field_name].get("value", fallback))


func _read_globalb_row(globalb_path: String, row_offset: int) -> PackedByteArray:
	if globalb_path == "" or row_offset < 0:
		return PackedByteArray()
	var data := Binary.load_bundle_bytes(globalb_path)
	if data.is_empty():
		return PackedByteArray()
	var row_size := 0x560
	if row_offset + row_size > data.size():
		return PackedByteArray()
	return data.slice(row_offset, row_offset + row_size)


func _row_float(row: PackedByteArray, offset: int, fallback: float) -> float:
	if row.is_empty() or offset < 0 or offset + 4 > row.size():
		return fallback
	return Binary.f32(row, offset)
