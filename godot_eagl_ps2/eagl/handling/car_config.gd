class_name CarConfig
extends Resource

const WheelStateScript = preload("res://eagl/handling/wheel_state.gd")

const SLOT_IDS = ["FL", "FR", "RL", "RR"]
const SLOT_AXLES = ["front", "front", "rear", "rear"]
const SLOT_SIDES = ["left", "right", "left", "right"]

@export var car_name = "HP2 Car"
@export var row_index = -1
@export var duplicate_index = 1
@export_enum("FWD", "RWD", "AWD") var drive_type = "RWD"
@export var globalb_vehicle_type_id = -1
@export var globalb_vehicle_class_id = -1
@export var globalb_handling_profile_id = -1
@export var globalb_handling_profile_count = 0
@export var globalb_handling_profile_sequence = PackedInt32Array()

@export var mass_kg = 1000.0
@export var center_of_mass_ps2 = Vector3.ZERO
@export var body_size_ps2 = Vector3(4.6, 1.9, 1.2)
@export var physics_origin_offset_ps2 = Vector3.ZERO

@export var wheel_local_positions_ps2: Array[Vector3] = [
	Vector3(1.3, 0.72, 0.2),
	Vector3(1.3, -0.72, 0.2),
	Vector3(-1.36, 0.72, 0.2),
	Vector3(-1.36, -0.72, 0.2),
]
@export var wheel_radii = PackedFloat32Array([0.32, 0.32, 0.33, 0.33])

@export var front_progressive_spring_scale = 4.5
@export var front_spring_coefficient = 55.0
@export var front_rebound_damping = 5.3
@export var front_bump_damping = 5.0
@export var front_bump_stop_coefficient = 32.0
@export var front_anti_roll_coefficient = 32.0
@export var front_rest_length = 1.46
@export var front_travel_limit = 1.85
@export var front_max_compression = 0.125
@export var front_min_compression = -0.13
@export var front_reference_length = 0.0
@export var hp2_front_tire_0x1a0 = 0.0
@export var hp2_front_tire_0x1a4 = 0.0
@export var hp2_front_tire_0x1a8 = 0.0
@export var hp2_front_tire_0x1ac = 0.0
@export var hp2_front_tire_0x1b0 = 0.0
@export var hp2_front_tire_0x1b4 = 0.0
@export var hp2_front_tire_0x1b8 = 0.0
@export var hp2_front_tire_0x1bc = 0.0

@export var rear_progressive_spring_scale = 4.5
@export var rear_spring_coefficient = 53.0
@export var rear_rebound_damping = 5.3
@export var rear_bump_damping = 5.0
@export var rear_bump_stop_coefficient = 34.0
@export var rear_anti_roll_coefficient = 34.0
@export var rear_rest_length = 1.56
@export var rear_travel_limit = 1.95
@export var rear_max_compression = 0.115
@export var rear_min_compression = -0.115
@export var rear_reference_length = 0.0
@export var hp2_rear_tire_0x1c0 = 0.0
@export var hp2_rear_tire_0x1c4 = 0.0
@export var hp2_rear_tire_0x1c8 = 0.0
@export var hp2_rear_tire_0x1cc = 0.0
@export var hp2_rear_tire_0x1d0 = 0.0
@export var hp2_rear_tire_0x1d4 = 0.0
@export var hp2_rear_tire_0x1d8 = 0.0
@export var hp2_rear_tire_0x1dc = 0.0

@export var steering_response = 3.42
@export var steering_return = 3.42
@export var steering_lock_scale = 1.0
@export var steering_max_degrees = 28.0
@export var steering_hysteresis_enter = 0.12
@export var steering_hysteresis_exit = 0.06
@export var low_speed_steer_scale = 1.0
@export var high_speed_steer_scale = 0.28
@export var high_speed_steer_kph = 240.0

@export var front_lateral_grip = 1.18
@export var rear_lateral_grip = 1.08
@export var front_longitudinal_grip = 1.15
@export var rear_longitudinal_grip = 1.22
@export var slip_grip_reduction_start_deg = 6.0
@export var slip_grip_reduction_end_deg = 24.0
@export var drift_grip_scale = 0.58
@export var stabilization_slip_deg = 10.0
@export var drift_slip_deg = 18.0
@export var stabilization_min_speed_kph = 30.0
@export var yaw_damping = 1.8
@export var yaw_assist = 1350.0
@export var steering_yaw_assist = 680.0
@export var hp2_row_0x300 = 0.0
@export var hp2_row_0x304 = 0.0
@export var hp2_row_0x308 = 0.0
@export var hp2_row_0x310 = 0.0
@export var hp2_row_0x314 = 0.0
@export var hp2_row_0x318 = 0.0
@export var hp2_row_0x31c = 0.0
@export var hp2_row_0x320 = 0.0

@export var final_drive_ratio = 4.0
@export var reverse_gear_ratio = -2.97
@export var forward_gears = PackedFloat32Array([2.97, 2.07, 1.43, 1.0, 0.84, 0.56])
@export var idle_rpm = 900.0
@export var engine_peak_rpm = 6500.0
@export var engine_redline_rpm = 7200.0
@export var shift_up_rpm = 6900.0
@export var shift_down_rpm = 3600.0
@export var engine_force_scale = 8400.0
@export var top_speed_reference_kph = 315.0
@export var brake_force = 10500.0
@export var handbrake_force = 4600.0

@export var rolling_resistance = 0.045
@export var aero_drag = 0.000473


