class_name VehicleBodyConfigAdapter
extends RefCounted

const MathUtils = preload("res://eagl/utils/math_utils.gd")

const SLOT_IDS := ["FL", "FR", "RL", "RR"]
const SAFE_SUSPENSION_TRAVEL_MIN := 0.08
const SAFE_SUSPENSION_TRAVEL_MAX := 0.35
const SAFE_REST_LENGTH_MIN := 0.04
const SAFE_REST_LENGTH_MAX := 0.25
const GODOT_LAUNCH_FORCE_PER_DRIVEN_WHEEL := 3200.0
const GODOT_BRAKE_FORCE_TOTAL_1000KG := 450.0
const GODOT_HAND_BRAKE_FORCE_TOTAL_1000KG := 1700.0
const GODOT_FRICTION_SLIP_MIN := 8.5
const GODOT_FRICTION_SLIP_MAX := 12.5
const GODOT_ROLLING_RESISTANCE_SCALE := 0.08
const GODOT_ROLLING_RESISTANCE_MIN := 0.002
const GODOT_ROLLING_RESISTANCE_MAX := 0.01
const GODOT_AERO_DRAG_SCALE := 1.0
const LOW_SPEED_TORQUE_BOOST := 1.45
const LOW_SPEED_TORQUE_FADE_KPH := 90.0
const ENGINE_BRAKE_GAIN := 0.035
const COAST_DRAG_GAIN := 0.01
const BRAKE_LOCK_ENTRY := 0.78
const BRAKE_LOCK_REAR_SLIP_SCALE := 0.16
const HANDBRAKE_REAR_SLIP_SCALE := 0.22
const FRONT_BRAKE_SLIP_SCALE := 0.92


static func visual_anchor_basis() -> Basis:
	return Basis(
		Vector3(0.0, 0.0, 1.0),
		Vector3(0.0, 1.0, 0.0),
		Vector3(1.0, 0.0, 0.0)
	)


static func vehicle_space_from_ps2(value: Vector3) -> Vector3:
	return visual_anchor_basis() * MathUtils.ps2_to_godot_vec3(value)


static func visual_space_from_vehicle(value: Vector3) -> Vector3:
	return Vector3(value.z, value.y, value.x)


static func body_size_vehicle(config) -> Vector3:
	return Vector3(
		absf(config.body_size_ps2.y),
		absf(config.body_size_ps2.z),
		absf(config.body_size_ps2.x)
	)


