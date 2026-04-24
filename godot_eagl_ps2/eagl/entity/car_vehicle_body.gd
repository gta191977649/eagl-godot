class_name EAGLCar
extends VehicleBody3D

const CarConfigScript = preload("res://eagl/handling/car_config.gd")
const VehicleBodyConfigAdapter = preload("res://eagl/handling/vehicle_body_config_adapter.gd")

const SLOT_IDS := ["FL", "FR", "RL", "RR"]
const VEHICLE_FORWARD := Vector3(0.0, 0.0, 1.0)
const DEBUG_AXIS_LENGTH := 0.45
const DEBUG_WHEEL_PHYSICS_SEGMENTS := 20
const WHEEL_NODE_ANCHOR_EPSILON := 0.08

@export var config = null
@export var draw_debug := true
@export var auto_fit_collision_from_visual := true

var current_gear := 1
var engine_rpm := 900.0
var signed_slip_angle := 0.0

var _throttle_input := 0.0
var _brake_input := 0.0
var _steering_input := 0.0
var _handbrake_input := 0.0
var _steering_state := 0.0
var _steering_engaged := false
var _debug_snapshot := {}
var _vehicle_setup := {}
var _last_drag_force := Vector3.ZERO
var _reverse_hold_time := 0.0
var _reverse_ready := false
var _shift_lock_time := 0.0
var _shift_cut_time := 0.0
var _wheel_nodes: Dictionary = {}
var _wheel_pivots: Dictionary = {}
var _wheel_visuals: Dictionary = {}
var _wheel_roll_visuals: Dictionary = {}
var _wheel_suspension_nodes: Dictionary = {}
var _wheel_spin_angles: Dictionary = {}
var _wheel_base_slip: Dictionary = {}
var _wheel_visual_radii: Dictionary = {}
var _wheel_last_grounded_lengths: Dictionary = {}
var _wheel_last_grounded_offsets: Dictionary = {}
var _visual_wheel_slots: Dictionary = {}

var _visual_root: Node3D
var _debug_mesh := ImmediateMesh.new()
var _debug_mesh_instance: MeshInstance3D
var _debug_material: StandardMaterial3D


func _ready() -> void:
	if config == null:
		config = CarConfigScript.new()
	_visual_root = get_node_or_null("VisualRoot") as Node3D
	if _visual_root != null:
		_visual_root.transform = Transform3D(VehicleBodyConfigAdapter.visual_anchor_basis(), Vector3.ZERO)
	_cache_wheel_nodes()
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 8
	apply_config(config)
	set_debug_overlay_enabled(draw_debug)


func _physics_process(delta: float) -> void:
	if config == null:
		return
	_update_inputs()
	_update_motion_state(delta)
	_apply_drag_forces()
	_apply_yaw_assist()
	_apply_wheel_forces()
	_update_debug_snapshot()


func _process(delta: float) -> void:
	_update_visuals(delta)
	if draw_debug:
		_rebuild_debug_mesh()


func apply_config(new_config) -> void:
	if new_config == null:
		return
	config = new_config
	_vehicle_setup = VehicleBodyConfigAdapter.build_vehicle_setup(config)
	mass = float(_vehicle_setup.get("mass", config.mass_kg))
	center_of_mass = _vehicle_setup.get("center_of_mass", Vector3.ZERO)
	_fit_chassis_collision_shape()
	_rebuild_wheel_nodes_for_setup()
	refresh_visual_bindings()
	_reset_runtime_values()
	_update_debug_snapshot()


func reset_runtime_state(target_transform: Transform3D = transform) -> void:
	transform = target_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	sleeping = false
	_reset_runtime_values()
	_update_visuals(0.0)
	_update_debug_snapshot()
	if draw_debug:
		_rebuild_debug_mesh()


func refresh_visual_bindings() -> void:
	_wheel_visuals.clear()
	_wheel_roll_visuals.clear()
	_wheel_suspension_nodes.clear()
	_wheel_pivots.clear()
	_wheel_visual_radii.clear()
	_wheel_last_grounded_offsets.clear()
	_visual_wheel_slots.clear()
	if _visual_root == null:
		return
	var car_visual := _visual_root.get_node_or_null("CarVisual") as Node3D
	if car_visual == null:
		return
	_cache_visual_wheel_slots(car_visual)
	for slot_id in SLOT_IDS:
		var pivot_node := car_visual.get_node_or_null("WheelPivots/%s" % slot_id) as Node3D
		if pivot_node != null:
			_wheel_pivots[slot_id] = pivot_node
		var suspension_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension" % slot_id) as Node3D
		if suspension_node != null:
			_wheel_suspension_nodes[slot_id] = suspension_node
		var steer_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer" % slot_id) as Node3D
		if steer_node != null:
			_wheel_visuals[slot_id] = steer_node
		var roll_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll/Spin" % slot_id) as Node3D
		if roll_node == null:
			roll_node = car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll" % slot_id) as Node3D
		if roll_node != null:
			_wheel_roll_visuals[slot_id] = roll_node
			_wheel_visual_radii[slot_id] = _visual_radius_from_node(roll_node)
	_apply_visual_wheel_slot_overrides()
	if auto_fit_collision_from_visual:
		_fit_collision_shape_to_visual_bounds()


