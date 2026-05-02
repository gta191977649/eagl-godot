class_name HP2PlayerInput
extends "res://gameplay/vehicles/hp2_controller/input_source.gd"


@export var throttle_action := "car_accelerate"
@export var brake_action := "car_brake"
@export var steer_left_action := "car_steer_left"
@export var steer_right_action := "car_steer_right"


func get_throttle() -> float:
	return maxf(_action_strength(throttle_action, "ui_up"), _key_strength([KEY_W, KEY_UP]))


func get_brake() -> float:
	return maxf(_action_strength(brake_action, "ui_down"), _key_strength([KEY_S, KEY_DOWN]))


func get_steer() -> float:
	var left := maxf(_action_strength(steer_left_action, "ui_left"), _key_strength([KEY_A, KEY_LEFT]))
	var right := maxf(_action_strength(steer_right_action, "ui_right"), _key_strength([KEY_D, KEY_RIGHT]))
	return left - right


func _action_strength(primary_action: String, fallback_action: String) -> float:
	if InputMap.has_action(primary_action):
		return Input.get_action_strength(primary_action)
	if InputMap.has_action(fallback_action):
		return Input.get_action_strength(fallback_action)
	return 0.0


func _key_strength(keycodes: Array[int]) -> float:
	for keycode in keycodes:
		if Input.is_physical_key_pressed(keycode):
			return 1.0
	return 0.0