func build_wheel_states() -> Array:
	var states: Array = []
	var front_preload = _front_axle_preload()
	var rear_preload = _rear_axle_preload()

	for index in range(SLOT_IDS.size()):
		if index >= wheel_local_positions_ps2.size() or index >= wheel_radii.size():
			break
		var wheel = WheelStateScript.new()
		var physics_local_position: Vector3 = wheel_local_positions_ps2[index] - physics_origin_offset_ps2
		wheel.slot_id = SLOT_IDS[index]
		wheel.axle = SLOT_AXLES[index]
		wheel.side = SLOT_SIDES[index]
		wheel.pivot_local_position_ps2 = physics_local_position
		wheel.local_position_ps2 = physics_local_position
		wheel.wheel_radius = wheel_radii[index]
		if wheel.is_front():
			wheel.progressive_spring_scale = front_progressive_spring_scale
			wheel.spring_coefficient = front_spring_coefficient
			wheel.rebound_damping = front_rebound_damping
			wheel.bump_damping = front_bump_damping
			wheel.bump_stop_coefficient = front_bump_stop_coefficient
			wheel.anti_roll_coefficient = front_anti_roll_coefficient
			wheel.rest_length = front_rest_length
			wheel.min_travel = front_min_compression
			wheel.max_travel = front_max_compression
			wheel.reference_length = front_reference_length
			wheel.preload_force = front_preload
			wheel.lateral_grip = front_lateral_grip
			wheel.longitudinal_grip = front_longitudinal_grip
		else:
			wheel.progressive_spring_scale = rear_progressive_spring_scale
			wheel.spring_coefficient = rear_spring_coefficient
			wheel.rebound_damping = rear_rebound_damping
			wheel.bump_damping = rear_bump_damping
			wheel.bump_stop_coefficient = rear_bump_stop_coefficient
			wheel.anti_roll_coefficient = rear_anti_roll_coefficient
			wheel.rest_length = rear_rest_length
			wheel.min_travel = rear_min_compression
			wheel.max_travel = rear_max_compression
			wheel.reference_length = rear_reference_length
			wheel.preload_force = rear_preload
			wheel.lateral_grip = rear_lateral_grip
			wheel.longitudinal_grip = rear_longitudinal_grip
		var length_min := minf(wheel.min_travel, wheel.max_travel)
		wheel.current_length = length_min
		wheel.previous_length = length_min
		wheel.suspension_distance = length_min
		wheel.center_offset = length_min
		states.append(wheel)
	return states


func get_gear_ratio(gear: int) -> float:
	if gear < 0:
		return reverse_gear_ratio
	var gear_index = clampi(gear - 1, 0, maxi(forward_gears.size() - 1, 0))
	if forward_gears.is_empty():
		return 1.0
	return forward_gears[gear_index]


func top_gear() -> int:
	return maxi(forward_gears.size(), 1)


func drive_bias_for_slot(slot_id: String) -> float:
	match drive_type:
		"FWD":
			return 0.5 if slot_id in ["FL", "FR"] else 0.0
		"AWD":
			return 0.25
		_:
			return 0.5 if slot_id in ["RL", "RR"] else 0.0


func driven_average_radius() -> float:
	var total = 0.0
	var count = 0
	for index in range(SLOT_IDS.size()):
		if drive_bias_for_slot(SLOT_IDS[index]) <= 0.0 or index >= wheel_radii.size():
			continue
		total += wheel_radii[index]
		count += 1
	return total / float(count) if count > 0 else 0.33


func sample_engine_force(speed_mps: float, rpm: float) -> float:
	var speed_kph = speed_mps * 3.6
	var speed_factor = 1.0 - clampf(speed_kph / maxf(top_speed_reference_kph, 1.0), 0.0, 1.0)
	var rpm_span = maxf(engine_redline_rpm - idle_rpm, 1.0)
	var peak_offset = absf(rpm - engine_peak_rpm) / rpm_span
	var rpm_factor = clampf(1.0 - peak_offset * 1.35, 0.35, 1.0)
	return engine_force_scale * speed_factor * rpm_factor


func front_axle_center_x() -> float:
	if wheel_local_positions_ps2.size() < 2:
		return 1.0
	return (wheel_local_positions_ps2[0].x + wheel_local_positions_ps2[1].x) * 0.5


func rear_axle_center_x() -> float:
	if wheel_local_positions_ps2.size() < 4:
		return -1.0
	return (wheel_local_positions_ps2[2].x + wheel_local_positions_ps2[3].x) * 0.5


func wheelbase_meters() -> float:
	return absf(front_axle_center_x() - rear_axle_center_x())


func _front_axle_preload() -> float:
	var split = _axle_preload_split()
	return split["front_each"]


func _rear_axle_preload() -> float:
	var split = _axle_preload_split()
	return split["rear_each"]


func _axle_preload_split() -> Dictionary:
	# HP2 uses the row + 0x110 X value to bias front/rear wheel preload in
	# FUN_001375f0, but that value has not been verified as the rigid-body COM
	# handed to Godot. Keep axle-load balance separate from center_of_mass_ps2.
	var load_origin_x: float = physics_origin_offset_ps2.x
	if absf(load_origin_x) <= 0.0001:
		load_origin_x = center_of_mass_ps2.x
	var front_x: float = front_axle_center_x() - load_origin_x
	var rear_x: float = rear_axle_center_x() - load_origin_x
	var denom: float = front_x - rear_x
	if absf(denom) <= 0.0001:
		var equal_share: float = mass_kg * 9.8 * 0.25
		return {
			"front_each": equal_share,
			"rear_each": equal_share,
		}
	var rear_each_fraction: float = (front_x / denom) * 0.5
	var front_each_fraction: float = 0.5 - rear_each_fraction
	var total_load: float = mass_kg * 9.8
	return {
		"front_each": total_load * front_each_fraction,
		"rear_each": total_load * rear_each_fraction,
	}