func set_debug_overlay_enabled(enabled: bool) -> void:
	draw_debug = enabled
	if draw_debug:
		_ensure_debug_mesh()
		_debug_mesh_instance.visible = true
		_rebuild_debug_mesh()
	elif _debug_mesh_instance != null:
		_debug_mesh.clear_surfaces()
		_debug_mesh_instance.visible = false


func get_debug_snapshot() -> Dictionary:
	return _debug_snapshot.duplicate(true)


func replace_visual(visual: Node3D) -> void:
	if _visual_root == null:
		return
	var existing := _visual_root.get_node_or_null("CarVisual")
	if existing != null:
		_visual_root.remove_child(existing)
		existing.queue_free()
	if visual == null:
		refresh_visual_bindings()
		return
	if visual.get_parent() != null:
		visual.get_parent().remove_child(visual)
	_visual_root.add_child(visual)
	refresh_visual_bindings()


func sync_wheel_slots_from_visual() -> void:
	_update_visuals(0.0)
	_update_debug_snapshot()


func _cache_wheel_nodes() -> void:
	_wheel_nodes.clear()
	for slot_id in SLOT_IDS:
		var wheel := get_node_or_null(slot_id) as VehicleWheel3D
		if wheel != null:
			_wheel_nodes[slot_id] = wheel
			_wheel_spin_angles[slot_id] = 0.0


func _apply_wheel_setup() -> void:
	for slot_id in SLOT_IDS:
		var wheel := _wheel_nodes.get(slot_id, null) as VehicleWheel3D
		if wheel == null:
			continue
		var data: Dictionary = _vehicle_setup.get("wheels", {}).get(slot_id, {})
		if data.is_empty():
			continue
		_configure_wheel_node(slot_id, wheel, data)


func _rebuild_wheel_nodes_for_setup() -> void:
	if not is_inside_tree():
		_apply_wheel_setup()
		return
	# VehicleWheel3D caches its chassis connection when it enters VehicleBody3D.
	# Rebuild the nodes so the configured HP2 hardpoint is the runtime ray anchor.
	var setup_wheels: Dictionary = _vehicle_setup.get("wheels", {})
	for slot_id in SLOT_IDS:
		var data: Dictionary = setup_wheels.get(slot_id, {})
		if data.is_empty():
			continue
		var existing := get_node_or_null(slot_id) as VehicleWheel3D
		var wheel := VehicleWheel3D.new()
		wheel.name = slot_id
		_configure_wheel_node(slot_id, wheel, data)
		if existing == null:
			add_child(wheel)
			continue
		var child_index := existing.get_index()
		remove_child(existing)
		existing.queue_free()
		add_child(wheel)
		move_child(wheel, child_index)
	_cache_wheel_nodes()


func _configure_wheel_node(slot_id: String, wheel: VehicleWheel3D, data: Dictionary) -> void:
	wheel.position = data.get("position", wheel.position)
	wheel.use_as_steering = bool(data.get("use_as_steering", false))
	wheel.use_as_traction = bool(data.get("use_as_traction", false))
	wheel.wheel_radius = float(data.get("wheel_radius", wheel.wheel_radius))
	wheel.wheel_rest_length = float(data.get("wheel_rest_length", wheel.wheel_rest_length))
	wheel.suspension_travel = float(data.get("suspension_travel", wheel.suspension_travel))
	wheel.suspension_stiffness = float(data.get("suspension_stiffness", wheel.suspension_stiffness))
	wheel.suspension_max_force = float(data.get("suspension_max_force", wheel.suspension_max_force))
	wheel.damping_compression = float(data.get("damping_compression", wheel.damping_compression))
	wheel.damping_relaxation = float(data.get("damping_relaxation", wheel.damping_relaxation))
	wheel.wheel_friction_slip = float(data.get("wheel_friction_slip", wheel.wheel_friction_slip))
	_wheel_base_slip[slot_id] = wheel.wheel_friction_slip
	wheel.wheel_roll_influence = float(data.get("wheel_roll_influence", wheel.wheel_roll_influence))
	wheel.engine_force = 0.0
	wheel.brake = 0.0
	wheel.steering = 0.0


func _cache_visual_wheel_slots(car_visual: Node3D) -> void:
	var wheel_slots: Array = car_visual.get_meta("eagl_wheel_slots", [])
	for slot in wheel_slots:
		var slot_dict: Dictionary = slot
		var slot_id := String(slot_dict.get("slot_id", ""))
		if slot_id == "":
			continue
		_visual_wheel_slots[slot_id] = slot_dict.duplicate(true)


func _apply_visual_wheel_slot_overrides() -> void:
	return


func _reset_runtime_values() -> void:
	current_gear = 1
	engine_rpm = maxf(config.idle_rpm, 900.0)
	signed_slip_angle = 0.0
	_throttle_input = 0.0
	_brake_input = 0.0
	_steering_input = 0.0
	_handbrake_input = 0.0
	_steering_state = 0.0
	_steering_engaged = false
	_reverse_hold_time = 0.0
	_reverse_ready = false
	_shift_lock_time = 0.0
	_shift_cut_time = 0.0
	for slot_id in SLOT_IDS:
		_wheel_spin_angles[slot_id] = 0.0
		_wheel_last_grounded_lengths.erase(slot_id)
		_wheel_last_grounded_offsets.erase(slot_id)
		var wheel := _wheel_nodes.get(slot_id, null) as VehicleWheel3D
		if wheel == null:
			continue
		wheel.engine_force = 0.0
		wheel.brake = 0.0
		wheel.steering = 0.0


