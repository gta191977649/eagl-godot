class_name HP2CarData
extends RefCounted

const REVERSE_FACTS := {
	"status": "partial",
	"notes": "Recovered from Ghidra pass plus GLOBALB.BUN/CARS geometry chunks; handling constants are still partial, but wheel visual dummies are decoded from car geometry.",
	"functions": {
		"car_assembly": "HP2_CarRenderPhysicsAttachmentSetup_FUN_0011e860",
		"car_light_setup": "FUN_0011fe60",
		"damage_runtime_parts": "FUN_0011ff68",
		"attached_part_locator_scan": "HP2_AttachedPartLocatorScan_FUN_00120360",
		"physics_move_string": "PhysicsCar::Move()",
		"physics_forces_string": "PhysicsCar::ResolveForces()",
		"wheel_forces_marker": "World::DoTimestep - Do Wheel Forces",
		"physics_integrator_marker": "PhysicsSystem::IntegrateEuler()",
			"physics_derivative_marker": "PhysicsSystem::GetDerivative()",
			"steering_marker": "TwoWheelAckermanSteering",
			"suspension_marker": "Suspension",
			"engine_marker": "EngineSlotPool",
			"drivetrain_marker": "DriveTrainSlotPool",
			"drivetrain_type_marker": "DriveTrain",
			"engine_timestep_marker": "World::DoTimestep - FakeEngineTask",
		},
	"runtime_table": {
		"symbol": "uGpffffaf78",
		"init_function": "FUN_00187f98",
		"source_chunk": "GLOBAL/GLOBALB.BUN chunk 0x00034600",
		"row_stride": 0x560,
		"wheel_vector_offsets": [0x120, 0x140, 0x160, 0x180],
		"vehicle_type_offset": 0x538,
	},
	"wheel_visual_dummies": {
		"source_chunk": "CARS/*/GEOMETRY.BIN chunk 0x00034013",
		"source_function": "FUN_00120360",
		"hashes": {
			"front_left": 0xACEC665C,
			"front_right": 0x4AE7F96F,
			"rear_left": [0x7EFCF06F, 0xBEA9AEE6],
			"rear_right": [0x5F09C5E2, 0x944E5339],
		},
	},
	"runtime_part_names": {
		"tires": [
			"%s_TIRE_FRONT_A",
			"%s_TIRE_FRONT_B",
			"%s_TIRE_FRONT_C",
			"%s_TIRE_REAR_A",
			"%s_TIRE_REAR_B",
			"%s_TIRE_REAR_C",
		],
		"brakes": ["%s_BRAKE_FRONT", "%s_BRAKE_REAR"],
		"cullable_tires": [
			"CULLABLE_CAR_PART_TIRE_FL",
			"CULLABLE_CAR_PART_TIRE_FR",
			"CULLABLE_CAR_PART_TIRE_RR",
			"CULLABLE_CAR_PART_TIRE_RL",
		],
		"cullable_brakes": [
			"CULLABLE_CAR_PART_BRAKE_FL",
			"CULLABLE_CAR_PART_BRAKE_FR",
			"CULLABLE_CAR_PART_BRAKE_RR",
			"CULLABLE_CAR_PART_BRAKE_RL",
		],
	},
}

const PLAYER_SPORT_CARS := {
	"911TURBO": true,
	"BARCHETTA": true,
	"BMWM5": true,
	"BMWZ8": true,
	"CARRERAGT": true,
	"CHALLENGE": true,
	"CL55AMG": true,
	"CLK_GTR": true,
	"CORVETTE": true,
	"ELISE": true,
	"F50": true,
	"HOLDEN": true,
	"JAGUAR": true,
	"MCLAREN": true,
	"MCLARENLM": true,
	"MURCIELAGO": true,
	"MUSTANG": true,
	"OPEL": true,
	"SPIDER": true,
	"TS50": true,
	"VANQUISH": true,
	"VAUXHALL": true,
	"VIPERGTS": true,
}

const COP_CARS := {
	"BMWM5COP": true,
	"CORVETTECOP": true,
	"LAMBOCOP": true,
	"MUSTANGCOP": true,
}

