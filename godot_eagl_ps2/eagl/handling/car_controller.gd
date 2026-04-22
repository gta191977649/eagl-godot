class_name CarController
extends RigidBody3D

const CarConfigScript = preload("res://eagl/handling/car_config.gd")
const CarVisualRigScript = preload("res://eagl/assets/car/car_visual_rig.gd")
const RoadSurfaceSamplerScript = preload("res://eagl/handling/road_surface_sampler.gd")
const WheelStateScript = preload("res://eagl/handling/wheel_state.gd")
const MathUtils = preload("res://eagl/utils/math_utils.gd")

const SUBSTEP_TARGET_DT = 0.0044
const GRAVITY_MPS2 = 9.8
const HP2_SERVICE_BRAKE_SCALE := {
	"FL": 1.0,
	"FR": 1.0,
	"RL": 0.6,
	"RR": 0.6,
}
const HP2_HANDBRAKE_SCALE := {
	"FL": 0.0,
	"FR": 0.0,
	"RL": 1.0,
	"RR": 1.0,
}
const HP2_STABILITY_BASE_FORCE_SCALE = 1.0
const HP2_STABILITY_HANDBRAKE_ACTIVE = 0.5
const HP2_STABILITY_HANDBRAKE_MIN_BLEND = 0.5
const HP2_STABILITY_HANDBRAKE_RELEASE_RATE = 1.0
const HP2_STABILITY_HANDBRAKE_APPLY_RATE = 20.0
const HP2_STABILITY_HANDBRAKE_SLIP_BYPASS_RAD = 0.349065899848938
const HP2_STABILITY_SPEED_RANGE = 30.0
const HP2_STABILITY_MAX_EXTRA_GAIN = 0.7
const HP2_SUSPENSION_BUMP_STOP_SCALE = 32.0
const HP2_ALT_BRANCH_SPEED_SCALE = 1.5
const HP2_ALT_BRANCH_ENTRY_SPEED = 15.0
const HP2_ALT_BRANCH_ENTRY_SLIP_LIMIT_RAD = 0.1963493824005127
const HP2_ALT_BRANCH_EXIT_SLIP_LIMIT_RAD = 0.30000001192092896
const HP2_ALT_BRANCH_ENTRY_SPIN_MIN = 1.5
const HP2_ALT_BRANCH_ENTRY_SPIN_MAX = 3.0
const HP2_ALT_BRANCH_CLEAR_SPIN = 1.0
const HP2_ALT_BRANCH_PAIR_SCALE_DEFAULT = 0.4
const HP2_ALT_BRANCH_PAIR_HOLD_TIME = 1.0
const HP2_ALT_BRANCH_PAIR_CLEAR_DELAY = 0.1666666716337204
const HP2_WHEEL_SPIN_SERVICE_SCALE = 4.0
const HP2_WHEEL_SPIN_HANDBRAKE_SCALE = 10.0
const HP2_TIRE_MIN_LONG_SLIP = 0.5
const HP2_TIRE_POWER_BIAS = 1.5
const HP2_TIRE_LOCK_SCALE = 1.2
const HP2_TIRE_LOCK_ANGULAR_SPEED_BIAS = 0.1
const HP2_TIRE_MIN_FORCE_EPSILON = 0.001
const HP2_TIRE_STATIC_HOLD_SPEED_MPS = 0.35
const HP2_TIRE_STATIC_HOLD_INPUT_EPSILON = 0.02
const HP2_TIRE_LOW_SPEED_SLIP_BLEND_MPS = 5.0
const HP2_TIRE_LOW_SPEED_SLIDE_LONG_SLIP = 2.0
const HP2_TIRE_STATIC_FORCE_BOOST = 1.2

@export var config = null
@export var auto_build_visuals = true
@export var draw_debug = true
@export var debug_normal_length = 0.45
@export var debug_axis_length = 0.65
@export var hp2_state_39c_enabled = false

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
var _hp2_handbrake_stability_blend = 1.0
var _hp2_force_limit_scale = HP2_STABILITY_BASE_FORCE_SCALE
var _hp2_state_39c = 0
var _hp2_state_3a4 = 0
var _hp2_state_3a8 = 0.0
var _hp2_state_3ac = 1.0
var _hp2_state_3b0 = 0.0
var _debug_snapshot = {}

