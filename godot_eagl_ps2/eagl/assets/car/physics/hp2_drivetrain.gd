class_name HP2DriveTrain
extends RefCounted


func reset(owner) -> void:
	owner.filtered_throttle = 0.0
	owner.filtered_reverse_throttle = 0.0
	owner.current_gear = 1
	owner.clutch_engagement = 1.0
	owner.shift_timer = 0.0
	owner.reverse_hold_timer = 0.0
	owner.drivetrain_mode = "forward"
	owner.last_gear_ratio = 0.0
	owner.last_engine_brake_force = 0.0
	owner.last_wheel_torque = 0.0


func update(owner, config, engine, delta: float) -> void:
	var idle = config.engine_idle_rpm()
	var redline = config.engine_redline_rpm()
	var gear_count = config.gear_count()
	var max_forward_speed = float(config.tuning.get("max_forward_speed", 86.0))
	var max_reverse_speed = float(config.tuning.get("max_reverse_speed", 18.0))
	var response = float(config.tuning.get("throttle_response_rate", 7.5))
	owner.filtered_throttle = move_toward(owner.filtered_throttle, owner.throttle, response * delta)
	var reverse_requested = owner.brake > 0.0 and owner.throttle <= 0.0 and owner.local_longitudinal_speed <= float(config.tuning.get("reverse_engage_speed", 1.2))
	owner.reverse_hold_timer = owner.reverse_hold_timer + delta if reverse_requested else 0.0
	var reverse_ready = owner.reverse_hold_timer >= float(config.tuning.get("reverse_hold_delay", 0.10))
	if reverse_ready:
		owner.current_gear = -1
	elif owner.throttle > 0.0 and owner.local_longitudinal_speed > -0.6:
		owner.current_gear = maxi(owner.current_gear, 1)
	var target_reverse_throttle = owner.brake if owner.current_gear < 0 and reverse_ready else 0.0
	owner.filtered_reverse_throttle = move_toward(owner.filtered_reverse_throttle, target_reverse_throttle, response * delta)
	if owner.current_gear > 0:
		update_forward_auto_shift(owner, config, engine, gear_count, delta)

	if owner.shift_timer > 0.0:
		owner.shift_timer = maxf(0.0, owner.shift_timer - delta)
	var shift_duration = maxf(float(config.tuning.get("shift_duration", 0.18)), 0.01)
	owner.clutch_engagement = 1.0 - clampf(owner.shift_timer / shift_duration, 0.0, 1.0)

	var ratio = config.current_gear_ratio(owner.current_gear)
	owner.last_gear_ratio = ratio
	var wheel_radius = maxf(float(config.tuning.get("rear_wheel_radius", config.tuning.get("wheel_radius", 0.36))), 0.01)
	var wheel_rpm = absf(owner.local_longitudinal_speed) / wheel_radius * 60.0 / TAU
	var coupled_rpm = wheel_rpm * absf(ratio) * config.final_drive_ratio()
	var input_amount = owner.filtered_reverse_throttle if owner.current_gear < 0 else owner.filtered_throttle
	var free_rev_target = lerpf(idle, redline * 0.72, input_amount)
	var target_rpm = maxf(coupled_rpm, free_rev_target if absf(owner.local_longitudinal_speed) < 1.0 else idle)
	owner.engine_rpm = move_toward(owner.engine_rpm, clampf(target_rpm, idle, redline * 1.04), maxf(redline * 2.4, 1.0) * delta)
	if owner.engine_rpm > redline:
		owner.engine_rpm = move_toward(owner.engine_rpm, redline, redline * 4.0 * delta)
	owner.last_torque_curve = engine.torque_curve(owner.engine_rpm, config)
	if owner.current_gear < 0:
		owner.drivetrain_mode = "reverse"
	elif owner.shift_timer > 0.0:
		owner.drivetrain_mode = "shift"
	elif owner.throttle > 0.0:
		owner.drivetrain_mode = "drive"
	elif owner.brake > 0.0 and owner.local_longitudinal_speed > 1.0:
		owner.drivetrain_mode = "brake"
	else:
		owner.drivetrain_mode = "coast"
	if owner.current_gear < 0 and absf(owner.local_longitudinal_speed) > max_reverse_speed:
		owner.filtered_reverse_throttle = 0.0
	if owner.current_gear > 0 and owner.local_longitudinal_speed > max_forward_speed:
		owner.filtered_throttle = 0.0