const HEAVY_TRAFFIC := {
	"AMBULANCE": true,
	"BUS": true,
	"FIRETRUCK": true,
	"MINIVAN": true,
	"PANELVAN": true,
	"PARCELVAN": true,
	"PICKUP": true,
	"SUV": true,
}


static func data_for_car(car_id: String, fallback_slots: Array, runtime_slots: Array = [], globalb_row: Dictionary = {}) -> Dictionary:
	var id := car_id.to_upper()
	var decoded_slots := _normalise_slots(runtime_slots)
	var fallback_normalised := _normalise_slots(fallback_slots)
	var slots := decoded_slots if decoded_slots.size() >= 4 else fallback_normalised
	var estimated_handling := _handling_for_car(id)
	var handling := _handling_from_globalb(id, slots, globalb_row, estimated_handling)
	_apply_runtime_wheel_radius(handling, decoded_slots)
	var has_globalb_row := not globalb_row.is_empty()
	return {
		"car_id": id,
		"reverse_facts": REVERSE_FACTS.duplicate(true),
		"handling": handling,
		"globalb_row": globalb_row.duplicate(true),
		"vehicle_dimensions": globalb_row.get("vehicle_dimensions", {}).duplicate(true),
		"suspension": handling.get("suspension", {}).duplicate(true),
		"drivetrain": handling.get("drivetrain", {}).duplicate(true),
		"tire_model": handling.get("tire_model", {}).duplicate(true),
		"aero": handling.get("aero", {}).duplicate(true),
		"exact_handling_status": "globalb_row_verified_layout_inferred_force_model" if has_globalb_row else ("globalb_runtime_wheel_vectors_partial_handling" if decoded_slots.size() >= 4 else "partial_reverse_estimated_constants"),
		"handling_source": "GLOBALB row 0x00034600 decoded with verified layout and inferred physics fields" if has_globalb_row else "Ghidra runtime layout facts plus estimated controller constants",
		"wheel_slots": slots,
		"brake_slots": slots.duplicate(true),
		"wheel_slot_source": _wheel_slot_source(slots),
		"decoded_wheel_slot_count": decoded_slots.size(),
		"fallback_wheel_slot_count": fallback_normalised.size(),
		"globalb_row_index": int(globalb_row.get("row_index", -1)),
		"globalb_row_offset": int(globalb_row.get("row_offset", -1)),
		"globalb_row_count": int(globalb_row.get("row_count", 0)),
		"source_confidence": {
			"runtime_part_names": "high",
			"wheel_table_offsets": "high" if decoded_slots.size() >= 4 else "medium",
			"wheel_slot_positions": _wheel_slot_source(slots),
			"handling_constants": "inferred_from_globalb_row" if has_globalb_row else "estimated",
			"globalb_row_stride": "verified" if has_globalb_row else "missing",
			"globalb_vehicle_type": "verified" if has_globalb_row else "missing",
			"force_formulas": "research_in_progress",
		},
	}


