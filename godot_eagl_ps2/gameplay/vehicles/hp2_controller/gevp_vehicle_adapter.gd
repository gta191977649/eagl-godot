class_name HP2GevpVehicleAdapter
extends Vehicle


const CarConfigScript = preload("res://eagl/handling/car_config.gd")
const VehicleBodyConfigAdapter = preload("res://eagl/handling/vehicle_body_config_adapter.gd")
const MathUtils = preload("res://eagl/utils/math_utils.gd")
const HP2PlayerInputScript = preload("res://gameplay/vehicles/hp2_controller/player_input.gd")

const SLOT_IDS := ["FL", "FR", "RL", "RR"]
const DEMO_BASELINE := "demo_arcade"
const DEMO_ROAD_TIRE_STIFFNESS := 1.0
const DEMO_DIRT_TIRE_STIFFNESS := 0.85
const DEMO_GRASS_TIRE_STIFFNESS := 0.7
const DEMO_ROAD_COF := 1.0
const DEMO_DIRT_COF := 0.72
const DEMO_GRASS_COF := 0.5
const DEMO_ROAD_ROLLING_RESISTANCE := 1.0
const DEMO_DIRT_ROLLING_RESISTANCE := 2.0
const DEMO_GRASS_ROLLING_RESISTANCE := 4.0
const DEMO_ROAD_LATERAL_GRIP_ASSIST := 0.05
const DEMO_LONGITUDINAL_GRIP_RATIO := 0.5
const DEMO_BRAKING_GRIP_MULTIPLIER := 1.1
const DEMO_DAMPING_RATIO := 0.6
const DEMO_STABILITY_YAW_GROUND_MULTIPLIER := 1.35
const DEMO_TRACTION_CONTROL_MAX_SLIP := 0.0

@export var config = null
@export var draw_debug := true
@export_enum("Road", "Dirt", "Grass") var surface_type := "Road"
@export var auto_fit_collision_from_visual := true
@export var drive_area_surface_filter_enabled := true
@export_range(0.0, 1.0) var drive_area_off_surface_friction_scale := 0.25
@export_enum("demo_arcade") var handling_baseline := DEMO_BASELINE

var input_source = null
var surface_sampler = null

var _vehicle_setup := {}
var _debug_snapshot := {}
var _runtime_parameters := {}
var _visual_root: Node3D
var _wheel_nodes := {}
var _wheel_helpers := {}
var _wheel_pivots := {}
var _wheel_suspension_nodes := {}
var _wheel_steer_nodes := {}
var _wheel_roll_nodes := {}
var _wheel_spin_nodes := {}
var _debug_mesh := ImmediateMesh.new()
var _debug_mesh_instance: MeshInstance3D
var _debug_material: StandardMaterial3D


func _ready() -> void:
	_visual_root = get_node_or_null("VisualRoot") as Node3D
	if _visual_root != null:
		_visual_root.transform = Transform3D(VehicleBodyConfigAdapter.gevp_visual_anchor_basis(), Vector3.ZERO)
	surface_type = _normalize_surface_name(surface_type)
	if config == null:
		config = CarConfigScript.new()
	if input_source == null:
		input_source = HP2PlayerInputScript.new()
	_cache_wheel_nodes()
	apply_config(config)
	print("HP2Car controller=GEVP scene=hp2_car.tscn script=%s" % get_script().resource_path)
	_log_runtime_configuration()
	set_debug_overlay_enabled(draw_debug)


func _physics_process(delta: float) -> void:
	_update_inputs()
	super._physics_process(delta)


func _process(delta: float) -> void:
	_sync_visual_wheels_from_helpers()
	if draw_debug:
		_rebuild_debug_mesh()
	_update_debug_snapshot()


func apply_config(new_config) -> void:
	if new_config == null:
		return
	config = new_config
	_vehicle_setup = VehicleBodyConfigAdapter.build_gevp_vehicle_setup(config)
	_cache_wheel_nodes()
	_apply_config_to_vehicle()
	_sync_scene_component_nodes_from_config()
	_reinitialize_vehicle_runtime()
	refresh_visual_bindings()
	_fit_chassis_collision_shape()
	if auto_fit_collision_from_visual:
		_fit_collision_shape_to_visual_bounds()
	_update_debug_snapshot()


func reset_runtime_state(target_transform: Transform3D = Transform3D.IDENTITY) -> void:
	if target_transform == Transform3D.IDENTITY:
		target_transform = transform
	transform = target_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	sleeping = false
	previous_global_position = global_position
	delta_time = 0.0
	current_gear = 1
	requested_gear = 1
	steering_amount = 0.0
	true_steering_amount = 0.0
	steering_exponent_amount = 0.0
	throttle_amount = 0.0
	brake_amount = 0.0
	clutch_amount = 0.0
	torque_output = 0.0
	clutch_torque = 0.0
	handbrake_force = 0.0
	brake_force = 0.0
	motor_rpm = idle_rpm
	for wheel in wheel_array:
		wheel.spin = 0.0
		wheel.force_vector = Vector2.ZERO
		wheel.slip_vector = Vector2.ZERO
		wheel.spring_force = 0.0
		wheel.damping_force = 0.0
		wheel.previous_velocity = Vector3.ZERO
		wheel.previous_global_position = wheel.global_position
		wheel.spring_current_length = wheel.spring_length
		wheel.last_collider = null
	_sync_visual_wheels_from_helpers()
	_update_debug_snapshot()
	if draw_debug:
		_rebuild_debug_mesh()


func replace_visual(visual: Node3D) -> void:
	if _visual_root == null:
		_visual_root = get_node_or_null("VisualRoot") as Node3D
	if _visual_root == null:
		return
	var existing := _visual_root.get_node_or_null("CarVisual") as Node3D
	if existing == null:
		existing = Node3D.new()
		existing.name = "CarVisual"
		_visual_root.add_child(existing)
	_ensure_scene_visual_components(existing)
	_clear_scene_visual_content(existing)
	if visual == null:
		refresh_visual_bindings()
		return
	if visual.get_parent() != null:
		visual.get_parent().remove_child(visual)
	_merge_visual_content_into_scene(visual, existing)
	visual.queue_free()
	refresh_visual_bindings()
	if auto_fit_collision_from_visual:
		_fit_collision_shape_to_visual_bounds()


