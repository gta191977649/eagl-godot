# Legacy reverse-engineered HP2 controller kept for reference only.
# Runtime use has been replaced by the VehicleBody3D-based entity in
# res://eagl/entity/Car.tscn.
class_name CarController
extends RigidBody3D

const CarConfigScript = preload("res://eagl/handling/car_config.gd")
const RoadSurfaceSamplerScript = preload("res://eagl/handling/road_surface_sampler.gd")
const WheelStateScript = preload("res://eagl/handling/wheel_state.gd")
const MathUtils = preload("res://eagl/utils/math_utils.gd")

const SUBSTEP_TARGET_DT = 0.0044
const GRAVITY_MPS2 = 9.8
const REST_SETTLE_LINEAR_SPEED = 0.12
const REST_SETTLE_ANGULAR_SPEED = 0.12
const REST_SETTLE_TRAVEL_SPEED = 0.02
const REST_SETTLE_LINEAR_DAMP = 4.0
const REST_SETTLE_ANGULAR_DAMP = 6.0
const REST_FREEZE_LINEAR_SPEED = 0.03
const REST_FREEZE_ANGULAR_SPEED = 0.03
const GROUNDED_HEAVE_DAMPING = 6.0
const GROUNDED_PITCH_DAMPING = 950.0
const GROUNDED_ROLL_DAMPING = 950.0

@export var config = null
@export var auto_build_visuals = true
@export var draw_debug = true
@export var debug_normal_length = 0.45
@export var debug_axis_length = 0.65

var surface_sampler = null
var wheels: Array = []
var current_gear = 1
var engine_rpm = 900.0
var signed_slip_angle = 0.0

var _throttle_input = 0.0
var _brake_input = 0.0
var _steering_input = 0.0
var _handbrake_input = 0.0
var _steering_state = 0.0
var _steering_engaged = false
var _debug_snapshot = {}

var _visual_root: Node3D
var _body_visual: MeshInstance3D
var _wheel_visuals = {}
var _wheel_roll_visuals = {}
var _wheel_suspension_nodes = {}
var _debug_pivot_nodes = {}
var _debug_dummy_nodes = {}
var _debug_mesh_instance: MeshInstance3D
var _debug_mesh = ImmediateMesh.new()
var _debug_material: StandardMaterial3D


func _ready() -> void:
	if config == null:
		config = CarConfigScript.new()

	custom_integrator = true
	gravity_scale = 0.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	apply_config(config)


func _process(_delta: float) -> void:
	_update_inputs()
	_update_visuals()
	if draw_debug:
		_rebuild_debug_mesh()
	_update_debug_snapshot()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if config == null or wheels.is_empty():
		return

	var step = state.step
	var substeps = int(floor(step / SUBSTEP_TARGET_DT)) + 1
	var sub_dt = step / float(substeps)
	for _substep in range(substeps):
		_step_vehicle(state, sub_dt)


func set_surface_sampler(sampler) -> void:
	surface_sampler = sampler


func apply_config(new_config) -> void:
	if new_config == null:
		return
	config = new_config
	mass = config.mass_kg
	center_of_mass = _ps2_to_godot(config.center_of_mass_ps2)
	engine_rpm = maxf(config.idle_rpm, 900.0)
	current_gear = 1
	signed_slip_angle = 0.0
	_steering_state = 0.0
	_steering_engaged = false
	wheels = config.build_wheel_states()
	_fit_chassis_collision_shape()
	refresh_visual_bindings()
	if auto_build_visuals and _wheel_visuals.is_empty():
		_ensure_generated_visuals()
		refresh_visual_bindings()
	_prime_wheels_from_current_transform()
	set_debug_overlay_enabled(draw_debug)
	_update_visuals()
	_update_debug_snapshot()


func reset_runtime_state(target_transform: Transform3D = transform) -> void:
	transform = target_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	sleeping = false
	current_gear = 1
	engine_rpm = maxf(config.idle_rpm, 900.0)
	signed_slip_angle = 0.0
	_throttle_input = 0.0
	_brake_input = 0.0
	_steering_input = 0.0
	_handbrake_input = 0.0
	_steering_state = 0.0
	_steering_engaged = false
	for wheel in wheels:
		wheel.reset_runtime()
	_prime_wheels_from_current_transform()
	_update_visuals()
	if draw_debug:
		_rebuild_debug_mesh()
	_update_debug_snapshot()


func set_debug_overlay_enabled(enabled: bool) -> void:
	draw_debug = enabled
	if draw_debug:
		_ensure_debug_mesh()
		_debug_mesh_instance.visible = true
		_rebuild_debug_mesh()
	elif _debug_mesh_instance != null:
		_debug_mesh.clear_surfaces()
		_debug_mesh_instance.visible = false


func refresh_visual_bindings() -> void:
	_wheel_visuals.clear()
	_wheel_roll_visuals.clear()
	_wheel_suspension_nodes.clear()
	_debug_pivot_nodes.clear()
	_debug_dummy_nodes.clear()
	_visual_root = null
	_body_visual = null
	var visual_root := get_node_or_null("CarVisual") as Node3D
	if visual_root == null:
		return
	_visual_root = visual_root
	for slot_id in ["FL", "FR", "RL", "RR"]:
		var pivot_node := visual_root.get_node_or_null("WheelPivots/%s" % slot_id)
		if pivot_node != null:
			_debug_pivot_nodes[slot_id] = pivot_node
		var suspension_node := visual_root.get_node_or_null("WheelPivots/%s/Suspension" % slot_id)
		if suspension_node != null:
			_wheel_suspension_nodes[slot_id] = suspension_node
			var steer_node := visual_root.get_node_or_null("WheelPivots/%s/Suspension/Steer" % slot_id)
			if steer_node != null:
				_wheel_visuals[slot_id] = steer_node
			var roll_node := visual_root.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll/Spin" % slot_id)
			if roll_node == null:
				roll_node = visual_root.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll" % slot_id)
			if roll_node != null:
				_wheel_roll_visuals[slot_id] = roll_node
	var dummies_root := visual_root.get_node_or_null("Dummies")
	if dummies_root != null:
		for child in dummies_root.get_children():
			if child is Node3D:
				_debug_dummy_nodes[String(child.name)] = child
	_fit_collision_shape_to_visual_bounds()


