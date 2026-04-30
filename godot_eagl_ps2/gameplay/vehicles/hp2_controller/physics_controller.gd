class_name HP2PhysicsController
extends RigidBody3D


const HP2WheelScript = preload("res://gameplay/vehicles/hp2_controller/wheel.gd")
const HP2EngineScript = preload("res://gameplay/vehicles/hp2_controller/engine.gd")
const HP2DrivetrainScript = preload("res://gameplay/vehicles/hp2_controller/drivetrain.gd")
const HP2SteeringSystemScript = preload("res://gameplay/vehicles/hp2_controller/steering_system.gd")
const HP2AssistScript = preload("res://gameplay/vehicles/hp2_controller/hp2_assist.gd")
const HP2PlayerInputScript = preload("res://gameplay/vehicles/hp2_controller/player_input.gd")
const VehicleBodyConfigAdapter = preload("res://eagl/handling/vehicle_body_config_adapter.gd")

const SLOT_IDS := ["FL", "FR", "RL", "RR"]
const SURFACE_TABLE := {
	"asphalt": 1.0,
	"dirt": 0.7,
	"grass": 0.5,
	"gravel": 0.6,
	"ice": 0.2,
}
const GRAVITY := 9.81
const MIN_SIDESLIP_SPEED_MS := 5.0 / 3.6

@export_group("Planar Body")
@export var vehicle_mass_kg := 1450.0
@export var inertia_yaw := 2200.0
@export var wheelbase := 2.60
@export var track_front := 1.60
@export var track_rear := 1.58
@export var cg_height := 0.42
@export_range(0.0, 1.0) var front_weight_bias := 0.58
@export var wheel_radius := 0.32
@export var ride_height := 0.35

@export_group("Tire And Surface")
@export var base_mu := 1.0
@export_enum("asphalt", "dirt", "grass", "gravel", "ice") var surface_type := "asphalt"
@export var front_wheel_grip_scale := 1.0
@export var rear_wheel_grip_scale := 1.0
@export var longitudinal_stiffness := 6000.0
@export var lateral_stiffness := 6500.0
@export var brake_torque_total := 4200.0
@export_range(0.0, 1.0) var brake_bias_front := 0.65
@export var rolling_resistance := 0.035
@export var aero_drag := 0.42

@export_group("HP2 Validation Controls")
@export var weight_transfer_coeff := 0.64
@export var substeps := 4
@export var yaw_damping := 95.0
@export var auto_simulate := true
@export var visual_spin_scale := 1.0

@export var config = null
@export var draw_debug := false

var input_source = null
var engine = HP2EngineScript.new()
var drivetrain = HP2DrivetrainScript.new()
var steering_system = HP2SteeringSystemScript.new()
var assist = HP2AssistScript.new()
var wheels: Dictionary = {}

var sim_time := 0.0
var speed_ms := 0.0
var speed_kmh := 0.0
var sideslip_deg := 0.0
var accel_long := 0.0
var current_gear := 1
var shift_cut_active := false
var surface_mu := 1.0
var airborne_debug_enabled := false

var _pos_x := 0.0
var _pos_z := 0.0
var _display_y := 0.35
var _vertical_velocity := 0.0
var _heading := 0.0
var _vx := 0.0
var _vz := 0.0
var _yaw_rate := 0.0
var _last_forward_speed := 0.0
var _last_inputs := {
	"throttle": 0.0,
	"brake": 0.0,
	"steer": 0.0,
}
var _visual_root: Node3D
var _wheel_pivots: Dictionary = {}
var _wheel_suspension_nodes: Dictionary = {}
var _wheel_steer_nodes: Dictionary = {}
var _wheel_spin_nodes: Dictionary = {}
var _wheel_spin_angles: Dictionary = {}


func _ready() -> void:
	_visual_root = get_node_or_null("VisualRoot") as Node3D
	if _visual_root != null:
		_visual_root.transform = Transform3D(VehicleBodyConfigAdapter.visual_anchor_basis(), Vector3.ZERO)
	freeze = true
	if config != null:
		apply_config(config)
	mass = vehicle_mass_kg
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3.ZERO
	drivetrain.engine = engine
	_rebuild_wheels()
	if input_source == null:
		input_source = HP2PlayerInputScript.new()
	_sync_state_from_transform(global_transform)
	_apply_state_to_body()
	_refresh_visual_bindings()


func _process(delta: float) -> void:
	_update_visuals(delta)


