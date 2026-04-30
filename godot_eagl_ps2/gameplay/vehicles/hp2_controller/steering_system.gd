class_name HP2SteeringSystem
extends RefCounted


var steering_response_rate := 5.5
var max_steer_degrees := 30.0
var low_speed_steer_scale := 1.0
var high_speed_steer_scale := 0.28
var high_speed_steer_kph := 240.0
var current_steer := 0.0


func reset_runtime() -> void:
	current_steer = 0.0


func update(target_steer: float, delta: float, speed_kmh: float = 0.0) -> float:
	var target := clampf(target_steer, -1.0, 1.0)
	var t := clampf(speed_kmh / maxf(high_speed_steer_kph, 1.0), 0.0, 1.0)
	var speed_scale := lerpf(low_speed_steer_scale, high_speed_steer_scale, t * t)
	current_steer = move_toward(current_steer, target, steering_response_rate * speed_scale * delta)
	return current_angle()


func current_angle() -> float:
	return deg_to_rad(max_steer_degrees) * current_steer