func get_debug_snapshot() -> Dictionary:
	return _debug_snapshot.duplicate(true)


func _step_vehicle(state: PhysicsDirectBodyState3D, sub_dt: float) -> void:
	var transform = state.transform
	var body_origin_ps2 = _godot_to_ps2(transform.origin)
	var body_up_ps2 = _basis_axis_ps2(transform.basis, Vector3(0.0, 0.0, 1.0))
	var body_forward_ps2 = _basis_axis_ps2(transform.basis, Vector3(1.0, 0.0, 0.0))
	var body_right_ps2 = _basis_axis_ps2(transform.basis, Vector3(0.0, 1.0, 0.0))
	var linear_velocity_ps2 = _godot_to_ps2(state.linear_velocity)
	var flat_velocity_ps2 = _horizontal_ps2(linear_velocity_ps2)
	var speed_mps = flat_velocity_ps2.length()

	state.apply_impulse(Vector3.DOWN * config.mass_kg * GRAVITY_MPS2 * sub_dt)
	_update_steering_state(speed_mps, sub_dt)
	_update_body_slip(body_forward_ps2, body_up_ps2, flat_velocity_ps2)

	var driven_angular_speed = 0.0
	var driven_count = 0

	for wheel in wheels:
		_step_suspension_for_wheel(state, wheel, transform, body_up_ps2, body_origin_ps2, sub_dt)
		if wheel.grounded and config.drive_bias_for_slot(wheel.slot_id) > 0.0:
			driven_angular_speed += wheel.forward_speed / maxf(wheel.wheel_radius, 0.01)
			driven_count += 1

	if driven_count > 0:
		driven_angular_speed /= float(driven_count)
	engine_rpm = _compute_rpm(speed_mps, driven_angular_speed, sub_dt)
	_update_gear()

	var engine_force_total = config.sample_engine_force(speed_mps, engine_rpm) * _throttle_input * config.get_gear_ratio(current_gear) * config.final_drive_ratio

	for wheel in wheels:
		if not wheel.grounded:
			continue
		var drive_bias = config.drive_bias_for_slot(wheel.slot_id)
		var wheel_heading_ps2 = _wheel_heading_ps2(transform.basis, body_up_ps2, wheel)
		if wheel_heading_ps2.length_squared() <= 0.0001:
			wheel_heading_ps2 = body_forward_ps2

		var drive_force = engine_force_total * drive_bias
		var brake_force = config.brake_force * _brake_input
		if wheel.is_rear():
			brake_force += config.handbrake_force * _handbrake_input

		var drive_force_ps2 = wheel_heading_ps2 * drive_force
		var braking_direction = -signf(_safe_speed_sign(wheel.forward_speed, speed_mps)) * wheel_heading_ps2
		var brake_force_ps2 = braking_direction * brake_force
		var lateral_force_ps2 = _lateral_force_for_wheel(wheel, sub_dt)
		var longitudinal_force_ps2 = _longitudinal_limit_force(wheel, drive_force_ps2 + brake_force_ps2)

		_apply_impulse_ps2(state, lateral_force_ps2 * sub_dt, wheel.contact_point_ps2)
		_apply_impulse_ps2(state, longitudinal_force_ps2 * sub_dt, wheel.contact_point_ps2)

	var drag_force_ps2 = _drag_force_ps2(flat_velocity_ps2, speed_mps)
	_apply_impulse_ps2(state, drag_force_ps2 * sub_dt, body_origin_ps2)
	_apply_grounded_chassis_damping(state, body_origin_ps2, body_up_ps2, body_forward_ps2, body_right_ps2, sub_dt)
	_apply_torque_impulse_ps2(state, _yaw_assist_torque_ps2(body_up_ps2, state, speed_mps) * sub_dt)
	_apply_rest_settle(state, sub_dt)