static func _handling_from_globalb(car_id: String, slots: Array[Dictionary], globalb_row: Dictionary, fallback: Dictionary) -> Dictionary:
	var handling := fallback.duplicate(true)
	if globalb_row.is_empty():
		return handling
	var fields: Dictionary = globalb_row.get("inferred_float_fields", {})
	var tire_front: Array = globalb_row.get("tire_curve_front", [])
	var tire_rear: Array = globalb_row.get("tire_curve_rear", [])
	var front_radius := _average_radius(slots, "front", float(handling.get("wheel_radius", 0.36)))
	var rear_radius := _average_radius(slots, "rear", front_radius)
	var wheel_radius := (front_radius + rear_radius) * 0.5
	var mass := clampf(_field_value(fields, "mass", 1200.0), 700.0, 6000.0)
	var redline := clampf(_field_value(fields, "engine_redline_rpm", 7600.0), 3000.0, 12000.0)
	var peak_rpm := clampf(_field_value(fields, "engine_peak_rpm", redline * 0.85), 2500.0, redline)
	var idle_rpm := clampf(redline * 0.115, 650.0, 1200.0)
	var gear_count := clampi(int(round(_field_value(fields, "gear_count", 5.0))), 3, 7)
	var gear_ratios := _globalb_gear_ratios(fields, gear_count)
	gear_count = clampi(gear_ratios.size(), 3, 7)
	var reverse_ratio := _field_value(fields, "reverse_gear_ratio", -gear_ratios[0])
	var final_drive_ratio := clampf(_field_value(fields, "final_drive_ratio", 3.42), 0.5, 8.0)
	var front_tire_grip := _field_value(fields, "front_tire_grip", 70.0)
	var rear_tire_grip := _field_value(fields, "rear_tire_grip", front_tire_grip)
	var avg_tire_grip := maxf(1.0, (front_tire_grip + rear_tire_grip) * 0.5)
	var lateral_curve_avg := maxf(0.25, (_curve_average(tire_front, 0.65) + _curve_average(tire_rear, 0.65)) * 0.5)
	var forward_speed_hint := maxf(20.0, redline / 100.0)
	var reverse_speed_hint := maxf(8.0, forward_speed_hint * clampf(absf(reverse_ratio) / maxf(absf(float(gear_ratios[0])), 0.1), 0.55, 1.2) * 0.32)
	var steering_response := clampf(_field_value(fields, "steering_response", 3.0), 1.0, 8.0)
	var steering_return := clampf(_field_value(fields, "steering_return", steering_response), 1.0, 8.0)
	var steering_lock_scale := clampf(_field_value(fields, "steering_lock_scale", 1.0), 0.35, 1.25)
	var suspension_rest := maxf(0.15, (_field_value(fields, "front_suspension_rest", wheel_radius) + _field_value(fields, "rear_suspension_rest", wheel_radius)) * 0.25)
	var suspension_travel := maxf(0.12, (_field_value(fields, "front_suspension_travel", 1.6) + _field_value(fields, "rear_suspension_travel", 1.6)) * 0.08)
	handling["source"] = "globalb_0x00034600_verified_layout_inferred_force_model"
	handling["status"] = "globalb_decoded_inferred_physics"
	handling["exact_handling_status"] = "globalb_row_verified_layout_inferred_force_model"
	handling["movement_model"] = "hp2_custom_four_wheel_force_pipeline"
	handling["car_id"] = car_id
	handling["globalb_row_index"] = int(globalb_row.get("row_index", -1))
	handling["globalb_row_offset"] = int(globalb_row.get("row_offset", -1))
	handling["globalb_vehicle_type"] = int(_field_dict(globalb_row.get("vehicle_type", {})).get("value", 0))
	handling["wheel_radius"] = wheel_radius
	handling["front_wheel_radius"] = front_radius
	handling["rear_wheel_radius"] = rear_radius
	handling["mass"] = mass
	handling["max_forward_speed"] = forward_speed_hint
	handling["max_reverse_speed"] = reverse_speed_hint
	handling["engine_accel"] = clampf(peak_rpm / 200.0, 14.0, 60.0)
	handling["brake_accel"] = clampf(avg_tire_grip * 0.70, 25.0, 90.0)
	handling["reverse_accel"] = clampf(peak_rpm / 400.0, 8.0, 32.0)
	handling["engine_idle_rpm"] = idle_rpm
	handling["engine_peak_rpm"] = peak_rpm
	handling["engine_redline_rpm"] = redline
	handling["engine_brake_accel"] = clampf(peak_rpm / 900.0, 4.0, 12.0)
	handling["gear_count"] = gear_count
	handling["gear_ratios"] = gear_ratios
	handling["reverse_gear_ratio"] = reverse_ratio
	handling["final_drive_ratio"] = final_drive_ratio
	handling["shift_up_rpm"] = redline * 0.94
	handling["shift_down_rpm"] = peak_rpm * 0.58
	handling["shift_strategy"] = "hp2_torque_crossing_recovered_from_FUN_0018ac38"
	handling["shift_scan_step_rpm"] = 50.0
	handling["shift_redline_margin_rpm"] = 200.0
	handling["shift_up_speed_scale"] = 0.82
	handling["shift_down_speed_scale"] = 0.62
	handling["shift_duration"] = 0.18
	handling["throttle_response_rate"] = 7.5
	handling["reverse_engage_speed"] = 1.2
	handling["reverse_hold_delay"] = 0.10
	handling["linear_drag"] = clampf(_field_value(fields, "aero_drag", 0.0004) * 900.0, 0.18, 0.8)
	handling["rolling_drag"] = clampf(_field_value(fields, "rolling_resistance", 0.05) * 45.0, 1.0, 4.5)
	handling["lateral_grip"] = clampf(lateral_curve_avg * 13.0, 4.0, 11.0)
	handling["front_lateral_grip"] = clampf(_field_value(fields, "front_lateral_grip", 5.0) * 1.45, 4.0, 12.0)
	handling["rear_lateral_grip"] = clampf(_field_value(fields, "rear_lateral_grip", 5.0) * 1.45, 4.0, 12.0)
	handling["front_longitudinal_grip"] = clampf(_field_value(fields, "front_longitudinal_grip", 70.0) / 9.0, 3.0, 12.0)
	handling["rear_longitudinal_grip"] = clampf(_field_value(fields, "rear_longitudinal_grip", 70.0) / 9.0, 3.0, 12.0)
	handling["handbrake_grip_scale"] = 0.38
	handling["steer_rate"] = steering_response
	handling["steer_return_rate"] = steering_return
	handling["max_steer_angle"] = 0.58 * steering_lock_scale
	handling["yaw_response"] = steering_response
	handling["yaw_damping"] = clampf(steering_return * 1.65, 2.5, 9.0)
	handling["gravity"] = 28.0
	handling["suspension_height"] = maxf(0.35, wheel_radius + suspension_rest * 0.5)
	handling["ground_probe_distance"] = maxf(0.9, wheel_radius + suspension_rest + suspension_travel)
	handling["suspension"] = {
		"schema": "hp2_globalb_suspension_inferred",
		"confidence": "inferred",
		"front_rest_length": _copy_field(fields, "front_suspension_rest"),
		"front_travel": _copy_field(fields, "front_suspension_travel"),
		"rear_rest_length": _copy_field(fields, "rear_suspension_rest"),
		"rear_travel": _copy_field(fields, "rear_suspension_travel"),
		"runtime_rest_length": _derived_field(suspension_rest, ["front_suspension_rest", "rear_suspension_rest"], "inferred"),
		"runtime_travel": _derived_field(suspension_travel, ["front_suspension_travel", "rear_suspension_travel"], "inferred"),
		"spring_rate": _derived_field(clampf(mass * 5.5, 4500.0, 30000.0), ["mass"], "inferred"),
		"damping": _derived_field(clampf(mass * 0.75, 650.0, 6000.0), ["mass"], "inferred"),
	}
	handling["drivetrain"] = {
		"schema": "hp2_globalb_drivetrain_inferred",
		"confidence": "inferred",
		"note": "PhysicsCar constructs Engine from row+0x2b0 and DriveTrain from row+0x270. Gear count at row+0x288 and ratios at row+0x290.. are confirmed by HP2_BuildAccelerationOrShiftCurve_FUN_00188df0; upshift RPM follows the torque-crossing scan recovered from HP2_DriveTrain_BuildShiftTables_FUN_0018ac38.",
		"mass": _copy_field(fields, "mass"),
		"engine_idle_rpm": _derived_field(idle_rpm, ["engine_redline_rpm"], "inferred"),
		"engine_peak_rpm": _copy_field(fields, "engine_peak_rpm"),
		"engine_redline_rpm": _copy_field(fields, "engine_redline_rpm"),
		"gear_count": _copy_field(fields, "gear_count"),
		"gear_ratios": _derived_field(handling["gear_ratios"], ["gear_ratio_1", "gear_ratio_2", "gear_ratio_3", "gear_ratio_4", "gear_ratio_5", "gear_ratio_6"], "inferred"),
		"reverse_gear_ratio": _copy_field(fields, "reverse_gear_ratio"),
		"neutral_gear_ratio": _copy_field(fields, "neutral_gear_ratio"),
		"final_drive_ratio": _copy_field(fields, "final_drive_ratio"),
		"shift_up_rpm": _derived_field(handling["shift_up_rpm"], ["engine_redline_rpm", "gear_ratios"], "inferred"),
		"shift_down_rpm": _derived_field(handling["shift_down_rpm"], ["engine_peak_rpm"], "inferred"),
		"shift_strategy": _derived_field(handling["shift_strategy"], ["gear_ratios", "engine_peak_rpm", "engine_redline_rpm"], "inferred"),
		"max_forward_speed": _derived_field(forward_speed_hint, ["engine_redline_rpm"], "inferred"),
		"max_reverse_speed": _derived_field(reverse_speed_hint, ["reverse_gear_ratio", "gear_ratio_1", "engine_redline_rpm"], "inferred"),
	}
	handling["tire_model"] = {
		"schema": "hp2_globalb_tire_curve_inferred",
		"confidence": "inferred",
		"front_curve": _copy_array(tire_front),
		"rear_curve": _copy_array(tire_rear),
		"front_lateral_grip": _copy_field(fields, "front_lateral_grip"),
		"rear_lateral_grip": _copy_field(fields, "rear_lateral_grip"),
		"front_longitudinal_grip": _copy_field(fields, "front_longitudinal_grip"),
		"rear_longitudinal_grip": _copy_field(fields, "rear_longitudinal_grip"),
	}
	handling["aero"] = {
		"schema": "hp2_globalb_aero_inferred",
		"confidence": "inferred",
		"aero_reference": _copy_field(fields, "aero_reference"),
		"aero_drag": _copy_field(fields, "aero_drag"),
	}
	return handling