var _visual_rig = CarVisualRigScript.new()
var _debug_mesh_instance: MeshInstance3D
var _debug_mesh = ImmediateMesh.new()
var _debug_material: StandardMaterial3D


func _ready() -> void:
	_visual_rig.set_owner(self)
	if config == null:
		config = CarConfigScript.new()

	custom_integrator = true
	gravity_scale = 0.0
	can_sleep = false
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
	center_of_mass = _ps2_to_godot(config.center_of_mass_ps2 - config.physics_origin_offset_ps2)
	engine_rpm = maxf(config.idle_rpm, 900.0)
	current_gear = 1
	signed_slip_angle = 0.0
	_steering_state = 0.0
	_steering_engaged = false
	_hp2_handbrake_stability_blend = 1.0
	_hp2_force_limit_scale = HP2_STABILITY_BASE_FORCE_SCALE
	_reset_hp2_alt_branch_state()
	wheels = config.build_wheel_states()
	_fit_chassis_collision_shape()
	refresh_visual_bindings()
	if auto_build_visuals and not _visual_rig.has_wheel_visuals():
		_ensure_generated_visuals()
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
	_hp2_handbrake_stability_blend = 1.0
	_hp2_force_limit_scale = HP2_STABILITY_BASE_FORCE_SCALE
	_reset_hp2_alt_branch_state()
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
	var physics_origin_offset_ps2: Vector3 = config.physics_origin_offset_ps2 if config != null else Vector3.ZERO
	_visual_rig.refresh_bindings(physics_origin_offset_ps2)


func set_visual_root(visual: Node3D) -> void:
	var physics_origin_offset_ps2: Vector3 = config.physics_origin_offset_ps2 if config != null else Vector3.ZERO
	_visual_rig.replace_visual_root(visual, physics_origin_offset_ps2)


func get_debug_snapshot() -> Dictionary:
	return _debug_snapshot.duplicate(true)


func _step_vehicle(state: PhysicsDirectBodyState3D, sub_dt: float) -> void:
	var transform = state.transform
	var body_origin_ps2 = _godot_to_ps2(transform.origin)
	var body_up_ps2 = _basis_axis_ps2(transform.basis, Vector3(0.0, 0.0, 1.0))
	var body_forward_ps2 = _basis_axis_ps2(transform.basis, Vector3(1.0, 0.0, 0.0))
	var linear_velocity_ps2 = _godot_to_ps2(state.linear_velocity)
	var flat_velocity_ps2 = _horizontal_ps2(linear_velocity_ps2)
	var speed_mps = flat_velocity_ps2.length()

	state.apply_impulse(Vector3.DOWN * config.mass_kg * GRAVITY_MPS2 * sub_dt)
	_update_steering_state(speed_mps, sub_dt)
	_update_body_slip(body_forward_ps2, flat_velocity_ps2)
	_hp2_force_limit_scale = _hp2_stability_force_limit_scale(body_forward_ps2, linear_velocity_ps2.length(), sub_dt)
	_update_hp2_alt_branch_state(speed_mps * HP2_ALT_BRANCH_SPEED_SCALE, sub_dt)

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

	var engine_wheel_torque_total = config.sample_engine_force(speed_mps, engine_rpm) * _throttle_input * config.get_gear_ratio(current_gear) * config.final_drive_ratio

	for wheel in wheels:
		if not wheel.grounded:
			continue
		var drive_bias = config.drive_bias_for_slot(wheel.slot_id)
		var wheel_heading_ps2 = _wheel_heading_ps2(transform.basis, body_up_ps2, wheel)
		if wheel_heading_ps2.length_squared() <= 0.0001:
			wheel_heading_ps2 = body_forward_ps2

		var drive_torque = engine_wheel_torque_total * drive_bias
		var drive_force = drive_torque / maxf(wheel.wheel_radius, 0.01)
		var brake_force = config.brake_force * _brake_input * _hp2_service_brake_scale(wheel.slot_id)
		brake_force += config.handbrake_force * _handbrake_input * _hp2_handbrake_scale(wheel.slot_id)
		var wheel_right_ps2 = _wheel_right_axis_ps2(transform.basis, wheel)
		var wheel_force_limit_scale = _hp2_force_limit_scale * wheel.hp2_pair_force_scale
		var brake_force_scalar = -signf(_safe_speed_sign(wheel.forward_speed, speed_mps)) * brake_force
		var tire_force_local_ps2: Vector2 = _hp2_tire_force_local_for_wheel(
			wheel,
			drive_force + brake_force_scalar,
			speed_mps * HP2_ALT_BRANCH_SPEED_SCALE,
			sub_dt,
			wheel_force_limit_scale
		)
		var tire_force_ps2 = wheel_heading_ps2 * tire_force_local_ps2.x + wheel_right_ps2 * tire_force_local_ps2.y
		_apply_impulse_ps2(state, tire_force_ps2 * sub_dt, wheel.contact_point_ps2)
		_update_hp2_wheel_spin_accumulator(wheel, speed_mps * HP2_ALT_BRANCH_SPEED_SCALE)

	var drag_force_ps2 = _drag_force_ps2(flat_velocity_ps2, speed_mps)
	_apply_impulse_ps2(state, drag_force_ps2 * sub_dt, body_origin_ps2)


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
	var free_rolling_angular_speed: float = wheel.forward_speed / maxf(wheel.wheel_radius, 0.01)
	if wheel.hp2_lock_active:
		wheel.angular_speed = 0.0
	else:
		wheel.angular_speed = free_rolling_angular_speed
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
	# HP2's suspension update applies a shared bump-stop scale here rather than
	# a per-car tuning value from the row block.
	var overtravel_force = HP2_SUSPENSION_BUMP_STOP_SCALE * wheel.over_limit

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