func _step_suspension_for_wheel(
	state: PhysicsDirectBodyState3D,
	wheel,
	transform: Transform3D,
	body_up_ps2: Vector3,
	body_origin_ps2: Vector3,
	sub_dt: float
) -> void:
	var pivot_local_ps2: Vector3 = wheel.pivot_local_position_ps2
	var sample_local_ps2: Vector3 = wheel.local_position_ps2
	var pivot_world_ps2 = _transform_point_ps2(transform, pivot_local_ps2)
	var sample_world_ps2 = _transform_point_ps2(transform, sample_local_ps2)
	var wheel_contact_query_ps2 = sample_world_ps2
	var length_min := minf(wheel.min_travel, wheel.max_travel)
	var length_max := maxf(wheel.min_travel, wheel.max_travel)
	var travel_range := maxf(length_max - length_min, 0.0001)
	var previous_length := clampf(wheel.previous_length, length_min, length_max)

	wheel.world_pivot_ps2 = pivot_world_ps2
	wheel.world_attachment_ps2 = sample_world_ps2
	wheel.prev_compression = wheel.compression
	wheel.grounded = false
	wheel.material_id = -1
	wheel.normal_ps2 = Vector3(0.0, 0.0, 1.0)
	wheel.contact_point_ps2 = sample_world_ps2
	wheel.world_wheel_center_ps2 = sample_world_ps2
	wheel.overtravel = 0.0
	wheel.over_limit = 0.0
	wheel.suspension_force = 0.0

	var wheel_velocity_ps2 = _godot_to_ps2(state.get_velocity_at_local_position(_ps2_to_godot(pivot_local_ps2)))
	var wheel_heading_ps2 = _wheel_heading_ps2(transform.basis, body_up_ps2, wheel)
	var wheel_right_ps2 = _wheel_right_axis_ps2(transform.basis, wheel)
	wheel.forward_speed = wheel_velocity_ps2.dot(wheel_heading_ps2)
	wheel.lateral_speed = wheel_velocity_ps2.dot(wheel_right_ps2)
	wheel.angular_speed = wheel.forward_speed / maxf(wheel.wheel_radius, 0.01)
	wheel.roll_angle += wheel.angular_speed * sub_dt

	if surface_sampler == null:
		wheel.current_length = previous_length
		wheel.travel_velocity = 0.0
		wheel.compression_velocity = 0.0
		wheel.suspension_distance = previous_length
		wheel.center_offset = previous_length
		return

	var surface: Dictionary = surface_sampler.sample_surface(wheel_contact_query_ps2)
	if surface.is_empty():
		wheel.compression = 0.0
		wheel.current_length = previous_length
		wheel.previous_length = previous_length
		wheel.travel_velocity = 0.0
		wheel.compression_velocity = 0.0
		wheel.suspension_distance = previous_length
		wheel.center_offset = previous_length
		wheel.world_wheel_center_ps2 = sample_world_ps2 + body_up_ps2 * previous_length
		return

	var suspension_axis_ps2 = body_up_ps2
	var surface_normal: Vector3 = surface["normal"]
	var surface_point: Vector3 = surface["point"]
	var denom = surface_normal.dot(suspension_axis_ps2)
	if absf(denom) <= 0.0001:
		wheel.compression = 0.0
		wheel.current_length = previous_length
		wheel.previous_length = previous_length
		wheel.travel_velocity = 0.0
		wheel.compression_velocity = 0.0
		wheel.suspension_distance = previous_length
		wheel.center_offset = previous_length
		wheel.world_wheel_center_ps2 = sample_world_ps2 + body_up_ps2 * previous_length
		return

	var t = surface_normal.dot(surface_point - sample_world_ps2) / denom
	var raw_length = t + wheel.wheel_radius
	var clamped_length = clampf(raw_length, length_min, length_max)
	var compression_length = clampf(clamped_length - length_min, 0.0, travel_range)
	var travel_velocity = (clamped_length - previous_length) / maxf(sub_dt, 0.0001)
	wheel.compression = compression_length / travel_range
	wheel.current_length = clamped_length
	wheel.travel_velocity = travel_velocity
	wheel.compression_velocity = travel_velocity
	wheel.grounded = raw_length >= length_min
	wheel.material_id = int(surface.get("material_id", -1))
	wheel.normal_ps2 = surface_normal
	wheel.suspension_distance = raw_length
	wheel.over_limit = maxf(raw_length - length_max, 0.0)
	wheel.overtravel = wheel.over_limit
	wheel.contact_point_ps2 = sample_world_ps2 + suspension_axis_ps2 * t
	wheel.center_offset = clamped_length
	wheel.world_wheel_center_ps2 = sample_world_ps2 + suspension_axis_ps2 * clamped_length

	if not wheel.grounded:
		wheel.suspension_force = 0.0
		wheel.previous_length = clamped_length
		return

	var spring_progress = maxf(clamped_length, 0.0)
	var spring_force = clamped_length * wheel.spring_coefficient * (1.0 + wheel.progressive_spring_scale * spring_progress)
	var damping = wheel.rebound_damping if travel_velocity > 0.0 else wheel.bump_damping
	var damper_force = damping * travel_velocity
	var anti_roll_force = 0.0
	var pair = _paired_axle_wheel(wheel)
	if pair != null:
		anti_roll_force = wheel.anti_roll_coefficient * (clamped_length - pair.current_length)
	var overtravel_force = wheel.bump_stop_coefficient * wheel.over_limit

	wheel.suspension_force = maxf(wheel.preload_force + spring_force + damper_force + anti_roll_force + overtravel_force, 0.0)
	wheel.load_ratio = wheel.suspension_force / maxf(wheel.preload_force, 1.0)
	_apply_impulse_ps2(state, body_up_ps2 * wheel.suspension_force * sub_dt, pivot_world_ps2)
	wheel.previous_length = clamped_length


func _compute_rpm(speed_mps: float, driven_angular_speed: float, sub_dt: float) -> float:
	var drivetrain_ratio = absf(config.get_gear_ratio(current_gear) * config.final_drive_ratio)
	var wheel_rpm = absf(driven_angular_speed) * 60.0 / TAU
	var target_rpm = clampf(wheel_rpm * drivetrain_ratio, config.idle_rpm, config.engine_redline_rpm)
	if absf(driven_angular_speed) <= 0.01:
		var free_rev_target = lerpf(config.idle_rpm, config.engine_redline_rpm, clampf(_throttle_input, 0.0, 1.0))
		target_rpm = maxf(target_rpm, free_rev_target * (0.45 + clampf(speed_mps / 30.0, 0.0, 0.55)))
	return move_toward(engine_rpm, target_rpm, maxf(config.engine_redline_rpm, 1000.0) * sub_dt)


func _update_gear() -> void:
	if current_gear < config.top_gear() and engine_rpm > config.shift_up_rpm:
		current_gear += 1
	elif current_gear > 1 and engine_rpm < config.shift_down_rpm:
		current_gear -= 1


func _update_steering_state(speed_mps: float, sub_dt: float) -> void:
	var speed_kph = speed_mps * 3.6
	var speed_alpha = clampf(speed_kph / maxf(config.high_speed_steer_kph, 1.0), 0.0, 1.0)
	var speed_scale = lerpf(config.low_speed_steer_scale, config.high_speed_steer_scale, speed_alpha)

	if not _steering_engaged and absf(_steering_input) >= config.steering_hysteresis_enter:
		_steering_engaged = true
	elif _steering_engaged and absf(_steering_input) <= config.steering_hysteresis_exit:
		_steering_engaged = false

	var engaged_scale = 1.0 if _steering_engaged else 0.7
	var target_angle = deg_to_rad(config.steering_max_degrees * config.steering_lock_scale) * _steering_input * speed_scale * engaged_scale
	var response = config.steering_response if absf(_steering_input) > 0.01 else config.steering_return
	_steering_state = move_toward(_steering_state, target_angle, response * sub_dt)