static func _average_radius(slots: Array[Dictionary], axle: String, fallback: float) -> float:
	var total := 0.0
	var count := 0
	for slot in slots:
		if String(slot.get("axle", "")).to_lower() != axle:
			continue
		var radius := float(slot.get("wheel_radius", 0.0))
		if radius <= 0.0:
			continue
		total += radius
		count += 1
	if count <= 0:
		return fallback
	return total / float(count)


static func _field_value(fields: Dictionary, name: String, fallback: float) -> float:
	if not fields.has(name):
		return fallback
	var field: Dictionary = fields[name]
	return float(field.get("value", fallback))


static func _field_dict(value) -> Dictionary:
	if value is Dictionary:
		return value
	return {}


static func _copy_field(fields: Dictionary, name: String) -> Dictionary:
	if not fields.has(name):
		return {
			"value": 0.0,
			"offset": -1,
			"offset_hex": "",
			"source": "GLOBAL/GLOBALB.BUN chunk 0x00034600 row + offset",
			"confidence": "unknown",
			"note": "Field not decoded for this row",
		}
	var field: Dictionary = fields[name]
	return field.duplicate(true)


static func _copy_array(values: Array) -> Array:
	var out: Array = []
	for value in values:
		if value is Dictionary:
			out.append((value as Dictionary).duplicate(true))
		else:
			out.append(value)
	return out