static func build_vehicle_setup(config) -> Dictionary:
	var resolved_mass := physics_mass_kg(config)
	var axle_masses := _axle_supported_masses(config)
	var driven_wheel_count := _driven_wheel_count(config)
	var mass_ratio := resolved_mass / 1000.0
	var hp2_idle_launch_force_total := _hp2_drive_force_total(config, 0.0, config.idle_rpm, 1)
	var hp2_launch_force_total := _hp2_drive_force_total(config, 0.0, config.engine_peak_rpm, 1)
	var hp2_launch_accel_reference := hp2_launch_force_total / resolved_mass
	var godot_launch_force_total := GODOT_LAUNCH_FORCE_PER_DRIVEN_WHEEL * float(driven_wheel_count) * mass_ratio
	var engine_force_normalization_gain := godot_launch_force_total / maxf(hp2_idle_launch_force_total, 0.001)
	var brake_force_total := GODOT_BRAKE_FORCE_TOTAL_1000KG * mass_ratio
	var handbrake_force_total := GODOT_HAND_BRAKE_FORCE_TOTAL_1000KG * mass_ratio
	var brake_force_normalization_gain := brake_force_total / maxf(config.brake_force, 0.001)
	var wheels := {}
	for index in range(SLOT_IDS.size()):
		if index >= config.wheel_local_positions_ps2.size() or index >= config.wheel_radii.size():
			break
		var slot_id: String = SLOT_IDS[index]
		var is_front := slot_id.begins_with("F")
		var suspension_travel := _suspension_travel_for_axle(config, is_front)
		var rest_length := _rest_length_for_axle(config, is_front)
		var static_ride_height := _static_ride_height_for_axle(config, is_front)
		var wheel_center := vehicle_space_from_ps2(config.wheel_local_positions_ps2[index])
		wheels[slot_id] = {
			"slot_id": slot_id,
			"position": wheel_center + Vector3.UP * rest_length,
			"wheel_center_rest": wheel_center,
			"wheel_radius": float(config.wheel_radii[index]),
			"wheel_rest_length": rest_length,
			"static_ride_height": static_ride_height,
			"suspension_travel": suspension_travel,
			"suspension_stiffness": _spring_for_axle(config, is_front),
			"damping_compression": _damping_compression_for_axle(config, is_front),
			"damping_relaxation": _damping_relaxation_for_axle(config, is_front),
			"suspension_max_force": _suspension_max_force_for_axle(axle_masses, is_front),
			"wheel_friction_slip": _friction_slip_for_axle(config, is_front),
			"wheel_roll_influence": _roll_influence_for_axle(config, is_front),
			"base_wheel_friction_slip": _friction_slip_for_axle(config, is_front),
			"use_as_steering": is_front,
			"use_as_traction": config.drive_bias_for_slot(slot_id) > 0.0,
			"axle": "front" if is_front else "rear",
			"side": "left" if slot_id.ends_with("L") else "right",
		}

	return {
		"mass": resolved_mass,
		"mass_is_estimate": bool(config.mass_kg_is_estimate),
		"center_of_mass": vehicle_space_from_ps2(config.center_of_mass_ps2),
		"body_size": body_size_vehicle(config),
		"body_transform_diagonal": config.body_transform_diagonal,
		"collision_center": Vector3(0.0, body_size_vehicle(config).y * 0.5, 0.0),
		"visual_anchor_basis": visual_anchor_basis(),
		"wheels": wheels,
		"driven_wheel_count": driven_wheel_count,
		"driven_average_radius": config.driven_average_radius(),
		"hp2_idle_launch_force_total": hp2_idle_launch_force_total,
		"hp2_launch_force_total": hp2_launch_force_total,
		"hp2_launch_accel_reference": hp2_launch_accel_reference,
		"godot_launch_force_total": godot_launch_force_total,
		"engine_force_normalization_gain": engine_force_normalization_gain,
		"low_speed_torque_boost": LOW_SPEED_TORQUE_BOOST,
		"low_speed_torque_fade_kph": LOW_SPEED_TORQUE_FADE_KPH,
		"service_brake_total": maxf(config.brake_force * brake_force_normalization_gain, 12.0),
		"handbrake_total": maxf(config.handbrake_force * brake_force_normalization_gain, handbrake_force_total),
		"brake_force_normalization_gain": brake_force_normalization_gain,
		"engine_brake_gain": ENGINE_BRAKE_GAIN,
		"coast_drag_gain": COAST_DRAG_GAIN,
		"brake_lock_entry": BRAKE_LOCK_ENTRY,
		"rear_brake_lock_slip_scale": BRAKE_LOCK_REAR_SLIP_SCALE,
		"handbrake_rear_slip_scale": HANDBRAKE_REAR_SLIP_SCALE,
		"front_brake_slip_scale": FRONT_BRAKE_SLIP_SCALE,
		"rolling_resistance": _godot_rolling_resistance(config),
		"aero_drag": _godot_aero_drag(config),
	}


static func _spring_for_axle(config, is_front: bool) -> float:
	return float(config.front_spring_coefficient if is_front else config.rear_spring_coefficient)


static func _damping_compression_for_axle(config, is_front: bool) -> float:
	var bump: float = config.front_bump_damping if is_front else config.rear_bump_damping
	return clampf(bump * 0.06, 0.2, 0.8)


static func _damping_relaxation_for_axle(config, is_front: bool) -> float:
	var rebound: float = config.front_rebound_damping if is_front else config.rear_rebound_damping
	var compression := _damping_compression_for_axle(config, is_front)
	return clampf(maxf(rebound * 0.09, compression + 0.05), 0.3, 1.0)


static func _friction_slip_for_axle(config, is_front: bool) -> float:
	var lateral: float = config.front_lateral_grip if is_front else config.rear_lateral_grip
	var longitudinal: float = config.front_longitudinal_grip if is_front else config.rear_longitudinal_grip
	var hp2_grip := (lateral + longitudinal) * 0.5
	var grip_alpha := inverse_lerp(0.95, 1.25, hp2_grip)
	return clampf(lerpf(GODOT_FRICTION_SLIP_MIN, GODOT_FRICTION_SLIP_MAX, grip_alpha), 7.5, 13.5)


static func _roll_influence_for_axle(config, is_front: bool) -> float:
	var anti_roll: float = config.front_anti_roll_coefficient if is_front else config.rear_anti_roll_coefficient
	return clampf(anti_roll / 40.0, 0.25, 0.9)