func _update_body_slip(body_forward_ps2: Vector3, body_up_ps2: Vector3, flat_velocity_ps2: Vector3) -> void:
	if flat_velocity_ps2.length() < 0.25:
		signed_slip_angle = 0.0
		return
	signed_slip_angle = _signed_angle_on_axis(body_forward_ps2, flat_velocity_ps2.normalized(), body_up_ps2)


func _lateral_force_for_wheel(wheel, sub_dt: float) -> Vector3:
	var slip_abs = absf(rad_to_deg(signed_slip_angle))
	var reduction_range = maxf(config.slip_grip_reduction_end_deg - config.slip_grip_reduction_start_deg, 0.001)
	var reduction_alpha = clampf((slip_abs - config.slip_grip_reduction_start_deg) / reduction_range, 0.0, 1.0)
	var grip_scale = lerpf(1.0, config.drift_grip_scale, reduction_alpha)
	var desired_force = -wheel.lateral_speed * wheel.lateral_grip * config.mass_kg * 0.25 / maxf(sub_dt, 0.0001)
	var max_force = wheel.suspension_force * wheel.lateral_grip * grip_scale
	var force_magnitude = clampf(desired_force, -max_force, max_force)
	return _wheel_right_axis_ps2(global_transform.basis, wheel) * force_magnitude


func _longitudinal_limit_force(wheel, requested_force_ps2: Vector3) -> Vector3:
	var max_force = wheel.suspension_force * wheel.longitudinal_grip
	if requested_force_ps2.length() <= max_force:
		return requested_force_ps2
	return requested_force_ps2.normalized() * max_force


func _drag_force_ps2(flat_velocity_ps2: Vector3, speed_mps: float) -> Vector3:
	if speed_mps <= 0.001:
		return Vector3.ZERO
	var rolling_force = flat_velocity_ps2.normalized() * -config.rolling_resistance * config.mass_kg * GRAVITY_MPS2
	var aero_force = flat_velocity_ps2.normalized() * -config.aero_drag * speed_mps * speed_mps * config.mass_kg
	return rolling_force + aero_force


func _apply_rest_settle(state: PhysicsDirectBodyState3D, sub_dt: float) -> void:
	if not _can_rest_settle(state):
		return
	state.linear_velocity = state.linear_velocity.move_toward(Vector3.ZERO, REST_SETTLE_LINEAR_DAMP * sub_dt)
	state.angular_velocity = state.angular_velocity.move_toward(Vector3.ZERO, REST_SETTLE_ANGULAR_DAMP * sub_dt)
	if state.linear_velocity.length() <= REST_FREEZE_LINEAR_SPEED:
		state.linear_velocity = Vector3.ZERO
	if state.angular_velocity.length() <= REST_FREEZE_ANGULAR_SPEED:
		state.angular_velocity = Vector3.ZERO
	for wheel in wheels:
		if absf(wheel.travel_velocity) > REST_SETTLE_TRAVEL_SPEED:
			continue
		wheel.travel_velocity = 0.0
		wheel.compression_velocity = 0.0
		wheel.previous_length = wheel.current_length


func _apply_grounded_chassis_damping(
	state: PhysicsDirectBodyState3D,
	body_origin_ps2: Vector3,
	body_up_ps2: Vector3,
	body_forward_ps2: Vector3,
	body_right_ps2: Vector3,
	sub_dt: float
) -> void:
	var grounded_count := 0
	for wheel in wheels:
		if wheel.grounded:
			grounded_count += 1
	if grounded_count == 0:
		return
	var grounded_alpha := float(grounded_count) / float(wheels.size())
	var linear_velocity_ps2 := _godot_to_ps2(state.linear_velocity)
	var vertical_speed := linear_velocity_ps2.dot(body_up_ps2)
	var heave_force_ps2: Vector3 = body_up_ps2 * (-vertical_speed * config.mass_kg * GROUNDED_HEAVE_DAMPING * grounded_alpha)
	_apply_impulse_ps2(state, heave_force_ps2 * sub_dt, body_origin_ps2)
	var angular_velocity_ps2 := _godot_to_ps2(state.angular_velocity)
	var pitch_rate := angular_velocity_ps2.dot(body_right_ps2)
	var roll_rate := angular_velocity_ps2.dot(body_forward_ps2)
	var attitude_torque_ps2: Vector3 = body_right_ps2 * (-pitch_rate * GROUNDED_PITCH_DAMPING * grounded_alpha)
	attitude_torque_ps2 += body_forward_ps2 * (-roll_rate * GROUNDED_ROLL_DAMPING * grounded_alpha)
	_apply_torque_impulse_ps2(state, attitude_torque_ps2 * sub_dt)


func _can_rest_settle(state: PhysicsDirectBodyState3D) -> bool:
	if absf(_throttle_input) > 0.01 or absf(_brake_input) > 0.01:
		return false
	if absf(_handbrake_input) > 0.01 or absf(_steering_input) > 0.01:
		return false
	if state.linear_velocity.length() > REST_SETTLE_LINEAR_SPEED:
		return false
	if state.angular_velocity.length() > REST_SETTLE_ANGULAR_SPEED:
		return false
	if wheels.is_empty():
		return false
	for wheel in wheels:
		if not wheel.grounded:
			return false
		if absf(wheel.travel_velocity) > REST_SETTLE_TRAVEL_SPEED:
			return false
	return true


func _yaw_assist_torque_ps2(body_up_ps2: Vector3, state: PhysicsDirectBodyState3D, speed_mps: float) -> Vector3:
	if speed_mps * 3.6 < config.stabilization_min_speed_kph:
		return body_up_ps2 * (-_godot_to_ps2(state.angular_velocity).z * config.yaw_damping)

	var slip_deg = absf(rad_to_deg(signed_slip_angle))
	var drift_range = maxf(config.drift_slip_deg - config.stabilization_slip_deg, 0.001)
	var slip_alpha = clampf((slip_deg - config.stabilization_slip_deg) / drift_range, 0.0, 1.0)
	var steer_assist = _steering_state * config.steering_yaw_assist * clampf(speed_mps / 30.0, 0.0, 1.0)
	var stabilize = -signf(signed_slip_angle) * config.yaw_assist * slip_alpha
	var yaw_rate_damping = -_godot_to_ps2(state.angular_velocity).z * config.yaw_damping
	return body_up_ps2 * (stabilize + yaw_rate_damping + steer_assist)