func _update_body_slip(body_forward_ps2: Vector3, flat_velocity_ps2: Vector3) -> void:
	if flat_velocity_ps2.dot(body_forward_ps2) < 5.0:
		signed_slip_angle = 0.0
		return
	var body_heading_deg = rad_to_deg(atan2(body_forward_ps2.y, body_forward_ps2.x))
	var velocity_heading_deg = rad_to_deg(atan2(flat_velocity_ps2.y, flat_velocity_ps2.x))
	var slip_deg = wrapf(body_heading_deg - velocity_heading_deg + 180.0, 0.0, 360.0) - 180.0
	signed_slip_angle = deg_to_rad(slip_deg)


func _hp2_stability_force_limit_scale(body_forward_ps2: Vector3, linear_speed_ps2: float, sub_dt: float) -> float:
	if _handbrake_input > HP2_STABILITY_HANDBRAKE_ACTIVE:
		_hp2_handbrake_stability_blend = maxf(
			_hp2_handbrake_stability_blend - sub_dt * HP2_STABILITY_HANDBRAKE_APPLY_RATE,
			HP2_STABILITY_HANDBRAKE_MIN_BLEND
		)
	else:
		_hp2_handbrake_stability_blend = minf(
			_hp2_handbrake_stability_blend + sub_dt * HP2_STABILITY_HANDBRAKE_RELEASE_RATE,
			1.0
		)

	var base_gain = absf(body_forward_ps2.z) + 1.0
	var slip_abs = absf(signed_slip_angle)
	if _handbrake_input > HP2_STABILITY_HANDBRAKE_ACTIVE and slip_abs < HP2_STABILITY_HANDBRAKE_SLIP_BYPASS_RAD:
		return 1.0 + _hp2_handbrake_stability_blend * maxf(base_gain - 1.0, 0.0)

	var speed_alpha = clampf(linear_speed_ps2 / HP2_STABILITY_SPEED_RANGE, 0.0, 1.0)
	var extra_gain = slip_abs * (config.hp2_row_0x310 + config.hp2_row_0x314) * speed_alpha
	extra_gain = minf(extra_gain, HP2_STABILITY_MAX_EXTRA_GAIN)
	var stability_gain = base_gain + extra_gain
	return 1.0 + _hp2_handbrake_stability_blend * maxf(stability_gain - 1.0, 0.0)