func apply_config(new_config) -> void:
	if new_config == null:
		return
	config = new_config
	vehicle_mass_kg = float(config.mass_kg)
	inertia_yaw = maxf(vehicle_mass_kg * wheelbase * wheelbase * 0.33, 1.0)
	if config.has_method("wheelbase_meters"):
		wheelbase = float(config.wheelbase_meters())
		inertia_yaw = maxf(vehicle_mass_kg * wheelbase * wheelbase * 0.33, 1.0)
	if config.has_method("front_axle_center_x") and config.has_method("rear_axle_center_x"):
		front_weight_bias = _front_load_bias_from_config(config)
	var configured_positions = config.get("wheel_local_positions_ps2")
	if configured_positions != null and configured_positions.size() >= 4:
		var positions: Array = configured_positions
		track_front = absf(float(positions[0].y) - float(positions[1].y))
		track_rear = absf(float(positions[2].y) - float(positions[3].y))
	var configured_radii = config.get("wheel_radii")
	if configured_radii != null and not configured_radii.is_empty():
		var radius_total := 0.0
		for radius in configured_radii:
			radius_total += float(radius)
		wheel_radius = radius_total / float(configured_radii.size())
	_apply_handling_profile_params(config)
	mass = vehicle_mass_kg
	_rebuild_wheels()
	_update_derived_state()


func _apply_handling_profile_params(source_config) -> void:
	engine.idle_rpm = float(source_config.idle_rpm)
	engine.peak_rpm = float(source_config.engine_peak_rpm)
	engine.max_rpm = float(source_config.engine_redline_rpm)
	engine.rpm = engine.idle_rpm
	drivetrain.final_drive = float(source_config.final_drive_ratio)
	var ratios: Array[float] = [float(source_config.reverse_gear_ratio)]
	for ratio in source_config.forward_gears:
		ratios.append(float(ratio))
	if ratios.size() > 1:
		drivetrain.gear_ratios = PackedFloat32Array(ratios)
	drivetrain.upshift_rpm = minf(float(source_config.shift_up_rpm), float(source_config.engine_peak_rpm) * 0.98)
	drivetrain.downshift_rpm = float(source_config.shift_down_rpm)
	steering_system.steering_response_rate = maxf(float(source_config.steering_response), 0.1)
	steering_system.max_steer_degrees = float(source_config.steering_max_degrees) * float(source_config.steering_lock_scale)
	var average_long_grip := (float(source_config.front_longitudinal_grip) + float(source_config.rear_longitudinal_grip)) * 0.5
	var average_lat_grip := (float(source_config.front_lateral_grip) + float(source_config.rear_lateral_grip)) * 0.5
	base_mu = maxf((average_long_grip + average_lat_grip) * 0.5, 0.1)
	longitudinal_stiffness = 6000.0 * maxf(average_long_grip, 0.1)
	lateral_stiffness = 6500.0 * maxf(average_lat_grip, 0.1)
	brake_torque_total = maxf(float(source_config.brake_force) * wheel_radius, 1.0)
	front_wheel_grip_scale = maxf((float(source_config.front_longitudinal_grip) + float(source_config.front_lateral_grip)) * 0.5, 0.1)
	rear_wheel_grip_scale = maxf((float(source_config.rear_longitudinal_grip) + float(source_config.rear_lateral_grip)) * 0.5, 0.1)
	rolling_resistance = maxf(float(source_config.rolling_resistance), 0.0)
	aero_drag = maxf(float(source_config.aero_drag) * vehicle_mass_kg, 0.0)
	yaw_damping = maxf(float(source_config.yaw_damping) * 55.0, 1.0)
	assist.sideslip_threshold_deg = float(source_config.stabilization_slip_deg)