func _wheel_heading_ps2(basis: Basis, body_up_ps2: Vector3, wheel) -> Vector3:
	var base_forward_ps2 = _basis_axis_ps2(basis, Vector3(1.0, 0.0, 0.0))
	if wheel.is_front():
		wheel.steer_angle = _steering_state
		return base_forward_ps2.rotated(body_up_ps2, wheel.steer_angle).normalized()
	wheel.steer_angle = 0.0
	return base_forward_ps2


func _wheel_right_axis_ps2(basis: Basis, wheel) -> Vector3:
	var body_up_ps2 = _basis_axis_ps2(basis, Vector3(0.0, 0.0, 1.0))
	var heading_ps2 = _wheel_heading_ps2(basis, body_up_ps2, wheel)
	return body_up_ps2.cross(heading_ps2).normalized()


func _wheel_axle_ps2(basis: Basis, wheel) -> Vector3:
	var axle_ps2 = _wheel_right_axis_ps2(basis, wheel)
	if axle_ps2.length_squared() <= 0.0001:
		axle_ps2 = _basis_axis_ps2(basis, Vector3(0.0, 1.0, 0.0))
	return axle_ps2.normalized()


func _apply_impulse_ps2(state: PhysicsDirectBodyState3D, impulse_ps2: Vector3, world_position_ps2: Vector3) -> void:
	if impulse_ps2.length_squared() <= 0.000001:
		return
	var impulse_godot = _ps2_to_godot(impulse_ps2)
	var world_position_godot = _ps2_to_godot(world_position_ps2)
	var offset = world_position_godot - state.transform.origin
	state.apply_impulse(impulse_godot)
	state.apply_torque_impulse(offset.cross(impulse_godot))


func _apply_torque_impulse_ps2(state: PhysicsDirectBodyState3D, torque_ps2: Vector3) -> void:
	if torque_ps2.length_squared() <= 0.000001:
		return
	state.apply_torque_impulse(_ps2_to_godot(torque_ps2))


func _update_inputs() -> void:
	_throttle_input = _read_action_pair("car_accelerate", "ui_up")
	_brake_input = _read_action_pair("car_brake", "ui_down")
	_handbrake_input = _read_action_pair("car_handbrake", "")
	_steering_input = _read_action_pair("car_steer_left", "ui_left") - _read_action_pair("car_steer_right", "ui_right")


func _read_action_pair(primary: String, fallback: String) -> float:
	if primary != "" and InputMap.has_action(primary):
		return Input.get_action_strength(primary)
	if fallback != "" and InputMap.has_action(fallback):
		return Input.get_action_strength(fallback)
	return 0.0


func _update_debug_snapshot() -> void:
	var wheel_rows: Array = []
	for wheel in wheels:
		wheel_rows.append({
			"slot": wheel.slot_id,
			"compression": wheel.compression,
			"suspension_distance": wheel.suspension_distance,
			"current_length": wheel.current_length,
			"min_travel": wheel.min_travel,
			"max_travel": wheel.max_travel,
			"overtravel": wheel.overtravel,
			"travel_velocity": wheel.travel_velocity,
			"grounded": wheel.grounded,
			"force": wheel.suspension_force,
		})

	_debug_snapshot = {
		"speed_kph": _horizontal_ps2(_godot_to_ps2(linear_velocity)).length() * 3.6,
		"rpm": engine_rpm,
		"gear": current_gear,
		"slip_angle_deg": rad_to_deg(signed_slip_angle),
		"wheels": wheel_rows,
	}


func _ensure_generated_visuals() -> void:
	if not _wheel_visuals.is_empty():
		return
	_visual_root = get_node_or_null("GeneratedVisuals")
	if _visual_root == null:
		_visual_root = Node3D.new()
		_visual_root.name = "GeneratedVisuals"
		add_child(_visual_root)

	_body_visual = _visual_root.get_node_or_null("Body") as MeshInstance3D
	if _body_visual == null:
		_body_visual = MeshInstance3D.new()
		_body_visual.name = "Body"
		var body_mesh = BoxMesh.new()
		body_mesh.size = _ps2_to_godot(config.body_size_ps2).abs()
		_body_visual.mesh = body_mesh
		var material = StandardMaterial3D.new()
		material.albedo_color = Color(0.82, 0.08, 0.05, 1.0)
		_body_visual.material_override = material
		_body_visual.position = _ps2_to_godot(config.center_of_mass_ps2)
		_visual_root.add_child(_body_visual)

	for wheel in wheels:
		if _wheel_visuals.has(wheel.slot_id):
			continue
		var wheel_visual = MeshInstance3D.new()
		wheel_visual.name = wheel.slot_id
		var wheel_mesh = SphereMesh.new()
		wheel_mesh.radius = wheel.wheel_radius
		wheel_mesh.height = wheel.wheel_radius * 2.0
		wheel_visual.mesh = wheel_mesh
		var wheel_material = StandardMaterial3D.new()
		wheel_material.albedo_color = Color(0.08, 0.08, 0.08, 1.0)
		wheel_visual.material_override = wheel_material
		_visual_root.add_child(wheel_visual)
		_wheel_visuals[wheel.slot_id] = wheel_visual


func _ensure_debug_mesh() -> void:
	_debug_mesh_instance = get_node_or_null("DebugLines") as MeshInstance3D
	if _debug_mesh_instance == null:
		_debug_mesh_instance = MeshInstance3D.new()
		_debug_mesh_instance.name = "DebugLines"
		add_child(_debug_mesh_instance)
	if _debug_material == null:
		_debug_material = StandardMaterial3D.new()
		_debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_debug_material.vertex_color_use_as_albedo = true
		_debug_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_debug_material.no_depth_test = true
	_debug_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_debug_mesh_instance.material_override = _debug_material
	_debug_mesh_instance.mesh = _debug_mesh


