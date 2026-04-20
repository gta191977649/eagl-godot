class_name HP2Engine
extends RefCounted


func reset(owner, config) -> void:
	owner.engine_rpm = config.engine_idle_rpm()
	owner.last_torque_curve = 0.0
	owner.last_engine_torque = 0.0


func torque_curve(rpm: float, config) -> float:
	var idle = config.engine_idle_rpm()
	var peak = config.engine_peak_rpm()
	var redline = config.engine_redline_rpm()
	var clamped_rpm = clampf(rpm, idle, redline)
	if clamped_rpm <= peak:
		return clampf(lerpf(0.42, 1.0, (clamped_rpm - idle) / maxf(peak - idle, 1.0)), 0.35, 1.0)
	return clampf(lerpf(1.0, 0.68, (clamped_rpm - peak) / maxf(redline - peak, 1.0)), 0.55, 1.0)