func _update_hp2_alt_branch_state(speed_scaled: float, sub_dt: float) -> void:
	if hp2_state_39c_enabled:
		_hp2_state_39c = 1
	else:
		_hp2_state_39c = 0

	if _hp2_state_39c != 1:
		_hp2_state_3a4 = 0
		_hp2_state_3a8 = 0.0
		_hp2_state_3ac = 1.0
		_hp2_state_3b0 = 0.0
		_apply_hp2_pair_force_scales()
		return

	if _hp2_state_3a4 == 0:
		if speed_scaled <= 0.0:
			_apply_hp2_pair_force_scales()
			return
		if speed_scaled < HP2_ALT_BRANCH_ENTRY_SPEED:
			_apply_hp2_pair_force_scales()
			return
		if absf(signed_slip_angle) >= HP2_ALT_BRANCH_ENTRY_SLIP_LIMIT_RAD:
			_apply_hp2_pair_force_scales()
			return
		_try_enter_hp2_alt_pair_state(speed_scaled)
		_apply_hp2_pair_force_scales()
		return

	_hp2_state_3a8 -= sub_dt
	if _hp2_state_3a8 < 0.0:
		_clear_hp2_alt_pair_state()
		_apply_hp2_pair_force_scales()
		return
	if absf(signed_slip_angle) > HP2_ALT_BRANCH_EXIT_SLIP_LIMIT_RAD:
		_clear_hp2_alt_pair_state()
		_apply_hp2_pair_force_scales()
		return
	if _all_hp2_spin_accumulators_below(HP2_ALT_BRANCH_CLEAR_SPIN):
		_hp2_state_3b0 += sub_dt
		if HP2_ALT_BRANCH_PAIR_CLEAR_DELAY < _hp2_state_3b0:
			_clear_hp2_alt_pair_state()
	else:
		_hp2_state_3b0 = 0.0
	_apply_hp2_pair_force_scales()


func _try_enter_hp2_alt_pair_state(speed_scaled: float) -> void:
	if wheels.size() < 4:
		return
	var trigger_index := -1
	var pair_selector := 0
	if wheels[2].hp2_spin_accumulator <= HP2_ALT_BRANCH_ENTRY_SPIN_MIN:
		if HP2_ALT_BRANCH_ENTRY_SPIN_MIN < wheels[3].hp2_spin_accumulator:
			trigger_index = 2
			if wheels[3].hp2_spin_accumulator < wheels[2].hp2_spin_accumulator:
				pair_selector = 1
			else:
				trigger_index = 3
				pair_selector = 2
		elif HP2_ALT_BRANCH_ENTRY_SPIN_MIN < wheels[0].hp2_spin_accumulator or HP2_ALT_BRANCH_ENTRY_SPIN_MIN < wheels[1].hp2_spin_accumulator:
			trigger_index = 1
			if wheels[0].hp2_spin_accumulator < wheels[1].hp2_spin_accumulator:
				pair_selector = 1
			else:
				trigger_index = 0
				pair_selector = 2
	else:
		trigger_index = 2
		if wheels[3].hp2_spin_accumulator < wheels[2].hp2_spin_accumulator:
			pair_selector = 1
		else:
			trigger_index = 3
			pair_selector = 2

	if trigger_index < 0 or pair_selector == 0:
		return

	var trigger_spin = wheels[trigger_index].hp2_spin_accumulator
	var trigger_alpha = clampf(
		(trigger_spin - HP2_ALT_BRANCH_ENTRY_SPIN_MIN) / maxf(HP2_ALT_BRANCH_ENTRY_SPIN_MAX - HP2_ALT_BRANCH_ENTRY_SPIN_MIN, 0.0001),
		0.0,
		1.0
	)
	_hp2_state_3a4 = pair_selector
	_hp2_state_3a8 = HP2_ALT_BRANCH_PAIR_HOLD_TIME
	_hp2_state_3b0 = 0.0
	_hp2_state_3ac = HP2_ALT_BRANCH_PAIR_SCALE_DEFAULT + (speed_scaled / HP2_ALT_BRANCH_ENTRY_SPEED) * (1.0 - trigger_alpha) * (1.0 - HP2_ALT_BRANCH_PAIR_SCALE_DEFAULT)


