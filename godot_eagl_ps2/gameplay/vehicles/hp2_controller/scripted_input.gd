class_name HP2ScriptedInput
extends "res://gameplay/vehicles/hp2_controller/input_source.gd"


var throttle := 0.0
var brake := 0.0
var steer := 0.0


func set_values(new_throttle: float, new_brake: float, new_steer: float) -> void:
	throttle = clampf(new_throttle, 0.0, 1.0)
	brake = clampf(new_brake, 0.0, 1.0)
	steer = clampf(new_steer, -1.0, 1.0)


func get_throttle() -> float:
	return throttle


func get_brake() -> float:
	return brake


func get_steer() -> float:
	return steer