func sync_wheel_slots_from_visual() -> void:
	var car_visual: Node3D = null
	if _visual_root != null:
		car_visual = _visual_root.get_node_or_null("CarVisual") as Node3D
	if car_visual != null:
		_ensure_scene_visual_components(car_visual)
	refresh_visual_bindings()
	_sync_visual_wheels_from_helpers()
	_update_debug_snapshot()


func refresh_visual_bindings() -> void:
	_wheel_pivots.clear()
	_wheel_suspension_nodes.clear()
	_wheel_steer_nodes.clear()
	_wheel_roll_nodes.clear()
	_wheel_spin_nodes.clear()
	if _visual_root == null:
		return
	var car_visual := _visual_root.get_node_or_null("CarVisual") as Node3D
	if car_visual == null:
		return
	for slot_id in SLOT_IDS:
		var pivot_node := car_visual.get_node_or_null("WheelPivots/%s" % slot_id) as Node3D
		var suspension_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension" % slot_id) as Node3D
		var steer_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer" % slot_id) as Node3D
		var roll_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll" % slot_id) as Node3D
		var spin_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll/Spin" % slot_id) as Node3D
		if pivot_node != null:
			_wheel_pivots[slot_id] = pivot_node
		if suspension_node != null:
			_wheel_suspension_nodes[slot_id] = suspension_node
		if steer_node != null:
			_wheel_steer_nodes[slot_id] = steer_node
		if roll_node != null:
			_wheel_roll_nodes[slot_id] = roll_node
		if spin_node != null:
			_wheel_spin_nodes[slot_id] = spin_node


func set_surface_sampler(sampler) -> void:
	surface_sampler = sampler


func set_debug_overlay_enabled(enabled: bool) -> void:
	draw_debug = enabled
	if draw_debug:
		_ensure_debug_mesh()
		if _debug_mesh_instance != null:
			_debug_mesh_instance.visible = true
			_rebuild_debug_mesh()
	elif _debug_mesh_instance != null:
		_debug_mesh.clear_surfaces()
		_debug_mesh_instance.visible = false


func get_debug_snapshot() -> Dictionary:
	return _debug_snapshot.duplicate(true)


func get_telemetry_row() -> Dictionary:
	var snapshot := get_debug_snapshot()
	var row := {
		"t": delta_time,
		"speed_kmh": float(snapshot.get("speed_kmh", 0.0)),
		"speed_ms": float(snapshot.get("speed_ms", 0.0)),
		"yaw_rate": rad_to_deg(angular_velocity.y),
		"sideslip": float(snapshot.get("slip_angle_deg", 0.0)),
		"heading": rad_to_deg(rotation.y),
		"vx": linear_velocity.x,
		"vy": linear_velocity.z,
		"pos_x": global_position.x,
		"pos_y": global_position.z,
		"accel_long": float(snapshot.get("engine_force_total", 0.0)) / maxf(mass, 1.0),
		"rpm": float(snapshot.get("rpm", 0.0)),
		"gear": int(snapshot.get("gear", 0)),
		"shift_cut": 1 if is_shifting else 0,
		"surface_type": String(snapshot.get("surface_type", "")),
		"surface_mu": float(snapshot.get("surface_mu", 0.0)),
	}
	for slot_id in SLOT_IDS:
		row["grip_%s" % slot_id] = _wheel_snapshot_value(slot_id, "skid")
		row["load_%s" % slot_id] = _wheel_snapshot_value(slot_id, "normal_load")
	return row


func default_wheel_surface_name() -> String:
	return _normalize_surface_name(surface_type)


func get_hp2_body_slip_angle_deg() -> float:
	return _slip_angle_deg()


func get_hp2_grip_solver_name() -> String:
	return "hp2_lambda"


func set_debug_surface_type(new_surface: String) -> void:
	surface_type = _normalize_surface_name(new_surface)
	for wheel in wheel_array:
		if wheel != null and wheel.has_method("_set_surface_profile"):
			wheel.call("_set_surface_profile", surface_type)


func is_driveable_point(world_point: Vector3) -> bool:
	if surface_sampler == null:
		return true
	return bool(surface_sampler.has_driveable_surface(_godot_to_ps2(world_point)))