func get_reference_params() -> Dictionary:
	return {
		"car_name": String(config.car_name) if config != null else "HP2 Car",
		"row_index": int(config.row_index) if config != null else -1,
		"duplicate_index": int(config.duplicate_index) if config != null else 1,
		"drive_type": String(config.drive_type) if config != null else "RWD",
		"handling_profile_id": int(config.globalb_handling_profile_id) if config != null else -1,
		"handling_profile_sequence": Array(config.globalb_handling_profile_sequence) if config != null else [],
		"mass": vehicle_mass_kg,
		"inertia_yaw": inertia_yaw,
		"wheelbase": wheelbase,
		"track_front": track_front,
		"track_rear": track_rear,
		"cg_height": cg_height,
		"front_weight_bias": front_weight_bias,
		"wheel_radius": wheel_radius,
		"base_mu": base_mu,
		"front_wheel_grip_scale": front_wheel_grip_scale,
		"rear_wheel_grip_scale": rear_wheel_grip_scale,
		"longitudinal_stiffness": longitudinal_stiffness,
		"lateral_stiffness": lateral_stiffness,
		"brake_torque_total": brake_torque_total,
		"brake_bias_front": brake_bias_front,
		"rolling_resistance": rolling_resistance,
		"aero_drag": aero_drag,
		"weight_transfer_coeff": weight_transfer_coeff,
		"yaw_damping": yaw_damping,
		"final_drive": drivetrain.final_drive,
		"gear_ratios": Array(drivetrain.gear_ratios),
		"upshift_rpm": drivetrain.upshift_rpm,
		"downshift_rpm": drivetrain.downshift_rpm,
		"idle_rpm": engine.idle_rpm,
		"peak_rpm": engine.peak_rpm,
		"max_rpm": engine.max_rpm,
		"steering_response_rate": steering_system.steering_response_rate,
		"max_steer_degrees": steering_system.max_steer_degrees,
		"assist_sideslip_threshold_deg": assist.sideslip_threshold_deg,
	}


func _front_load_bias_from_config(source_config) -> float:
	var load_origin_x: float = source_config.physics_origin_offset_ps2.x
	if absf(load_origin_x) <= 0.0001:
		load_origin_x = source_config.center_of_mass_ps2.x
	var front_x: float = source_config.front_axle_center_x() - load_origin_x
	var rear_x: float = source_config.rear_axle_center_x() - load_origin_x
	var denom: float = front_x - rear_x
	if absf(denom) <= 0.0001:
		return front_weight_bias
	var rear_each_fraction: float = (front_x / denom) * 0.5
	var front_each_fraction: float = 0.5 - rear_each_fraction
	return clampf(front_each_fraction * 2.0, 0.25, 0.75)


func replace_visual(visual: Node3D) -> void:
	if _visual_root == null:
		_visual_root = get_node_or_null("VisualRoot") as Node3D
	if _visual_root == null:
		return
	var existing := _visual_root.get_node_or_null("CarVisual")
	if existing != null:
		_visual_root.remove_child(existing)
		existing.queue_free()
	if visual == null:
		return
	if visual.get_parent() != null:
		visual.get_parent().remove_child(visual)
	visual.name = "CarVisual"
	_visual_root.add_child(visual)
	_refresh_visual_bindings()


func sync_wheel_slots_from_visual() -> void:
	_refresh_visual_bindings()
	_update_visuals(0.0)


func set_debug_overlay_enabled(enabled: bool) -> void:
	draw_debug = enabled


func set_airborne_debug_enabled(enabled: bool, airborne_height: float) -> void:
	airborne_debug_enabled = enabled
	_vx = 0.0
	_vz = 0.0
	_yaw_rate = 0.0
	_vertical_velocity = 0.0
	_display_y = airborne_height if enabled else ride_height
	_apply_state_to_body()


func set_forward_speed(speed_mps: float) -> void:
	var forward := _forward_vector(_heading)
	_vx = forward.x * speed_mps
	_vz = forward.y * speed_mps
	_last_forward_speed = speed_mps
	_update_derived_state()
	_apply_state_to_body()


func _physics_process(delta: float) -> void:
	if not auto_simulate:
		return
	var throttle: float = input_source.get_throttle() if input_source != null else 0.0
	var brake: float = input_source.get_brake() if input_source != null else 0.0
	var steer: float = input_source.get_steer() if input_source != null else 0.0
	if airborne_debug_enabled and _is_airborne():
		simulate_airborne(delta, throttle, brake, steer)
		return
	simulate(delta, throttle, brake, steer)


func simulate(delta: float, throttle: float, brake: float, steer: float) -> void:
	_last_inputs = {
		"throttle": clampf(throttle, 0.0, 1.0),
		"brake": clampf(brake, 0.0, 1.0),
		"steer": clampf(steer, -1.0, 1.0),
	}
	var step_count := maxi(substeps, 1)
	var step_delta := delta / float(step_count)
	for _index in range(step_count):
		_substep(step_delta, float(_last_inputs["throttle"]), float(_last_inputs["brake"]), float(_last_inputs["steer"]))
	sim_time += delta
	_update_derived_state()
	_apply_state_to_body()


