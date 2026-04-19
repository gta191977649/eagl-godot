class_name EAGLFreeCamera
extends Camera3D

@export var mouse_sensitivity := 0.0025
@export var base_speed := 300.0
@export var sprint_multiplier := 4.0
@export var slow_multiplier := 0.25
@export var speed_step := 1.25
@export var min_speed := 1.0
@export var max_speed := 8000.0
@export var capture_mouse_on_ready := true

var yaw := 0.0
var pitch := 0.0
var mouse_captured := false
var speed_label: Label


func _ready() -> void:
	current = true
	_set_angles_from_rotation()
	_create_speed_hud()
	_update_speed_hud()
	if capture_mouse_on_ready:
		capture_mouse()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		if mouse_button.pressed and mouse_button.button_index == MOUSE_BUTTON_LEFT:
			capture_mouse()
		elif mouse_button.pressed and mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP:
			adjust_speed(speed_step)
		elif mouse_button.pressed and mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			adjust_speed(1.0 / speed_step)
	elif event is InputEventMouseMotion and mouse_captured:
		var motion := event as InputEventMouseMotion
		yaw -= motion.relative.x * mouse_sensitivity
		pitch -= motion.relative.y * mouse_sensitivity
		pitch = clampf(pitch, deg_to_rad(-89.0), deg_to_rad(89.0))
		rotation = Vector3(pitch, yaw, 0.0)
	elif event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			release_mouse()
		elif key.pressed and key.keycode in [KEY_EQUAL, KEY_PLUS, KEY_KP_ADD, KEY_BRACKETRIGHT]:
			adjust_speed(speed_step)
		elif key.pressed and key.keycode in [KEY_MINUS, KEY_KP_SUBTRACT, KEY_BRACKETLEFT]:
			adjust_speed(1.0 / speed_step)
		elif key.pressed and not key.echo and key.keycode == KEY_0:
			base_speed = 300.0
			_update_speed_hud()


func _physics_process(delta: float) -> void:
	var direction := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		direction -= transform.basis.z
	if Input.is_physical_key_pressed(KEY_S):
		direction += transform.basis.z
	if Input.is_physical_key_pressed(KEY_A):
		direction -= transform.basis.x
	if Input.is_physical_key_pressed(KEY_D):
		direction += transform.basis.x
	if Input.is_physical_key_pressed(KEY_SPACE) or Input.is_physical_key_pressed(KEY_E):
		direction += Vector3.UP
	if Input.is_physical_key_pressed(KEY_CTRL) or Input.is_physical_key_pressed(KEY_Q):
		direction -= Vector3.UP

	if direction == Vector3.ZERO:
		return

	var speed := base_speed
	if Input.is_physical_key_pressed(KEY_SHIFT):
		speed *= sprint_multiplier
	if Input.is_physical_key_pressed(KEY_ALT):
		speed *= slow_multiplier

	global_position += direction.normalized() * speed * delta


func capture_mouse() -> void:
	mouse_captured = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_speed_hud()


func release_mouse() -> void:
	mouse_captured = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_update_speed_hud()


func look_at_target(target: Vector3) -> void:
	look_at(target, Vector3.UP)
	_set_angles_from_rotation()


func _set_angles_from_rotation() -> void:
	yaw = rotation.y
	pitch = rotation.x


func adjust_speed(multiplier: float) -> void:
	base_speed = clampf(base_speed * multiplier, min_speed, max_speed)
	_update_speed_hud()


func _create_speed_hud() -> void:
	if speed_label != null:
		return
	var layer := CanvasLayer.new()
	layer.name = "FreeCameraHud"
	add_child(layer)

	speed_label = Label.new()
	speed_label.name = "SpeedLabel"
	speed_label.position = Vector2(16.0, 16.0)
	speed_label.add_theme_font_size_override("font_size", 16)
	speed_label.add_theme_color_override("font_color", Color(0.92, 0.95, 0.98, 1.0))
	speed_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	speed_label.add_theme_constant_override("shadow_offset_x", 1)
	speed_label.add_theme_constant_override("shadow_offset_y", 1)
	layer.add_child(speed_label)


func _update_speed_hud() -> void:
	if speed_label == null:
		return
	var mode := "captured" if mouse_captured else "visible"
	speed_label.text = "Free camera\nSpeed: %.1f  Sprint: %.1f\nWheel / +/- / [] adjust, 0 reset\nWASD move, Space/E up, Ctrl/Q down, Shift fast, Alt slow, Esc mouse %s" % [
		base_speed,
		base_speed * sprint_multiplier,
		mode,
	]
