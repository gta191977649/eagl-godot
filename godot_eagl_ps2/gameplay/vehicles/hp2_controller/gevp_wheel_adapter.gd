class_name HP2GevpWheelAdapter
extends Wheel


const HP2WheelScript = preload("res://gameplay/vehicles/hp2_controller/wheel.gd")
const CATEGORY_MAP := {
	"asphalt": "Road",
	"road": "Road",
	"drivearea": "Road",
	"terrain": "Dirt",
	"dirt": "Dirt",
	"grass": "Grass",
}

const SLOT_IDS := ["FL", "FR", "RL", "RR"]

var hp2_runtime = HP2WheelScript.new()
var hp2_slot_id := ""
var hp2_surface_scale := 1.0
var hp2_grip_scale_long := 1.0
var hp2_grip_scale_lat := 1.0
var hp2_force_regime := "airborne"
var hp2_solver_name := "hp2_lambda"

var _last_drive_torque := 0.0
var _last_brake_torque := 0.0


func initialize() -> void:
	super.initialize()
	hp2_slot_id = _infer_slot_id()
	hp2_runtime.slot_id = hp2_slot_id
	hp2_runtime.wheel_radius = tire_radius
	_sync_hp2_runtime_config()
	_reset_hp2_contact_state()


func process_torque(drive: float, drive_inertia: float, brake_torque: float, allow_abs: bool, delta: float) -> float:
	_last_drive_torque = drive
	_last_brake_torque = brake_torque

	var net_torque := force_vector.y * tire_radius
	var previous_spin := spin
	net_torque += drive

	if abs_enable_time > vehicle.delta_time:
		brake_torque = 0.0
		allow_abs = false

	if absf(spin) > 5.0 and spin_velocity_diff < abs_spin_difference_threshold:
		if allow_abs and brake_torque > 0.0:
			brake_torque = 0.0
			abs_enable_time = vehicle.delta_time + abs_pulse_time

	if is_zero_approx(spin):
		applied_torque = absf(drive - brake_torque)
	else:
		applied_torque = absf(drive - (brake_torque * signf(spin)))

	if absf(spin) < 5.0 and brake_torque > absf(net_torque):
		if allow_abs and absf(local_velocity.z) > 2.0:
			abs_enable_time = vehicle.delta_time + abs_pulse_time
		else:
			spin = 0.0
	else:
		net_torque -= brake_torque * signf(spin)
		var new_spin: float = spin + ((net_torque / (wheel_moment + drive_inertia)) * delta)
		if signf(spin) != signf(new_spin) and brake_torque > absf(drive):
			new_spin = 0.0
		spin = new_spin

	if is_zero_approx(drive * delta):
		return 0.5
	return (spin - previous_spin) * (wheel_moment + drive_inertia) / (drive * delta)