func _clear_hp2_alt_pair_state() -> void:
	_hp2_state_3a4 = 0
	_hp2_state_3a8 = 0.0
	_hp2_state_3ac = 1.0
	_hp2_state_3b0 = 0.0


func _apply_hp2_pair_force_scales() -> void:
	for wheel in wheels:
		wheel.hp2_pair_force_scale = 1.0
	if _hp2_state_3a4 == 1:
		if wheels.size() >= 4:
			wheels[0].hp2_pair_force_scale = _hp2_state_3ac
			wheels[3].hp2_pair_force_scale = _hp2_state_3ac
	elif _hp2_state_3a4 == 2:
		if wheels.size() >= 4:
			wheels[1].hp2_pair_force_scale = _hp2_state_3ac
			wheels[2].hp2_pair_force_scale = _hp2_state_3ac


func _all_hp2_spin_accumulators_below(threshold: float) -> bool:
	for wheel in wheels:
		if threshold <= wheel.hp2_spin_accumulator:
			return false
	return true


func _update_hp2_wheel_spin_accumulator(wheel, speed_scaled: float) -> void:
	var wheel_sign = signf(wheel.angular_speed)
	if wheel_sign > 0.0:
		wheel.hp2_spin_accumulator -= HP2_WHEEL_SPIN_SERVICE_SCALE * _hp2_service_brake_scale(wheel.slot_id) * config.hp2_row_0x304 * _brake_input
		wheel.hp2_spin_accumulator -= HP2_WHEEL_SPIN_HANDBRAKE_SCALE * _hp2_handbrake_wheel_signal(wheel.slot_id, speed_scaled) * config.hp2_row_0x308
	else:
		wheel.hp2_spin_accumulator += HP2_WHEEL_SPIN_SERVICE_SCALE * _hp2_service_brake_scale(wheel.slot_id) * config.hp2_row_0x304 * _brake_input
		wheel.hp2_spin_accumulator += HP2_WHEEL_SPIN_HANDBRAKE_SCALE * _hp2_handbrake_wheel_signal(wheel.slot_id, speed_scaled) * config.hp2_row_0x308
	if wheel.hp2_lock_active:
		wheel.hp2_spin_accumulator = 0.0


func _hp2_handbrake_wheel_signal(slot_id: String, speed_scaled: float) -> float:
	var wheel_signal = _handbrake_input * _hp2_handbrake_scale(slot_id)
	if _hp2_state_39c == 0:
		if 0.2 < wheel_signal:
			wheel_signal += 0.5
	elif 0.2 < wheel_signal and HP2_ALT_BRANCH_EXIT_SLIP_LIMIT_RAD < absf(signed_slip_angle) and speed_scaled < 80.0:
		wheel_signal += 0.5
	return wheel_signal


func _reset_hp2_alt_branch_state() -> void:
	_hp2_state_39c = 1 if hp2_state_39c_enabled else 0
	_hp2_state_3a4 = 0
	_hp2_state_3a8 = 0.0
	_hp2_state_3ac = 1.0
	_hp2_state_3b0 = 0.0


func _lateral_force_for_wheel(wheel, sub_dt: float, force_limit_scale: float) -> Vector3:
	var desired_force = -wheel.lateral_speed * _hp2_tire_slide_force_scale_for_wheel(wheel) * config.mass_kg * 0.25 / maxf(sub_dt, 0.0001)
	var max_force = wheel.suspension_force * _hp2_tire_slide_force_scale_for_wheel(wheel) * force_limit_scale
	var force_magnitude = clampf(desired_force, -max_force, max_force)
	return _wheel_right_axis_ps2(global_transform.basis, wheel) * force_magnitude


func _longitudinal_limit_force(wheel, requested_force_ps2: Vector3, force_limit_scale: float) -> Vector3:
	var max_force = wheel.suspension_force * _hp2_tire_combined_force_scale_for_wheel(wheel) * force_limit_scale
	if requested_force_ps2.length() <= max_force:
		return requested_force_ps2
	return requested_force_ps2.normalized() * max_force