func _update_motion_state(delta: float) -> void:
	var flat_velocity := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var speed_mps := flat_velocity.length()
	_shift_lock_time = maxf(_shift_lock_time - delta, 0.0)
	_shift_cut_time = maxf(_shift_cut_time - delta, 0.0)
	var local_velocity := global_basis.inverse() * linear_velocity
	if Vector2(local_velocity.x, local_velocity.z).length() > 0.25:
		signed_slip_angle = atan2(local_velocity.x, local_velocity.z)
	else:
		signed_slip_angle = 0.0
	_update_steering_state(speed_mps, delta)
	_update_engine_state(speed_mps, delta)


func _update_engine_state(speed_mps: float, delta: float) -> void:
	var driven_rpm := _average_driven_wheel_rpm()
	if driven_rpm <= 0.01:
		driven_rpm = _speed_rpm_estimate(speed_mps)
	var gear_ratio := _active_gear_ratio()
	var drivetrain_ratio := absf(gear_ratio * config.final_drive_ratio)
	var target_rpm := clampf(driven_rpm * drivetrain_ratio, config.idle_rpm, config.engine_redline_rpm)
	if absf(speed_mps) <= 0.25:
		var free_rev_target = lerpf(config.idle_rpm, config.engine_redline_rpm, _hp2_throttle_command(speed_mps))
		target_rpm = maxf(target_rpm, free_rev_target * (0.45 + clampf(speed_mps / 30.0, 0.0, 0.55)))
	engine_rpm = move_toward(engine_rpm, target_rpm, maxf(config.engine_redline_rpm, 1000.0) * delta)
	_update_gear_state(speed_mps, delta)


func _update_gear_state(speed_mps: float, delta: float) -> void:
	var speed_kph := speed_mps * 3.6
	if current_gear >= 0:
		if speed_kph < 0.75:
			if _brake_input < 0.15:
				_reverse_ready = true
				_reverse_hold_time = 0.0
			elif _reverse_ready and _brake_input > 0.97 and _throttle_input < 0.05:
				_reverse_hold_time += delta
				if _reverse_hold_time >= 0.25:
					current_gear = -1
					_reverse_hold_time = 0.0
					_reverse_ready = false
					return
			else:
				_reverse_hold_time = 0.0
		else:
			_reverse_hold_time = 0.0
			_reverse_ready = false
	if current_gear < 0:
		if _throttle_input > 0.15 or (_brake_input < 0.2 and speed_kph < 0.5):
			current_gear = 1
			_reverse_hold_time = 0.0
			_reverse_ready = false
		return
	if _shift_lock_time > 0.0:
		return
	var throttle_alpha := pow(clampf(_throttle_input, 0.0, 1.0), 0.75)
	var brake_alpha := clampf(_brake_input, 0.0, 1.0)
	var upshift_rpm := lerpf(config.engine_peak_rpm * 0.88, config.engine_redline_rpm * 0.985, throttle_alpha)
	var downshift_rpm := lerpf(config.idle_rpm * 2.1, config.engine_peak_rpm * 0.7, maxf(throttle_alpha, brake_alpha))
	if brake_alpha > 0.25:
		downshift_rpm = maxf(downshift_rpm, config.engine_peak_rpm * 0.78)
	if current_gear < config.top_gear():
		var post_shift_rpm := _estimated_engine_rpm_for_gear(speed_mps, current_gear + 1)
		if engine_rpm >= upshift_rpm and post_shift_rpm >= config.idle_rpm * 1.35:
			current_gear += 1
			_shift_lock_time = 0.22
			_shift_cut_time = 0.11
			return
	if current_gear > 1:
		var lower_gear_rpm := _estimated_engine_rpm_for_gear(speed_mps, current_gear - 1)
		if engine_rpm <= downshift_rpm and lower_gear_rpm <= config.engine_redline_rpm * 0.98:
			current_gear -= 1
			_shift_lock_time = 0.14
			_shift_cut_time = 0.04


func _apply_wheel_forces() -> void:
	var service_brake_total := float(_vehicle_setup.get("service_brake_total", 24.0))
	var handbrake_total := float(_vehicle_setup.get("handbrake_total", 8.0))
	var speed_mps := Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()
	var throttle_command := _hp2_throttle_command(speed_mps)
	var reverse_command := 0.0
	if current_gear < 0:
		reverse_command = _brake_input
		throttle_command = 0.0
	var drive_input := throttle_command - reverse_command
	var engine_brake_total := _engine_braking_force_total(speed_mps, engine_rpm, current_gear)
	var drive_force_total: float = _godot_engine_force_total(speed_mps, engine_rpm, current_gear) * drive_input
	drive_force_total *= _shift_cut_scale()
	if current_gear >= 0 and throttle_command <= 0.02 and reverse_command <= 0.0 and _brake_input <= 0.05:
		drive_force_total -= engine_brake_total
	var brake_alpha := clampf(_brake_input, 0.0, 1.0) if current_gear >= 0 else 0.0
	var lock_entry := float(_vehicle_setup.get("brake_lock_entry", 0.78))
	var rear_lock_alpha := clampf((brake_alpha - lock_entry) / maxf(1.0 - lock_entry, 0.001), 0.0, 1.0)
	var brake_speed_scale := clampf((speed_mps * 3.6) / 40.0, 0.32, 1.0)
	var front_service_total := service_brake_total * 0.34 * brake_alpha * brake_speed_scale
	var rear_service_total := service_brake_total * 0.10 * brake_alpha * brake_speed_scale
	var rear_lock_total := service_brake_total * 0.56 * rear_lock_alpha * lerpf(0.5, 1.0, brake_speed_scale)
	for slot_id in SLOT_IDS:
		var wheel := _wheel_nodes.get(slot_id, null) as VehicleWheel3D
		if wheel == null:
			continue
		var drive_bias: float = config.drive_bias_for_slot(slot_id)
		wheel.engine_force = drive_force_total * drive_bias
		wheel.steering = _steering_state if wheel.use_as_steering else 0.0
		var brake_force := front_service_total * 0.5 if slot_id.begins_with("F") else rear_service_total * 0.5
		if current_gear < 0 and reverse_command > 0.0:
			brake_force = 0.0
		if slot_id.begins_with("R"):
			brake_force += rear_lock_total * 0.5
			brake_force += handbrake_total * 0.5 * _handbrake_input
		wheel.brake = brake_force
		_apply_dynamic_wheel_slip(slot_id, wheel, brake_alpha, rear_lock_alpha)