func _apply_config_to_vehicle() -> void:
	var wheel_positions: Dictionary = _vehicle_wheel_positions_from_config()
	var front_left: Vector3 = wheel_positions["FL"]
	var front_right: Vector3 = wheel_positions["FR"]
	var rear_left: Vector3 = wheel_positions["RL"]
	var rear_right: Vector3 = wheel_positions["RR"]
	front_left_wheel.position = front_left
	front_right_wheel.position = front_right
	rear_left_wheel.position = rear_left
	rear_right_wheel.position = rear_right

	vehicle_mass = float(_vehicle_setup.get("mass", config.mass_kg))
	front_weight_distribution = _front_weight_distribution_from_config(config)
	center_of_gravity_height_offset = _center_of_gravity_height_offset(front_left, front_right, rear_left, rear_right)
	inertia_multiplier = clampf(1.05 + vehicle_mass / 3000.0, 1.0, 1.8)

	steering_speed = maxf(float(config.steering_response), 0.1)
	countersteer_speed = maxf(float(config.steering_return), steering_speed)
	steering_speed_decay = clampf(0.14 + float(config.high_speed_steer_scale) * 0.22, 0.08, 0.28)
	steering_slip_assist = clampf(deg_to_rad(float(config.stabilization_slip_deg)) * 0.45, 0.08, 0.28)
	countersteer_assist = clampf(float(config.steering_yaw_assist) / 1500.0, 0.2, 1.2)
	steering_exponent = 1.35
	max_steering_angle = deg_to_rad(float(config.steering_max_degrees) * float(config.steering_lock_scale))
	front_steering_ratio = 1.0
	rear_steering_ratio = 0.0

	throttle_speed = 14.0 + float(config.steering_response)
	throttle_steering_adjust = 0.12
	braking_speed = 11.0
	brake_force_multiplier = 1.0
	front_brake_bias = clampf(0.54 + (front_weight_distribution - 0.5) * 0.32, 0.48, 0.68)
	traction_control_max_slip = _baseline_traction_control_max_slip(config)
	front_abs_pulse_time = 0.03
	front_abs_spin_difference_threshold = 12.0
	rear_abs_pulse_time = 0.03
	rear_abs_spin_difference_threshold = 12.0

	enable_stability = true
	stability_yaw_engage_angle = clampf(float(config.stabilization_slip_deg) / maxf(float(config.drift_slip_deg), 1.0), 0.12, 0.55)
	stability_yaw_strength = clampf(float(config.yaw_assist) / 220.0, 2.5, 9.5)
	stability_yaw_ground_multiplier = _baseline_stability_yaw_ground_multiplier(config)
	stability_upright_spring = 1.15
	stability_upright_damping = 950.0

	gear_ratios = _typed_float_array(config.forward_gears)
	final_drive = float(config.final_drive_ratio)
	reverse_ratio = absf(float(config.reverse_gear_ratio))
	shift_time = 0.22
	automatic_transmission = true
	automatic_time_between_shifts = 250.0
	gear_inertia = 0.025

	front_torque_split = _front_torque_split_from_config(config)
	variable_torque_split = false
	front_variable_split = front_torque_split
	variable_split_speed = 1.0
	front_locking_differential_engage_torque = 180.0
	front_torque_vectoring = 0.0
	rear_locking_differential_engage_torque = 180.0
	rear_torque_vectoring = 0.0

	var front_travel := _suspension_travel(config, true)
	var rear_travel := _suspension_travel(config, false)
	front_spring_length = front_travel
	rear_spring_length = rear_travel
	front_resting_ratio = _resting_ratio(config, true)
	rear_resting_ratio = _resting_ratio(config, false)
	front_damping_ratio = _baseline_damping_ratio(config, true)
	rear_damping_ratio = _baseline_damping_ratio(config, false)
	front_bump_damp_multiplier = clampf(float(config.front_bump_damping) / maxf(float(config.front_rebound_damping), 0.1), 0.45, 1.35)
	front_rebound_damp_multiplier = clampf(float(config.front_rebound_damping) / maxf(float(config.front_bump_damping), 0.1), 0.75, 1.75)
	rear_bump_damp_multiplier = clampf(float(config.rear_bump_damping) / maxf(float(config.rear_rebound_damping), 0.1), 0.45, 1.35)
	rear_rebound_damp_multiplier = clampf(float(config.rear_rebound_damping) / maxf(float(config.rear_bump_damping), 0.1), 0.75, 1.75)
	front_arb_ratio = clampf(float(config.front_anti_roll_coefficient) / 120.0, 0.08, 0.85)
	rear_arb_ratio = clampf(float(config.rear_anti_roll_coefficient) / 120.0, 0.08, 0.85)
	front_camber = 0.01745329
	rear_camber = 0.01745329
	front_toe = 0.01
	rear_toe = 0.01
	front_bump_stop_multiplier = clampf(float(config.front_bump_stop_coefficient) / 28.0, 0.7, 2.2)
	rear_bump_stop_multiplier = clampf(float(config.rear_bump_stop_coefficient) / 28.0, 0.7, 2.2)
	front_beam_axle = false
	rear_beam_axle = false

	contact_patch = 0.19
	braking_grip_multiplier = _baseline_braking_grip_multiplier(config)
	wheel_to_body_torque_multiplier = 0.75
	var grip_profiles := _surface_profiles_from_config(config)
	tire_stiffnesses = grip_profiles["tire_stiffnesses"]
	coefficient_of_friction = grip_profiles["coefficient_of_friction"]
	rolling_resistance = grip_profiles["rolling_resistance"]
	lateral_grip_assist = grip_profiles["lateral_grip_assist"]
	longitudinal_grip_ratio = grip_profiles["longitudinal_grip_ratio"]
	front_tire_radius = float(config.wheel_radii[0]) if config.wheel_radii.size() > 0 else 0.32
	rear_tire_radius = float(config.wheel_radii[2]) if config.wheel_radii.size() > 2 else front_tire_radius
	front_tire_width = 245.0
	rear_tire_width = 255.0
	front_wheel_mass = 15.0
	rear_wheel_mass = 16.0

	var body_size: Vector3 = _vehicle_setup.get("body_size", Vector3(1.9, 1.2, 4.6))
	frontal_area = maxf(body_size.x * body_size.y * 0.82, 1.6)
	coefficient_of_drag = clampf(0.24 + float(config.aero_drag) * vehicle_mass * 0.22, 0.24, 0.48)
	air_density = 1.225

	max_rpm = float(config.engine_redline_rpm)
	idle_rpm = float(config.idle_rpm)
	torque_curve = _build_torque_curve(config.engine_torque_samples)
	if torque_curve == null:
		torque_curve = _build_torque_curve(PackedFloat32Array())
	max_torque = _estimated_max_torque(config)
	motor_drag = _estimated_motor_drag(config)
	motor_brake = _estimated_motor_brake(config)
	motor_moment = clampf(vehicle_mass / 3200.0, 0.4, 1.15)
	clutch_out_rpm = lerpf(idle_rpm * 1.8, float(config.engine_peak_rpm), 0.45)
	max_clutch_torque_ratio = 1.7
	_runtime_parameters = _build_runtime_parameters(config)


func _reinitialize_vehicle_runtime() -> void:
	is_ready = false
	wheel_array.clear()
	axles.clear()
	drive_wheels.clear()
	front_axle = null
	rear_axle = null
	previous_global_position = global_position
	vehicle_inertia = Vector3.ZERO
	current_gravity = ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3.DOWN) * ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	initialize()
	motor_rpm = idle_rpm
	current_gear = 1
	requested_gear = 1
	_apply_brake_force_mapping(config)
	_apply_ackermann_for_config()
	_sync_visual_wheels_from_helpers()


func _apply_brake_force_mapping(_source_config) -> void:
	var setup_force := float(_vehicle_setup.get("service_brake_total", max_brake_force))
	max_brake_force = maxf(setup_force * 0.6, 10.0)
	max_handbrake_force = maxf(float(_vehicle_setup.get("handbrake_total", max_handbrake_force)) * 0.10, 2.0)


func _apply_ackermann_for_config() -> void:
	var wheel_base := absf(rear_left_wheel.position.z - front_left_wheel.position.z)
	var front_track_width := absf(front_right_wheel.position.x - front_left_wheel.position.x)
	var rear_track_width := absf(rear_right_wheel.position.x - rear_left_wheel.position.x)
	if wheel_base <= 0.0001 or absf(max_steering_angle) <= 0.0001:
		return
	var front_ackermann := (atan((wheel_base * tan(max_steering_angle)) / maxf(wheel_base - (front_track_width * 0.5 * tan(max_steering_angle)), 0.0001)) / max_steering_angle) - 1.0
	var rear_ackermann := (atan((wheel_base * tan(max_steering_angle)) / maxf(wheel_base - (rear_track_width * 0.5 * tan(max_steering_angle)), 0.0001)) / max_steering_angle) - 1.0
	front_left_wheel.ackermann = front_ackermann
	front_right_wheel.ackermann = -front_ackermann
	rear_left_wheel.ackermann = rear_ackermann
	rear_right_wheel.ackermann = -rear_ackermann