func _hp2_tire_force_local_for_wheel(
	wheel,
	requested_longitudinal_force: float,
	speed_scaled: float,
	sub_dt: float,
	force_limit_scale: float
) -> Vector2:
	var requested_lateral_force = _hp2_requested_lateral_force_for_wheel(wheel, sub_dt, force_limit_scale)
	var static_hold_force = _hp2_static_hold_force_for_wheel(wheel, sub_dt, force_limit_scale)
	var local_force = Vector2(requested_longitudinal_force + static_hold_force, requested_lateral_force)
	var slip_vector = Vector2(
		wheel.angular_speed * wheel.wheel_radius - wheel.forward_speed,
		-wheel.lateral_speed
	)
	var slide_force_limit = _hp2_slide_force_limit_for_wheel(wheel, force_limit_scale)
	wheel.hp2_longitudinal_slip = slip_vector.x
	wheel.hp2_local_slip_angle_deg = _hp2_local_velocity_slip_angle_deg(wheel)
	_update_hp2_wheel_lock_state(wheel, slide_force_limit, slip_vector, speed_scaled)
	if _hp2_wheel_is_sliding(wheel, slip_vector.x):
		var slip_length = slip_vector.length()
		if HP2_TIRE_MIN_FORCE_EPSILON < slide_force_limit and HP2_TIRE_MIN_FORCE_EPSILON < slip_length:
			local_force = slip_vector * (slide_force_limit / slip_length)
		else:
			local_force = Vector2.ZERO
		wheel.hp2_is_sliding = true
	else:
		wheel.hp2_is_sliding = false
	return _hp2_clamp_local_tire_force(wheel, local_force, force_limit_scale)


func _hp2_requested_lateral_force_for_wheel(wheel, sub_dt: float, force_limit_scale: float) -> float:
	var low_speed_blend = _hp2_low_speed_blend_for_wheel(wheel)
	var response_scale = lerpf(0.55, 1.0, low_speed_blend)
	var desired_force = -wheel.lateral_speed * _hp2_tire_lateral_response_scale_for_wheel(wheel) * response_scale * config.mass_kg * 0.25 / maxf(sub_dt, 0.0001)
	var max_force = _hp2_combined_force_limit_for_wheel(wheel, force_limit_scale)
	return clampf(desired_force, -max_force, max_force)


func _hp2_slide_force_limit_for_wheel(wheel, force_limit_scale: float) -> float:
	return wheel.suspension_force * _hp2_tire_slide_force_scale_for_wheel(wheel) * force_limit_scale


func _hp2_combined_force_limit_for_wheel(wheel, force_limit_scale: float) -> float:
	return wheel.suspension_force * _hp2_tire_combined_force_scale_for_wheel(wheel) * force_limit_scale


func _hp2_static_hold_force_for_wheel(wheel, sub_dt: float, force_limit_scale: float) -> float:
	var has_driver_longitudinal_input := (
		absf(_throttle_input) > HP2_TIRE_STATIC_HOLD_INPUT_EPSILON
		or absf(_brake_input) > HP2_TIRE_STATIC_HOLD_INPUT_EPSILON
		or absf(_handbrake_input) > HP2_TIRE_STATIC_HOLD_INPUT_EPSILON
	)
	if has_driver_longitudinal_input:
		return 0.0
	if absf(wheel.forward_speed) > HP2_TIRE_STATIC_HOLD_SPEED_MPS:
		return 0.0
	var hold_force = -wheel.forward_speed * config.mass_kg * 0.25 / maxf(sub_dt, 0.0001)
	var hold_limit = _hp2_combined_force_limit_for_wheel(wheel, force_limit_scale)
	return clampf(hold_force, -hold_limit, hold_limit)


func _hp2_clamp_local_tire_force(wheel, local_force: Vector2, force_limit_scale: float) -> Vector2:
	var combined_force_limit = _hp2_combined_force_limit_for_wheel(wheel, force_limit_scale)
	if not wheel.hp2_is_sliding:
		combined_force_limit *= lerpf(HP2_TIRE_STATIC_FORCE_BOOST, 1.0, _hp2_low_speed_blend_for_wheel(wheel))
	var biased_force = local_force
	var power_bias_active = biased_force.x > 0.0 and not wheel.hp2_lock_active
	if power_bias_active:
		biased_force.x *= HP2_TIRE_POWER_BIAS
	var force_magnitude = biased_force.length()
	if combined_force_limit <= HP2_TIRE_MIN_FORCE_EPSILON:
		wheel.hp2_force_saturation = 1.0
		if power_bias_active:
			biased_force.x /= HP2_TIRE_POWER_BIAS
		return biased_force
	wheel.hp2_force_saturation = minf(force_magnitude / combined_force_limit, 1.0)
	if force_magnitude <= combined_force_limit or force_magnitude <= HP2_TIRE_MIN_FORCE_EPSILON:
		if power_bias_active:
			biased_force.x /= HP2_TIRE_POWER_BIAS
		return biased_force
	return biased_force * (combined_force_limit / force_magnitude)


