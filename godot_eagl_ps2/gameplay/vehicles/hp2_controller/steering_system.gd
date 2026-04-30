class_name HP2SteeringSystem
extends RefCounted


var steering_response_rate := 5.5
var max_steer_degrees := 30.0
var current_steer := 0.0


func reset_runtime() -> void:
	current_steer = 0.0


func update(target_steer: float, delta: float) -> float:
	var target := clampf(target_steer, -1.0, 1.0)
	current_steer = move_toward(current_steer, target, steering_response_rate * delta)
	return current_angle()


func current_angle() -> float:
	return deg_to_rad(max_steer_degrees) * current_steer
