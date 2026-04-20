class_name EAGLCarController3D
extends Node3D

@export var visual_root_path: NodePath
@export var enabled := true
@export var debug_free_drive := false
@export var debug_free_drive_speed := 28.0
@export var debug_free_drive_boost_speed := 64.0
@export var debug_free_drive_accel := 72.0
@export var debug_free_drive_yaw_speed := 2.4

var tuning: Dictionary = {}
var handling_data: Dictionary = {}
var velocity := Vector3.ZERO
var yaw_rate := 0.0
var steer := 0.0
var steering_angle := 0.0
var throttle := 0.0
var brake := 0.0
var handbrake := false
var grounded := false
var movement_mode := "coast"
var local_longitudinal_speed := 0.0
var local_lateral_speed := 0.0
var slip := 0.0
var wheel_angular_speed := 0.0
var last_drive_force := 0.0
var last_brake_force := 0.0
var last_lateral_force := 0.0
var last_drag_force := 0.0

var _free_drive_input := Vector2.ZERO
var _free_drive_yaw_input := 0.0
var _free_drive_boost := false
var _spin_pivots: Array[Node3D] = []
var _steer_pivots: Array[Node3D] = []
var _visual_root: Node3D


func _ready() -> void:
	_cache_visual_parts()


func reset_motion() -> void:
	velocity = Vector3.ZERO
	yaw_rate = 0.0
	steer = 0.0
	steering_angle = 0.0
	throttle = 0.0
	brake = 0.0
	handbrake = false
	movement_mode = "coast"
	local_longitudinal_speed = 0.0
	local_lateral_speed = 0.0
	slip = 0.0
	wheel_angular_speed = 0.0
	last_drive_force = 0.0
	last_brake_force = 0.0
	last_lateral_force = 0.0
	last_drag_force = 0.0
	_free_drive_input = Vector2.ZERO
	_free_drive_yaw_input = 0.0
	_free_drive_boost = false


func _physics_process(delta: float) -> void:
	if not enabled:
		return
	var body := get_parent() as Node3D
	if body == null:
		return
	if _visual_root == null:
		_cache_visual_parts()

	_read_input(delta)
	if debug_free_drive:
		_integrate_free_drive_body(body, delta)
	else:
		_integrate_body(body, delta)
	_update_wheel_visuals(delta)


func _read_input(delta: float) -> void:
	if debug_free_drive:
		_read_free_drive_input(delta)
	else:
		_read_vehicle_input(delta)


func _read_vehicle_input(delta: float) -> void:
	var target_steer := 0.0
	if Input.is_key_pressed(KEY_A) or Input.get_action_strength("ui_left") > 0.0:
		target_steer += 1.0
	if Input.is_key_pressed(KEY_D) or Input.get_action_strength("ui_right") > 0.0:
		target_steer -= 1.0
	throttle = 1.0 if Input.is_key_pressed(KEY_W) or Input.get_action_strength("ui_up") > 0.0 else 0.0
	brake = 1.0 if Input.is_key_pressed(KEY_S) or Input.get_action_strength("ui_down") > 0.0 else 0.0
	handbrake = Input.is_key_pressed(KEY_SPACE)

	var rate := float(tuning.get("steer_rate", 2.6)) if absf(target_steer) > absf(steer) else float(tuning.get("steer_return_rate", 5.0))
	steer = move_toward(steer, target_steer, rate * delta)


func _read_free_drive_input(delta: float) -> void:
	var horizontal := 0.0
	var vertical := 0.0
	if Input.is_key_pressed(KEY_A) or Input.get_action_strength("ui_left") > 0.0:
		horizontal -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.get_action_strength("ui_right") > 0.0:
		horizontal += 1.0
	if Input.is_key_pressed(KEY_W) or Input.get_action_strength("ui_up") > 0.0:
		vertical += 1.0
	if Input.is_key_pressed(KEY_S) or Input.get_action_strength("ui_down") > 0.0:
		vertical -= 1.0

	_free_drive_input = Vector2(horizontal, vertical)
	_free_drive_yaw_input = 0.0
	if Input.is_key_pressed(KEY_Q):
		_free_drive_yaw_input += 1.0
	if Input.is_key_pressed(KEY_E):
		_free_drive_yaw_input -= 1.0
	_free_drive_boost = Input.is_key_pressed(KEY_SHIFT)

	throttle = maxf(vertical, 0.0)
	brake = maxf(-vertical, 0.0)
	handbrake = Input.is_key_pressed(KEY_SPACE)
	var rate := float(tuning.get("steer_rate", 2.6)) if absf(_free_drive_yaw_input) > absf(steer) else float(tuning.get("steer_return_rate", 5.0))
	steer = move_toward(steer, _free_drive_yaw_input, rate * delta)


