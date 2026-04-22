class_name GlobalBHandlingLoader
extends RefCounted

const CarConfigScript = preload("res://eagl/handling/car_config.gd")
const Binary = preload("res://eagl/platforms/ps2/ps2_binary_reader.gd")
const TrackParserPS2Script = preload("res://eagl/assets/track/track_parser_ps2.gd")

const CHUNK_GLOBAL_CAR_TABLE := 0x00034600
const HP2_GLOBALB_ROW_STRIDE := 0x560
const HP2_GLOBALB_MAX_ROWS := 64
const HP2_GLOBALB_WHEEL_VECTOR_OFFSETS := {
	"FL": 0x120,
	"FR": 0x140,
	"RR": 0x160,
	"RL": 0x180,
}
const HP2_GLOBALB_INFERRED_FLOAT_OFFSETS := {
	"body_length": 0x1E4,
	"body_width": 0x1E8,
	"body_height": 0x1EC,
	"steering_response": 0x278,
	"steering_return": 0x27C,
	"steering_lock_scale": 0x280,
	"rolling_resistance": 0x284,
	"final_drive_ratio": 0x28C,
	"reverse_gear_ratio": 0x290,
	"gear_ratio_1": 0x298,
	"gear_ratio_2": 0x29C,
	"gear_ratio_3": 0x2A0,
	"gear_ratio_4": 0x2A4,
	"gear_ratio_5": 0x2A8,
	"gear_ratio_6": 0x2AC,
	"mass": 0x2B0,
	"engine_peak_rpm": 0x2B4,
	"engine_redline_rpm": 0x2B8,
	"aero_drag": 0x2BC,
}
const HP2_GLOBALB_INFERRED_INT_OFFSETS := {
	"gear_count": 0x288,
}

var _track_parser := TrackParserPS2Script.new()


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


func load_config_from_globalb(globalb_path: String, car_name: String, duplicate_index: int = 1, drive_type: String = "RWD"):
	var row := _parse_globalb_row(globalb_path, car_name, duplicate_index)
	if row.is_empty():
		return null
	return _config_from_row(row, drive_type, globalb_path)


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
	# Keep the rigid-body COM neutral until the executable path for the 0x0F0..0x0F8
	# triplet is confirmed. HP2 does use the 0x110 X value for axle preload balance,
	# but that does not prove it is the Godot rigid-body center of mass.
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
	config.front_anti_roll_coefficient = _row_float(globalb_row, 0x240, config.front_anti_roll_coefficient)

	config.rear_progressive_spring_scale = _row_float(globalb_row, 0x250, config.rear_progressive_spring_scale)
	config.rear_spring_coefficient = _row_float(globalb_row, 0x254, config.rear_spring_coefficient)
	config.rear_rebound_damping = _row_float(globalb_row, 0x258, config.rear_rebound_damping)
	config.rear_bump_damping = _row_float(globalb_row, 0x25c, config.rear_bump_damping)
	config.rear_anti_roll_coefficient = _row_float(globalb_row, 0x260, config.rear_anti_roll_coefficient)

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


func _parse_globalb_row(globalb_path: String, car_name: String, duplicate_index: int = 1) -> Dictionary:
	if globalb_path == "" or not FileAccess.file_exists(globalb_path):
		return {}
	var bundle := Binary.load_bundle_bytes(globalb_path)
	if bundle.is_empty():
		return {}
	var chunks: Array[Dictionary] = _track_parser._parse_chunks(bundle)
	var chunk := _first_chunk(chunks, CHUNK_GLOBAL_CAR_TABLE)
	if chunk.is_empty():
		return {}
	var table_base := (int(chunk.get("offset", 0)) + 0x17) & ~0xF
	var table_end := int(chunk.get("end_offset", bundle.size()))
	var car_row := -1
	var match_count := 0
	for row_index in range(_globalb_row_count(table_base, table_end)):
		var row_offset := table_base + row_index * HP2_GLOBALB_ROW_STRIDE
		if _globalb_car_name(bundle, row_offset) != car_name.to_upper():
			continue
		match_count += 1
		if match_count == duplicate_index:
			car_row = row_index
			break
	if car_row < 0:
		return {}
	var row_base := table_base + car_row * HP2_GLOBALB_ROW_STRIDE
	var wheel_slots: Array[Dictionary] = []
	for slot_id in ["FL", "FR", "RL", "RR"]:
		var vector_offset := int(HP2_GLOBALB_WHEEL_VECTOR_OFFSETS[slot_id])
		var p := Vector3(
			Binary.f32(bundle, row_base + vector_offset),
			Binary.f32(bundle, row_base + vector_offset + 4),
			Binary.f32(bundle, row_base + vector_offset + 8)
		)
		wheel_slots.append({
			"slot_id": slot_id,
			"position_ps2": {
				"x": p.x,
				"y": p.y,
				"z": p.z,
			},
			"wheel_radius": Binary.f32(bundle, row_base + vector_offset + 12),
		})
	var floats := {}
	for field_name in HP2_GLOBALB_INFERRED_FLOAT_OFFSETS.keys():
		var offset := int(HP2_GLOBALB_INFERRED_FLOAT_OFFSETS[field_name])
		floats[field_name] = {"value": Binary.f32(bundle, row_base + offset)}
	var ints := {}
	for field_name in HP2_GLOBALB_INFERRED_INT_OFFSETS.keys():
		var offset := int(HP2_GLOBALB_INFERRED_INT_OFFSETS[field_name])
		ints[field_name] = {"value": Binary.u32(bundle, row_base + offset)}
	return {
		"car_name": car_name.to_upper(),
		"row_index": car_row,
		"row_offset": row_base,
		"duplicate_index": duplicate_index,
		"wheel_slots": wheel_slots,
		"inferred_float_fields": floats,
		"inferred_int_fields": ints,
	}


func _field_value(fields: Dictionary, field_name: String, fallback: float) -> float:
	if not fields.has(field_name):
		return fallback
	return float(fields[field_name].get("value", fallback))


func _first_chunk(chunks: Array[Dictionary], chunk_id: int) -> Dictionary:
	for chunk in _track_parser._walk_chunks(chunks):
		if int(chunk.get("id", 0)) == chunk_id:
			return chunk
	return {}


func _globalb_row_count(table_base: int, table_end: int) -> int:
	var count := 0
	for row_index in range(HP2_GLOBALB_MAX_ROWS):
		var row_offset := table_base + row_index * HP2_GLOBALB_ROW_STRIDE
		if row_offset + HP2_GLOBALB_ROW_STRIDE > table_end:
			break
		count += 1
	return count


func _globalb_car_name(bundle: PackedByteArray, row_offset: int) -> String:
	var bytes := PackedByteArray()
	for offset in range(row_offset + 0x20, row_offset + 0x30):
		var value := Binary.u8(bundle, offset)
		if value == 0:
			break
		bytes.append(value)
	return bytes.get_string_from_ascii().strip_edges().to_upper()


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