func _update_visuals() -> void:
	for wheel in wheels:
		var wheel_visual = _wheel_visuals.get(wheel.slot_id, null)
		var suspension_node = _wheel_suspension_nodes.get(wheel.slot_id, null)
		var pivot_node = _debug_pivot_nodes.get(wheel.slot_id, null)
		if _is_live_node3d(suspension_node) and _is_live_node3d(pivot_node) and _is_live_node3d(_visual_root):
			var suspension_transform: Node3D = suspension_node
			suspension_transform.position = _ps2_to_godot(wheel.world_wheel_center_ps2 - wheel.world_pivot_ps2)
		elif _is_live_node3d(wheel_visual):
			var target_position = _ps2_to_godot(wheel.world_wheel_center_ps2)
			var wheel_node: Node3D = wheel_visual
			wheel_node.global_position = target_position
		if not _is_live_node3d(wheel_visual):
			continue
		var steer_node: Node3D = wheel_visual
		var steer_rotation = steer_node.rotation
		steer_rotation.y = wheel.steer_angle
		steer_node.rotation = steer_rotation
		var roll_visual = _wheel_roll_visuals.get(wheel.slot_id, null)
		if _is_live_node3d(roll_visual):
			var roll_node: Node3D = roll_visual
			var roll_rotation = roll_node.rotation
			roll_rotation.x = wheel.roll_angle * float(roll_node.get_meta("eagl_spin_direction", 1.0))
			roll_node.rotation = roll_rotation


func _rebuild_debug_mesh() -> void:
	if _debug_mesh_instance == null:
		return
	var pivot_basis := _ps2_debug_basis()
	_debug_mesh.clear_surfaces()
	_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_add_chassis_debug_wireframe()
	for wheel in wheels:
		var pivot = _debug_local_from_ps2(wheel.world_pivot_ps2)
		var attachment = _debug_local_from_ps2(wheel.world_attachment_ps2)
		var center = _debug_local_from_ps2(wheel.world_wheel_center_ps2)
		var contact = _debug_local_from_ps2(wheel.contact_point_ps2)
		var axis_end = contact if wheel.grounded else center
		var spring_min = _debug_local_from_ps2(wheel.world_attachment_ps2 + _basis_axis_ps2(global_transform.basis, Vector3(0.0, 0.0, 1.0)) * wheel.min_travel)
		var spring_max = _debug_local_from_ps2(wheel.world_attachment_ps2 + _basis_axis_ps2(global_transform.basis, Vector3(0.0, 0.0, 1.0)) * wheel.max_travel)
		var normal_end = _debug_local_from_global(_ps2_to_godot(wheel.contact_point_ps2 + wheel.normal_ps2 * debug_normal_length))
		var normal_start = center
		if wheel.contact_point_ps2 != Vector3.ZERO:
			normal_start = contact
		_debug_mesh.surface_set_color(Color(1.0, 0.35, 0.15, 1.0))
		_debug_mesh.surface_add_vertex(pivot + Vector3.LEFT * 0.09)
		_debug_mesh.surface_add_vertex(pivot + Vector3.RIGHT * 0.09)
		_debug_mesh.surface_add_vertex(pivot + Vector3.UP * 0.09)
		_debug_mesh.surface_add_vertex(pivot + Vector3.DOWN * 0.09)
		_debug_mesh.surface_set_color(Color(0.15, 0.95, 0.85, 0.95))
		_debug_mesh.surface_add_vertex(pivot)
		_debug_mesh.surface_add_vertex(attachment)
		_debug_mesh.surface_set_color(Color(0.0, 0.85, 1.0, 1.0))
		_debug_mesh.surface_add_vertex(attachment)
		_debug_mesh.surface_add_vertex(axis_end)
		_debug_mesh.surface_set_color(Color(0.15, 0.95, 0.85, 0.95))
		_debug_mesh.surface_add_vertex(spring_min)
		_debug_mesh.surface_add_vertex(spring_max)
		_debug_mesh.surface_set_color(Color(0.25, 1.0, 0.3, 1.0))
		_debug_mesh.surface_add_vertex(normal_start)
		_debug_mesh.surface_add_vertex(normal_end)
		_debug_mesh.surface_set_color(Color(1.0, 0.75, 0.15, 1.0))
		_debug_mesh.surface_add_vertex(center + Vector3.LEFT * 0.08)
		_debug_mesh.surface_add_vertex(center + Vector3.RIGHT * 0.08)
		_debug_mesh.surface_add_vertex(center + Vector3.UP * 0.08)
		_debug_mesh.surface_add_vertex(center + Vector3.DOWN * 0.08)
		_add_suspension_force_marker(wheel, pivot)
		_add_circle_marker(attachment, 0.11, _debug_local_direction_ps2(_basis_axis_ps2(global_transform.basis, Vector3(0.0, 0.0, 1.0))), Color(0.15, 0.95, 0.85, 0.75), 16)
		_add_circle_marker(center, maxf(wheel.wheel_radius, 0.05), _debug_local_direction_ps2(_wheel_axle_ps2(global_transform.basis, wheel)), Color(1.0, 0.75, 0.15, 0.9), 18)
		if wheel.grounded:
			_add_circle_marker(contact, 0.09, _debug_local_direction_ps2(wheel.normal_ps2), Color(0.25, 1.0, 0.3, 0.8), 14)
	for slot_id in _debug_pivot_nodes.keys():
		var pivot_node: Node3D = _debug_pivot_nodes[slot_id]
		if not _is_live_node3d(pivot_node):
			_debug_pivot_nodes.erase(slot_id)
			continue
		var pivot_position = _debug_local_from_global(pivot_node.global_position)
		_add_cross_marker(pivot_position, 0.12, Color(1.0, 0.35, 0.15, 1.0))
		_add_circle_marker(pivot_position, 0.18, _debug_local_direction_global((pivot_node.global_basis * pivot_basis.y).normalized()), Color(1.0, 0.55, 0.15, 1.0))
		_add_axis_marker(pivot_position, _debug_local_basis(pivot_node.global_basis * pivot_basis), 0.22)
	for dummy_name in _debug_dummy_nodes.keys():
		var dummy_node: Node3D = _debug_dummy_nodes[dummy_name]
		if not _is_live_node3d(dummy_node):
			_debug_dummy_nodes.erase(dummy_name)
			continue
		var dummy_color := Color(0.85, 0.3, 1.0, 1.0) if dummy_name.ends_with("_PIVOT") else Color(0.35, 0.95, 0.85, 1.0)
		var dummy_position = _debug_local_from_global(dummy_node.global_position)
		_add_cross_marker(dummy_position, 0.09, dummy_color)
		_add_circle_marker(dummy_position, 0.13, _debug_local_direction_global((dummy_node.global_basis * pivot_basis.y).normalized()), dummy_color)
		_add_axis_marker(dummy_position, _debug_local_basis(dummy_node.global_basis * pivot_basis), 0.16)
	_add_body_forward_marker()
	_debug_mesh.surface_end()