static func _suspension_travel_for_axle(config, is_front: bool) -> float:
	var min_compression: float = config.front_min_compression if is_front else config.rear_min_compression
	var max_compression: float = config.front_max_compression if is_front else config.rear_max_compression
	return clampf(absf(max_compression - min_compression), SAFE_SUSPENSION_TRAVEL_MIN, SAFE_SUSPENSION_TRAVEL_MAX)


static func _rest_length_for_axle(config, is_front: bool) -> float:
	var min_compression: float = config.front_min_compression if is_front else config.rear_min_compression
	return clampf(absf(min_compression), SAFE_REST_LENGTH_MIN, SAFE_REST_LENGTH_MAX)


static func _static_ride_height_for_axle(config, is_front: bool) -> float:
	var min_compression: float = config.front_min_compression if is_front else config.rear_min_compression
	var max_compression: float = config.front_max_compression if is_front else config.rear_max_compression
	# HP2 does not derive a baked "static ride height" from the 0x1A0 axle block.
	# The wheel runtime solves current length from terrain projection, then clamps it
	# with 0x244/0x248 and applies preload via FUN_001375f0 -> FUN_001a5f88.
	# At rest the spring/preload equilibrium is centered on the neutral length, so the
	# Godot-side visual bias should stay at 0 and let the live contact solve move it.
	return clampf(0.0, min_compression, max_compression)


static func _axle_load_fraction(config, is_front: bool) -> float:
	var load_origin_x: float = config.physics_origin_offset_ps2.x
	if absf(load_origin_x) <= 0.0001:
		load_origin_x = config.center_of_mass_ps2.x
	var front_x: float = config.front_axle_center_x() - load_origin_x
	var rear_x: float = config.rear_axle_center_x() - load_origin_x
	var denom: float = front_x - rear_x
	if absf(denom) <= 0.0001:
		return 0.5
	var rear_each_fraction: float = (front_x / denom) * 0.5
	var front_each_fraction: float = 0.5 - rear_each_fraction
	var front_total := clampf(front_each_fraction * 2.0, 0.0, 1.0)
	if is_front:
		return front_total
	return 1.0 - front_total


static func _suspension_max_force_for_axle(axle_masses: Dictionary, is_front: bool) -> float:
	var axle_mass: float = axle_masses.get("front", 0.0) if is_front else axle_masses.get("rear", 0.0)
	return maxf((axle_mass * 9.8) * 3.5 / 2.0, 3000.0)


static func _axle_supported_masses(config) -> Dictionary:
	var load_origin_x: float = config.physics_origin_offset_ps2.x
	if absf(load_origin_x) <= 0.0001:
		load_origin_x = config.center_of_mass_ps2.x
	var front_x: float = config.front_axle_center_x() - load_origin_x
	var rear_x: float = config.rear_axle_center_x() - load_origin_x
	var denom: float = front_x - rear_x
	var total_mass := physics_mass_kg(config)
	if absf(denom) <= 0.0001:
		return {
			"front": total_mass * 0.5,
			"rear": total_mass * 0.5,
		}
	var rear_each_fraction: float = (front_x / denom) * 0.5
	var front_each_fraction: float = 0.5 - rear_each_fraction
	return {
		"front": total_mass * front_each_fraction * 2.0,
		"rear": total_mass * rear_each_fraction * 2.0,
	}


static func _driven_wheel_count(config) -> int:
	var count := 0
	for slot_id in SLOT_IDS:
		if config.drive_bias_for_slot(slot_id) > 0.0:
			count += 1
	return maxi(count, 1)


static func _hp2_drive_force_total(config, speed_mps: float, rpm: float, gear: int) -> float:
	var gear_ratio := absf(config.get_gear_ratio(gear) * config.final_drive_ratio)
	return config.sample_engine_force(speed_mps, rpm) * gear_ratio


static func _godot_rolling_resistance(config) -> float:
	return clampf(config.rolling_resistance * GODOT_ROLLING_RESISTANCE_SCALE, GODOT_ROLLING_RESISTANCE_MIN, GODOT_ROLLING_RESISTANCE_MAX)


static func _godot_aero_drag(config) -> float:
	return maxf(config.aero_drag * GODOT_AERO_DRAG_SCALE, 0.0)


static func physics_mass_kg(config) -> float:
	return maxf(config.mass_kg, 1.0)
