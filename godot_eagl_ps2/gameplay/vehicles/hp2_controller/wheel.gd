class_name HP2Wheel
extends RefCounted


var slot_id := ""
var local_position := Vector2.ZERO
var wheel_radius := 0.32

var steer_angle := 0.0
var normal_load := 0.0
var surface_mu := 1.0
var grip_scale := 1.0       # longitudinal grip scale
var lat_grip_scale := 1.0   # lateral grip scale (separate per RE: front/rear differ)
var drive_torque := 0.0
var brake_torque := 0.0
var angular_velocity := 0.0

# Suspension spring/damper params (loaded from CarConfig)
var progressive_spring_scale := 0.0
var spring_coefficient := 55.0
var bump_damping := 5.0
var rebound_damping := 5.3
var bump_stop_coefficient := 32.0
var rest_length := 0.0
var min_travel := -0.13
var max_travel := 0.125
var reference_length := 0.0
var preload_force := 0.0
var target_length := 0.0
var current_length := 0.0
var previous_length := 0.0
var travel_velocity := 0.0
var suspension_distance := 0.0
var center_offset := 0.0
var over_limit := 0.0
var overtravel := 0.0
var compression := 0.0
var suspension_force := 0.0
var grounded := false
var load_ratio := 0.0

var slip_long := 0.0
var slip_lat := 0.0
var force_long := 0.0
var force_lat := 0.0
var grip_utilization := 0.0


func reset_runtime() -> void:
	steer_angle = 0.0
	normal_load = 0.0
	surface_mu = 1.0
	grip_scale = 1.0
	lat_grip_scale = 1.0
	drive_torque = 0.0
	brake_torque = 0.0
	angular_velocity = 0.0
	slip_long = 0.0
	slip_lat = 0.0
	force_long = 0.0
	force_lat = 0.0
	grip_utilization = 0.0
	var neutral_length := _length_for_static_load(preload_force)
	current_length = neutral_length
	target_length = neutral_length
	previous_length = neutral_length
	travel_velocity = 0.0
	suspension_distance = neutral_length
	center_offset = neutral_length
	over_limit = 0.0
	overtravel = 0.0
	compression = 0.0
	suspension_force = 0.0
	grounded = false
	load_ratio = 0.0


func configure_suspension_from_state(state) -> void:
	wheel_radius = float(state.wheel_radius)
	progressive_spring_scale = float(state.progressive_spring_scale)
	spring_coefficient = maxf(float(state.spring_coefficient), 0.0)
	bump_damping = maxf(float(state.bump_damping), 0.0)
	rebound_damping = maxf(float(state.rebound_damping), 0.0)
	bump_stop_coefficient = float(state.bump_stop_coefficient)
	rest_length = float(state.rest_length)
	min_travel = float(state.min_travel)
	max_travel = float(state.max_travel)
	reference_length = float(state.reference_length)
	preload_force = maxf(float(state.preload_force), 0.0)
	current_length = _length_for_static_load(preload_force)
	previous_length = current_length
	target_length = current_length
	travel_velocity = 0.0
	suspension_distance = current_length
	center_offset = current_length


func update_suspension_load(target_load: float, surface_scale: float, delta: float) -> float:
	previous_length = current_length
	if surface_scale <= 0.0:
		grounded = false
		travel_velocity = 0.0
		suspension_force = 0.0
		normal_load = 0.0
		load_ratio = 0.0
		return 0.0

	grounded = true
	var effective_preload := maxf(target_load * surface_scale, 0.0)
	target_length = _length_for_static_load(effective_preload)
	_integrate_suspension_length(delta)
	suspension_distance = current_length
	center_offset = current_length
	over_limit = 0.0
	overtravel = 0.0
	suspension_force = maxf(_force_for_length(current_length, travel_velocity, effective_preload), 0.0)
	normal_load = suspension_force
	load_ratio = suspension_force / maxf(preload_force, 1.0)
	var length_min := minf(min_travel, max_travel)
	var length_max := maxf(min_travel, max_travel)
	compression = clampf((current_length - length_min) / maxf(length_max - length_min, 0.0001), 0.0, 1.0)
	return normal_load


