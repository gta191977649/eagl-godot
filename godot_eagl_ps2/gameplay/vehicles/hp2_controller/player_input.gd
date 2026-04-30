class_name HP2PlayerInput
extends "res://gameplay/vehicles/hp2_controller/input_source.gd"


@export var throttle_action := "car_accelerate"
@export var brake_action := "car_brake"
@export var steer_left_action := "car_steer_left"
@export var steer_right_action := "car_steer_right"


func get_throttle() -> float:
	return _action_strength(throttle_action, "ui_up")


func get_brake() -> float:
	return _action_strength(brake_action, "ui_down")


func get_steer() -> float:
	return _action_strength(steer_left_action, "ui_left") - _action_strength(steer_right_action, "ui_right")


func _action_strength(primary_action: String, fallback_action: String) -> float:
	if InputMap.has_action(primary_action):
		return Input.get_action_strength(primary_action)
	if InputMap.has_action(fallback_action):
		return Input.get_action_strength(fallback_action)
	return 0.0