func process_forces(opposite_compression: float, braking: bool, delta: float) -> float:
	force_raycast_update()
	previous_velocity = local_velocity
	local_velocity = (global_position - previous_global_position) / delta * global_transform.basis
	previous_global_position = global_position

	if is_colliding():
		last_collider = get_collider()
		last_collision_point = get_collision_point()
		last_collision_normal = get_collision_normal()
		var resolved_surface := _resolved_surface_type(last_collider)
		if surface_type != resolved_surface:
			_set_surface_profile(resolved_surface)
	else:
		last_collider = null
		last_collision_point = global_position + Vector3.DOWN * tire_radius
		last_collision_normal = Vector3.UP

	var off_driveable_surface := _is_off_driveable_surface()
	if off_driveable_surface:
		_apply_off_surface_profile()

	var compression := process_suspension(opposite_compression, delta)
	if is_colliding() and last_collider:
		process_tires(braking, delta)
		var contact := last_collision_point - vehicle.global_position
		if spring_force > 0.0:
			vehicle.apply_force(last_collision_normal * spring_force, contact)
		else:
			vehicle.apply_force(-global_transform.basis.y * vehicle.mass, global_position - vehicle.global_position)

		vehicle.apply_force(global_transform.basis.x * force_vector.x, contact)
		vehicle.apply_force(global_transform.basis.z * force_vector.y, contact)

		if braking:
			wheel_to_body_torque_multiplier = 1.0 / (braking_grip_multiplier + 1.0)
		vehicle.apply_force(-global_transform.basis.y * force_vector.y * 0.5 * wheel_to_body_torque_multiplier, to_global(Vector3.FORWARD * tire_radius))
		vehicle.apply_force(global_transform.basis.y * force_vector.y * 0.5 * wheel_to_body_torque_multiplier, to_global(Vector3.BACK * tire_radius))
		return compression

	_sync_hp2_runtime_config()
	hp2_runtime.drive_torque = _last_drive_torque
	hp2_runtime.brake_torque = _last_brake_torque
	hp2_runtime.update_airborne_angular_velocity(delta)
	spin = hp2_runtime.angular_velocity
	force_vector = Vector2.ZERO
	slip_vector = Vector2.ZERO
	_reset_hp2_contact_state()
	return 0.0


func process_tires(braking: bool, delta: float) -> void:
	_sync_hp2_runtime_config()
	hp2_runtime.wheel_radius = tire_radius
	hp2_runtime.surface_mu = maxf(current_cof, 0.05)
	hp2_runtime.drive_torque = _last_drive_torque
	hp2_runtime.brake_torque = _last_brake_torque
	hp2_surface_scale = hp2_runtime.surface_mu
	hp2_grip_scale_long = _hp2_grip_scale(false)
	hp2_grip_scale_lat = _hp2_grip_scale(true) * _hp2_drift_lateral_scale()
	hp2_runtime.grip_scale = hp2_grip_scale_long
	hp2_runtime.lat_grip_scale = hp2_grip_scale_lat

	var filtered_load := hp2_runtime.update_filtered_load(maxf(spring_force, 0.0), delta)
	hp2_runtime.normal_load = filtered_load
	hp2_runtime.angular_velocity = spin

	var contact_long_velocity := -local_velocity.z
	var contact_lat_velocity := local_velocity.x
	var wheel_surface_velocity := spin * tire_radius
	hp2_runtime.set_contact_slip_velocity(wheel_surface_velocity - contact_long_velocity, contact_lat_velocity)

	var wheel_effective_mass := maxf(filtered_load / maxf(vehicle.current_gravity.length(), 0.001), 0.0)
	var brake_direction := signf(contact_long_velocity)
	if is_zero_approx(brake_direction):
		brake_direction = 0.0 if is_zero_approx(spin) else signf(spin)
	var raw_drive_force := _last_drive_torque / maxf(tire_radius, 0.0001)
	var engine_brake := 0.0
	var drive_force_request := raw_drive_force
	if raw_drive_force < 0.0 and not _is_reversing():
		var stop_force := wheel_effective_mass * absf(contact_long_velocity) / maxf(delta, 0.0001)
		engine_brake = minf(-raw_drive_force, stop_force)
		drive_force_request = 0.0
	var brake_force_request := ((_last_brake_torque / maxf(tire_radius, 0.0001)) + engine_brake) * brake_direction
	var lateral_force_request := contact_lat_velocity * wheel_effective_mass / maxf(delta, 0.0001)
	hp2_runtime.compute_contact_forces(drive_force_request - brake_force_request, lateral_force_request)
	hp2_runtime.update_angular_velocity(delta, contact_long_velocity)
	spin = hp2_runtime.angular_velocity

	# HP2 helper returns positive longitudinal force for "vehicle forward".
	# In the current GEVP wheel basis, forward traction is represented by negative Y force.
	force_vector.y = -hp2_runtime.force_long
	force_vector.x = hp2_runtime.force_lat
	if not is_zero_approx(contact_long_velocity):
		force_vector.y += process_rolling_resistance() * signf(contact_long_velocity)

	slip_vector.x = deg_to_rad(hp2_runtime.slip_angle_deg)
	slip_vector.y = hp2_runtime.combined_slip_ratio
	spin_velocity_diff = wheel_surface_velocity - contact_long_velocity
	limit_spin = hp2_runtime.slip_locked or (braking and absf(spin_velocity_diff) > absf(abs_spin_difference_threshold))
	hp2_force_regime = "abs" if braking and limit_spin else ("clamped" if hp2_runtime.slip_locked else "linear")