func _vehicle_wheel_positions_from_config() -> Dictionary:
	var out := {}
	var positions: Array = config.wheel_local_positions_ps2
	for index in range(mini(SLOT_IDS.size(), positions.size())):
		var slot_id: String = SLOT_IDS[index]
		var vehicle_position := VehicleBodyConfigAdapter.gevp_vehicle_space_from_ps2(positions[index])
		out[slot_id] = vehicle_position
	return {
		"FL": out.get("FL", Vector3(-0.72, 0.2, -1.3)),
		"FR": out.get("FR", Vector3(0.72, 0.2, -1.3)),
		"RL": out.get("RL", Vector3(-0.72, 0.2, 1.36)),
		"RR": out.get("RR", Vector3(0.72, 0.2, 1.36)),
	}


func _sync_scene_component_nodes_from_config() -> void:
	var car_visual: Node3D = null
	if _visual_root != null:
		car_visual = _visual_root.get_node_or_null("CarVisual") as Node3D
	if car_visual == null:
		return
	_ensure_scene_visual_components(car_visual)
	var body_root := car_visual.get_node_or_null("Body") as Node3D
	if body_root != null:
		body_root.position = Vector3.ZERO
	var dummies_root := car_visual.get_node_or_null("Dummies") as Node3D
	for index in range(mini(SLOT_IDS.size(), config.wheel_local_positions_ps2.size())):
		var slot_id: String = SLOT_IDS[index]
		var visual_position := MathUtils.ps2_to_godot_vec3(config.wheel_local_positions_ps2[index])
		var pivot_node := car_visual.get_node_or_null("WheelPivots/%s" % slot_id) as Node3D
		if pivot_node != null:
			pivot_node.position = visual_position
		if dummies_root != null:
			var dummy_node := dummies_root.get_node_or_null("%s_PIVOT" % slot_id) as Node3D
			if dummy_node != null:
				dummy_node.position = visual_position
	var center_dummy: Node3D = null
	if dummies_root != null:
		center_dummy = dummies_root.get_node_or_null("BODY_CENTER") as Node3D
	if center_dummy != null:
		center_dummy.position = Vector3.ZERO


func _update_inputs() -> void:
	if input_source != null:
		if input_source.has_method("get_throttle"):
			throttle_input = float(input_source.get_throttle())
		else:
			throttle_input = _read_action_pair("car_accelerate", "ui_up")
		if input_source.has_method("get_brake"):
			brake_input = float(input_source.get_brake())
		else:
			brake_input = _read_action_pair("car_brake", "ui_down")
		if input_source.has_method("get_steer"):
			steering_input = float(input_source.get_steer())
		else:
			steering_input = _read_action_pair("car_steer_left", "ui_left") - _read_action_pair("car_steer_right", "ui_right")
		if input_source.has_method("get_handbrake"):
			handbrake_input = float(input_source.get_handbrake())
		else:
			handbrake_input = _read_action_pair("car_handbrake", "")
		return
	throttle_input = _read_action_pair("car_accelerate", "ui_up")
	brake_input = _read_action_pair("car_brake", "ui_down")
	steering_input = _read_action_pair("car_steer_left", "ui_left") - _read_action_pair("car_steer_right", "ui_right")
	handbrake_input = _read_action_pair("car_handbrake", "")


func _read_action_pair(primary_action: String, fallback_action: String) -> float:
	if primary_action != "" and InputMap.has_action(primary_action):
		return Input.get_action_strength(primary_action)
	if fallback_action != "" and InputMap.has_action(fallback_action):
		return Input.get_action_strength(fallback_action)
	return 0.0


func _cache_wheel_nodes() -> void:
	_wheel_nodes = {
		"FL": get_node_or_null("WheelFrontLeft"),
		"FR": get_node_or_null("WheelFrontRight"),
		"RL": get_node_or_null("WheelRearLeft"),
		"RR": get_node_or_null("WheelRearRight"),
	}
	_wheel_helpers = {
		"FL": get_node_or_null("WheelFrontLeft/FrontLeftWheel"),
		"FR": get_node_or_null("WheelFrontRight/FrontRightWheel"),
		"RL": get_node_or_null("WheelRearLeft/RearLeftWheel"),
		"RR": get_node_or_null("WheelRearRight/RearRightWheel"),
	}


func _sync_visual_wheels_from_helpers() -> void:
	for slot_id in SLOT_IDS:
		var helper := _wheel_helpers.get(slot_id, null) as Node3D
		if helper == null:
			continue
		var suspension_node := _wheel_suspension_nodes.get(slot_id, null) as Node3D
		if suspension_node != null:
			var suspension_position := suspension_node.position
			suspension_position.y = helper.position.y
			suspension_node.position = suspension_position
		var wheel_node := _wheel_nodes.get(slot_id, null) as Wheel
		var steer_node := _wheel_steer_nodes.get(slot_id, null) as Node3D
		if wheel_node != null and steer_node != null:
			var steer_rotation := steer_node.rotation
			steer_rotation.y = wheel_node.rotation.y
			steer_node.rotation = steer_rotation
		var roll_node := _wheel_roll_nodes.get(slot_id, null) as Node3D
		if roll_node != null:
			var roll_rotation := roll_node.rotation
			roll_rotation.z = helper.rotation.z
			roll_node.rotation = roll_rotation
		var spin_node := _wheel_spin_nodes.get(slot_id, null) as Node3D
		if spin_node != null:
			var spin_rotation := spin_node.rotation
			spin_rotation.x = helper.rotation.x * float(spin_node.get_meta("eagl_spin_direction", 1.0))
			spin_node.rotation = spin_rotation


