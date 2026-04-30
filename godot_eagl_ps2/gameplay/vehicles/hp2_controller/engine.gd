class_name HP2Engine
extends RefCounted


const SHIFT_CUT_FACTOR := 0.35
const SHIFT_CUT_DURATION := 0.4
const REV_LIMITER_DRAG := 0.5

var rpm := 900.0
var idle_rpm := 900.0
var peak_rpm := 6500.0
var max_rpm := 8500.0
var throttle_scale := 1.0
var throttle_multiplier := 1.0
var shift_cut_active := false
var shift_cut_timer := 0.0

var torque_curve: Array[Vector2] = [
	Vector2(0.00, 80.0),
	Vector2(0.10, 160.0),
	Vector2(0.20, 280.0),
	Vector2(0.30, 340.0),
	Vector2(0.40, 380.0),
	Vector2(0.55, 400.0),
	Vector2(0.70, 370.0),
	Vector2(0.85, 310.0),
	Vector2(1.00, 200.0),
]

var friction_curve: Array[Vector2] = [
	Vector2(0.0, 20.0),
	Vector2(0.5, 35.0),
	Vector2(1.0, 60.0),
]


func reset_runtime() -> void:
	rpm = idle_rpm
	shift_cut_active = false
	shift_cut_timer = 0.0


func apply_globalb_samples(torque_samples: PackedFloat32Array, friction_samples: PackedFloat32Array) -> void:
	if torque_samples.size() >= 2:
		torque_curve = _samples_to_curve(torque_samples, 400.0)
	if friction_samples.size() >= 2:
		friction_curve = _samples_to_curve(friction_samples, 60.0)


func get_net_torque(throttle: float) -> float:
	var rpm_normalized := clampf(rpm / maxf(max_rpm, 1.0), 0.0, 1.0)
	var peak_torque := _sample_curve(torque_curve, rpm_normalized) * throttle_scale
	if shift_cut_active:
		peak_torque *= SHIFT_CUT_FACTOR
	if rpm >= max_rpm - 100.0:
		peak_torque = -REV_LIMITER_DRAG * absf(peak_torque)

	var friction := _sample_curve(friction_curve, rpm_normalized)
	return peak_torque * throttle * throttle_multiplier - friction * (1.0 - throttle * throttle_multiplier)


func update(delta: float, driven_wheel_angular_velocity: float, effective_gear_ratio: float) -> void:
	var target_rpm := absf(driven_wheel_angular_velocity * effective_gear_ratio * 60.0 / TAU)
	target_rpm = clampf(target_rpm, idle_rpm, max_rpm * 1.05)
	rpm = lerpf(rpm, target_rpm, clampf(delta * 15.0, 0.0, 1.0))

	if shift_cut_active:
		shift_cut_timer += delta
		if shift_cut_timer >= SHIFT_CUT_DURATION:
			shift_cut_active = false
			shift_cut_timer = 0.0


func trigger_shift_cut() -> void:
	shift_cut_active = true
	shift_cut_timer = 0.0


func _sample_curve(curve: Array[Vector2], x: float) -> float:
	if curve.is_empty():
		return 0.0
	if x <= curve[0].x:
		return curve[0].y
	for index in range(1, curve.size()):
		var previous := curve[index - 1]
		var current := curve[index]
		if x <= current.x:
			var alpha := clampf((x - previous.x) / maxf(current.x - previous.x, 0.0001), 0.0, 1.0)
			return lerpf(previous.y, current.y, alpha)
	return curve[curve.size() - 1].y


func _samples_to_curve(samples: PackedFloat32Array, output_peak: float) -> Array[Vector2]:
	var max_sample := 0.0
	for sample in samples:
		max_sample = maxf(max_sample, float(sample))
	if max_sample <= 0.0001:
		return []
	var curve: Array[Vector2] = []
	var denom := maxf(float(samples.size() - 1), 1.0)
	for index in range(samples.size()):
		var x := float(index) / denom
		var y := float(samples[index]) / max_sample * output_peak
		curve.append(Vector2(x, y))
	return curve
