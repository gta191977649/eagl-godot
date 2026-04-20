class_name HP2Wheel
extends RefCounted


func resolve_force(owner, config, drivetrain, slot_id: String, basis: Basis, mass: float, delta: float) -> Dictionary:
	var state: Dictionary = owner.wheel_states.get(slot_id, {})
	if not bool(state.get("grounded", false)):
		return {"force": Vector3.ZERO, "yaw_torque": 0.0}
	var slot: Dictionary = state.get("slot", {})
	var axle = String(slot.get("axle", "front"))
	var local_pos: Vector3 = slot.get("position_godot", Vector3.ZERO)
	var steer_angle = float(state.get("steering_angle", 0.0))
	var contact_normal: Vector3 = state.get("contact_normal", basis.y.normalized())
	contact_normal = contact_normal.normalized() if contact_normal.length_squared() > 0.001 else basis.y.normalized()
	var forward = (-basis.z).rotated(basis.y.normalized(), steer_angle).slide(contact_normal)
	if forward.length_squared() <= 0.001:
		forward = (-basis.z).rotated(basis.y.normalized(), steer_angle)
	forward = forward.normalized()
	var right = forward.cross(contact_normal).normalized()
	if right.dot(basis.x) < 0.0:
		right = -right
	var contact_velocity = owner.velocity + owner.angular_velocity.cross(basis * local_pos)
	var longitudinal_speed = contact_velocity.dot(forward)
	var lateral_speed = contact_velocity.dot(right)
	var normal_force = float(state.get("normal_force", mass * float(config.tuning.get("gravity", 28.0)) * 0.25))
	var longitudinal_grip = float(config.tuning.get("%s_longitudinal_grip" % axle, config.tuning.get("rear_longitudinal_grip", 7.0)))
	var lateral_grip = float(config.tuning.get("%s_lateral_grip" % axle, config.tuning.get("lateral_grip", 8.0)))
	if owner.handbrake and axle == "rear":
		lateral_grip *= float(config.tuning.get("handbrake_grip_scale", 0.38))
	var drivetrain_force = drivetrain.force_for_wheel(owner, config, axle, longitudinal_speed, mass)
	var drive_force = float(drivetrain_force.get("drive_force", 0.0))
	var engine_brake_force = float(drivetrain_force.get("engine_brake_force", 0.0))
	var service_brake = owner.brake
	if owner.current_gear < 0 and owner.filtered_reverse_throttle > 0.0 and owner.local_longitudinal_speed < float(config.tuning.get("reverse_engage_speed", 1.2)):
		service_brake = 0.0
	var brake_force = float(config.tuning.get("brake_accel", 48.0)) * mass * service_brake * 0.25
	if owner.handbrake and axle == "rear":
		brake_force += float(config.tuning.get("brake_accel", 48.0)) * mass * 0.20
	var tire_longitudinal_limit = normal_force * longitudinal_grip
	var tire_lateral_limit = normal_force * lateral_grip
	var rolling = -signf(longitudinal_speed) * minf(absf(longitudinal_speed) * float(config.tuning.get("rolling_drag", 2.0)) * mass * 0.03, tire_longitudinal_limit * 0.25)
	var requested_longitudinal = drive_force + engine_brake_force - signf(longitudinal_speed) * brake_force + rolling
	var requested_lateral = -lateral_speed * mass * lateral_grip * 0.28
	var slip_angle = atan2(lateral_speed, maxf(absf(longitudinal_speed), 0.5))
	var slip_falloff = lerpf(1.0, float(config.tuning.get("tire_high_slip_grip_scale", 0.72)), clampf((absf(slip_angle) - 0.35) / 0.65, 0.0, 1.0))
	tire_lateral_limit *= slip_falloff
	var combined = resolve_combined_tire_forces(state, requested_longitudinal, requested_lateral, tire_longitudinal_limit, tire_lateral_limit, delta, config)
	var longitudinal_force = float(combined.get("longitudinal_force", 0.0))
	var lateral_force = float(combined.get("lateral_force", 0.0))
	var total = forward * longitudinal_force + right * lateral_force
	var yaw_torque = (basis * local_pos).cross(total).dot(basis.y.normalized())
	var radius = float(slot.get("wheel_radius", config.tuning.get("wheel_radius", 0.36)))
	var angular_speed = longitudinal_speed / maxf(radius, 0.01)
	var slip_ratio = absf(requested_longitudinal - longitudinal_force) / maxf(tire_longitudinal_limit, 1.0)
	state["longitudinal_speed"] = longitudinal_speed
	state["lateral_speed"] = lateral_speed
	state["requested_longitudinal_force"] = requested_longitudinal
	state["requested_lateral_force"] = requested_lateral
	state["longitudinal_force"] = longitudinal_force
	state["lateral_force"] = lateral_force
	state["combined_tire_saturation"] = combined.get("saturation", 0.0)
	state["tire_slip_falloff"] = slip_falloff
	state["drive_force"] = drive_force
	state["engine_brake_force"] = engine_brake_force
	state["brake_force"] = brake_force
	state["rolling_force"] = rolling
	state["slip_ratio"] = slip_ratio
	state["slip_angle"] = slip_angle
	state["angular_speed"] = angular_speed
	state["skidding"] = absf(slip_angle) > 0.28 or slip_ratio > 0.18
	owner.wheel_states[slot_id] = state
	owner.last_drive_force += absf(drive_force)
	owner.last_engine_brake_force += absf(engine_brake_force)
	owner.last_brake_force += absf(brake_force)
	owner.last_lateral_force += absf(lateral_force)
	owner.last_normal_force += normal_force
	owner.last_rolling_force += absf(rolling)
	return {"force": total, "yaw_torque": yaw_torque}


