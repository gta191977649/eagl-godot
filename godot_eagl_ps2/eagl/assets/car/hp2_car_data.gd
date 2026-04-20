class_name HP2CarData
extends RefCounted

const REVERSE_FACTS := {
	"status": "partial",
	"notes": "Recovered from Ghidra pass plus GLOBALB.BUN/CARS geometry chunks; handling constants are still partial, but wheel visual dummies are decoded from car geometry.",
	"functions": {
		"car_assembly": "FUN_0011e860",
		"car_light_setup": "FUN_0011fe60",
		"damage_runtime_parts": "FUN_0011ff68",
		"attached_part_locator_scan": "FUN_00120360",
		"physics_move_string": "PhysicsCar::Move()",
		"physics_forces_string": "PhysicsCar::ResolveForces()",
	},
	"runtime_table": {
		"symbol": "uGpffffaf78",
		"init_function": "FUN_00187f98",
		"source_chunk": "GLOBAL/GLOBALB.BUN chunk 0x00034600",
		"row_stride": 0x560,
		"wheel_vector_offsets": [0x120, 0x140, 0x160, 0x180],
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


static func data_for_car(car_id: String, fallback_slots: Array, runtime_slots: Array = []) -> Dictionary:
	var id := car_id.to_upper()
	var decoded_slots := _normalise_slots(runtime_slots)
	var fallback_normalised := _normalise_slots(fallback_slots)
	var slots := decoded_slots if decoded_slots.size() >= 4 else fallback_normalised
	var handling := _handling_for_car(id)
	_apply_runtime_wheel_radius(handling, decoded_slots)
	return {
		"car_id": id,
		"reverse_facts": REVERSE_FACTS.duplicate(true),
		"handling": handling,
		"exact_handling_status": "globalb_runtime_wheel_vectors_partial_handling" if decoded_slots.size() >= 4 else "partial_reverse_estimated_constants",
		"handling_source": "Ghidra runtime layout facts plus estimated controller constants",
		"wheel_slots": slots,
		"brake_slots": slots.duplicate(true),
		"wheel_slot_source": _wheel_slot_source(slots),
		"decoded_wheel_slot_count": decoded_slots.size(),
		"fallback_wheel_slot_count": fallback_normalised.size(),
		"source_confidence": {
			"runtime_part_names": "high",
			"wheel_table_offsets": "high" if decoded_slots.size() >= 4 else "medium",
			"wheel_slot_positions": _wheel_slot_source(slots),
			"handling_constants": "estimated",
		},
	}


static func _handling_for_car(car_id: String) -> Dictionary:
	var handling := {
		"source": "partial_hp2_reverse_estimated_constants",
		"reverse_notes": "res://eagl/assets/car/reverse_notes.md",
		"car_id": car_id,
		"movement_model": "custom_node3d_ps2_style",
		"max_forward_speed": 86.0,
		"max_reverse_speed": 18.0,
		"engine_accel": 34.0,
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