func _update_debug_snapshot() -> void:
	var dominant_surface := surface_type
	var surface_mu_total := 0.0
	var surface_mu_count := 0
	var wheel_rows: Array[Dictionary] = []
	var engine_force_total := 0.0
	var engine_brake_total := 0.0
	for slot_id in SLOT_IDS:
		var wheel := _wheel_nodes.get(slot_id, null) as Wheel
		if wheel == null:
			continue
		var wheel_surface: String = _normalize_surface_name(String(wheel.surface_type))
		if wheel.is_colliding():
			dominant_surface = wheel_surface
		surface_mu_total += float(wheel.current_cof)
		surface_mu_count += 1
		var wheel_engine_force := float(wheel.force_vector.y) if wheel.is_driven else 0.0
		var wheel_brake_force := _command_brake_force_for_wheel(slot_id)
		engine_force_total += wheel_engine_force
		engine_brake_total += wheel_brake_force
		var wheel_row := {
			"slot": slot_id,
			"grounded": wheel.is_colliding(),
			"rpm": wheel.spin * 60.0 / TAU,
			"skid": wheel.slip_vector.length(),
			"lock": wheel.limit_spin,
			"slip_locked": wheel.limit_spin,
			"steering_deg": rad_to_deg(wheel.rotation.y),
			"engine_force": wheel_engine_force,
			"brake_force": wheel_brake_force,
			"suspension_length": wheel.spring_current_length,
			"raw_length": wheel.spring_current_length,
			"current_length": wheel.spring_current_length,
			"travel_velocity": wheel.damping_force,
			"spring_force": wheel.spring_force,
			"damper_force": wheel.damping_force,
			"suspension_force": wheel.spring_force,
			"normal_load": wheel.spring_force,
			"slip_long": wheel.slip_vector.y,
			"slip_lat": wheel.slip_vector.x,
			"force_long": wheel.force_vector.y,
			"force_lat": wheel.force_vector.x,
			"grip": wheel.slip_vector.length(),
			"surface_type": wheel_surface,
		}
		if wheel.has_method("get_hp2_debug_state"):
			wheel_row.merge(wheel.call("get_hp2_debug_state"), true)
		wheel_rows.append(wheel_row)
	var flat_speed := Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()
	_debug_snapshot = {
		"speed_kmh": flat_speed * 3.6,
		"speed_kph": flat_speed * 3.6,
		"speed_ms": flat_speed,
		"rpm": motor_rpm,
		"gear": current_gear,
		"slip_angle_deg": _slip_angle_deg(),
		"steering_deg": rad_to_deg(true_steering_amount),
		"mass_kg": mass,
		"mass_is_estimate": bool(_vehicle_setup.get("mass_is_estimate", false)),
		"driven_wheel_count": drive_wheels.size(),
		"engine_force_gain": float(_vehicle_setup.get("engine_force_normalization_gain", 0.0)),
		"hp2_launch_accel_reference": float(_vehicle_setup.get("hp2_launch_accel_reference", 0.0)),
		"drag_force": 0.5 * air_density * pow(flat_speed, 2.0) * frontal_area * coefficient_of_drag,
		"engine_force_total": engine_force_total,
		"engine_brake_total": engine_brake_total,
		"surface_type": dominant_surface,
		"surface_mu": surface_mu_total / float(surface_mu_count) if surface_mu_count > 0 else 0.0,
		"grip_solver": get_hp2_grip_solver_name(),
		"handling_baseline": handling_baseline,
		"road_cof": float(coefficient_of_friction.get("Road", 0.0)),
		"road_tire_stiffness": float(tire_stiffnesses.get("Road", 0.0)),
		"traction_control_active": tcs_active,
		"stability_active": stability_active,
		"wheels": wheel_rows,
		"runtime": _runtime_parameters.duplicate(true),
	}


func _wheel_snapshot_value(slot_id: String, key: String):
	for wheel in _debug_snapshot.get("wheels", []):
		if String(wheel.get("slot", "")) == slot_id:
			return wheel.get(key, 0.0)
	return 0.0


func _slip_angle_deg() -> float:
	var horizontal_velocity := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	if horizontal_velocity.length_squared() <= 0.0001:
		return 0.0
	var forward := (global_transform.basis * Vector3.FORWARD).normalized()
	var flat_forward := Vector3(forward.x, 0.0, forward.z).normalized()
	if flat_forward.length_squared() <= 0.0001:
		return 0.0
	var flat_velocity := horizontal_velocity.normalized()
	return rad_to_deg(atan2(flat_forward.cross(flat_velocity).y, flat_forward.dot(flat_velocity)))


func _command_brake_force_for_wheel(slot_id: String) -> float:
	var axle := front_axle if slot_id in ["FL", "FR"] else rear_axle
	if axle == null:
		return 0.0
	var base_force := brake_force * 0.5 * axle.brake_bias
	if slot_id in ["RL", "RR"]:
		base_force += handbrake_force * 0.5
	return base_force


func _build_runtime_parameters(source_config) -> Dictionary:
	return {
		"wheelbase": absf(float(source_config.wheelbase_meters())),
		"wheel_radius": source_config.driven_average_radius(),
		"gear_ratios": _float_array(source_config.forward_gears),
		"reverse_ratio": absf(float(source_config.reverse_gear_ratio)),
		"final_drive": float(source_config.final_drive_ratio),
		"front_longitudinal_grip": float(source_config.front_longitudinal_grip),
		"rear_longitudinal_grip": float(source_config.rear_longitudinal_grip),
		"front_lateral_grip": float(source_config.front_lateral_grip),
		"rear_lateral_grip": float(source_config.rear_lateral_grip),
		"max_torque": max_torque,
		"idle_rpm": idle_rpm,
		"peak_rpm": float(source_config.engine_peak_rpm),
		"max_rpm": max_rpm,
		"motor_drag": motor_drag,
		"motor_brake": motor_brake,
		"upshift_rpm": max_rpm * 0.8,
		"downshift_rpm": maxf(idle_rpm * 2.0, max_rpm * 0.55),
		"steering_speed": steering_speed,
		"countersteer_speed": countersteer_speed,
		"max_steer_degrees": rad_to_deg(max_steering_angle),
		"grip_solver": get_hp2_grip_solver_name(),
		"handling_baseline": handling_baseline,
		"front_weight_distribution": front_weight_distribution,
		"coefficient_of_drag": coefficient_of_drag,
		"rolling_resistance": rolling_resistance.get("Road", 1.0),
		"road_cof": coefficient_of_friction.get("Road", 0.0),
		"road_tire_stiffness": tire_stiffnesses.get("Road", 0.0),
		"surface_force_scale": coefficient_of_friction.duplicate(true),
		"tire_stiffnesses": tire_stiffnesses.duplicate(true),
		"coefficient_of_friction": coefficient_of_friction.duplicate(true),
		"longitudinal_grip_ratio": longitudinal_grip_ratio.duplicate(true),
		"torque_curve": _samples_to_points(source_config.engine_torque_samples),
		"friction_curve": _friction_curve_points(source_config.engine_friction_samples),
	}