# Elliptical friction model: separate longitudinal and lateral grip limits.
# slip_long/lat are force requests in Newtons; normal_load * grip_scale sets the limit.
func compute_contact_forces(new_slip_long: float, new_slip_lat: float) -> void:
	slip_long = new_slip_long
	slip_lat = new_slip_lat

	var max_long := surface_mu * grip_scale * normal_load
	var max_lat := surface_mu * lat_grip_scale * normal_load

	# Normalise each axis to its own limit, then clamp to unit ellipse
	var nx := slip_long / maxf(max_long, 0.0001)
	var ny := slip_lat / maxf(max_lat, 0.0001)
	var combined := sqrt(nx * nx + ny * ny)
	var scale := minf(1.0, 1.0 / maxf(combined, 0.0001))

	force_long = nx * scale * max_long
	force_lat = -(ny * scale * max_lat)
	grip_utilization = clampf(combined, 0.0, 1.0)


func update_angular_velocity(delta: float, longitudinal_velocity: float) -> void:
	var target := longitudinal_velocity / maxf(wheel_radius, 0.0001)
	if brake_torque > 0.0:
		target = lerpf(target, 0.0, clampf(brake_torque / 2200.0, 0.0, 0.85))
	if absf(drive_torque) > 0.0 and grip_utilization > 0.98:
		target += drive_torque * 0.015
	angular_velocity = lerpf(angular_velocity, target, clampf(delta * 18.0, 0.0, 1.0))
	angular_velocity = clampf(angular_velocity, -450.0, 450.0)


func update_airborne_angular_velocity(delta: float) -> void:
	var brake_direction := signf(angular_velocity)
	var net_torque := drive_torque - brake_torque * brake_direction
	var wheel_inertia := 1.8
	angular_velocity = clampf(angular_velocity + (net_torque / wheel_inertia) * delta, -900.0, 900.0)
	if absf(net_torque) <= 0.0001:
		angular_velocity = move_toward(angular_velocity, 0.0, 0.35 * delta)


func _length_for_static_load(target_load: float) -> float:
	var length_min := minf(min_travel, max_travel)
	var length_max := maxf(min_travel, max_travel)
	var low_force := _static_force_for_length(length_min, preload_force)
	var high_force := _static_force_for_length(length_max, preload_force)
	if target_load <= low_force:
		return length_min
	if target_load >= high_force:
		return length_max

	var positive_min := maxf(length_min, 0.0)
	var zero_force := _static_force_for_length(positive_min, preload_force)
	if target_load <= zero_force or length_max <= 0.0:
		return clampf(_solve_linear_length(target_load), length_min, minf(length_max, positive_min))

	var linear_term := spring_coefficient + bump_stop_coefficient
	var constant_term := preload_force - bump_stop_coefficient * reference_length - target_load
	var quadratic_term := spring_coefficient * progressive_spring_scale
	if absf(quadratic_term) <= 0.0001:
		return clampf(_solve_linear_length(target_load), positive_min, length_max)
	var discriminant := maxf(linear_term * linear_term - 4.0 * quadratic_term * constant_term, 0.0)
	var root := (-linear_term + sqrt(discriminant)) / (2.0 * quadratic_term)
	return clampf(root, positive_min, length_max)


func _integrate_suspension_length(delta: float) -> void:
	if delta <= 0.0:
		return
	var previous := current_length
	var damping := rebound_damping if travel_velocity > 0.0 else bump_damping
	var spring_acceleration := (target_length - current_length) * spring_coefficient
	var damper_acceleration := -travel_velocity * damping
	travel_velocity += (spring_acceleration + damper_acceleration) * delta
	current_length += travel_velocity * delta

	var length_min := minf(min_travel, max_travel)
	var length_max := maxf(min_travel, max_travel)
	var clamped := clampf(current_length, length_min, length_max)
	if clamped != current_length:
		current_length = clamped
		travel_velocity = 0.0
	previous_length = previous


func _solve_linear_length(target_load: float) -> float:
	var denom := spring_coefficient + bump_stop_coefficient
	if absf(denom) <= 0.0001:
		return minf(min_travel, max_travel)
	return (target_load - preload_force + bump_stop_coefficient * reference_length) / denom


func _force_for_length(length: float, velocity: float, preload_term: float) -> float:
	var damping := rebound_damping if velocity > 0.0 else bump_damping
	return _static_force_for_length(length, preload_term) + velocity * damping


func _static_force_for_length(length: float, preload_term: float) -> float:
	var spring_progress := maxf(length, 0.0)
	var spring_force := length * spring_coefficient * (1.0 + progressive_spring_scale * spring_progress)
	var reference_force := bump_stop_coefficient * (length - reference_length)
	return preload_term + spring_force + reference_force