func simulate_airborne(delta: float, throttle: float, brake: float, steer: float) -> void:
	_last_inputs = {
		"throttle": clampf(throttle, 0.0, 1.0),
		"brake": clampf(brake, 0.0, 1.0),
		"steer": clampf(steer, -1.0, 1.0),
	}
	var step_count := maxi(substeps, 1)
	var step_delta := delta / float(step_count)
	for _index in range(step_count):
		_airborne_substep(step_delta, float(_last_inputs["throttle"]), float(_last_inputs["brake"]), float(_last_inputs["steer"]))
	sim_time += delta
	_update_derived_state()
	_apply_state_to_body()


func reset_runtime_state(target_transform: Transform3D = Transform3D.IDENTITY) -> void:
	var resolved_transform := target_transform
	if resolved_transform == Transform3D.IDENTITY:
		resolved_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, ride_height, 0.0))
	_sync_state_from_transform(resolved_transform)
	_vx = 0.0
	_vz = 0.0
	_yaw_rate = 0.0
	_vertical_velocity = 0.0
	sim_time = 0.0
	accel_long = 0.0
	_last_forward_speed = 0.0
	engine.reset_runtime()
	drivetrain.reset_runtime()
	steering_system.reset_runtime()
	assist.reset_runtime()
	for wheel in wheels.values():
		wheel.reset_runtime()
	_update_derived_state()
	_apply_state_to_body()


func get_debug_snapshot() -> Dictionary:
	var wheel_rows: Array[Dictionary] = []
	for slot_id in SLOT_IDS:
		var wheel = wheels.get(slot_id, null)
		if wheel == null:
			continue
		wheel_rows.append({
			"slot": slot_id,
			"grounded": true,
			"rpm": wheel.angular_velocity * 60.0 / TAU,
			"skid": wheel.grip_utilization,
			"steering_deg": rad_to_deg(wheel.steer_angle),
			"engine_force": wheel.force_long,
			"brake_force": wheel.brake_torque,
			"load": wheel.normal_load,
			"grip": wheel.grip_utilization,
			"slip_long": wheel.slip_long,
			"slip_lat": wheel.slip_lat,
			"force_long": wheel.force_long,
			"force_lat": wheel.force_lat,
			"drive_torque": wheel.drive_torque,
			"brake_torque": wheel.brake_torque,
			"angular_velocity": wheel.angular_velocity,
		})
	return {
		"speed_kmh": speed_kmh,
		"speed_ms": speed_ms,
		"rpm": engine.rpm,
		"gear": drivetrain.current_gear,
		"slip_angle_deg": sideslip_deg,
		"steering_deg": rad_to_deg(steering_system.current_angle()),
		"mass_kg": vehicle_mass_kg,
		"mass_is_estimate": false,
		"driven_wheel_count": 2,
		"engine_force_gain": 1.0,
		"hp2_launch_accel_reference": accel_long,
		"drag_force": aero_drag * speed_ms * speed_ms,
		"engine_force_total": wheels["RL"].force_long + wheels["RR"].force_long,
		"engine_brake_total": wheels["FL"].brake_torque + wheels["FR"].brake_torque + wheels["RL"].brake_torque + wheels["RR"].brake_torque,
		"yaw_rate": rad_to_deg(_yaw_rate),
		"sideslip": sideslip_deg,
		"heading": rad_to_deg(_heading),
		"accel_long": accel_long,
		"surface_type": surface_type,
		"surface_mu": surface_mu,
		"assist_wheel": assist.active_wheel,
		"inputs": _last_inputs.duplicate(),
		"wheels": wheel_rows,
	}


func get_telemetry_row() -> Dictionary:
	return {
		"t": sim_time,
		"speed_kmh": speed_kmh,
		"speed_ms": speed_ms,
		"yaw_rate": rad_to_deg(_yaw_rate),
		"sideslip": sideslip_deg,
		"heading": rad_to_deg(_heading),
		"vx": _vx,
		"vy": _vz,
		"pos_x": _pos_x,
		"pos_y": _pos_z,
		"accel_long": accel_long,
		"rpm": engine.rpm,
		"gear": drivetrain.current_gear,
		"shift_cut": 1 if engine.shift_cut_active else 0,
		"grip_FL": _wheel_value("FL", "grip_utilization"),
		"grip_FR": _wheel_value("FR", "grip_utilization"),
		"grip_RL": _wheel_value("RL", "grip_utilization"),
		"grip_RR": _wheel_value("RR", "grip_utilization"),
		"load_FL": _wheel_value("FL", "normal_load"),
		"load_FR": _wheel_value("FR", "normal_load"),
		"load_RL": _wheel_value("RL", "normal_load"),
		"load_RR": _wheel_value("RR", "normal_load"),
		"surface_type": surface_type,
		"surface_mu": surface_mu,
	}


