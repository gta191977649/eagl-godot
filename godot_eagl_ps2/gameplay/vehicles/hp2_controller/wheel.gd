class_name HP2Wheel
extends RefCounted


var slot_id := ""
var local_position := Vector2.ZERO
var wheel_radius := 0.32
var pivot_local_z := 0.03

var steer_angle := 0.0
var normal_load := 0.0
var surface_mu := 1.0
var grip_scale := 1.0       # longitudinal grip scale
var lat_grip_scale := 1.0   # lateral grip scale (separate per RE: front/rear differ)
var drive_torque := 0.0
var brake_torque := 0.0
var angular_velocity := 0.0

# Suspension spring/damper params (loaded from CarConfig)
var spring_coefficient := 55.0
var progressive_spring_scale := 0.0
var bump_damping := 5.0
var rebound_damping := 5.3
var bump_stop_coefficient := 32.0
var anti_roll_coefficient := 0.0
var min_travel := -0.13
var max_travel := 0.125
var reference_length := 0.0
var preload_force := 0.0

var raw_length := 0.0
var current_length := 0.0
var previous_length := 0.0
var travel_velocity := 0.0
var overtravel := 0.0
var spring_force := 0.0
var damper_force := 0.0
var suspension_force := 0.0
var grounded := true
var world_pivot_ps2 := Vector3.ZERO
var world_wheel_center_ps2 := Vector3.ZERO
var contact_point_ps2 := Vector3.ZERO
var normal_ps2 := Vector3(0.0, 0.0, 1.0)
var visual_suspension_offset := 0.0

var slip_long := 0.0
var slip_lat := 0.0
var slip_speed_long := 0.0
var slip_speed_lat := 0.0
var slip_speed := 0.0
var slip_angle_deg := 0.0
var combined_slip_ratio := 0.0
var lambda_long := 0.0
var lambda_lat := 0.0
var force_long := 0.0
var force_lat := 0.0
var grip_utilization := 0.0
var slip_locked := false

var _filtered_load := -1.0  # negative = uninitialized, snaps on first frame


func reset_runtime() -> void:
	steer_angle = 0.0
	normal_load = 0.0
	surface_mu = 1.0
	grip_scale = 1.0
	lat_grip_scale = 1.0
	drive_torque = 0.0
	brake_torque = 0.0
	angular_velocity = 0.0
	raw_length = 0.0
	current_length = 0.0
	previous_length = 0.0
	travel_velocity = 0.0
	overtravel = 0.0
	spring_force = 0.0
	damper_force = 0.0
	suspension_force = 0.0
	grounded = true
	world_pivot_ps2 = Vector3.ZERO
	world_wheel_center_ps2 = Vector3.ZERO
	contact_point_ps2 = Vector3.ZERO
	normal_ps2 = Vector3(0.0, 0.0, 1.0)
	visual_suspension_offset = 0.0
	slip_long = 0.0
	slip_lat = 0.0
	slip_speed_long = 0.0
	slip_speed_lat = 0.0
	slip_speed = 0.0
	slip_angle_deg = 0.0
	combined_slip_ratio = 0.0
	lambda_long = 0.0
	lambda_lat = 0.0
	force_long = 0.0
	force_lat = 0.0
	grip_utilization = 0.0
	slip_locked = false
	_filtered_load = -1.0


# Requests are force-equivalents in Newtons; lambda_* stores the accepted contact result after grip clamp.
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

	lambda_long = nx * scale * max_long
	lambda_lat = -(ny * scale * max_lat)
	force_long = lambda_long
	force_lat = lambda_lat
	combined_slip_ratio = combined
	grip_utilization = clampf(combined, 0.0, 1.0)
	slip_locked = combined > 1.0


func set_contact_slip_velocity(longitudinal_velocity: float, lateral_velocity: float) -> void:
	slip_speed_long = longitudinal_velocity
	slip_speed_lat = lateral_velocity
	slip_speed = sqrt(longitudinal_velocity * longitudinal_velocity + lateral_velocity * lateral_velocity)
	slip_angle_deg = rad_to_deg(atan2(lateral_velocity, maxf(absf(longitudinal_velocity), 0.0001)))


# Spring-filtered normal load: smooths weight transfer at a rate proportional
# to spring stiffness (stiffer spring = faster response).
func update_filtered_load(target_load: float, delta: float) -> float:
	if _filtered_load < 0.0:
		_filtered_load = target_load  # snap on first frame
	var spring_rate := clampf(spring_coefficient * 0.35, 1.0, 60.0)
	var prev := _filtered_load
	_filtered_load = lerpf(_filtered_load, target_load, clampf(spring_rate * delta, 0.0, 1.0))
	# Add rebound/bump damping: resist rapid load changes (prevents oscillation)
	var load_velocity := (_filtered_load - prev) / maxf(delta, 0.0001)
	var damping := bump_damping if load_velocity > 0.0 else rebound_damping
	var damping_correction := -damping * load_velocity * delta * 0.012
	return maxf(_filtered_load + damping_correction, 0.0)


func update_angular_velocity(delta: float, longitudinal_velocity: float) -> void:
	var target := longitudinal_velocity / maxf(wheel_radius, 0.0001)
	if brake_torque > 0.0:
		target = lerpf(target, 0.0, clampf(brake_torque / 2200.0, 0.0, 0.85))
	angular_velocity = lerpf(angular_velocity, target, clampf(delta * 18.0, 0.0, 1.0))
	angular_velocity = clampf(angular_velocity, -450.0, 450.0)


func update_airborne_angular_velocity(delta: float) -> void:
	var brake_direction := signf(angular_velocity)
	var net_torque := drive_torque - brake_torque * brake_direction
	var wheel_inertia := 1.8
	angular_velocity = clampf(angular_velocity + (net_torque / wheel_inertia) * delta, -900.0, 900.0)
	if absf(net_torque) <= 0.0001:
		angular_velocity = move_toward(angular_velocity, 0.0, 0.35 * delta)