func resolve_combined_tire_forces(state: Dictionary, requested_longitudinal: float, requested_lateral: float, longitudinal_limit: float, lateral_limit: float, delta: float, config) -> Dictionary:
	var safe_longitudinal_limit = maxf(longitudinal_limit, 0.0)
	var safe_lateral_limit = maxf(lateral_limit, 0.0)
	if safe_longitudinal_limit <= 0.001 or safe_lateral_limit <= 0.001:
		return {"longitudinal_force": 0.0, "lateral_force": 0.0, "saturation": 0.0}
	var longitudinal_force = clampf(requested_longitudinal, -safe_longitudinal_limit, safe_longitudinal_limit)
	var lateral_force = clampf(requested_lateral, -safe_lateral_limit, safe_lateral_limit)
	var saturation = sqrt(pow(longitudinal_force / safe_longitudinal_limit, 2.0) + pow(lateral_force / safe_lateral_limit, 2.0))
	if saturation > 1.0:
		var scale = 1.0 / saturation
		longitudinal_force *= scale
		lateral_force *= scale
		saturation = 1.0
	var response = float(config.tuning.get("tire_force_response", 16.0))
	var previous_longitudinal = float(state.get("longitudinal_force", 0.0))
	var previous_lateral = float(state.get("lateral_force", 0.0))
	longitudinal_force = move_toward(previous_longitudinal, longitudinal_force, safe_longitudinal_limit * response * delta)
	lateral_force = move_toward(previous_lateral, lateral_force, safe_lateral_limit * response * delta)
	saturation = sqrt(pow(longitudinal_force / safe_longitudinal_limit, 2.0) + pow(lateral_force / safe_lateral_limit, 2.0))
	if saturation > 1.0:
		var relaxed_scale = 1.0 / saturation
		longitudinal_force *= relaxed_scale
		lateral_force *= relaxed_scale
		saturation = 1.0
	return {
		"longitudinal_force": longitudinal_force,
		"lateral_force": lateral_force,
		"saturation": saturation,
	}
