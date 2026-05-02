class_name HP2Drivetrain
extends RefCounted


var engine = null
var current_gear := 1
var final_drive := 3.91
var gear_ratios := PackedFloat32Array([-3.46, 3.15, 2.02, 1.43, 1.13, 0.93, 0.76])
var upshift_rpm := 6970.0
var downshift_rpm := 3400.0
var upshift_rpm_per_gear := PackedFloat32Array()
var downshift_rpm_per_gear := PackedFloat32Array()
var auto_shift_timer := 0.0
var min_shift_interval := 0.5
var anti_hunt_active := false
var anti_hunt_timer := 0.0
var anti_hunt_from_gear := 1

const SHIFT_SEARCH_STEP_RPM := 50.0
const SHIFT_REDLINE_MARGIN_RPM := 200.0
const DOWNSHIFT_RATIO_SCALE := 0.85
# Values below come from HP2 PS2 FUN_0018bce0's in-progress anti-hunt path.
const ANTI_HUNT_DURATION := 10.0
const ANTI_HUNT_IDLE_MARGIN_RPM := 100.0
const ANTI_HUNT_REDLINE_MARGIN_RPM := 300.0


func reset_runtime() -> void:
	current_gear = 1
	auto_shift_timer = 0.0
	anti_hunt_active = false
	anti_hunt_timer = 0.0
	anti_hunt_from_gear = 1


func effective_ratio() -> float:
	var gear_index := clampi(current_gear, 0, gear_ratios.size() - 1)
	return gear_ratios[gear_index] * final_drive


func build_shift_tables(torque_curve: Array[Vector2], idle_rpm: float, redline_rpm: float) -> void:
	var gear_count := gear_ratios.size()
	upshift_rpm_per_gear = PackedFloat32Array()
	downshift_rpm_per_gear = PackedFloat32Array()
	upshift_rpm_per_gear.resize(gear_count)
	downshift_rpm_per_gear.resize(gear_count)
	for index in range(gear_count):
		upshift_rpm_per_gear[index] = upshift_rpm
		downshift_rpm_per_gear[index] = downshift_rpm

	var search_start := (idle_rpm + redline_rpm) * 0.5
	var search_end := maxf(redline_rpm - SHIFT_REDLINE_MARGIN_RPM, search_start)
	for gear in range(1, gear_count):
		if gear >= gear_count - 1:
			upshift_rpm_per_gear[gear] = redline_rpm
			continue
		var current_ratio := absf(float(gear_ratios[gear]))
		var next_ratio := absf(float(gear_ratios[gear + 1]))
		if current_ratio <= 0.0001 or next_ratio <= 0.0001:
			continue

		var shift_rpm := search_end
		var rpm := search_start
		while rpm < search_end:
			var next_rpm := rpm * next_ratio / current_ratio
			var current_torque := _sample_torque_curve(torque_curve, rpm, redline_rpm)
			var next_effective_torque := _sample_torque_curve(torque_curve, next_rpm, redline_rpm) * next_ratio / current_ratio
			if current_torque < next_effective_torque:
				shift_rpm = rpm
				break
			rpm += SHIFT_SEARCH_STEP_RPM

		upshift_rpm_per_gear[gear] = shift_rpm
		downshift_rpm_per_gear[gear + 1] = maxf(
			idle_rpm + ANTI_HUNT_IDLE_MARGIN_RPM,
			shift_rpm * next_ratio / current_ratio * DOWNSHIFT_RATIO_SCALE
		)


func upshift_rpm_for_current_gear() -> float:
	if current_gear >= 0 and current_gear < upshift_rpm_per_gear.size():
		return upshift_rpm_per_gear[current_gear]
	return upshift_rpm


func downshift_rpm_for_current_gear() -> float:
	if anti_hunt_active and anti_hunt_timer <= ANTI_HUNT_DURATION and engine != null:
		return float(engine.idle_rpm) + ANTI_HUNT_IDLE_MARGIN_RPM
	if current_gear >= 0 and current_gear < downshift_rpm_per_gear.size():
		return downshift_rpm_per_gear[current_gear]
	return downshift_rpm


func update_shift_timers(delta: float) -> void:
	auto_shift_timer += delta
	if anti_hunt_active:
		anti_hunt_timer += delta
		if anti_hunt_timer > ANTI_HUNT_DURATION:
			anti_hunt_active = false


func record_auto_shift(previous_gear: int, new_gear: int) -> void:
	current_gear = new_gear
	auto_shift_timer = 0.0
	anti_hunt_active = true
	anti_hunt_timer = 0.0
	anti_hunt_from_gear = previous_gear


func blocks_hunt_upshift(shift_rpm: float, redline_rpm: float) -> bool:
	return (
		anti_hunt_active
		and anti_hunt_from_gear < current_gear
		and shift_rpm > redline_rpm - ANTI_HUNT_REDLINE_MARGIN_RPM
	)


func calculate_rear_wheel_torques(throttle: float, load_rl: float, load_rr: float) -> Dictionary:
	var torque := 0.0
	if engine != null:
		torque = engine.get_net_torque(throttle) * effective_ratio()

	var total_rear_load := maxf(load_rl + load_rr, 0.0001)
	var rr_split := clampf(load_rr / total_rear_load, 0.0, 1.0)
	return {
		"FL": 0.0,
		"FR": 0.0,
		"RL": torque * (1.0 - rr_split),
		"RR": torque * rr_split,
	}


func _sample_torque_curve(torque_curve: Array[Vector2], rpm: float, redline_rpm: float) -> float:
	if torque_curve.is_empty():
		return 0.0
	var x := clampf(rpm / maxf(redline_rpm, 1.0), 0.0, 1.0)
	if x <= torque_curve[0].x:
		return torque_curve[0].y
	for index in range(1, torque_curve.size()):
		var previous := torque_curve[index - 1]
		var current := torque_curve[index]
		if x <= current.x:
			var alpha := clampf((x - previous.x) / maxf(current.x - previous.x, 0.0001), 0.0, 1.0)
			return lerpf(previous.y, current.y, alpha)
	return torque_curve[torque_curve.size() - 1].y
