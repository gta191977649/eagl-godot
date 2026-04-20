class_name HP2InputState
extends RefCounted

var free_drive_input = Vector2.ZERO
var free_drive_yaw_input = 0.0
var free_drive_boost = false


func reset() -> void:
	free_drive_input = Vector2.ZERO
	free_drive_yaw_input = 0.0
	free_drive_boost = false


func read(owner, delta: float, config) -> void:
	if owner.debug_free_drive:
		_read_free_drive_input(owner, delta, config)
	else:
		_read_vehicle_input(owner, delta, config)


func _read_vehicle_input(owner, delta: float, config) -> void:
	var target_steer = 0.0
	if Input.is_key_pressed(KEY_A) or Input.get_action_strength("ui_left") > 0.0:
		target_steer += 1.0
	if Input.is_key_pressed(KEY_D) or Input.get_action_strength("ui_right") > 0.0:
		target_steer -= 1.0
	owner.throttle = 1.0 if Input.is_key_pressed(KEY_W) or Input.get_action_strength("ui_up") > 0.0 else 0.0
	owner.brake = 1.0 if Input.is_key_pressed(KEY_S) or Input.get_action_strength("ui_down") > 0.0 else 0.0
	owner.handbrake = Input.is_key_pressed(KEY_SPACE)

	var rate = float(config.tuning.get("steer_rate", 2.6)) if absf(target_steer) > absf(owner.steer) else float(config.tuning.get("steer_return_rate", 5.0))
	owner.steer = move_toward(owner.steer, target_steer, rate * delta)


func _read_free_drive_input(owner, delta: float, config) -> void:
	var horizontal = 0.0
	var vertical = 0.0
	if Input.is_key_pressed(KEY_A) or Input.get_action_strength("ui_left") > 0.0:
		horizontal -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.get_action_strength("ui_right") > 0.0:
		horizontal += 1.0
	if Input.is_key_pressed(KEY_W) or Input.get_action_strength("ui_up") > 0.0:
		vertical += 1.0
	if Input.is_key_pressed(KEY_S) or Input.get_action_strength("ui_down") > 0.0:
		vertical -= 1.0

	free_drive_input = Vector2(horizontal, vertical)
	free_drive_yaw_input = 0.0
	if Input.is_key_pressed(KEY_Q):
		free_drive_yaw_input += 1.0
	if Input.is_key_pressed(KEY_E):
		free_drive_yaw_input -= 1.0
	free_drive_boost = Input.is_key_pressed(KEY_SHIFT)

	owner.throttle = maxf(vertical, 0.0)
	owner.brake = maxf(-vertical, 0.0)
	owner.handbrake = Input.is_key_pressed(KEY_SPACE)
	var rate = float(config.tuning.get("steer_rate", 2.6)) if absf(free_drive_yaw_input) > absf(owner.steer) else float(config.tuning.get("steer_return_rate", 5.0))
	owner.steer = move_toward(owner.steer, free_drive_yaw_input, rate * delta)