func get_hp2_debug_state() -> Dictionary:
	return {
		"solver": hp2_solver_name,
		"force_regime": hp2_force_regime,
		"surface_scale": hp2_surface_scale,
		"grip_scale_long": hp2_grip_scale_long,
		"grip_scale_lat": hp2_grip_scale_lat,
		"normal_load_filtered": hp2_runtime.normal_load,
		"lambda_long": hp2_runtime.lambda_long,
		"lambda_lat": hp2_runtime.lambda_lat,
		"combined_slip_ratio": hp2_runtime.combined_slip_ratio,
		"slip_speed_long": hp2_runtime.slip_speed_long,
		"slip_speed_lat": hp2_runtime.slip_speed_lat,
		"slip_angle_deg": hp2_runtime.slip_angle_deg,
	}


func _resolved_surface_type(collider: Object) -> String:
	var fallback := "Road"
	if vehicle != null and vehicle.has_method("default_wheel_surface_name"):
		fallback = String(vehicle.call("default_wheel_surface_name"))
	for candidate in _surface_candidates(collider):
		var mapped: String = String(CATEGORY_MAP.get(candidate.to_lower(), ""))
		if mapped != "":
			return mapped
	return fallback


func _surface_candidates(collider: Object) -> Array[String]:
	var out: Array[String] = []
	if collider == null:
		return out
	if collider is Node:
		var node := collider as Node
		out.append_array(_node_surface_candidates(node))
		var parent := node.get_parent()
		if parent is Node:
			out.append_array(_node_surface_candidates(parent))
	return out


func _node_surface_candidates(node: Node) -> Array[String]:
	var out: Array[String] = []
	for group_name in node.get_groups():
		out.append(String(group_name))
	var meta_category := String(node.get_meta("eagl_collision_category", "")).strip_edges()
	if meta_category != "":
		out.append(meta_category)
	var node_name := String(node.name)
	if node_name != "":
		out.append(node_name)
	return out


func _set_surface_profile(new_surface: String) -> void:
	surface_type = new_surface if coefficient_of_friction.has(new_surface) else _first_surface_name()
	current_cof = coefficient_of_friction.get(surface_type, coefficient_of_friction.get(_first_surface_name(), 1.0))
	current_rolling_resistance = rolling_resistance.get(surface_type, rolling_resistance.get(_first_surface_name(), 1.0))
	current_lateral_grip_assist = lateral_grip_assist.get(surface_type, lateral_grip_assist.get(_first_surface_name(), 0.0))
	current_longitudinal_grip_ratio = longitudinal_grip_ratio.get(surface_type, longitudinal_grip_ratio.get(_first_surface_name(), 0.5))
	current_tire_stiffness = 1000000.0 + 8000000.0 * float(tire_stiffnesses.get(surface_type, tire_stiffnesses.get(_first_surface_name(), 1.0)))
	hp2_surface_scale = current_cof