func _apply_drag_forces() -> void:
	var flat_velocity := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var speed_mps := flat_velocity.length()
	if speed_mps <= 0.001:
		_last_drag_force = Vector3.ZERO
		return
	_last_drag_force = _drag_force_vector(flat_velocity)
	apply_central_force(_last_drag_force)


func _apply_yaw_assist() -> void:
	var speed_mps := Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()
	var local_angular := global_basis.inverse() * angular_velocity
	var yaw_rate := local_angular.y
	var torque: float = -yaw_rate * config.yaw_damping * 40.0
	if speed_mps * 3.6 >= config.stabilization_min_speed_kph:
		var slip_deg := absf(rad_to_deg(signed_slip_angle))
		var drift_range := maxf(config.drift_slip_deg - config.stabilization_slip_deg, 0.001)
		var slip_alpha := clampf((slip_deg - config.stabilization_slip_deg) / drift_range, 0.0, 1.0)
		torque += -signf(signed_slip_angle) * config.yaw_assist * slip_alpha * 0.35
		torque += _steering_state * config.steering_yaw_assist * clampf(speed_mps / 30.0, 0.0, 1.0) * 0.25
	apply_torque(Vector3.UP * torque)


func _update_steering_state(speed_mps: float, delta: float) -> void:
	var speed_kph := speed_mps * 3.6
	var speed_alpha := clampf(speed_kph / maxf(config.high_speed_steer_kph, 1.0), 0.0, 1.0)
	var speed_scale := lerpf(config.low_speed_steer_scale, config.high_speed_steer_scale, speed_alpha)
	if not _steering_engaged and absf(_steering_input) >= config.steering_hysteresis_enter:
		_steering_engaged = true
	elif _steering_engaged and absf(_steering_input) <= config.steering_hysteresis_exit:
		_steering_engaged = false
	var engaged_scale := 1.0 if _steering_engaged else 0.7
	var target_angle := deg_to_rad(config.steering_max_degrees * config.steering_lock_scale)
	target_angle *= _steering_input * speed_scale * engaged_scale
	var response: float = config.steering_response if absf(_steering_input) > 0.01 else config.steering_return
	_steering_state = move_toward(_steering_state, target_angle, response * delta)


func _average_driven_wheel_rpm() -> float:
	var total := 0.0
	var count := 0
	for slot_id in SLOT_IDS:
		if config.drive_bias_for_slot(slot_id) <= 0.0:
			continue
		var wheel := _wheel_nodes.get(slot_id, null) as VehicleWheel3D
		if wheel == null:
			continue
		total += absf(wheel.get_rpm())
		count += 1
	return total / float(count) if count > 0 else 0.0


func _speed_rpm_estimate(speed_mps: float) -> float:
	var radius := maxf(config.driven_average_radius(), 0.1)
	return absf(speed_mps / (TAU * radius) * 60.0)


func _active_gear_ratio() -> float:
	if current_gear < 0:
		return config.reverse_gear_ratio
	return config.get_gear_ratio(current_gear)


func _update_inputs() -> void:
	_throttle_input = _read_action_pair("car_accelerate", "ui_up")
	_brake_input = _read_action_pair("car_brake", "ui_down")
	_handbrake_input = _read_action_pair("car_handbrake", "")
	_steering_input = _read_action_pair("car_steer_left", "ui_left") - _read_action_pair("car_steer_right", "ui_right")


func _read_action_pair(primary_action: String, fallback_action: String) -> float:
	if primary_action != "" and InputMap.has_action(primary_action):
		return Input.get_action_strength(primary_action)
	if fallback_action != "" and InputMap.has_action(fallback_action):
		return Input.get_action_strength(fallback_action)
	return 0.0


func _hp2_drive_force_total(speed_mps: float, rpm: float, gear: int) -> float:
	var gear_ratio := _gear_ratio_for_force(gear)
	return config.sample_engine_force(speed_mps, rpm) * absf(gear_ratio * config.final_drive_ratio)


func _godot_engine_force_total(speed_mps: float, rpm: float, gear: int) -> float:
	var fade_kph := maxf(float(_vehicle_setup.get("low_speed_torque_fade_kph", 90.0)), 1.0)
	var speed_alpha := clampf((speed_mps * 3.6) / fade_kph, 0.0, 1.0)
	var launch_boost := lerpf(float(_vehicle_setup.get("low_speed_torque_boost", 1.0)), 1.0, speed_alpha)
	return _hp2_drive_force_total(speed_mps, rpm, gear) * float(_vehicle_setup.get("engine_force_normalization_gain", 0.0)) * launch_boost