func update_forward_auto_shift(owner, config, engine, gear_count: int, _delta: float) -> void:
	if owner.shift_timer > 0.0:
		return
	var current_rpm = maxf(owner.engine_rpm, rpm_from_wheels(owner.local_longitudinal_speed, owner.current_gear, config))
	var up_rpm = gear_shift_up_rpm(owner.current_gear, config, engine)
	var down_rpm = float(config.tuning.get("shift_down_rpm", config.engine_peak_rpm() * 0.58))
	var wants_upshift = current_rpm >= up_rpm
	var wants_downshift = current_rpm < down_rpm
	if owner.throttle > 0.2 and wants_upshift and owner.current_gear < gear_count:
		owner.current_gear += 1
		owner.shift_timer = float(config.tuning.get("shift_duration", 0.18))
	elif owner.throttle < 0.35 and wants_downshift and owner.current_gear > 1:
		owner.current_gear -= 1
		owner.shift_timer = float(config.tuning.get("shift_duration", 0.18))


func rpm_from_wheels(longitudinal_speed: float, gear: int, config) -> float:
	var wheel_radius = maxf(float(config.tuning.get("rear_wheel_radius", config.tuning.get("wheel_radius", 0.36))), 0.01)
	var wheel_rpm = absf(longitudinal_speed) / wheel_radius * 60.0 / TAU
	return wheel_rpm * absf(config.current_gear_ratio(gear)) * config.final_drive_ratio()


func speed_from_rpm(rpm: float, gear: int, config) -> float:
	var wheel_radius = maxf(float(config.tuning.get("rear_wheel_radius", config.tuning.get("wheel_radius", 0.36))), 0.01)
	var ratio = maxf(absf(config.current_gear_ratio(gear)) * config.final_drive_ratio(), 0.01)
	return (rpm / ratio) * TAU / 60.0 * wheel_radius


func shift_table_scale(config) -> float:
	var redline = config.engine_redline_rpm()
	var fallback_raw_rpm = maxf(config.engine_idle_rpm(), redline - float(config.tuning.get("shift_redline_margin_rpm", 200.0)))
	var fallback_scaled_rpm = clampf(float(config.tuning.get("shift_up_rpm", fallback_raw_rpm)), config.engine_idle_rpm(), redline)
	var default_scale = fallback_scaled_rpm / maxf(fallback_raw_rpm, 1.0)
	return clampf(float(config.tuning.get("shift_table_rpm_scale", default_scale)), 0.70, 1.10)


