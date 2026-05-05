class_name HP2SteeringSystem
extends RefCounted


var steering_response_rate := 5.5
var max_steer_degrees := 30.0
var steer_state := 0.0
var current_steer_input := 0.0


func reset_runtime() -> void:
	steer_state = 0.0
	current_steer_input = 0.0


func update(target_steer: float, delta: float, speed_kmh: float = 0.0) -> float:
	var _unused_speed_kmh := speed_kmh
	var target := clampf(target_steer, -1.0, 1.0)
	current_steer_input = target
	var max_angle := deg_to_rad(max_steer_degrees)
	var target_angle := max_angle * current_steer_input
	if steering_response_rate <= 0.0:
		steer_state = target_angle
		return current_angle()
	var angle_rate := max_angle * steering_response_rate
	steer_state = move_toward(steer_state, target_angle, angle_rate * delta)
	return current_angle()


func current_angle() -> float:
	return steer_state


func current_input() -> float:
	return current_steer_input