func _engine_braking_force_total(speed_mps: float, rpm: float, gear: int) -> float:
	if gear < 0 or speed_mps <= 0.1:
		return 0.0
	var rpm_alpha := clampf(inverse_lerp(config.idle_rpm, config.engine_redline_rpm, rpm), 0.0, 1.0)
	var hp2_force := _hp2_drive_force_total(speed_mps, rpm, gear)
	var engine_brake_gain := float(_vehicle_setup.get("engine_brake_gain", 0.09))
	var coast_drag_gain := float(_vehicle_setup.get("coast_drag_gain", 0.025))
	var engine_brake := hp2_force * engine_brake_gain * lerpf(0.45, 1.0, rpm_alpha)
	var coast_drag := speed_mps * mass * coast_drag_gain
	return engine_brake + coast_drag


func _hp2_throttle_command(speed_mps: float) -> float:
	var throttle_alpha := clampf(_throttle_input, 0.0, 1.0)
	var shaped := pow(throttle_alpha, 0.72)
	var launch_alpha := clampf(1.0 - (speed_mps * 3.6) / 95.0, 0.0, 1.0)
	if current_gear == 1:
		shaped = lerpf(shaped, minf(shaped * 1.18 + throttle_alpha * 0.1, 1.0), launch_alpha)
	return shaped


func _shift_cut_scale() -> float:
	if _shift_cut_time <= 0.0:
		return 1.0
	var alpha := clampf(_shift_cut_time / 0.11, 0.0, 1.0)
	return lerpf(1.0, 0.2, alpha)


func _estimated_engine_rpm_for_gear(speed_mps: float, gear: int) -> float:
	var wheel_rpm := _speed_rpm_estimate(speed_mps)
	var drivetrain_ratio := absf(_gear_ratio_for_force(gear) * config.final_drive_ratio)
	return clampf(wheel_rpm * drivetrain_ratio, config.idle_rpm, config.engine_redline_rpm)


func _gear_ratio_for_force(gear: int) -> float:
	if gear < 0:
		return config.reverse_gear_ratio
	return config.get_gear_ratio(maxi(gear, 1))


func _drag_force_vector(flat_velocity: Vector3) -> Vector3:
	var speed_mps := flat_velocity.length()
	if speed_mps <= 0.001:
		return Vector3.ZERO
	var direction := flat_velocity.normalized()
	var rolling_coeff := float(_vehicle_setup.get("rolling_resistance", config.rolling_resistance))
	var aero_coeff := float(_vehicle_setup.get("aero_drag", config.aero_drag))
	var rolling_force: Vector3 = -direction * rolling_coeff * mass * 9.8
	var aero_force: Vector3 = -direction * aero_coeff * speed_mps * speed_mps * mass
	return rolling_force + aero_force


func _apply_dynamic_wheel_slip(slot_id: String, wheel: VehicleWheel3D, brake_alpha: float, rear_lock_alpha: float) -> void:
	var base_slip := float(_wheel_base_slip.get(slot_id, wheel.wheel_friction_slip))
	var slip := base_slip
	if slot_id.begins_with("F") and brake_alpha > 0.0:
		var front_scale := float(_vehicle_setup.get("front_brake_slip_scale", 0.92))
		slip = lerpf(slip, base_slip * front_scale, brake_alpha)
	else:
		var rear_scale := float(_vehicle_setup.get("rear_brake_lock_slip_scale", 0.34))
		slip = lerpf(slip, base_slip * rear_scale, rear_lock_alpha)
		var hand_scale := float(_vehicle_setup.get("handbrake_rear_slip_scale", 0.22))
		slip = lerpf(slip, base_slip * hand_scale, clampf(_handbrake_input, 0.0, 1.0))
	wheel.wheel_friction_slip = maxf(slip, 1.2)


func _update_visuals(delta: float) -> void:
	var speed_mps := Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()
	for slot_id in SLOT_IDS:
		var wheel := _wheel_nodes.get(slot_id, null) as VehicleWheel3D
		if wheel == null:
			continue
		var suspension_node := _wheel_suspension_nodes.get(slot_id, null) as Node3D
		var pivot_node := _wheel_pivots.get(slot_id, null) as Node3D
		var steer_node := _wheel_visuals.get(slot_id, null) as Node3D
		var roll_node := _wheel_roll_visuals.get(slot_id, null) as Node3D
		if suspension_node != null and pivot_node != null:
			# HP2 keeps the authored wheel attachment on the pivot itself and only feeds
			# the live suspension travel back into the child node.
			suspension_node.position = VehicleBodyConfigAdapter.visual_space_from_vehicle(
				_current_visual_wheel_offset_vehicle(slot_id, wheel)
			)
		if steer_node != null:
			var steer_rotation := steer_node.rotation
			steer_rotation.y = _visual_steering_angle(wheel)
			steer_node.rotation = steer_rotation
		if roll_node != null:
			var visual_rpm := _visual_wheel_rpm(slot_id, wheel, speed_mps)
			_wheel_spin_angles[slot_id] = float(_wheel_spin_angles.get(slot_id, 0.0)) + visual_rpm * TAU / 60.0 * delta
			var roll_rotation := roll_node.rotation
			roll_rotation.x = float(_wheel_spin_angles.get(slot_id, 0.0)) * float(roll_node.get_meta("eagl_spin_direction", 1.0))
			roll_node.rotation = roll_rotation


