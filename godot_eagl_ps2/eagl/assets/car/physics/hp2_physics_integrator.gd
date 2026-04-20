class_name HP2PhysicsIntegrator
extends RefCounted

const WHEEL_ORDER = ["FL", "FR", "RL", "RR"]

var last_substep_count = 1
var last_substep_delta = 0.0


func integrate_hp2_body(owner, runtime, body: Node3D, delta: float) -> void:
	var basis = body.global_transform.basis.orthonormalized()
	var up = basis.y.normalized()
	var forward = -basis.z.normalized()
	var right = basis.x.normalized()
	owner.local_longitudinal_speed = owner.velocity.dot(forward)
	owner.local_lateral_speed = owner.velocity.dot(right)

	var mass = runtime.config.mass()
	_reset_force_telemetry(owner)
	runtime.drivetrain.update(owner, runtime.config, runtime.engine, delta)
	runtime.suspension.update_wheel_contacts(owner, runtime.config, body, basis, delta)
	owner.grounded = _has_ground_contact(owner)

	if owner.grounded:
		runtime.steering.update(owner, runtime.config)

	var max_step = maxf(float(runtime.config.tuning.get("physics_substep", 1.0 / 30.0)), 0.001)
	last_substep_count = maxi(1, int(delta / max_step) + 1)
	last_substep_delta = delta / float(last_substep_count)
	for _substep in range(last_substep_count):
		_integrate_substep(owner, runtime, body, last_substep_delta, mass)

	runtime.suspension.update_body_ground_pose(owner, runtime.config, body, delta)
	basis = body.global_transform.basis.orthonormalized()
	forward = -basis.z.normalized()
	right = basis.x.normalized()
	owner.local_longitudinal_speed = owner.velocity.dot(forward)
	owner.local_lateral_speed = owner.velocity.dot(right)
	owner.slip = absf(owner.local_lateral_speed) / maxf(absf(owner.local_longitudinal_speed), 1.0)
	owner.movement_mode = movement_mode(owner)


func _integrate_substep(owner, runtime, body: Node3D, delta: float, mass: float) -> void:
	var basis = body.global_transform.basis.orthonormalized()
	var up = basis.y.normalized()
	var force = Vector3.ZERO
	var torque_yaw = 0.0
	force -= Vector3.UP * mass * float(runtime.config.tuning.get("gravity", 28.0))
	if owner.grounded:
		for slot_id in WHEEL_ORDER:
			var state: Dictionary = owner.wheel_states.get(slot_id, {})
			if bool(state.get("grounded", false)):
				var suspension_force: Vector3 = state.get("suspension_force_vector", Vector3.ZERO)
				force += suspension_force
				owner.last_suspension_force += suspension_force.length()
			var wheel_force = runtime.wheel.resolve_force(owner, runtime.config, runtime.drivetrain, slot_id, basis, mass, delta)
			force += wheel_force["force"]
			torque_yaw += float(wheel_force["yaw_torque"])

	force += resolve_drag_force(owner, runtime.config)
	var acceleration = force / maxf(mass, 1.0)
	owner.velocity += acceleration * delta
	body.global_position += owner.velocity * delta
	owner.yaw_rate += (torque_yaw / maxf(runtime.config.yaw_inertia(), 1.0)) * delta
	var yaw_damping = float(runtime.config.tuning.get("yaw_damping", 5.5))
	owner.yaw_rate = move_toward(owner.yaw_rate, 0.0, yaw_damping * delta * 0.35)
	owner.angular_velocity = up * owner.yaw_rate
	if absf(owner.yaw_rate) > 0.00001:
		body.global_transform.basis = (Basis(up, owner.yaw_rate * delta) * body.global_transform.basis).orthonormalized()


func integrate_free_drive_body(owner, runtime, body: Node3D, delta: float) -> void:
	var basis = body.global_transform.basis.orthonormalized()
	var forward = -basis.z.normalized()
	var right = basis.x.normalized()
	var up = Vector3.UP
	var input_length = runtime.input_state.free_drive_input.length()
	var target_velocity = Vector3.ZERO
	var max_speed: float = owner.debug_free_drive_boost_speed if runtime.input_state.free_drive_boost else owner.debug_free_drive_speed

	_reset_force_telemetry(owner)
	if input_length > 0.001:
		var move_dir = (right * runtime.input_state.free_drive_input.x + forward * runtime.input_state.free_drive_input.y).normalized()
		target_velocity = move_dir * max_speed
		owner.last_drive_force = owner.debug_free_drive_accel
		owner.movement_mode = "free drive"
	else:
		owner.movement_mode = "free idle"
		owner.last_drag_force = owner.debug_free_drive_accel

	owner.velocity = owner.velocity.move_toward(target_velocity, owner.debug_free_drive_accel * delta)
	owner.velocity.y = 0.0
	owner.yaw_rate = runtime.input_state.free_drive_yaw_input * owner.debug_free_drive_yaw_speed
	owner.angular_velocity = up * owner.yaw_rate
	if absf(owner.yaw_rate) > 0.0001:
		body.global_transform.basis = Basis(up, owner.yaw_rate * delta) * body.global_transform.basis

	body.global_position += owner.velocity * delta
	runtime.suspension.update_wheel_contacts(owner, runtime.config, body, body.global_transform.basis.orthonormalized(), delta)
	runtime.suspension.update_body_ground_pose(owner, runtime.config, body, delta)

	basis = body.global_transform.basis.orthonormalized()
	forward = -basis.z.normalized()
	right = basis.x.normalized()
	owner.local_longitudinal_speed = owner.velocity.dot(forward)
	owner.local_lateral_speed = owner.velocity.dot(right)
	owner.slip = absf(owner.local_lateral_speed) / maxf(absf(owner.local_longitudinal_speed), 1.0)
	last_substep_count = 1
	last_substep_delta = delta


func resolve_drag_force(owner, config) -> Vector3:
	var speed = owner.velocity.length()
	if speed <= 0.001:
		return Vector3.ZERO
	var linear_drag = float(config.tuning.get("linear_drag", 0.42))
	var aero_drag = config.aero_drag()
	var drag_magnitude = speed * linear_drag * config.mass() + speed * speed * aero_drag * config.mass()
	owner.last_drag_force = drag_magnitude
	owner.last_aero_force = speed * speed * aero_drag * config.mass()
	return -owner.velocity.normalized() * drag_magnitude


func movement_mode(owner) -> String:
	if not owner.grounded:
		return "airborne"
	if owner.drivetrain_mode == "reverse":
		return "reverse"
	if owner.drivetrain_mode == "shift":
		return "shift"
	if owner.throttle > 0.0:
		return "drive"
	if owner.brake > 0.0 and owner.local_longitudinal_speed > 1.0:
		return "brake"
	if owner.brake > 0.0:
		return "reverse"
	if owner.handbrake:
		return "handbrake"
	return "coast"


func _has_ground_contact(owner) -> bool:
	for slot_id in WHEEL_ORDER:
		var state: Dictionary = owner.wheel_states.get(slot_id, {})
		if bool(state.get("grounded", false)):
			return true
	return false


func _reset_force_telemetry(owner) -> void:
	owner.last_drive_force = 0.0
	owner.last_brake_force = 0.0
	owner.last_lateral_force = 0.0
	owner.last_drag_force = 0.0
	owner.last_normal_force = 0.0
	owner.last_aero_force = 0.0
	owner.last_rolling_force = 0.0
	owner.last_suspension_force = 0.0
	owner.last_engine_torque = 0.0
	owner.last_wheel_torque = 0.0
	owner.last_engine_brake_force = 0.0