func _surface_profiles_from_config(source_config) -> Dictionary:
	var rolling_scale := clampf(1.0 + (float(source_config.rolling_resistance) - 0.045) * 4.0, 0.90, 1.15)
	return {
		"tire_stiffnesses": {
			"Road": DEMO_ROAD_TIRE_STIFFNESS,
			"Dirt": DEMO_DIRT_TIRE_STIFFNESS,
			"Grass": DEMO_GRASS_TIRE_STIFFNESS,
		},
		"coefficient_of_friction": {
			"Road": DEMO_ROAD_COF,
			"Dirt": DEMO_DIRT_COF,
			"Grass": DEMO_GRASS_COF,
		},
		"rolling_resistance": {
			"Road": DEMO_ROAD_ROLLING_RESISTANCE * rolling_scale,
			"Dirt": DEMO_DIRT_ROLLING_RESISTANCE * rolling_scale,
			"Grass": DEMO_GRASS_ROLLING_RESISTANCE * rolling_scale,
		},
		"lateral_grip_assist": {
			"Road": 0.0,
			"Dirt": 0.0,
			"Grass": 0.0,
		},
		"longitudinal_grip_ratio": {
			"Road": 1.0,
			"Dirt": 1.0,
			"Grass": 1.0,
		},
	}


func _grip_scalar(value: float, reference_value: float, minimum: float, maximum: float) -> float:
	return clampf(1.0 + ((value - reference_value) * 0.28), minimum, maximum)


func _baseline_damping_ratio(source_config, is_front: bool) -> float:
	var bump: float = source_config.front_bump_damping if is_front else source_config.rear_bump_damping
	return clampf(DEMO_DAMPING_RATIO + ((bump - 5.0) * 0.035), 0.52, 0.72)


func _baseline_braking_grip_multiplier(source_config) -> float:
	var brake_scalar := clampf(1.0 + ((float(source_config.brake_force) - 10500.0) / 9000.0) * 0.18, 0.94, 1.08)
	return clampf(DEMO_BRAKING_GRIP_MULTIPLIER * brake_scalar, 0.95, 1.25)


func _baseline_stability_yaw_ground_multiplier(source_config) -> float:
	return clampf(DEMO_STABILITY_YAW_GROUND_MULTIPLIER + ((float(source_config.yaw_damping) - 1.8) * 0.12), 1.0, 1.6)


func _baseline_traction_control_max_slip(source_config) -> float:
	return DEMO_TRACTION_CONTROL_MAX_SLIP


func _log_runtime_configuration() -> void:
	print(
		"HP2Car config baseline=%s solver=%s road_cof=%.2f road_tire_stiffness=%.2f engine_sound=%s" % [
			handling_baseline,
			get_hp2_grip_solver_name(),
			float(coefficient_of_friction.get("Road", 0.0)),
			float(tire_stiffnesses.get("Road", 0.0)),
			"yes" if get_node_or_null("EngineSound") != null else "no",
		]
	)


func _normalize_surface_name(value: String) -> String:
	match value.to_lower():
		"asphalt", "road":
			return "Road"
		"terrain", "dirt":
			return "Dirt"
		"grass":
			return "Grass"
		_:
			return "Road"


func _typed_float_array(values) -> Array[float]:
	var out: Array[float] = []
	for value in values:
		out.append(float(value))
	return out


func _float_array(values) -> Array:
	var out: Array = []
	for value in values:
		out.append(float(value))
	return out


func _build_torque_curve(samples: PackedFloat32Array) -> Curve:
	var curve := Curve.new()
	if samples.is_empty():
		curve.add_point(Vector2(0.0, 0.45))
		curve.add_point(Vector2(0.6, 1.0))
		curve.add_point(Vector2(1.0, 0.7))
		return curve
	var max_sample := 0.0
	for sample in samples:
		max_sample = maxf(max_sample, float(sample))
	var denom := maxf(float(samples.size() - 1), 1.0)
	for index in range(samples.size()):
		var x := float(index) / denom
		var y := float(samples[index]) / maxf(max_sample, 0.0001)
		curve.add_point(Vector2(x, y))
	return curve


func _estimated_max_torque(source_config) -> float:
	if gear_ratios.is_empty():
		return 300.0
	var avg_radius := maxf(source_config.driven_average_radius(), 0.1)
	var first_ratio := absf(float(gear_ratios[0]) * final_drive)
	var idle_factor := torque_curve.sample_baked(clampf(idle_rpm / maxf(max_rpm, 1.0), 0.0, 1.0))
	var hp2_launch_force := float(_vehicle_setup.get("hp2_idle_launch_force_total", source_config.engine_force_scale))
	return clampf(hp2_launch_force * avg_radius / maxf(first_ratio * maxf(idle_factor, 0.18), 0.1), 220.0, 1400.0)


func _estimated_motor_drag(source_config) -> float:
	var average := _average_sample(source_config.engine_friction_samples, 0.55)
	return clampf(average * 0.018, 0.004, 0.018)


func _estimated_motor_brake(source_config) -> float:
	var first := float(source_config.engine_friction_samples[0]) if source_config.engine_friction_samples.size() > 0 else 0.55
	return clampf(first * 34.0, 8.0, 28.0)


func _average_sample(samples: PackedFloat32Array, fallback: float) -> float:
	if samples.is_empty():
		return fallback
	var total := 0.0
	for sample in samples:
		total += float(sample)
	return total / float(samples.size())


func _front_torque_split_from_config(source_config) -> float:
	var split: Dictionary = source_config.drivetrain_axle_bias()
	return clampf(float(split.get("front", 0.0)), 0.0, 1.0)


func _front_weight_distribution_from_config(source_config) -> float:
	var load_origin_x: float = source_config.physics_origin_offset_ps2.x
	if absf(load_origin_x) <= 0.0001:
		load_origin_x = source_config.center_of_mass_ps2.x
	var front_x: float = source_config.front_axle_center_x() - load_origin_x
	var rear_x: float = source_config.rear_axle_center_x() - load_origin_x
	var denom: float = front_x - rear_x
	if absf(denom) <= 0.0001:
		return 0.5
	var rear_each_fraction: float = (front_x / denom) * 0.5
	var front_each_fraction: float = 0.5 - rear_each_fraction
	return clampf(front_each_fraction * 2.0, 0.25, 0.75)


