class_name FreeCamera
extends Camera3D

@export var base_speed = 60.0
@export var fast_multiplier = 5.0
@export var slow_multiplier = 0.2
@export var mouse_sensitivity = 0.002
@export var speed_step = 1.15

var _captured = false
var _pitch = 0.0
var _yaw = 0.0


func _ready() -> void:
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_set_capture(not _captured)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed and _captured:
		base_speed *= speed_step
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed and _captured:
		base_speed = max(1.0, base_speed / speed_step)
	if event is InputEventMouseMotion and _captured:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clamp(_pitch - event.relative.y * mouse_sensitivity, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		_set_capture(false)


func _process(delta: float) -> void:
	var dir = _input_dir()
	if dir == Vector3.ZERO:
		return
	var speed = base_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= fast_multiplier
	if Input.is_key_pressed(KEY_CTRL):
		speed *= slow_multiplier
	global_position += global_transform.basis * dir.normalized() * speed * delta


func _input_dir() -> Vector3:
	var dir = Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		dir.z += 1.0
	if Input.is_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_E):
		dir.y += 1.0
	if Input.is_key_pressed(KEY_Q):
		dir.y -= 1.0
	return dir


func _set_capture(enabled: bool) -> void:
	_captured = enabled
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if enabled else Input.MOUSE_MODE_VISIBLE


func is_captured() -> bool:
	return _captured