func _substep(delta: float, throttle: float, brake: float, steer: float) -> void:
	surface_mu = base_mu * float(SURFACE_TABLE.get(surface_type, 1.0))
	var steer_angle := steering_system.update(steer, delta)
	var steer_angles := _ackermann_angles(steer_angle)
	var forward := _forward_vector(_heading)
	var right := _right_vector(_heading)
	var forward_speed := Vector2(_vx, _vz).dot(forward)

	engine.update(delta, _average_rear_wheel_angular_velocity(), drivetrain.effective_ratio())
	_update_auto_shift(delta)

	var loads := _compute_normal_loads(accel_long)
	var drive_torques := drivetrain.calculate_rear_wheel_torques(throttle, float(loads["RL"]), float(loads["RR"]))
	for slot_id in SLOT_IDS:
		var wheel = wheels[slot_id]
		wheel.normal_load = float(loads[slot_id])
		wheel.surface_mu = surface_mu
		wheel.grip_scale = _wheel_grip_scale(slot_id)
		wheel.drive_torque = float(drive_torques[slot_id])
		wheel.brake_torque = _brake_torque_for_slot(slot_id, brake)
		wheel.steer_angle = float(steer_angles.get(slot_id, 0.0))

	sideslip_deg = _compute_sideslip()
	assist.apply(wheels, speed_kmh, sideslip_deg)

	var total_force := Vector2.ZERO
	var yaw_torque := 0.0
	for slot_id in SLOT_IDS:
		var wheel = wheels[slot_id]
		var local_pos: Vector2 = wheel.local_position
		var world_pos := right * local_pos.x + forward * local_pos.y
		var wheel_velocity := Vector2(_vx + _yaw_rate * world_pos.y, _vz - _yaw_rate * world_pos.x)
		var wheel_heading: float = _heading + wheel.steer_angle
		var wheel_forward := _forward_vector(wheel_heading)
		var wheel_right := _right_vector(wheel_heading)
		var v_long := wheel_velocity.dot(wheel_forward)
		var v_lat := wheel_velocity.dot(wheel_right)
		var brake_direction := signf(v_long)
		if brake_direction == 0.0:
			brake_direction = signf(wheel.angular_velocity)
		var drive_force_request: float = wheel.drive_torque / maxf(wheel.wheel_radius, 0.0001)
		var brake_force_request: float = wheel.brake_torque / maxf(wheel.wheel_radius, 0.0001) * brake_direction

		wheel.compute_contact_forces(
			drive_force_request - brake_force_request - v_long * longitudinal_stiffness * 0.02,
			v_lat * lateral_stiffness
		)
		wheel.update_angular_velocity(delta, v_long)

		var force_world: Vector2 = wheel_forward * wheel.force_long + wheel_right * wheel.force_lat
		total_force += force_world
		yaw_torque += world_pos.y * force_world.x - world_pos.x * force_world.y

	if speed_ms > 0.01:
		var drag_magnitude := aero_drag * speed_ms * speed_ms + rolling_resistance * vehicle_mass_kg * GRAVITY
		total_force -= Vector2(_vx, _vz).normalized() * drag_magnitude

	var acceleration := total_force / maxf(vehicle_mass_kg, 1.0)
	_vx += acceleration.x * delta
	_vz += acceleration.y * delta
	_yaw_rate += ((yaw_torque - yaw_damping * _yaw_rate) / maxf(inertia_yaw, 1.0)) * delta
	_heading = wrapf(_heading + _yaw_rate * delta, -PI, PI)
	_pos_x += _vx * delta
	_pos_z += _vz * delta

	var new_forward_speed := Vector2(_vx, _vz).dot(_forward_vector(_heading))
	accel_long = (new_forward_speed - _last_forward_speed) / maxf(delta, 0.0001)
	_last_forward_speed = new_forward_speed
	_update_derived_state()


