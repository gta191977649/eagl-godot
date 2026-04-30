class_name HP2Drivetrain
extends RefCounted


var engine = null
var current_gear := 1
var final_drive := 3.91
var gear_ratios := PackedFloat32Array([-3.46, 3.15, 2.02, 1.43, 1.13, 0.93, 0.76])
var upshift_rpm := 6970.0
var downshift_rpm := 3400.0
var auto_shift_timer := 0.0
var min_shift_interval := 0.5


func reset_runtime() -> void:
	current_gear = 1
	auto_shift_timer = 0.0


func effective_ratio() -> float:
	var gear_index := clampi(current_gear, 1, gear_ratios.size() - 1)
	return gear_ratios[gear_index] * final_drive


func update_auto_shift(delta: float) -> void:
	if engine == null:
		return
	auto_shift_timer += delta
	if auto_shift_timer < min_shift_interval:
		return
	if engine.rpm > upshift_rpm and current_gear < gear_ratios.size() - 1:
		current_gear += 1
		engine.trigger_shift_cut()
		auto_shift_timer = 0.0
	elif engine.rpm < downshift_rpm and current_gear > 1:
		current_gear -= 1
		auto_shift_timer = 0.0


func calculate_rear_wheel_torques(throttle: float, load_rl: float, load_rr: float) -> Dictionary:
	var torque := 0.0
	if engine != null:
		torque = engine.get_net_torque(throttle) * absf(effective_ratio())

	var total_rear_load := maxf(load_rl + load_rr, 0.0001)
	var rr_split := clampf(load_rr / total_rear_load, 0.0, 1.0)
	return {
		"FL": 0.0,
		"FR": 0.0,
		"RL": torque * (1.0 - rr_split),
		"RR": torque * rr_split,
	}