func _current_wheel_center_vehicle(wheel: VehicleWheel3D, slot_id: String = "") -> Vector3:
	var wheel_center_rest := _wheel_attachment_rest_vehicle(slot_id, wheel)
	if freeze:
		return wheel_center_rest
	if _wheel_node_position_matches_setup(wheel, wheel_center_rest):
		return wheel.position
	var suspension_length := _current_wheel_suspension_length(slot_id, wheel)
	return wheel_center_rest + Vector3.UP * (wheel.wheel_rest_length - suspension_length)


func _current_visual_wheel_center_vehicle(slot_id: String, wheel: VehicleWheel3D) -> Vector3:
	var pivot := _current_wheel_pivot_vehicle(slot_id)
	return pivot + _current_visual_wheel_offset_vehicle(slot_id, wheel)


func _current_visual_wheel_offset_vehicle(slot_id: String, wheel: VehicleWheel3D) -> Vector3:
	var runtime_offset := _current_wheel_center_vehicle(wheel, slot_id) - _wheel_attachment_rest_vehicle(slot_id, wheel)
	return Vector3(0.0, runtime_offset.y, 0.0)


func _wheel_attachment_rest_vehicle(slot_id: String, wheel: VehicleWheel3D) -> Vector3:
	var wheel_data: Dictionary = _vehicle_setup.get("wheels", {}).get(slot_id, {})
	var wheel_center_rest: Variant = wheel_data.get("wheel_center_rest", null)
	if wheel_center_rest is Vector3:
		return wheel_center_rest
	return wheel.position - Vector3.UP * wheel.wheel_rest_length


func _wheel_attachment_origin_vehicle(slot_id: String, wheel: VehicleWheel3D) -> Vector3:
	var wheel_data: Dictionary = _vehicle_setup.get("wheels", {}).get(slot_id, {})
	var attachment_origin: Variant = wheel_data.get("position", null)
	if attachment_origin is Vector3:
		return attachment_origin
	return wheel.position


func _current_visual_suspension_offset(slot_id: String, wheel: VehicleWheel3D) -> float:
	var neutral_height := _wheel_static_ride_height(slot_id)
	if wheel.is_in_contact():
		var pivot := _current_wheel_pivot_vehicle(slot_id)
		var contact := to_local(wheel.get_contact_point())
		var grounded_offset := contact.y + _ground_contact_radius(slot_id, wheel) - pivot.y
		_wheel_last_grounded_offsets[slot_id] = grounded_offset
		return grounded_offset
	var cached: Variant = _wheel_last_grounded_offsets.get(slot_id, null)
	if cached is float:
		return float(cached)
	return neutral_height


func _current_wheel_suspension_length(slot_id: String, wheel: VehicleWheel3D) -> float:
	if freeze:
		return wheel.wheel_rest_length
	var wheel_center_rest := _wheel_attachment_rest_vehicle(slot_id, wheel)
	if _wheel_node_position_matches_setup(wheel, wheel_center_rest):
		return maxf(_wheel_attachment_origin_vehicle(slot_id, wheel).y - wheel.position.y, 0.0)
	if wheel.is_in_contact():
		var suspension_length := _projected_wheel_suspension_length(wheel, slot_id)
		if slot_id != "":
			_wheel_last_grounded_lengths[slot_id] = suspension_length
		return suspension_length
	if slot_id != "":
		var cached: Variant = _wheel_last_grounded_lengths.get(slot_id, wheel.wheel_rest_length)
		if cached is float:
			return float(cached)
	return wheel.wheel_rest_length


func _update_debug_snapshot() -> void:
	var flat_velocity := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var wheel_rows: Array[Dictionary] = []
	for slot_id in SLOT_IDS:
		var wheel := _wheel_nodes.get(slot_id, null) as VehicleWheel3D
		if wheel == null:
			continue
		var contact_point := wheel.get_contact_point()
		var suspension_length := _projected_wheel_suspension_length(wheel, slot_id)
		wheel_rows.append({
			"slot": slot_id,
			"grounded": wheel.is_in_contact(),
			"rpm": wheel.get_rpm(),
			"skid": wheel.get_skidinfo(),
			"steering_deg": rad_to_deg(wheel.steering),
			"engine_force": wheel.engine_force,
			"brake_force": wheel.brake,
			"suspension_length": suspension_length,
		})
	_debug_snapshot = {
		"speed_kph": flat_velocity.length() * 3.6,
		"rpm": engine_rpm,
		"gear": current_gear,
		"slip_angle_deg": rad_to_deg(signed_slip_angle),
		"steering_deg": rad_to_deg(_steering_state),
		"mass_kg": mass,
		"mass_is_estimate": bool(_vehicle_setup.get("mass_is_estimate", false)),
		"driven_wheel_count": int(_vehicle_setup.get("driven_wheel_count", 0)),
		"engine_force_gain": float(_vehicle_setup.get("engine_force_normalization_gain", 0.0)),
		"hp2_launch_accel_reference": float(_vehicle_setup.get("hp2_launch_accel_reference", 0.0)),
		"drag_force": _last_drag_force.length(),
		"engine_force_total": _godot_engine_force_total(flat_velocity.length(), engine_rpm, current_gear),
		"engine_brake_total": _engine_braking_force_total(flat_velocity.length(), engine_rpm, current_gear),
		"wheels": wheel_rows,
	}


