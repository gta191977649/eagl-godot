class_name HP2CarRuntime
extends RefCounted

const HP2VehicleConfigScript = preload("res://eagl/assets/car/physics/hp2_vehicle_config.gd")
const HP2InputStateScript = preload("res://eagl/assets/car/physics/hp2_input_state.gd")
const HP2EngineScript = preload("res://eagl/assets/car/physics/hp2_engine.gd")
const HP2DriveTrainScript = preload("res://eagl/assets/car/physics/hp2_drivetrain.gd")
const HP2AckermannSteeringScript = preload("res://eagl/assets/car/physics/hp2_ackermann_steering.gd")
const HP2SuspensionScript = preload("res://eagl/assets/car/physics/hp2_suspension.gd")
const HP2WheelScript = preload("res://eagl/assets/car/physics/hp2_wheel.gd")
const HP2PhysicsIntegratorScript = preload("res://eagl/assets/car/physics/hp2_physics_integrator.gd")
const HP2VisualWheelRigScript = preload("res://eagl/assets/car/physics/hp2_visual_wheel_rig.gd")

var config = HP2VehicleConfigScript.new()
var input_state = HP2InputStateScript.new()
var engine = HP2EngineScript.new()
var drivetrain = HP2DriveTrainScript.new()
var steering = HP2AckermannSteeringScript.new()
var suspension = HP2SuspensionScript.new()
var wheel = HP2WheelScript.new()
var integrator = HP2PhysicsIntegratorScript.new()
var visual_wheel_rig = HP2VisualWheelRigScript.new()


func configure(owner) -> void:
	config.configure(owner.tuning, owner.handling_data)


func ready(owner) -> void:
	configure(owner)
	visual_wheel_rig.cache(owner)
	steering.init_wheel_states(owner, config)


func reset_motion(owner) -> void:
	configure(owner)
	owner.velocity = Vector3.ZERO
	owner.yaw_rate = 0.0
	owner.angular_velocity = Vector3.ZERO
	owner.steer = 0.0
	owner.steering_angle = 0.0
	owner.throttle = 0.0
	owner.brake = 0.0
	owner.handbrake = false
	drivetrain.reset(owner)
	engine.reset(owner, config)
	owner.grounded = false
	owner.movement_mode = "coast"
	owner.local_longitudinal_speed = 0.0
	owner.local_lateral_speed = 0.0
	owner.slip = 0.0
	owner.wheel_angular_speed = 0.0
	owner.last_drive_force = 0.0
	owner.last_brake_force = 0.0
	owner.last_lateral_force = 0.0
	owner.last_drag_force = 0.0
	owner.last_normal_force = 0.0
	owner.last_aero_force = 0.0
	owner.last_rolling_force = 0.0
	owner.last_suspension_force = 0.0
	owner.last_engine_torque = 0.0
	owner.last_wheel_torque = 0.0
	owner.last_engine_brake_force = 0.0
	owner.last_gear_ratio = 0.0
	owner.last_torque_curve = 0.0
	input_state.reset()
	steering.init_wheel_states(owner, config)


func physics_process(owner, delta: float) -> void:
	configure(owner)
	if visual_wheel_rig.visual_root == null:
		visual_wheel_rig.cache(owner)
	if owner.wheel_states.is_empty():
		steering.init_wheel_states(owner, config)
	input_state.read(owner, delta, config)
	var body = owner.get_parent() as Node3D
	if body == null:
		return
	if owner.debug_free_drive:
		integrator.integrate_free_drive_body(owner, self, body, delta)
	else:
		integrator.integrate_hp2_body(owner, self, body, delta)
	visual_wheel_rig.update(owner, config, steering, delta)