static func _curve_average(values: Array, fallback: float) -> float:
	if values.is_empty():
		return fallback
	var total := 0.0
	var count := 0
	for value in values:
		var item: Dictionary = value
		var f := float(item.get("value", 0.0))
		if f <= 0.0 or f > 10.0:
			continue
		total += f
		count += 1
	if count <= 0:
		return fallback
	return total / float(count)


static func _derived_field(value, inputs: Array, confidence: String) -> Dictionary:
	return {
		"value": value,
		"inputs": inputs.duplicate(),
		"source": "Derived from decoded GLOBALB row fields",
		"confidence": confidence,
		"note": "Runtime formula is still under Ghidra verification",
	}


static func _default_gear_ratios(gear_count: int) -> Array:
	var count := clampi(gear_count, 3, 7)
	var ratios := []
	for i in range(count):
		var t := float(i) / maxf(float(count - 1), 1.0)
		ratios.append(lerpf(3.10, 0.72, pow(t, 0.72)))
	return ratios


static func _globalb_gear_ratios(fields: Dictionary, gear_count: int) -> Array:
	var ratios := []
	var count := clampi(gear_count, 3, 6)
	for index in range(count):
		var ratio := _field_value(fields, "gear_ratio_%d" % (index + 1), 0.0)
		if ratio <= 0.01:
			break
		ratios.append(ratio)
	if ratios.size() < 3:
		return _default_gear_ratios(maxi(gear_count, 4))
	return ratios