func _visual_steering_angle(wheel: VehicleWheel3D) -> float:
	return -wheel.steering


func _visual_wheel_rpm(slot_id: String, wheel: VehicleWheel3D, speed_mps: float) -> float:
	var rpm := wheel.get_rpm()
	if not slot_id.begins_with("R"):
		return rpm
	var brake_alpha := clampf((_brake_input - 0.2) / 0.8, 0.0, 1.0)
	var handbrake_alpha := clampf(_handbrake_input, 0.0, 1.0)
	var lock_alpha := maxf(handbrake_alpha, brake_alpha)
	if lock_alpha <= 0.0 or wheel.brake <= 0.0:
		return rpm
	var speed_alpha := clampf((speed_mps * 3.6) / 120.0, 0.0, 1.0)
	var hard_brake_alpha := clampf((_brake_input - 0.72) / 0.28, 0.0, 1.0)
	var target_lock := maxf(lock_alpha * 0.85, hard_brake_alpha)
	var speed_scaled_lock := lerpf(target_lock, minf(target_lock * 0.75, 1.0), speed_alpha)
	return lerpf(rpm, 0.0, speed_scaled_lock)


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


func _rebuild_debug_mesh() -> void:
	if _debug_mesh_instance == null:
		return
	_debug_mesh.clear_surfaces()
	_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_add_collision_wireframe()
	for slot_id in SLOT_IDS:
		var wheel := _wheel_nodes.get(slot_id, null) as VehicleWheel3D
		if wheel == null:
			continue
		var origin := _current_wheel_pivot_vehicle(slot_id)
		var visual_center := _current_visual_wheel_center_vehicle(slot_id, wheel)
		var physical_center := _current_wheel_center_vehicle(wheel, slot_id)
		var contact := to_local(wheel.get_contact_point())
		var projected_contact := Vector3(physical_center.x, contact.y, physical_center.z)
		_debug_mesh.surface_set_color(Color(0.15, 0.9, 0.95, 0.95))
		_debug_mesh.surface_add_vertex(origin)
		_debug_mesh.surface_add_vertex(visual_center)
		_debug_mesh.surface_set_color(Color(1.0, 0.35, 0.95, 0.9))
		_debug_mesh.surface_add_vertex(visual_center)
		_debug_mesh.surface_add_vertex(physical_center)
		_debug_mesh.surface_set_color(Color(1.0, 0.75, 0.2, 0.95))
		_debug_mesh.surface_add_vertex(visual_center + Vector3.LEFT * 0.08)
		_debug_mesh.surface_add_vertex(visual_center + Vector3.RIGHT * 0.08)
		_debug_mesh.surface_add_vertex(visual_center + Vector3.UP * 0.08)
		_debug_mesh.surface_add_vertex(visual_center + Vector3.DOWN * 0.08)
		_debug_mesh.surface_set_color(Color(0.9, 0.95, 1.0, 0.9))
		_debug_mesh.surface_add_vertex(physical_center + Vector3.LEFT * 0.06)
		_debug_mesh.surface_add_vertex(physical_center + Vector3.RIGHT * 0.06)
		_debug_mesh.surface_add_vertex(physical_center + Vector3.UP * 0.06)
		_debug_mesh.surface_add_vertex(physical_center + Vector3.DOWN * 0.06)
		_add_physics_wheel_outline(physical_center, wheel, Color(0.15, 0.65, 1.0, 0.9))
		if wheel.is_in_contact():
			_debug_mesh.surface_set_color(Color(0.25, 1.0, 0.3, 0.95))
			_debug_mesh.surface_add_vertex(physical_center)
			_debug_mesh.surface_add_vertex(projected_contact)
			_debug_mesh.surface_add_vertex(projected_contact + Vector3.LEFT * 0.06)
			_debug_mesh.surface_add_vertex(projected_contact + Vector3.RIGHT * 0.06)
			_debug_mesh.surface_add_vertex(projected_contact + Vector3.FORWARD * 0.06)
			_debug_mesh.surface_add_vertex(projected_contact + Vector3.BACK * 0.06)
			if projected_contact.distance_to(contact) > 0.01:
				_debug_mesh.surface_set_color(Color(1.0, 0.65, 0.2, 0.9))
				_debug_mesh.surface_add_vertex(projected_contact)
				_debug_mesh.surface_add_vertex(contact)
				_debug_mesh.surface_add_vertex(contact + Vector3.LEFT * 0.035)
				_debug_mesh.surface_add_vertex(contact + Vector3.RIGHT * 0.035)
				_debug_mesh.surface_add_vertex(contact + Vector3.FORWARD * 0.035)
				_debug_mesh.surface_add_vertex(contact + Vector3.BACK * 0.035)
	_debug_mesh.surface_set_color(Color(1.0, 0.15, 0.15, 1.0))
	_debug_mesh.surface_add_vertex(Vector3.ZERO)
	_debug_mesh.surface_add_vertex(VEHICLE_FORWARD * 1.5)
	var com_local := center_of_mass
	_debug_mesh.surface_set_color(Color(0.85, 0.35, 1.0, 0.95))
	_debug_mesh.surface_add_vertex(com_local + Vector3.LEFT * 0.09)
	_debug_mesh.surface_add_vertex(com_local + Vector3.RIGHT * 0.09)
	_debug_mesh.surface_add_vertex(com_local + Vector3.UP * 0.09)
	_debug_mesh.surface_add_vertex(com_local + Vector3.DOWN * 0.09)
	_debug_mesh.surface_add_vertex(com_local + Vector3.FORWARD * 0.09)
	_debug_mesh.surface_add_vertex(com_local + Vector3.BACK * 0.09)
	_debug_mesh.surface_end()