func _is_live_node3d(node: Variant) -> bool:
	return node is Node3D and is_instance_valid(node)


func _add_cross_marker(center: Vector3, radius: float, color: Color) -> void:
	_debug_mesh.surface_set_color(color)
	_debug_mesh.surface_add_vertex(center + Vector3.LEFT * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.RIGHT * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.UP * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.DOWN * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.FORWARD * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.BACK * radius)


func _add_axis_marker(origin: Vector3, basis: Basis, axis_length: float) -> void:
	_debug_mesh.surface_set_color(Color(1.0, 0.2, 0.2, 1.0))
	_debug_mesh.surface_add_vertex(origin)
	_debug_mesh.surface_add_vertex(origin + basis.x.normalized() * axis_length)
	_debug_mesh.surface_set_color(Color(0.2, 1.0, 0.35, 1.0))
	_debug_mesh.surface_add_vertex(origin)
	_debug_mesh.surface_add_vertex(origin + basis.y.normalized() * axis_length)
	_debug_mesh.surface_set_color(Color(0.25, 0.65, 1.0, 1.0))
	_debug_mesh.surface_add_vertex(origin)
	_debug_mesh.surface_add_vertex(origin + basis.z.normalized() * axis_length)


func _add_circle_marker(center: Vector3, radius: float, normal: Vector3, color: Color, segments: int = 20) -> void:
	var circle_normal := normal.normalized()
	if circle_normal.length_squared() <= 0.000001:
		circle_normal = Vector3.UP
	var tangent := circle_normal.cross(Vector3.RIGHT)
	if tangent.length_squared() <= 0.000001:
		tangent = circle_normal.cross(Vector3.FORWARD)
	tangent = tangent.normalized()
	var bitangent := circle_normal.cross(tangent).normalized()
	_debug_mesh.surface_set_color(color)
	for index in range(segments):
		var t0 := TAU * float(index) / float(segments)
		var t1 := TAU * float(index + 1) / float(segments)
		var p0 := center + (tangent * cos(t0) + bitangent * sin(t0)) * radius
		var p1 := center + (tangent * cos(t1) + bitangent * sin(t1)) * radius
		_debug_mesh.surface_add_vertex(p0)
		_debug_mesh.surface_add_vertex(p1)


func _add_chassis_debug_wireframe() -> void:
	var collision_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision_shape == null:
		return
	var box_shape := collision_shape.shape as BoxShape3D
	if box_shape == null:
		return
	var extents := box_shape.size * 0.5
	var corners := [
		Vector3(-extents.x, -extents.y, -extents.z),
		Vector3(extents.x, -extents.y, -extents.z),
		Vector3(extents.x, extents.y, -extents.z),
		Vector3(-extents.x, extents.y, -extents.z),
		Vector3(-extents.x, -extents.y, extents.z),
		Vector3(extents.x, -extents.y, extents.z),
		Vector3(extents.x, extents.y, extents.z),
		Vector3(-extents.x, extents.y, extents.z),
	]
	var transformed: Array[Vector3] = []
	transformed.resize(corners.size())
	for index in range(corners.size()):
		transformed[index] = collision_shape.transform * corners[index]
	var edges := [
		Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3), Vector2i(3, 0),
		Vector2i(4, 5), Vector2i(5, 6), Vector2i(6, 7), Vector2i(7, 4),
		Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
	]
	_debug_mesh.surface_set_color(Color(1.0, 1.0, 1.0, 0.9))
	for edge in edges:
		_debug_mesh.surface_add_vertex(transformed[edge.x])
		_debug_mesh.surface_add_vertex(transformed[edge.y])


func _add_suspension_force_marker(wheel, pivot: Vector3) -> void:
	var force_alpha := clampf(wheel.suspension_force / maxf(wheel.preload_force * 1.35, 1.0), 0.0, 1.0)
	var force_color := Color(0.35, 0.22, 0.22, 0.45)
	if wheel.suspension_force > 0.5:
		force_color = Color(0.55 + 0.45 * force_alpha, 0.08, 0.08, 0.8 + 0.2 * force_alpha)
	var force_axis := _debug_local_direction_ps2(_basis_axis_ps2(global_transform.basis, Vector3(0.0, 0.0, 1.0)))
	var force_length := lerpf(0.06, 0.6, force_alpha)
	var force_end := pivot + force_axis * force_length
	_debug_mesh.surface_set_color(force_color)
	_debug_mesh.surface_add_vertex(pivot)
	_debug_mesh.surface_add_vertex(force_end)
	var tip_radius := 0.025 + force_alpha * 0.04
	_debug_mesh.surface_add_vertex(force_end)
	_debug_mesh.surface_add_vertex(force_end - force_axis * tip_radius + Vector3.LEFT * tip_radius)
	_debug_mesh.surface_add_vertex(force_end)
	_debug_mesh.surface_add_vertex(force_end - force_axis * tip_radius + Vector3.RIGHT * tip_radius)