func _integrate_body(body: Node3D, delta: float) -> void:
	var basis := body.global_transform.basis.orthonormalized()
	var forward := -basis.z.normalized()
	var right := basis.x.normalized()
	var up := basis.y.normalized()

	local_longitudinal_speed = velocity.dot(forward)
	local_lateral_speed = velocity.dot(right)
	var max_forward_speed := float(tuning.get("max_forward_speed", 86.0))
	var max_reverse_speed := float(tuning.get("max_reverse_speed", 18.0))
	var engine_accel := float(tuning.get("engine_accel", 34.0))
	var brake_accel := float(tuning.get("brake_accel", 48.0))
	var reverse_accel := float(tuning.get("reverse_accel", 18.0))
	var linear_drag := float(tuning.get("linear_drag", 0.42))
	var rolling_drag := float(tuning.get("rolling_drag", 2.0))
	var lateral_grip := float(tuning.get("lateral_grip", 8.5))
	var handbrake_grip_scale := float(tuning.get("handbrake_grip_scale", 0.38))
	var gravity := float(tuning.get("gravity", 28.0))

	last_drive_force = 0.0
	last_brake_force = 0.0
	last_lateral_force = 0.0
	last_drag_force = 0.0
	movement_mode = "airborne" if not grounded else "coast"
	if throttle > 0.0 and local_longitudinal_speed < max_forward_speed:
		last_drive_force = engine_accel * throttle
		velocity += forward * last_drive_force * delta
		movement_mode = "drive"
	if brake > 0.0:
		if local_longitudinal_speed > 1.0:
			last_brake_force = brake_accel * brake
			velocity -= forward * last_brake_force * delta
			movement_mode = "brake"
		elif local_longitudinal_speed > -max_reverse_speed:
			last_brake_force = reverse_accel * brake
			velocity -= forward * last_brake_force * delta
			movement_mode = "reverse"

	var grip := lateral_grip * (handbrake_grip_scale if handbrake else 1.0)
	last_lateral_force = local_lateral_speed * grip
	velocity -= right * local_lateral_speed * clampf(grip * delta, 0.0, 1.0)
	if grounded:
		last_drag_force = local_longitudinal_speed * linear_drag
		velocity -= forward * local_longitudinal_speed * clampf(linear_drag * delta, 0.0, 0.35)
		velocity = velocity.move_toward(Vector3.ZERO, rolling_drag * delta)
	else:
		velocity -= up * gravity * delta

	local_longitudinal_speed = velocity.dot(forward)
	local_lateral_speed = velocity.dot(right)
	slip = absf(local_lateral_speed) / maxf(absf(local_longitudinal_speed), 1.0)
	_update_yaw(body, up, delta)

	body.global_position += velocity * delta
	_update_ground_contact(body, delta)


func _integrate_free_drive_body(body: Node3D, delta: float) -> void:
	var basis := body.global_transform.basis.orthonormalized()
	var forward := -basis.z.normalized()
	var right := basis.x.normalized()
	var up := Vector3.UP
	var input_length := _free_drive_input.length()
	var target_velocity := Vector3.ZERO
	var max_speed := debug_free_drive_boost_speed if _free_drive_boost else debug_free_drive_speed

	last_drive_force = 0.0
	last_brake_force = 0.0
	last_lateral_force = 0.0
	last_drag_force = 0.0
	if input_length > 0.001:
		var move_dir := (right * _free_drive_input.x + forward * _free_drive_input.y).normalized()
		target_velocity = move_dir * max_speed
		last_drive_force = debug_free_drive_accel
		movement_mode = "free drive"
	else:
		movement_mode = "free idle"
		last_drag_force = debug_free_drive_accel

	velocity = velocity.move_toward(target_velocity, debug_free_drive_accel * delta)
	velocity.y = 0.0
	yaw_rate = _free_drive_yaw_input * debug_free_drive_yaw_speed
	if absf(yaw_rate) > 0.0001:
		body.global_transform.basis = Basis(up, yaw_rate * delta) * body.global_transform.basis

	body.global_position += velocity * delta
	_update_ground_contact(body, delta)

	basis = body.global_transform.basis.orthonormalized()
	forward = -basis.z.normalized()
	right = basis.x.normalized()
	local_longitudinal_speed = velocity.dot(forward)
	local_lateral_speed = velocity.dot(right)
	slip = absf(local_lateral_speed) / maxf(absf(local_longitudinal_speed), 1.0)


func _update_yaw(body: Node3D, up: Vector3, delta: float) -> void:
	var max_steer := float(tuning.get("max_steer_angle", 0.62))
	var yaw_response := float(tuning.get("yaw_response", 2.8))
	var yaw_damping := float(tuning.get("yaw_damping", 5.5))
	var speed_factor := clampf(absf(local_longitudinal_speed) / 32.0, 0.0, 1.35)
	var direction := 1.0 if local_longitudinal_speed >= 0.0 else -1.0
	var handbrake_boost := 1.65 if handbrake else 1.0
	yaw_rate += steer * max_steer * yaw_response * speed_factor * direction * handbrake_boost * delta
	yaw_rate = move_toward(yaw_rate, 0.0, yaw_damping * delta * maxf(0.35, 1.0 - minf(slip, 0.8) * 0.5))
	if absf(yaw_rate) > 0.0001:
		body.global_transform.basis = Basis(up, yaw_rate * delta) * body.global_transform.basis


