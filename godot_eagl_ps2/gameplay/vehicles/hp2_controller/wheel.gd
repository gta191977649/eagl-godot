class_name HP2Wheel
extends RefCounted


var slot_id := ""
var local_position := Vector2.ZERO
var wheel_radius := 0.32

var steer_angle := 0.0
var normal_load := 0.0
var surface_mu := 1.0
var grip_scale := 1.0
var drive_torque := 0.0
var brake_torque := 0.0
var angular_velocity := 0.0

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
	drive_torque = 0.0
	brake_torque = 0.0
	angular_velocity = 0.0
	slip_long = 0.0
	slip_lat = 0.0
	force_long = 0.0
	force_lat = 0.0
	grip_utilization = 0.0


func compute_contact_forces(new_slip_long: float, new_slip_lat: float) -> void:
	slip_long = new_slip_long
	slip_lat = new_slip_lat

	var speed := sqrt(slip_long * slip_long + slip_lat * slip_lat)
	var max_grip := surface_mu * grip_scale * normal_load
	var scale := minf(1.0, max_grip / maxf(speed, 0.0001))

	force_long = slip_long * scale
	force_lat = -slip_lat * scale
	grip_utilization = clampf((speed * scale) / maxf(max_grip, 0.0001), 0.0, 1.0)


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