func _airborne_substep(delta: float, throttle: float, brake: float, steer: float) -> void:
	surface_mu = base_mu * float(SURFACE_TABLE.get(surface_type, 1.0))
	var steer_angle := steering_system.update(steer, delta)
	var steer_angles := _ackermann_angles(steer_angle)
	engine.update(delta, _average_rear_wheel_angular_velocity(), drivetrain.effective_ratio())
	_update_auto_shift(delta)
	var drive_torques := drivetrain.calculate_rear_wheel_torques(throttle, 1.0, 1.0) if throttle > 0.001 else {
		"FL": 0.0,
		"FR": 0.0,
		"RL": 0.0,
		"RR": 0.0,
	}
	for slot_id in SLOT_IDS:
		var wheel = wheels[slot_id]
		wheel.normal_load = 0.0
		wheel.surface_mu = surface_mu
		wheel.grip_scale = _wheel_grip_scale(slot_id)
		wheel.drive_torque = float(drive_torques[slot_id])
		wheel.brake_torque = _brake_torque_for_slot(slot_id, brake)
		wheel.steer_angle = float(steer_angles.get(slot_id, 0.0))
		wheel.compute_contact_forces(0.0, 0.0)
		wheel.update_airborne_angular_velocity(delta)
	_apply_vertical_gravity(delta)


func _rebuild_wheels() -> void:
	wheels.clear()
	var front_z := wheelbase * (1.0 - front_weight_bias)
	var rear_z := -wheelbase * front_weight_bias
	var positions := {
		"FL": Vector2(-track_front * 0.5, front_z),
		"FR": Vector2(track_front * 0.5, front_z),
		"RL": Vector2(-track_rear * 0.5, rear_z),
		"RR": Vector2(track_rear * 0.5, rear_z),
	}
	for slot_id in SLOT_IDS:
		var wheel = HP2WheelScript.new()
		wheel.slot_id = slot_id
		wheel.local_position = positions[slot_id]
		wheel.wheel_radius = wheel_radius
		wheels[slot_id] = wheel
		_wheel_spin_angles[slot_id] = 0.0


func _ackermann_angles(center_angle: float) -> Dictionary:
	if absf(center_angle) < 0.0001:
		return {
			"FL": 0.0,
			"FR": 0.0,
			"RL": 0.0,
			"RR": 0.0,
		}
	var sign := signf(center_angle)
	var turn_radius := wheelbase / maxf(tan(absf(center_angle)), 0.0001)
	var inner := atan(wheelbase / maxf(turn_radius - track_front * 0.5, 0.0001)) * sign
	var outer := atan(wheelbase / (turn_radius + track_front * 0.5)) * sign
	if center_angle > 0.0:
		return {
			"FL": outer,
			"FR": inner,
			"RL": 0.0,
			"RR": 0.0,
		}
	return {
		"FL": inner,
		"FR": outer,
		"RL": 0.0,
		"RR": 0.0,
	}


func _compute_normal_loads(longitudinal_acceleration: float) -> Dictionary:
	var base_front := vehicle_mass_kg * GRAVITY * front_weight_bias
	var base_rear := vehicle_mass_kg * GRAVITY * (1.0 - front_weight_bias)
	var transfer := vehicle_mass_kg * longitudinal_acceleration * cg_height / maxf(wheelbase, 0.0001) * weight_transfer_coeff
	var front := maxf(base_front - transfer, 0.0)
	var rear := maxf(base_rear + transfer, 0.0)
	return {
		"FL": front * 0.5,
		"FR": front * 0.5,
		"RL": rear * 0.5,
		"RR": rear * 0.5,
	}


func _brake_torque_for_slot(slot_id: String, brake: float) -> float:
	if slot_id in ["FL", "FR"]:
		return brake * brake_torque_total * brake_bias_front * 0.5
	return brake * brake_torque_total * (1.0 - brake_bias_front) * 0.5


func _wheel_grip_scale(slot_id: String) -> float:
	return front_wheel_grip_scale if slot_id in ["FL", "FR"] else rear_wheel_grip_scale


func _update_auto_shift(delta: float) -> void:
	drivetrain.auto_shift_timer += delta
	if drivetrain.auto_shift_timer < drivetrain.min_shift_interval:
		return
	if engine.rpm > drivetrain.upshift_rpm and drivetrain.current_gear < drivetrain.gear_ratios.size() - 1:
		drivetrain.current_gear += 1
		engine.trigger_shift_cut()
		drivetrain.auto_shift_timer = 0.0
	elif engine.rpm < drivetrain.downshift_rpm and drivetrain.current_gear > 1 and speed_kmh < 25.0:
		drivetrain.current_gear -= 1
		drivetrain.auto_shift_timer = 0.0


