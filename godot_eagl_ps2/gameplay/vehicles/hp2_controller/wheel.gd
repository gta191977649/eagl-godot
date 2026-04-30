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
var spring_coefficient := 55.0
var bump_damping := 5.0
var rebound_damping := 5.3

var slip_long := 0.0
var slip_lat := 0.0
var force_long := 0.0
var force_lat := 0.0
var grip_utilization := 0.0

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
	slip_long = 0.0
	slip_lat = 0.0
	force_long = 0.0
	force_lat = 0.0
	grip_utilization = 0.0
	_filtered_load = -1.0


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
	if drive_torque > 0.0 and grip_utilization > 0.98:
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