func _update_ground_contact(body: Node3D, delta: float) -> void:
	var world := get_world_3d()
	if world == null:
		grounded = false
		return
	var suspension_height := float(tuning.get("suspension_height", 0.75))
	var probe_distance := float(tuning.get("ground_probe_distance", 1.35))
	var from := body.global_position + Vector3.UP * suspension_height
	var to := body.global_position - Vector3.UP * probe_distance
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit := world.direct_space_state.intersect_ray(query)
	grounded = not hit.is_empty()
	if not grounded:
		return
	var hit_position: Vector3 = hit.get("position", body.global_position)
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	body.global_position.y = lerpf(body.global_position.y, hit_position.y + suspension_height, clampf(delta * 16.0, 0.0, 1.0))
	_align_to_ground_normal(body, normal, delta)
	if velocity.y < 0.0:
		velocity.y = 0.0


func _align_to_ground_normal(body: Node3D, normal: Vector3, delta: float) -> void:
	if normal.length_squared() <= 0.001:
		return
	var basis := body.global_transform.basis.orthonormalized()
	var forward := (-basis.z).slide(normal).normalized()
	if forward.length_squared() <= 0.001:
		return
	var target := Basis.looking_at(forward, normal)
	body.global_transform.basis = basis.slerp(target, clampf(delta * 7.0, 0.0, 1.0)).orthonormalized()


func _update_wheel_visuals(delta: float) -> void:
	var wheel_radius := float(tuning.get("wheel_radius", 0.36))
	var max_steer := float(tuning.get("max_steer_angle", 0.62))
	wheel_angular_speed = local_longitudinal_speed / maxf(wheel_radius, 0.01)
	steering_angle = steer * max_steer
	for spin_pivot in _spin_pivots:
		if spin_pivot == null or not is_instance_valid(spin_pivot):
			continue
		var spin_direction := float(spin_pivot.get_meta("eagl_spin_direction", 1.0))
		spin_pivot.rotation.x += wheel_angular_speed * spin_direction * delta
	for steer_pivot in _steer_pivots:
		if steer_pivot == null or not is_instance_valid(steer_pivot):
			continue
		steer_pivot.rotation.y = steering_angle
		steer_pivot.set_meta("eagl_visual_steer", steer)
		steer_pivot.set_meta("eagl_visual_steering_angle", steering_angle)


func _cache_visual_parts() -> void:
	_spin_pivots.clear()
	_steer_pivots.clear()
	_visual_root = get_node_or_null(visual_root_path) as Node3D
	if _visual_root == null:
		return
	for node in _visual_root.find_children("*", "Node3D", true, false):
		var node3d := node as Node3D
		if node3d == null:
			continue
		if node3d.has_meta("eagl_spin_pivot") and bool(node3d.get_meta("eagl_spin_pivot")):
			_spin_pivots.append(node3d)
		if node3d.has_meta("eagl_steer_pivot") and bool(node3d.get_meta("eagl_steer_pivot")):
			_steer_pivots.append(node3d)


func debug_state() -> Dictionary:
	return {
		"speed_mps": velocity.length(),
		"speed_kmh": velocity.length() * 3.6,
		"longitudinal_speed": local_longitudinal_speed,
		"lateral_speed": local_lateral_speed,
		"yaw_rate": yaw_rate,
		"steer": steer,
		"steering_angle": steering_angle,
		"throttle": throttle,
		"brake": brake,
		"handbrake": handbrake,
		"grounded": grounded,
		"movement_mode": movement_mode,
		"slip": slip,
		"wheel_angular_speed": wheel_angular_speed,
		"spin_pivot_count": _spin_pivots.size(),
		"steer_pivot_count": _steer_pivots.size(),
		"drive_force": last_drive_force,
		"brake_force": last_brake_force,
		"lateral_force": last_lateral_force,
		"drag_force": last_drag_force,
		"debug_free_drive": debug_free_drive,
		"debug_free_drive_boost": _free_drive_boost,
		"debug_free_drive_input": _free_drive_input,
		"handling_source": handling_data.get("handling_source", tuning.get("source", "unknown")),
		"exact_handling_status": handling_data.get("exact_handling_status", tuning.get("exact_handling_status", "unknown")),
		"decoded_car_id": handling_data.get("car_id", tuning.get("car_id", "")),
		"tuning_source": tuning.get("source", "unknown"),
		"tuning_status": tuning.get("status", "unknown"),
	}