func _hp2_wheel_is_sliding(wheel, longitudinal_slip: float) -> bool:
	if wheel.hp2_lock_active:
		return true
	var low_speed_blend = _hp2_low_speed_blend_for_wheel(wheel)
	var longitudinal_threshold = lerpf(HP2_TIRE_LOW_SPEED_SLIDE_LONG_SLIP, HP2_TIRE_MIN_LONG_SLIP, low_speed_blend)
	if longitudinal_threshold < absf(longitudinal_slip):
		return true
	return _hp2_tire_slip_angle_threshold_deg_for_wheel(wheel) < wheel.hp2_local_slip_angle_deg


func _hp2_local_velocity_slip_angle_deg(wheel) -> float:
	if wheel.forward_speed == 0.0 and wheel.lateral_speed == 0.0:
		return 0.0
	var forward_abs = absf(wheel.forward_speed)
	var raw_angle_deg = absf(rad_to_deg(atan2(wheel.lateral_speed, maxf(forward_abs, 0.001))))
	return raw_angle_deg * _hp2_low_speed_blend_for_wheel(wheel)


func _hp2_low_speed_blend_for_wheel(wheel) -> float:
	var planar_speed = sqrt(wheel.forward_speed * wheel.forward_speed + wheel.lateral_speed * wheel.lateral_speed)
	return clampf(planar_speed / HP2_TIRE_LOW_SPEED_SLIP_BLEND_MPS, 0.0, 1.0)


func _hp2_tire_slip_angle_threshold_deg_for_wheel(wheel) -> float:
	if wheel.is_front():
		return config.hp2_front_tire_0x1a0
	return config.hp2_rear_tire_0x1c0


func _update_hp2_wheel_lock_state(wheel, slide_force_limit: float, slip_vector: Vector2, speed_scaled: float) -> void:
	var slip_length = slip_vector.length()
	var longitudinal_contact_force = 0.0
	if HP2_TIRE_MIN_FORCE_EPSILON < slide_force_limit and HP2_TIRE_MIN_FORCE_EPSILON < slip_length:
		longitudinal_contact_force = absf(wheel.forward_speed) * (slide_force_limit / slip_length)
	var service_term = HP2_WHEEL_SPIN_SERVICE_SCALE * _hp2_service_brake_scale(wheel.slot_id) * config.hp2_row_0x304 * _brake_input
	var handbrake_term = HP2_WHEEL_SPIN_HANDBRAKE_SCALE * _hp2_handbrake_wheel_signal(wheel.slot_id, speed_scaled) * config.hp2_row_0x308
	var lock_threshold = (service_term + handbrake_term) * HP2_TIRE_LOCK_SCALE
	if lock_threshold <= longitudinal_contact_force * wheel.wheel_radius + absf(wheel.angular_speed) * HP2_TIRE_LOCK_ANGULAR_SPEED_BIAS:
		wheel.hp2_lock_active = false
		return
	wheel.hp2_lock_active = lock_threshold > 1.0
	if wheel.hp2_lock_active:
		wheel.angular_speed = 0.0


func _drag_force_ps2(flat_velocity_ps2: Vector3, speed_mps: float) -> Vector3:
	if speed_mps <= 0.001:
		return Vector3.ZERO
	var rolling_force = flat_velocity_ps2.normalized() * -config.rolling_resistance * config.mass_kg * GRAVITY_MPS2
	var aero_force = flat_velocity_ps2.normalized() * -config.aero_drag * speed_mps * speed_mps * config.mass_kg
	return rolling_force + aero_force


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