static func _handling_for_car(car_id: String) -> Dictionary:
	var handling := {
		"source": "partial_hp2_reverse_estimated_constants",
		"reverse_notes": "res://eagl/assets/car/reverse_notes.md",
		"car_id": car_id,
		"movement_model": "custom_node3d_ps2_style",
		"max_forward_speed": 86.0,
		"max_reverse_speed": 18.0,
		"engine_accel": 34.0,
		"engine_idle_rpm": 850.0,
		"engine_peak_rpm": 6500.0,
		"engine_redline_rpm": 7600.0,
		"engine_brake_accel": 7.0,
		"gear_count": 5,
		"gear_ratios": _default_gear_ratios(5),
		"reverse_gear_ratio": -3.10,
		"final_drive_ratio": 3.42,
		"shift_up_rpm": 7100.0,
		"shift_down_rpm": 3700.0,
		"shift_up_speed_scale": 0.82,
		"shift_down_speed_scale": 0.62,
		"shift_duration": 0.18,
		"throttle_response_rate": 7.5,
		"reverse_engage_speed": 1.2,
		"reverse_hold_delay": 0.10,
		"brake_accel": 48.0,
		"reverse_accel": 18.0,
		"linear_drag": 0.42,
		"rolling_drag": 2.0,
		"lateral_grip": 8.5,
		"handbrake_grip_scale": 0.38,
		"steer_rate": 2.6,
		"steer_return_rate": 5.0,
		"max_steer_angle": 0.62,
		"yaw_response": 2.8,
		"yaw_damping": 5.5,
		"gravity": 28.0,
		"suspension_height": 0.75,
		"ground_probe_distance": 1.35,
		"wheel_radius": 0.36,
		"status": "partial_reverse_estimated",
		"exact_handling_status": "partial_reverse_estimated_constants",
	}
	if HEAVY_TRAFFIC.has(car_id):
		handling["max_forward_speed"] = 42.0
		handling["engine_accel"] = 18.0
		handling["brake_accel"] = 34.0
		handling["lateral_grip"] = 6.2
		handling["yaw_response"] = 1.45
		handling["yaw_damping"] = 4.4
		handling["max_steer_angle"] = 0.5
		handling["wheel_radius"] = 0.48
	elif COP_CARS.has(car_id):
		handling["max_forward_speed"] = 82.0
		handling["engine_accel"] = 32.0
		handling["lateral_grip"] = 8.0
	elif PLAYER_SPORT_CARS.has(car_id):
		handling["max_forward_speed"] = 92.0
		handling["engine_accel"] = 38.0
		handling["lateral_grip"] = 9.0
	return handling


static func _normalise_slots(slots: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for slot in slots:
		var slot_dict: Dictionary = slot
		var axle := String(slot_dict.get("axle", "front")).to_lower()
		var side := String(slot_dict.get("side", "left")).to_lower()
		var slot_id := _slot_id(axle, side)
		var normalised := slot_dict.duplicate(true)
		normalised["slot_id"] = slot_id
		normalised["name"] = slot_id
		normalised["axle"] = axle
		normalised["side"] = side
		normalised["is_front"] = axle == "front"
		normalised["is_right"] = side == "right"
		if String(normalised.get("source", "")) == "":
			normalised["source"] = "geometry_locator_0x00034013"
		out.append(normalised)
	return out


static func _apply_runtime_wheel_radius(handling: Dictionary, slots: Array[Dictionary]) -> void:
	var total := 0.0
	var count := 0
	for slot in slots:
		var radius := float(slot.get("wheel_radius", 0.0))
		if radius <= 0.0:
			continue
		total += radius
		count += 1
	if count > 0:
		handling["wheel_radius"] = total / float(count)
		handling["wheel_radius_source"] = "globalb_0x00034600_runtime_wheel_table"


static func _wheel_slot_source(slots: Array[Dictionary]) -> String:
	if slots.is_empty():
		return "unresolved"
	var source := String(slots[0].get("source", "geometry_locator_0x00034013"))
	for slot in slots:
		var slot_source := String(slot.get("source", "geometry_locator_0x00034013"))
		if slot_source != source:
			return "mixed_binary_wheel_slots"
	if source == "geometry_bounds_estimated":
		return "geometry_bounds_estimated_fallback"
	if source == "geometry_locator_0x00034013":
		return "geometry_locator_0x00034013_binary"
	return source


static func _slot_id(axle: String, side: String) -> String:
	if axle == "front":
		return "FR" if side == "right" else "FL"
	return "RR" if side == "right" else "RL"