func _apply_off_surface_profile() -> void:
	var grass_surface := "Grass" if coefficient_of_friction.has("Grass") else _first_surface_name()
	var friction_scale := 0.25
	if vehicle != null:
		friction_scale = float(vehicle.get("drive_area_off_surface_friction_scale"))
	surface_type = grass_surface
	current_cof = float(coefficient_of_friction.get(grass_surface, 1.0)) * friction_scale
	current_rolling_resistance = float(rolling_resistance.get(grass_surface, 4.0))
	current_lateral_grip_assist = float(lateral_grip_assist.get(grass_surface, 0.0))
	current_longitudinal_grip_ratio = float(longitudinal_grip_ratio.get(grass_surface, 0.45))
	current_tire_stiffness = (1000000.0 + 8000000.0 * float(tire_stiffnesses.get(grass_surface, 0.5))) * friction_scale
	hp2_surface_scale = current_cof


func _is_off_driveable_surface() -> bool:
	if vehicle == null:
		return false
	if not bool(vehicle.get("drive_area_surface_filter_enabled")):
		return false
	if not vehicle.has_method("is_driveable_point"):
		return false
	return not bool(vehicle.call("is_driveable_point", last_collision_point))


func _first_surface_name() -> String:
	if coefficient_of_friction.is_empty():
		return "Road"
	return String(coefficient_of_friction.keys()[0])


func _sync_hp2_runtime_config() -> void:
	hp2_runtime.slot_id = hp2_slot_id
	hp2_runtime.wheel_radius = tire_radius
	var config = _vehicle_config()
	if config == null:
		return
	var is_front := hp2_slot_id in ["FL", "FR"]
	hp2_runtime.spring_coefficient = float(config.front_spring_coefficient if is_front else config.rear_spring_coefficient)
	hp2_runtime.bump_damping = float(config.front_bump_damping if is_front else config.rear_bump_damping)
	hp2_runtime.rebound_damping = float(config.front_rebound_damping if is_front else config.rear_rebound_damping)


func _vehicle_config():
	if vehicle == null:
		return null
	return vehicle.get("config")


func _hp2_grip_scale(is_lateral: bool) -> float:
	var config = _vehicle_config()
	if config == null:
		return 1.0
	var is_front := hp2_slot_id in ["FL", "FR"]
	if is_lateral:
		return float(config.front_lateral_grip if is_front else config.rear_lateral_grip)
	return float(config.front_longitudinal_grip if is_front else config.rear_longitudinal_grip)


func _hp2_drift_lateral_scale() -> float:
	var config = _vehicle_config()
	if config == null:
		return 1.0
	var body_slip_deg := 0.0
	if vehicle != null and vehicle.has_method("get_hp2_body_slip_angle_deg"):
		body_slip_deg = absf(float(vehicle.call("get_hp2_body_slip_angle_deg")))
	var reduction_range := maxf(float(config.drift_slip_deg) - float(config.stabilization_slip_deg), 0.001)
	var reduction_alpha := clampf((body_slip_deg - float(config.stabilization_slip_deg)) / reduction_range, 0.0, 1.0)
	return lerpf(1.0, float(config.drift_grip_scale), reduction_alpha)


func _is_reversing() -> bool:
	if vehicle == null:
		return false
	return int(vehicle.get("current_gear")) < 0 or local_velocity.z > 0.0


func _infer_slot_id() -> String:
	var normalized_name := String(name).to_lower()
	if "frontleft" in normalized_name:
		return "FL"
	if "frontright" in normalized_name:
		return "FR"
	if "rearleft" in normalized_name:
		return "RL"
	if "rearright" in normalized_name:
		return "RR"
	for slot_id in SLOT_IDS:
		if normalized_name.ends_with(slot_id.to_lower()):
			return slot_id
	return "FL"


func _reset_hp2_contact_state() -> void:
	hp2_runtime.set_contact_slip_velocity(0.0, 0.0)
	hp2_runtime.compute_contact_forces(0.0, 0.0)
	hp2_surface_scale = current_cof if current_cof > 0.0 else 1.0
	hp2_grip_scale_long = _hp2_grip_scale(false)
	hp2_grip_scale_lat = _hp2_grip_scale(true)
	hp2_force_regime = "airborne"