func _hp2_service_brake_scale(slot_id: String) -> float:
	return float(HP2_SERVICE_BRAKE_SCALE.get(slot_id, 1.0))


func _hp2_handbrake_scale(slot_id: String) -> float:
	return float(HP2_HANDBRAKE_SCALE.get(slot_id, 0.0))


func _hp2_tire_slide_force_scale_for_wheel(wheel) -> float:
	if wheel.is_front():
		return config.hp2_front_tire_0x1b0
	return config.hp2_rear_tire_0x1d0


func _hp2_tire_lateral_response_scale_for_wheel(wheel) -> float:
	var response_scale := 0.0
	var fallback_scale := _hp2_tire_combined_force_scale_for_wheel(wheel)
	if wheel.is_front():
		response_scale = config.hp2_front_tire_0x1a8
	else:
		response_scale = config.hp2_rear_tire_0x1c8
	if absf(response_scale) <= HP2_TIRE_MIN_FORCE_EPSILON:
		return fallback_scale
	return response_scale


func _hp2_tire_combined_force_scale_for_wheel(wheel) -> float:
	if wheel.is_front():
		return config.hp2_front_tire_0x1ac
	return config.hp2_rear_tire_0x1cc


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
			"hp2_spin_accumulator": wheel.hp2_spin_accumulator,
			"hp2_lock_active": wheel.hp2_lock_active,
			"hp2_pair_force_scale": wheel.hp2_pair_force_scale,
			"hp2_longitudinal_slip": wheel.hp2_longitudinal_slip,
			"hp2_local_slip_angle_deg": wheel.hp2_local_slip_angle_deg,
			"hp2_force_saturation": wheel.hp2_force_saturation,
			"hp2_is_sliding": wheel.hp2_is_sliding,
		})

	_debug_snapshot = {
		"speed_kph": _horizontal_ps2(_godot_to_ps2(linear_velocity)).length() * 3.6,
		"rpm": engine_rpm,
		"gear": current_gear,
		"slip_angle_deg": rad_to_deg(signed_slip_angle),
		"hp2_force_limit_scale": _hp2_force_limit_scale,
		"hp2_handbrake_stability_blend": _hp2_handbrake_stability_blend,
		"hp2_state_39c": _hp2_state_39c,
		"hp2_state_3a4": _hp2_state_3a4,
		"hp2_state_3a8": _hp2_state_3a8,
		"hp2_state_3ac": _hp2_state_3ac,
		"hp2_state_3b0": _hp2_state_3b0,
		"wheels": wheel_rows,
	}


func _ensure_generated_visuals() -> void:
	_visual_rig.ensure_generated_visuals(config, wheels)


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
	_visual_rig.update_from_wheels(wheels)


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
	var debug_pivot_nodes = _visual_rig.debug_pivot_nodes
	for slot_id in debug_pivot_nodes.keys():
		var pivot_node: Node3D = debug_pivot_nodes[slot_id]
		if not _is_live_node3d(pivot_node):
			debug_pivot_nodes.erase(slot_id)
			continue
		var pivot_position = _debug_local_from_global(pivot_node.global_position)
		_add_cross_marker(pivot_position, 0.12, Color(1.0, 0.35, 0.15, 1.0))
		_add_circle_marker(pivot_position, 0.18, _debug_local_direction_global((pivot_node.global_basis * pivot_basis.y).normalized()), Color(1.0, 0.55, 0.15, 1.0))
		_add_axis_marker(pivot_position, _debug_local_basis(pivot_node.global_basis * pivot_basis), 0.22)
	var debug_dummy_nodes = _visual_rig.debug_dummy_nodes
	for dummy_name in debug_dummy_nodes.keys():
		var dummy_node: Node3D = debug_dummy_nodes[dummy_name]
		if not _is_live_node3d(dummy_node):
			debug_dummy_nodes.erase(dummy_name)
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
	collision_shape.position = _ps2_to_godot(Vector3(0.0, 0.0, config.body_size_ps2.z * 0.5) - config.physics_origin_offset_ps2)


func _fit_collision_shape_to_visual_bounds() -> void:
	_visual_rig.fit_collision_shape_to_visual_bounds()


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