func _add_physics_wheel_outline(center: Vector3, wheel: VehicleWheel3D, color: Color) -> void:
	var radius := maxf(wheel.wheel_radius, 0.01)
	var wheel_basis := _debug_wheel_basis_vehicle(wheel)
	var radial_up := (wheel_basis * Vector3.UP).normalized()
	var radial_forward := (wheel_basis * VEHICLE_FORWARD).normalized()
	_debug_mesh.surface_set_color(color)
	for index in range(DEBUG_WHEEL_PHYSICS_SEGMENTS):
		var angle_0 := TAU * float(index) / float(DEBUG_WHEEL_PHYSICS_SEGMENTS)
		var angle_1 := TAU * float(index + 1) / float(DEBUG_WHEEL_PHYSICS_SEGMENTS)
		var point_0 := center + (radial_up * cos(angle_0) + radial_forward * sin(angle_0)) * radius
		var point_1 := center + (radial_up * cos(angle_1) + radial_forward * sin(angle_1)) * radius
		_debug_mesh.surface_add_vertex(point_0)
		_debug_mesh.surface_add_vertex(point_1)
	_debug_mesh.surface_add_vertex(center - radial_up * radius)
	_debug_mesh.surface_add_vertex(center + radial_up * radius)
	_debug_mesh.surface_add_vertex(center - radial_forward * radius)
	_debug_mesh.surface_add_vertex(center + radial_forward * radius)


func _debug_wheel_basis_vehicle(wheel: VehicleWheel3D) -> Basis:
	if not wheel.use_as_steering:
		return Basis.IDENTITY
	return Basis(Vector3.UP, wheel.steering)


func _current_wheel_pivot_vehicle(slot_id: String) -> Vector3:
	var pivot_node := _wheel_pivots.get(slot_id, null) as Node3D
	if pivot_node != null:
		return to_local(pivot_node.global_position)
	var wheel := _wheel_nodes.get(slot_id, null) as VehicleWheel3D
	if wheel != null:
		return to_local(wheel.global_position)
	return Vector3.ZERO


func _projected_wheel_suspension_length(wheel: VehicleWheel3D, slot_id: String = "") -> float:
	var wheel_origin_local := _wheel_attachment_origin_vehicle(slot_id, wheel)
	var contact_local := to_local(wheel.get_contact_point())
	return maxf(wheel_origin_local.y - contact_local.y - wheel.wheel_radius, 0.0)


func _wheel_node_position_matches_setup(wheel: VehicleWheel3D, wheel_center_rest: Vector3) -> bool:
	var horizontal_delta := Vector2(
		wheel.position.x - wheel_center_rest.x,
		wheel.position.z - wheel_center_rest.z
	).length()
	return horizontal_delta <= WHEEL_NODE_ANCHOR_EPSILON


func _resolved_visual_wheel_radius(slot_id: String, wheel: VehicleWheel3D) -> float:
	return maxf(float(_wheel_visual_radii.get(slot_id, wheel.wheel_radius)), wheel.wheel_radius)


func _ground_contact_radius(slot_id: String, wheel: VehicleWheel3D) -> float:
	var visual_radius := _resolved_visual_wheel_radius(slot_id, wheel)
	# Some HP2 tire meshes are a little fatter/taller than the handling radius. If we
	# let the visual AABB fully drive the contact floor, the wheel sits visibly too high.
	# Use the physics radius as the main ground reference and allow only a tiny visual pad.
	return minf(visual_radius, wheel.wheel_radius + 0.006)


func _wheel_static_ride_height(slot_id: String) -> float:
	var wheel_data: Dictionary = _vehicle_setup.get("wheels", {}).get(slot_id, {})
	return float(wheel_data.get("static_ride_height", 0.0))


func _visual_radius_from_node(node: Node3D) -> float:
	var max_radius := 0.0
	for child in node.get_children():
		if not (child is MeshInstance3D):
			continue
		var mesh_instance := child as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var local_aabb := mesh_instance.transform * mesh_instance.mesh.get_aabb()
		var diameter := maxf(local_aabb.size.y, local_aabb.size.z)
		max_radius = maxf(max_radius, diameter * 0.5)
	return max_radius


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
	_debug_mesh.surface_set_color(Color(1.0, 1.0, 1.0, 0.9))
	for edge in edges:
		var start: Vector3 = collision_shape.transform * corners[edge.x]
		var finish: Vector3 = collision_shape.transform * corners[edge.y]
		_debug_mesh.surface_add_vertex(start)
		_debug_mesh.surface_add_vertex(finish)


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
	if box_shape == null:
		return
	if _visual_root == null:
		return
	var body_root := _visual_root.get_node_or_null("CarVisual/Body") as Node3D
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
			var point := to_local(mesh_instance.global_transform * corner)
			if not has_bounds:
				min_point = point
				max_point = point
				has_bounds = true
			else:
				min_point = min_point.min(point)
				max_point = max_point.max(point)
	if not has_bounds:
		return
	box_shape.size = (max_point - min_point).abs()
	collision_shape.position = (min_point + max_point) * 0.5