func _center_of_gravity_height_offset(front_left: Vector3, front_right: Vector3, rear_left: Vector3, rear_right: Vector3) -> float:
	var axle_front := front_left.lerp(front_right, 0.5)
	var axle_rear := rear_left.lerp(rear_right, 0.5)
	var base_center := axle_rear.lerp(axle_front, front_weight_distribution)
	var com_vehicle: Vector3 = _vehicle_setup.get("center_of_mass", Vector3.ZERO)
	return float(com_vehicle.y) - base_center.y


func _suspension_travel(source_config, is_front: bool) -> float:
	var min_compression: float = source_config.front_min_compression if is_front else source_config.rear_min_compression
	var max_compression: float = source_config.front_max_compression if is_front else source_config.rear_max_compression
	return clampf(absf(max_compression - min_compression), 0.12, 0.35)


func _resting_ratio(source_config, is_front: bool) -> float:
	var min_compression: float = source_config.front_min_compression if is_front else source_config.rear_min_compression
	var max_compression: float = source_config.front_max_compression if is_front else source_config.rear_max_compression
	var travel := maxf(absf(max_compression - min_compression), 0.001)
	return clampf(absf(min_compression) / travel, 0.18, 0.82)


func _samples_to_points(samples: PackedFloat32Array) -> Array:
	var out: Array = []
	if samples.is_empty():
		return out
	var denom := maxf(float(samples.size() - 1), 1.0)
	for index in range(samples.size()):
		out.append([float(index) / denom, float(samples[index])])
	return out


func _friction_curve_points(samples: PackedFloat32Array) -> Array:
	var out: Array = []
	if samples.is_empty():
		return [[0.0, motor_brake], [1.0, motor_brake + motor_drag * max_rpm]]
	var denom := maxf(float(samples.size() - 1), 1.0)
	for index in range(samples.size()):
		out.append([float(index) / denom, float(samples[index]) * 40.0])
	return out


func _fit_chassis_collision_shape() -> void:
	var collision_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision_shape == null:
		return
	var box_shape := collision_shape.shape as BoxShape3D
	if box_shape == null:
		box_shape = BoxShape3D.new()
		collision_shape.shape = box_shape
	var body_size: Vector3 = _vehicle_setup.get("body_size", Vector3(1.9, 1.2, 4.6))
	var collision_center: Vector3 = _vehicle_setup.get("collision_center", Vector3(0.0, body_size.y * 0.5, 0.0))
	box_shape.size = body_size
	collision_shape.position = collision_center


func _fit_collision_shape_to_visual_bounds() -> void:
	var collision_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision_shape == null:
		return
	var box_shape := collision_shape.shape as BoxShape3D
	if box_shape == null or _visual_root == null:
		return
	var body_root := _visual_root.get_node_or_null("CarVisual/Body") as Node3D
	if body_root == null:
		return
	var bounds := AABB()
	var has_bounds := false
	for child in body_root.get_children():
		if not (child is MeshInstance3D):
			continue
		var mesh_instance := child as MeshInstance3D
		var mesh_aabb := mesh_instance.get_aabb()
		var mesh_corners := [
			mesh_aabb.position,
			mesh_aabb.position + Vector3(mesh_aabb.size.x, 0.0, 0.0),
			mesh_aabb.position + Vector3(0.0, mesh_aabb.size.y, 0.0),
			mesh_aabb.position + Vector3(0.0, 0.0, mesh_aabb.size.z),
			mesh_aabb.position + Vector3(mesh_aabb.size.x, mesh_aabb.size.y, 0.0),
			mesh_aabb.position + Vector3(mesh_aabb.size.x, 0.0, mesh_aabb.size.z),
			mesh_aabb.position + Vector3(0.0, mesh_aabb.size.y, mesh_aabb.size.z),
			mesh_aabb.position + mesh_aabb.size,
		]
		for corner in mesh_corners:
			var point_local := to_local(mesh_instance.to_global(corner))
			if not has_bounds:
				bounds = AABB(point_local, Vector3.ZERO)
				has_bounds = true
			else:
				bounds = bounds.expand(point_local)
	if not has_bounds:
		return
	box_shape.size = Vector3(
		maxf(bounds.size.x, 0.4),
		maxf(bounds.size.y, 0.4),
		maxf(bounds.size.z, 0.8)
	)
	collision_shape.position = bounds.position + bounds.size * 0.5


func _ensure_scene_visual_components(car_visual: Node3D) -> void:
	var body := _ensure_node3d(car_visual, "Body")
	body.position = Vector3.ZERO
	var wheel_pivots := _ensure_node3d(car_visual, "WheelPivots")
	for slot_id in SLOT_IDS:
		var pivot := _ensure_node3d(wheel_pivots, slot_id)
		var suspension := _ensure_node3d(pivot, "Suspension")
		var steer := _ensure_node3d(suspension, "Steer")
		var roll := _ensure_node3d(steer, "Roll")
		_ensure_node3d(roll, "Spin")
	var dummies := _ensure_node3d(car_visual, "Dummies")
	_ensure_node3d(dummies, "BODY_CENTER")
	for slot_id in SLOT_IDS:
		_ensure_node3d(dummies, "%s_PIVOT" % slot_id)


func _ensure_node3d(parent: Node, child_name: String) -> Node3D:
	var existing := parent.get_node_or_null(NodePath(child_name)) as Node3D
	if existing != null:
		return existing
	var node := Node3D.new()
	node.name = child_name
	parent.add_child(node)
	return node


func _clear_scene_visual_content(car_visual: Node3D) -> void:
	for child in car_visual.get_children():
		if String(child.name) in ["Body", "WheelPivots", "Dummies"]:
			continue
		_remove_child_now(car_visual, child)
	var body_root := car_visual.get_node_or_null("Body") as Node3D
	if body_root != null:
		_remove_all_children(body_root)
	var wheel_pivots := car_visual.get_node_or_null("WheelPivots") as Node3D
	if wheel_pivots != null:
		for child in wheel_pivots.get_children():
			if not (String(child.name) in SLOT_IDS):
				_remove_child_now(wheel_pivots, child)
		for slot_id in SLOT_IDS:
			_clear_wheel_visual_content(wheel_pivots.get_node_or_null(slot_id) as Node3D)
	var dummies_root := car_visual.get_node_or_null("Dummies") as Node3D
	if dummies_root != null:
		var expected_dummies := ["BODY_CENTER"]
		for slot_id in SLOT_IDS:
			expected_dummies.append("%s_PIVOT" % slot_id)
		for child in dummies_root.get_children():
			if not (String(child.name) in expected_dummies):
				_remove_child_now(dummies_root, child)