func _ps2_debug_basis() -> Basis:
	return Basis(Vector3.RIGHT, Vector3.BACK, Vector3.UP)


func _fit_chassis_collision_shape() -> void:
	var collision_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision_shape == null:
		return
	var box_shape := collision_shape.shape as BoxShape3D
	if box_shape == null:
		return
	box_shape.size = _ps2_to_godot(config.body_size_ps2).abs()
	collision_shape.position = _ps2_to_godot(Vector3(0.0, 0.0, config.body_size_ps2.z * 0.5))


func _fit_collision_shape_to_visual_bounds() -> void:
	var collision_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision_shape == null:
		return
	var box_shape := collision_shape.shape as BoxShape3D
	if box_shape == null:
		return
	var body_root := get_node_or_null("CarVisual/Body") as Node3D
	if body_root == null:
		return
	var has_bounds := false
	var min_point := Vector3.ZERO
	var max_point := Vector3.ZERO
	for child in body_root.get_children():
		if not (child is MeshInstance3D):
			continue
		var mesh_instance := child as MeshInstance3D
		var local_aabb := mesh_instance.get_aabb()
		var corners := [
			local_aabb.position,
			local_aabb.position + Vector3(local_aabb.size.x, 0.0, 0.0),
			local_aabb.position + Vector3(0.0, local_aabb.size.y, 0.0),
			local_aabb.position + Vector3(0.0, 0.0, local_aabb.size.z),
			local_aabb.position + Vector3(local_aabb.size.x, local_aabb.size.y, 0.0),
			local_aabb.position + Vector3(local_aabb.size.x, 0.0, local_aabb.size.z),
			local_aabb.position + Vector3(0.0, local_aabb.size.y, local_aabb.size.z),
			local_aabb.position + local_aabb.size,
		]
		for corner in corners:
			var p: Vector3 = to_local(mesh_instance.global_transform * corner)
			if not has_bounds:
				min_point = p
				max_point = p
				has_bounds = true
			else:
				min_point = min_point.min(p)
				max_point = max_point.max(p)
	if not has_bounds:
		return
	box_shape.size = (max_point - min_point).abs()
	collision_shape.position = (min_point + max_point) * 0.5


func _add_body_forward_marker() -> void:
	var body_origin := Vector3.ZERO
	var body_forward := Vector3.RIGHT
	_debug_mesh.surface_set_color(Color(1.0, 0.1, 0.1, 1.0))
	_debug_mesh.surface_add_vertex(body_origin)
	_debug_mesh.surface_add_vertex(body_origin + body_forward.normalized() * 1.5)


func _prime_wheels_from_current_transform() -> void:
	var body_up_ps2 = _basis_axis_ps2(global_transform.basis, Vector3(0.0, 0.0, 1.0))
	for wheel in wheels:
		var pivot_world_ps2 = _transform_point_ps2(global_transform, wheel.pivot_local_position_ps2)
		var attachment_world_ps2 = _transform_point_ps2(global_transform, wheel.local_position_ps2)
		wheel.world_pivot_ps2 = pivot_world_ps2
		wheel.world_attachment_ps2 = attachment_world_ps2
		var length_min := minf(wheel.min_travel, wheel.max_travel)
		wheel.world_wheel_center_ps2 = attachment_world_ps2 + body_up_ps2 * length_min
		wheel.contact_point_ps2 = attachment_world_ps2
		wheel.normal_ps2 = body_up_ps2
		wheel.suspension_distance = length_min
		wheel.center_offset = length_min
		wheel.current_length = length_min
		wheel.previous_length = length_min
		wheel.travel_velocity = 0.0
		wheel.over_limit = 0.0
		wheel.compression = 0.0
		wheel.prev_compression = wheel.compression
		wheel.compression_velocity = 0.0


func _paired_axle_wheel(wheel):
	for other in wheels:
		if other == wheel:
			continue
		if other.axle != wheel.axle:
			continue
		if other.side == wheel.side:
			continue
		return other
	return null


func _debug_local_from_ps2(world_point_ps2: Vector3) -> Vector3:
	return _debug_local_from_global(_ps2_to_godot(world_point_ps2))


func _debug_local_from_global(world_point: Vector3) -> Vector3:
	return to_local(world_point)


func _debug_local_direction_ps2(direction_ps2: Vector3) -> Vector3:
	return global_transform.basis.inverse() * _ps2_to_godot(direction_ps2)


func _debug_local_direction_global(direction_global: Vector3) -> Vector3:
	return global_transform.basis.inverse() * direction_global


func _debug_local_basis(global_basis: Basis) -> Basis:
	return global_transform.basis.inverse() * global_basis


func _transform_point_ps2(transform: Transform3D, local_point_ps2: Vector3) -> Vector3:
	return _godot_to_ps2(transform * _ps2_to_godot(local_point_ps2))


func _basis_axis_ps2(basis: Basis, local_axis_ps2: Vector3) -> Vector3:
	return _godot_to_ps2(basis * _ps2_to_godot(local_axis_ps2)).normalized()


func _ps2_to_godot(value: Vector3) -> Vector3:
	return MathUtils.ps2_to_godot_vec3(value)


func _godot_to_ps2(value: Vector3) -> Vector3:
	return Vector3(value.x, -value.z, value.y)


func _horizontal_ps2(value: Vector3) -> Vector3:
	return Vector3(value.x, value.y, 0.0)


func _signed_angle_on_axis(from_vector: Vector3, to_vector: Vector3, axis: Vector3) -> float:
	var cross_value = from_vector.cross(to_vector)
	return atan2(axis.dot(cross_value), from_vector.dot(to_vector))


func _safe_speed_sign(primary_speed: float, fallback_speed: float) -> float:
	if absf(primary_speed) > 0.25:
		return signf(primary_speed)
	if fallback_speed > 0.25:
		return 1.0
	return 0.0