func debug_state(owner) -> Dictionary:
	configure(owner)
	steering.update(owner, config)
	var next_shift_rpm = drivetrain.gear_shift_up_rpm(owner.current_gear, config, engine)
	if not is_finite(next_shift_rpm):
		next_shift_rpm = 0.0
	var next_shift_speed = drivetrain.speed_from_rpm(next_shift_rpm, owner.current_gear, config) if next_shift_rpm > 0.0 else INF
	var state = {
		"speed_mps": owner.velocity.length(),
		"speed_kmh": owner.velocity.length() * 3.6,
		"longitudinal_speed": owner.local_longitudinal_speed,
		"lateral_speed": owner.local_lateral_speed,
		"yaw_rate": owner.yaw_rate,
		"steer": owner.steer,
		"steering_angle": owner.steering_angle,
		"throttle": owner.throttle,
		"filtered_throttle": owner.filtered_throttle,
		"brake": owner.brake,
		"filtered_reverse_throttle": owner.filtered_reverse_throttle,
		"handbrake": owner.handbrake,
		"engine_rpm": owner.engine_rpm,
		"engine_idle_rpm": config.engine_idle_rpm(),
		"engine_peak_rpm": config.engine_peak_rpm(),
		"engine_redline_rpm": config.engine_redline_rpm(),
		"gear": owner.current_gear,
		"gear_label": "R" if owner.current_gear < 0 else str(owner.current_gear),
		"gear_count": config.gear_count(),
		"gear_ratio": owner.last_gear_ratio,
		"final_drive_ratio": config.final_drive_ratio(),
		"shift_up_rpm": next_shift_rpm,
		"shift_up_speed": next_shift_speed,
		"shift_down_speed": drivetrain.gear_downshift_speed(owner.current_gear - 1, config.gear_count(), config),
		"clutch_engagement": owner.clutch_engagement,
		"shift_timer": owner.shift_timer,
		"drivetrain_mode": owner.drivetrain_mode,
		"torque_curve": owner.last_torque_curve,
		"engine_torque": owner.last_engine_torque,
		"wheel_torque": owner.last_wheel_torque,
		"engine_brake_force": owner.last_engine_brake_force,
		"grounded": owner.grounded,
		"movement_mode": owner.movement_mode,
		"slip": owner.slip,
		"wheel_angular_speed": owner.wheel_angular_speed,
		"spin_pivot_count": visual_wheel_rig.spin_pivots.size(),
		"steer_pivot_count": visual_wheel_rig.steer_pivots.size(),
		"drive_force": owner.last_drive_force,
		"brake_force": owner.last_brake_force,
		"lateral_force": owner.last_lateral_force,
		"drag_force": owner.last_drag_force,
		"normal_force": owner.last_normal_force,
		"aero_force": owner.last_aero_force,
		"rolling_force": owner.last_rolling_force,
		"suspension_force": owner.last_suspension_force,
		"debug_free_drive": owner.debug_free_drive,
		"debug_free_drive_boost": input_state.free_drive_boost,
		"debug_free_drive_input": input_state.free_drive_input,
		"handling_source": config.handling_data.get("handling_source", config.tuning.get("source", "unknown")),
		"exact_handling_status": config.handling_data.get("exact_handling_status", config.tuning.get("exact_handling_status", "unknown")),
		"decoded_car_id": config.handling_data.get("car_id", config.tuning.get("car_id", "")),
		"tuning_source": config.tuning.get("source", "unknown"),
		"tuning_status": config.tuning.get("status", "unknown"),
		"globalb_row_index": config.handling_data.get("globalb_row_index", config.tuning.get("globalb_row_index", -1)),
		"wheel_states": owner.wheel_states.duplicate(true),
		"ackermann": {
			"FL": owner.wheel_states.get("FL", {}).get("steering_angle", 0.0),
			"FR": owner.wheel_states.get("FR", {}).get("steering_angle", 0.0),
			"RL": owner.wheel_states.get("RL", {}).get("steering_angle", 0.0),
			"RR": owner.wheel_states.get("RR", {}).get("steering_angle", 0.0),
		},
	}
	state["input"] = {
		"raw_throttle": owner.throttle,
		"raw_brake": owner.brake,
		"raw_steer": owner.steer,
		"handbrake": owner.handbrake,
		"filtered_throttle": owner.filtered_throttle,
		"filtered_reverse_throttle": owner.filtered_reverse_throttle,
	}
	state["engine"] = {
		"rpm": owner.engine_rpm,
		"idle_rpm": config.engine_idle_rpm(),
		"peak_rpm": config.engine_peak_rpm(),
		"redline_rpm": config.engine_redline_rpm(),
		"torque_curve": owner.last_torque_curve,
	}
	state["drivetrain"] = {
		"gear": owner.current_gear,
		"gear_ratio": owner.last_gear_ratio,
		"final_drive_ratio": config.final_drive_ratio(),
		"mode": owner.drivetrain_mode,
		"clutch_engagement": owner.clutch_engagement,
		"shift_timer": owner.shift_timer,
	}
	state["wheels"] = owner.wheel_states.duplicate(true)
	state["suspension"] = _suspension_debug(owner)
	state["integrator"] = {
		"substep_count": integrator.last_substep_count,
		"substep_delta": integrator.last_substep_delta,
		"model": "hp2_custom_euler_substep",
	}
	state["reverse_confidence"] = {
		"ground_truth": "Ghidra offsets and update boundaries",
		"force_formulas": config.handling_data.get("source_confidence", {}).get("force_formulas", "inferred"),
	}
	return state


func _suspension_debug(owner) -> Dictionary:
	var out = {}
	for slot_id in ["FL", "FR", "RL", "RR"]:
		var wheel_state: Dictionary = owner.wheel_states.get(slot_id, {})
		out[slot_id] = {
			"grounded": wheel_state.get("grounded", false),
			"compression": wheel_state.get("compression", 0.0),
			"normal_force": wheel_state.get("normal_force", 0.0),
			"spring_force": wheel_state.get("spring_force", 0.0),
			"damper_force": wheel_state.get("damper_force", 0.0),
		}
	return out