func _clear_wheel_visual_content(wheel_root: Node3D) -> void:
	if wheel_root == null:
		return
	for child in wheel_root.get_children():
		if String(child.name) != "Suspension":
			_remove_child_now(wheel_root, child)
	var suspension := wheel_root.get_node_or_null("Suspension") as Node3D
	if suspension == null:
		return
	for child in suspension.get_children():
		if String(child.name) != "Steer":
			_remove_child_now(suspension, child)
	var steer := suspension.get_node_or_null("Steer") as Node3D
	if steer == null:
		return
	for child in steer.get_children():
		if String(child.name) != "Roll":
			_remove_child_now(steer, child)
	var roll := steer.get_node_or_null("Roll") as Node3D
	if roll == null:
		return
	for child in roll.get_children():
		if String(child.name) != "Spin":
			_remove_child_now(roll, child)
	var spin := roll.get_node_or_null("Spin") as Node3D
	if spin != null:
		_remove_all_children(spin)


func _merge_visual_content_into_scene(source: Node3D, destination: Node3D) -> void:
	_copy_node_state(source, destination)
	for child in source.get_children():
		var target_child := destination.get_node_or_null(NodePath(String(child.name))) as Node3D
		if child is Node3D and not (child is MeshInstance3D) and target_child != null:
			_merge_visual_content_into_scene(child as Node3D, target_child)
			continue
		source.remove_child(child)
		destination.add_child(child)


func _copy_node_state(source: Node3D, destination: Node3D) -> void:
	destination.transform = source.transform
	for meta_name in source.get_meta_list():
		destination.set_meta(String(meta_name), source.get_meta(String(meta_name)))


func _remove_all_children(parent: Node) -> void:
	for child in parent.get_children():
		_remove_child_now(parent, child)


func _remove_child_now(parent: Node, child: Node) -> void:
	parent.remove_child(child)
	child.queue_free()


func _ensure_debug_mesh() -> void:
	_debug_mesh_instance = get_node_or_null("DebugLines") as MeshInstance3D
	if _debug_mesh_instance == null:
		return
	if _debug_material == null:
		_debug_material = StandardMaterial3D.new()
		_debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_debug_material.vertex_color_use_as_albedo = true
		_debug_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_debug_material.no_depth_test = true
	_debug_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_debug_mesh_instance.material_override = _debug_material
	_debug_mesh_instance.mesh = _debug_mesh


func _rebuild_debug_mesh() -> void:
	if _debug_mesh_instance == null:
		_ensure_debug_mesh()
	if _debug_mesh_instance == null:
		return
	_debug_mesh.clear_surfaces()
	_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_add_collision_wireframe()
	for slot_id in SLOT_IDS:
		var raycast := _wheel_nodes.get(slot_id, null) as Wheel
		if raycast == null:
			continue
		var helper := _wheel_helpers.get(slot_id, null) as Node3D
		var pivot := to_local(raycast.global_position)
		var center := pivot
		if helper != null:
			center = to_local(helper.global_position)
		_debug_mesh.surface_set_color(Color(0.0, 0.85, 1.0, 1.0))
		_debug_mesh.surface_add_vertex(pivot)
		_debug_mesh.surface_add_vertex(center)
		_debug_mesh.surface_set_color(Color(1.0, 0.75, 0.2, 0.95))
		_add_debug_cross(center, 0.07)
		if raycast.is_colliding():
			var contact := to_local(raycast.last_collision_point)
			var normal_end := to_local(raycast.last_collision_point + raycast.last_collision_normal * 0.45)
			_debug_mesh.surface_set_color(Color(0.25, 1.0, 0.3, 0.95))
			_debug_mesh.surface_add_vertex(center)
			_debug_mesh.surface_add_vertex(contact)
			_add_debug_cross(contact, 0.05)
			_debug_mesh.surface_add_vertex(contact)
			_debug_mesh.surface_add_vertex(normal_end)
			_add_force_component(pivot + Vector3.LEFT * 0.08, Vector3.UP, raycast.spring_force, maxf(raycast.spring_force, 1.0), Color(0.1, 1.0, 0.35, 0.9))
			_add_force_component(contact, Vector3.FORWARD, raycast.force_vector.y, maxf(absf(raycast.force_vector.y), 1.0), Color(1.0, 0.55, 0.18, 0.9))
			_add_force_component(contact, Vector3.RIGHT, raycast.force_vector.x, maxf(absf(raycast.force_vector.x), 1.0), Color(0.22, 0.78, 1.0, 0.9))
	_debug_mesh.surface_end()


func _add_collision_wireframe() -> void:
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
	var edges := [
		Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3), Vector2i(3, 0),
		Vector2i(4, 5), Vector2i(5, 6), Vector2i(6, 7), Vector2i(7, 4),
		Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
	]
	_debug_mesh.surface_set_color(Color(1.0, 1.0, 1.0, 0.85))
	for edge in edges:
		var start: Vector3 = collision_shape.transform * corners[edge.x]
		var finish: Vector3 = collision_shape.transform * corners[edge.y]
		_debug_mesh.surface_add_vertex(start)
		_debug_mesh.surface_add_vertex(finish)


func _add_debug_cross(center: Vector3, radius: float) -> void:
	_debug_mesh.surface_add_vertex(center + Vector3.LEFT * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.RIGHT * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.UP * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.DOWN * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.FORWARD * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.BACK * radius)


func _add_force_component(origin: Vector3, direction: Vector3, value: float, reference_value: float, color: Color) -> void:
	var magnitude := clampf(value / maxf(reference_value, 0.001), -1.0, 1.0)
	var end_point := origin + direction.normalized() * magnitude * 0.35
	_debug_mesh.surface_set_color(color)
	_debug_mesh.surface_add_vertex(origin)
	_debug_mesh.surface_add_vertex(end_point)


func _godot_to_ps2(value: Vector3) -> Vector3:
	return Vector3(value.x, -value.z, value.y)
