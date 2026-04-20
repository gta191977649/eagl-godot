class_name EAGLCarController3D
extends Node3D

@export var visual_root_path: NodePath
@export var enabled := true

var tuning: Dictionary = {}
var velocity := Vector3.ZERO
var yaw_rate := 0.0
var steer := 0.0
var throttle := 0.0
var brake := 0.0
var handbrake := false
var grounded := false
var local_longitudinal_speed := 0.0
var local_lateral_speed := 0.0
var slip := 0.0
var wheel_angular_speed := 0.0

var _wheel_nodes: Array[Node3D] = []
var _front_wheel_nodes: Array[Node3D] = []
var _visual_root: Node3D


func _ready() -> void:
	_cache_visual_parts()


func reset_motion() -> void:
	velocity = Vector3.ZERO
	yaw_rate = 0.0
	steer = 0.0
	throttle = 0.0
	brake = 0.0
	handbrake = false
	local_longitudinal_speed = 0.0
	local_lateral_speed = 0.0
	slip = 0.0
	wheel_angular_speed = 0.0


func _physics_process(delta: float) -> void:
	if not enabled:
		return
	var body := get_parent() as Node3D
	if body == null:
		return
	if _visual_root == null:
		_cache_visual_parts()

	_read_input(delta)
	_integrate_body(body, delta)
	_update_wheel_visuals(delta)


func _read_input(delta: float) -> void:
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

	if throttle > 0.0 and local_longitudinal_speed < max_forward_speed:
		velocity += forward * engine_accel * throttle * delta
	if brake > 0.0:
		if local_longitudinal_speed > 1.0:
			velocity -= forward * brake_accel * brake * delta
		elif local_longitudinal_speed > -max_reverse_speed:
			velocity -= forward * reverse_accel * brake * delta

	var grip := lateral_grip * (handbrake_grip_scale if handbrake else 1.0)
	velocity -= right * local_lateral_speed * clampf(grip * delta, 0.0, 1.0)
	if grounded:
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
	wheel_angular_speed = local_longitudinal_speed / maxf(wheel_radius, 0.01)
	for wheel in _wheel_nodes:
		if wheel == null or not is_instance_valid(wheel):
			continue
		wheel.rotate_object_local(Vector3.RIGHT, wheel_angular_speed * delta)
	for wheel in _front_wheel_nodes:
		if wheel == null or not is_instance_valid(wheel):
			continue
		wheel.set_meta("eagl_visual_steer", steer)


func _cache_visual_parts() -> void:
	_wheel_nodes.clear()
	_front_wheel_nodes.clear()
	_visual_root = get_node_or_null(visual_root_path) as Node3D
	if _visual_root == null:
		return
	for node in _visual_root.find_children("*", "Node3D", true, false):
		var node3d := node as Node3D
		if node3d == null:
			continue
		var object_name := String(node3d.get_meta("eagl_object_name", node3d.name)).to_upper()
		if object_name.contains("TIRE") or object_name.contains("WHEEL"):
			_wheel_nodes.append(node3d)
			if object_name.contains("FRONT"):
				_front_wheel_nodes.append(node3d)


func debug_state() -> Dictionary:
	return {
		"speed_mps": velocity.length(),
		"speed_kmh": velocity.length() * 3.6,
		"longitudinal_speed": local_longitudinal_speed,
		"lateral_speed": local_lateral_speed,
		"yaw_rate": yaw_rate,
		"steer": steer,
		"throttle": throttle,
		"brake": brake,
		"handbrake": handbrake,
		"grounded": grounded,
		"slip": slip,
		"wheel_angular_speed": wheel_angular_speed,
		"tuning_source": tuning.get("source", "unknown"),
		"tuning_status": tuning.get("status", "unknown"),
	}