func _update_derived_state() -> void:
	speed_ms = Vector2(_vx, _vz).length()
	speed_kmh = speed_ms * 3.6
	sideslip_deg = _compute_sideslip()
	current_gear = drivetrain.current_gear
	shift_cut_active = engine.shift_cut_active


func _compute_sideslip() -> float:
	if speed_ms < MIN_SIDESLIP_SPEED_MS:
		return 0.0
	var velocity_heading := atan2(_vx, _vz)
	return rad_to_deg(wrapf(velocity_heading - _heading, -PI, PI))


func _average_rear_wheel_angular_velocity() -> float:
	var rl = wheels.get("RL", null)
	var rr = wheels.get("RR", null)
	if rl == null or rr == null:
		return 0.0
	return (rl.angular_velocity + rr.angular_velocity) * 0.5


func _wheel_value(slot_id: String, property_name: String) -> float:
	var wheel = wheels.get(slot_id, null)
	if wheel == null:
		return 0.0
	return float(wheel.get(property_name))


func _forward_vector(angle: float) -> Vector2:
	return Vector2(sin(angle), cos(angle))


func _right_vector(angle: float) -> Vector2:
	return Vector2(cos(angle), -sin(angle))


func _sync_state_from_transform(source_transform: Transform3D) -> void:
	var origin := source_transform.origin
	_pos_x = origin.x
	_pos_z = origin.z
	_display_y = origin.y
	_vertical_velocity = 0.0
	_heading = source_transform.basis.get_euler().y


func _apply_state_to_body() -> void:
	global_position = Vector3(_pos_x, _display_y, _pos_z)
	global_rotation = Vector3(0.0, _heading, 0.0)
	linear_velocity = Vector3(_vx, 0.0, _vz)
	angular_velocity = Vector3(0.0, _yaw_rate, 0.0)


func _is_airborne() -> bool:
	return _display_y > ride_height + 0.001


func _apply_vertical_gravity(delta: float) -> void:
	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", GRAVITY))
	_vertical_velocity -= gravity * delta
	_display_y += _vertical_velocity * delta
	if _display_y <= ride_height:
		_display_y = ride_height
		_vertical_velocity = 0.0


func _refresh_visual_bindings() -> void:
	_wheel_pivots.clear()
	_wheel_suspension_nodes.clear()
	_wheel_steer_nodes.clear()
	_wheel_spin_nodes.clear()
	if _visual_root == null:
		return
	var car_visual := _visual_root.get_node_or_null("CarVisual") as Node3D
	if car_visual == null:
		return
	for slot_id in SLOT_IDS:
		var pivot_node := car_visual.get_node_or_null("WheelPivots/%s" % slot_id) as Node3D
		if pivot_node != null:
			_wheel_pivots[slot_id] = pivot_node
		var suspension_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension" % slot_id) as Node3D
		if suspension_node != null:
			_wheel_suspension_nodes[slot_id] = suspension_node
		var steer_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer" % slot_id) as Node3D
		if steer_node != null:
			_wheel_steer_nodes[slot_id] = steer_node
		var spin_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll/Spin" % slot_id) as Node3D
		if spin_node == null:
			spin_node = car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll" % slot_id) as Node3D
		if spin_node != null:
			_wheel_spin_nodes[slot_id] = spin_node


func _update_visuals(delta: float) -> void:
	for slot_id in SLOT_IDS:
		var wheel = wheels.get(slot_id, null)
		if wheel == null:
			continue
		var steer_node := _wheel_steer_nodes.get(slot_id, null) as Node3D
		if steer_node != null:
			var steer_rotation := steer_node.rotation
			steer_rotation.y = -wheel.steer_angle
			steer_node.rotation = steer_rotation
		var spin_node := _wheel_spin_nodes.get(slot_id, null) as Node3D
		if spin_node != null:
			_wheel_spin_angles[slot_id] = float(_wheel_spin_angles.get(slot_id, 0.0)) + wheel.angular_velocity * delta * visual_spin_scale
			var spin_rotation := spin_node.rotation
			spin_rotation.x = float(_wheel_spin_angles[slot_id]) * float(spin_node.get_meta("eagl_spin_direction", 1.0))
			spin_node.rotation = spin_rotation