func force_for_wheel(owner, config, axle: String, longitudinal_speed: float, mass: float) -> Dictionary:
	if axle != "rear":
		return {"drive_force": 0.0, "engine_brake_force": 0.0}
	var drive_share = 0.5
	var input_amount = owner.filtered_reverse_throttle if owner.current_gear < 0 else owner.filtered_throttle
	var direction = -1.0 if owner.current_gear < 0 else 1.0
	var speed_limit = float(config.tuning.get("max_reverse_speed", 18.0)) if owner.current_gear < 0 else float(config.tuning.get("max_forward_speed", 86.0))
	var signed_speed = -owner.local_longitudinal_speed if owner.current_gear < 0 else owner.local_longitudinal_speed
	var speed_scale = clampf((speed_limit - signed_speed) / maxf(speed_limit * 0.16, 1.0), 0.0, 1.0)
	var gear_ratio_scale = clampf(absf(config.current_gear_ratio(owner.current_gear)) / 3.10, 0.45, 1.20)
	var base_accel = float(config.tuning.get("reverse_accel", 18.0)) if owner.current_gear < 0 else float(config.tuning.get("engine_accel", 34.0))
	var drive_force = direction * base_accel * mass * input_amount * owner.last_torque_curve * gear_ratio_scale * owner.clutch_engagement * speed_scale * drive_share
	var engine_brake = 0.0
	if input_amount < 0.05 and absf(longitudinal_speed) > 0.8 and owner.current_gear != 0:
		var brake_scale = clampf((owner.engine_rpm - config.engine_idle_rpm()) / maxf(config.engine_redline_rpm() - config.engine_idle_rpm(), 1.0), 0.0, 1.0)
		engine_brake = -signf(longitudinal_speed) * float(config.tuning.get("engine_brake_accel", 7.0)) * mass * brake_scale * owner.clutch_engagement * drive_share
	var wheel_radius = maxf(float(config.tuning.get("rear_wheel_radius", config.tuning.get("wheel_radius", 0.36))), 0.01)
	owner.last_engine_torque += absf(drive_force) * wheel_radius / maxf(absf(config.current_gear_ratio(owner.current_gear)) * config.final_drive_ratio(), 0.01)
	owner.last_wheel_torque += absf(drive_force) * wheel_radius
	return {"drive_force": drive_force, "engine_brake_force": engine_brake}


func gear_shift_up_rpm(gear: int, config, engine) -> float:
	var ratios: Array = config.tuning.get("gear_ratios", [])
	var gear_count = config.gear_count()
	if gear <= 0 or gear >= gear_count or gear >= ratios.size():
		return INF
	var current_ratio = maxf(absf(float(ratios[gear - 1])), 0.01)
	var next_ratio = maxf(absf(float(ratios[gear])), 0.01)
	var idle = config.engine_idle_rpm()
	var redline = config.engine_redline_rpm()
	var end_rpm = maxf(idle, redline - float(config.tuning.get("shift_redline_margin_rpm", 200.0)))
	var rpm = clampf((idle + redline) * 0.5, idle, end_rpm)
	var step = maxf(float(config.tuning.get("shift_scan_step_rpm", 50.0)), 1.0)
	var raw_shift_rpm = end_rpm
	while rpm < end_rpm:
		var current_torque = engine.torque_curve(rpm, config)
		var next_rpm = rpm * next_ratio / current_ratio
		var next_wheel_torque = engine.torque_curve(next_rpm, config) * next_ratio / current_ratio
		if current_torque < next_wheel_torque:
			raw_shift_rpm = rpm
			break
		rpm += step
	return maxf(idle, raw_shift_rpm * shift_table_scale(config))


func gear_speed_for_shift(gear: int, config) -> float:
	var ratios: Array = config.tuning.get("gear_ratios", [])
	if ratios.is_empty():
		return float(config.tuning.get("max_forward_speed", 86.0))
	var top_ratio = maxf(absf(float(ratios[ratios.size() - 1])), 0.01)
	var ratio = maxf(absf(float(ratios[clampi(gear - 1, 0, ratios.size() - 1)])), 0.01)
	return float(config.tuning.get("max_forward_speed", 86.0)) * top_ratio / ratio


func gear_upshift_speed(gear: int, gear_count: int, config) -> float:
	if gear <= 0 or gear >= gear_count:
		return INF
	var up_rpm = config.engine_redline_rpm() - float(config.tuning.get("shift_redline_margin_rpm", 200.0))
	return speed_from_rpm(maxf(config.engine_idle_rpm(), up_rpm * shift_table_scale(config)), gear, config)


func gear_downshift_speed(gear: int, gear_count: int, config) -> float:
	if gear <= 0 or gear >= gear_count:
		return 0.0
	var down_rpm = float(config.tuning.get("shift_down_rpm", config.engine_peak_rpm() * 0.58))
	return speed_from_rpm(down_rpm, gear, config)
