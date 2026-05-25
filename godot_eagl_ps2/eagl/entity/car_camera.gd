class_name EAGLCarCamera
extends Camera3D

enum CameraProfileType {
	DRIVE_CHASE = 0,
	DRIVE_CHASE_CLOSE = 1,
	DRIVE_FIXED_NEAR = 2,
	DRIVE_FIXED_FORWARD = 3,
	DRIVE_CHASE_REVERSE = 4,
}

const CAMERA_PROFILE_NAMES := [
	"DRIVE_CHASE",
	"DRIVE_CHASE_CLOSE",
	"DRIVE_FIXED_NEAR",
	"DRIVE_FIXED_FORWARD",
	"DRIVE_CHASE_REVERSE",
]
const CYCLE_PROFILE_COUNT := 4
const ANGLE_UNITS := 65536.0
const ANGLE_UNIT_TO_RAD := TAU / ANGLE_UNITS
const HP2_VELOCITY_BLEND_SPEED := 8.32
const HP2_VELOCITY_BLEND_SCALE := 0.212766
const HP2_YAW_RATE_FAST_UNITS := 60000.0
const HP2_YAW_RATE_SLOW_UNITS := 20000.0
const HP2_TURN_ENTER_RIGHT := 0.7
const HP2_TURN_ENTER_LEFT := -0.3
const HP2_TURN_BUILD_RATE := 0.03 * 60.0
const HP2_TURN_DECAY_RATE := 0.012 * 60.0
const HP2_TURN_HOLD_TIME := 2.0
const HP2_MIN_TURN_SWAY := -1.0
const HP2_MAX_TURN_SWAY := 6.0
const HP2_FOV_NARROW := 0x32dc * 360.0 / ANGLE_UNITS
const HP2_FOV_WIDE := 0x4000 * 360.0 / ANGLE_UNITS

@export var target_path: NodePath
@export var target: Node3D
@export var current_profile := 0
@export var collision_mask := 1
@export var collision_margin := 0.35
@export var enable_collision := true
@export var auto_current := true

@export_group("Chase")
@export var chase_distance := 8.32
@export var chase_close_distance := 6.0
@export var chase_height := 2.24
@export var chase_close_height := 1.7
@export var target_height := 1.25
@export var look_ahead := 2.7
@export var pitch_degrees := -9.5
@export var lateral_sway_distance := 0.35
@export var velocity_sway_scale := 0.08

@export_group("Bumper")
@export var hood_forward := 0.7
@export var hood_height := 1.25
@export var bumper_forward := 2.0
@export var bumper_height := 1.08
@export var bumper_look_distance := 30.0

var _yaw := 0.0
var _last_car_yaw := 0.0
var _turn_history: Array[float] = []
var _turn_sway := 0.0
var _turn_hold := 0.0
var _was_seeded := false
var _look_back := false
var _chase_reverse_held := false


func _ready() -> void:
	current_profile = _cycle_profile_index(current_profile)
	if target == null and target_path != NodePath():
		target = get_node_or_null(target_path) as Node3D
	if auto_current:
		current = true
	_seed_from_target()
	set_process(true)


func _process(delta: float) -> void:
	if target == null:
		return
	if not _was_seeded:
		_seed_from_target()
	_update_drive_camera(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("camera_pov_change"):
		cycle_profile()
	elif event.is_action_pressed("camera_chase_reverse_hold"):
		set_chase_reverse_held(true)
	elif event.is_action_released("camera_chase_reverse_hold"):
		set_chase_reverse_held(false)
	elif event.is_action_pressed("camera_look_back"):
		_look_back = true
	elif event.is_action_released("camera_look_back"):
		_look_back = false


func set_target(new_target: Node3D) -> void:
	target = new_target
	_seed_from_target()


func reset_to_target() -> void:
	_seed_from_target()
	_update_drive_camera(0.0)


func cycle_profile() -> void:
	current_profile = (current_profile + 1) % CYCLE_PROFILE_COUNT
	_reset_profile_motion()


func set_chase_reverse_held(held: bool) -> void:
	if _chase_reverse_held == held:
		return
	_chase_reverse_held = held
	_reset_profile_motion()


func get_camera_mode_name() -> String:
	var profile := _profile_type()
	return CAMERA_PROFILE_NAMES[clampi(profile, 0, CAMERA_PROFILE_NAMES.size() - 1)]


func _reset_profile_motion() -> void:
	_turn_sway = 0.0
	_turn_hold = 0.0
	_apply_profile_fov()


func _seed_from_target() -> void:
	if target == null:
		return
	var forward := _target_forward()
	_yaw = _yaw_from_forward(forward)
	_last_car_yaw = _yaw
	_turn_history.clear()
	_turn_sway = 0.0
	_turn_hold = 0.0
	_was_seeded = true


func _update_drive_camera(delta: float) -> void:
	var profile := _profile_type()
	_apply_profile_fov(profile)
	if profile == CameraProfileType.DRIVE_FIXED_FORWARD:
		_update_forward_camera(bumper_forward, bumper_height)
		return
	if profile == CameraProfileType.DRIVE_FIXED_NEAR:
		_update_forward_camera(hood_forward, hood_height)
		return

	var car_position := target.global_transform.origin
	var car_forward := _target_forward()
	var velocity := _target_velocity()
	var horizontal_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var chase_forward := _drive_chase_forward(car_forward, horizontal_velocity)
	if _look_back or profile == CameraProfileType.DRIVE_CHASE_REVERSE:
		chase_forward = -chase_forward

	var target_yaw := _yaw_from_forward(chase_forward)
	var yaw_rate := HP2_YAW_RATE_FAST_UNITS * ANGLE_UNIT_TO_RAD
	if _angle_abs_delta(_yaw, target_yaw) < deg_to_rad(55.0):
		yaw_rate = HP2_YAW_RATE_SLOW_UNITS * ANGLE_UNIT_TO_RAD
	_yaw = _move_angle_toward(_yaw, target_yaw, yaw_rate * delta)

	var camera_forward := _forward_from_yaw(_yaw)
	_update_turn_sway(delta, car_forward, velocity)

	var distance := chase_distance
	var height := chase_height
	if profile == CameraProfileType.DRIVE_CHASE_CLOSE:
		distance = chase_close_distance
		height = chase_close_height
	elif profile == CameraProfileType.DRIVE_CHASE_REVERSE:
		distance = chase_close_distance
		height = chase_close_height

	var right := Vector3.UP.cross(camera_forward).normalized()
	var speed_sway := clampf(horizontal_velocity.length() * velocity_sway_scale, 0.0, 2.0)
	var target_point := car_position + Vector3.UP * target_height + car_forward * look_ahead
	var desired_position := target_point - camera_forward * distance
	desired_position += Vector3.UP * height
	desired_position += right * (_turn_sway * lateral_sway_distance + speed_sway * signf(_turn_sway))

	global_position = _collide_camera(target_point, desired_position)
	var look_target := target_point + Vector3.UP * tan(deg_to_rad(-pitch_degrees)) * 0.15
	look_at(look_target, Vector3.UP)


func _update_forward_camera(forward_offset: float, height_offset: float) -> void:
	var car_forward := _target_forward()
	var origin := target.global_transform.origin + Vector3.UP * height_offset + car_forward * forward_offset
	if _look_back:
		car_forward = -car_forward
	global_position = origin
	look_at(origin + car_forward * bumper_look_distance, Vector3.UP)


func _drive_chase_forward(car_forward: Vector3, horizontal_velocity: Vector3) -> Vector3:
	var speed := horizontal_velocity.length()
	if speed <= 0.001:
		return car_forward
	var velocity_forward := horizontal_velocity / speed
	if velocity_forward.dot(car_forward) < 0.0:
		velocity_forward = (velocity_forward - car_forward * 2.0 * velocity_forward.dot(car_forward)).normalized()
	var blend := clampf((speed - HP2_VELOCITY_BLEND_SPEED) * HP2_VELOCITY_BLEND_SCALE, 0.0, 1.0)
	return car_forward.slerp(velocity_forward, blend).normalized()


func _update_turn_sway(delta: float, car_forward: Vector3, velocity: Vector3) -> void:
	var local_velocity := target.global_transform.basis.inverse() * velocity
	var lateral_sample := clampf(local_velocity.x * 0.045, -1.0, 1.0)
	_turn_history.push_front(lateral_sample)
	while _turn_history.size() > 20:
		_turn_history.pop_back()

	var desired_direction := 0.0
	var sample_sum := 0.0
	for sample in _turn_history:
		sample_sum += sample
	var average := sample_sum / maxf(float(_turn_history.size()), 1.0)
	if average > HP2_TURN_ENTER_RIGHT:
		desired_direction = 1.0
	elif average < HP2_TURN_ENTER_LEFT:
		desired_direction = -1.0

	if desired_direction == 0.0:
		_turn_hold = maxf(_turn_hold - delta, 0.0)
		var decay := HP2_TURN_DECAY_RATE * delta
		_turn_sway = move_toward(_turn_sway, 0.0, decay)
		return

	_turn_hold = HP2_TURN_HOLD_TIME
	_turn_sway = clampf(
		_turn_sway + desired_direction * HP2_TURN_BUILD_RATE * delta,
		HP2_MIN_TURN_SWAY,
		HP2_MAX_TURN_SWAY
	)
	var yaw_delta := _angle_delta(_last_car_yaw, _yaw_from_forward(car_forward))
	_last_car_yaw = _yaw_from_forward(car_forward)
	_turn_sway += clampf(yaw_delta * 1.0, -0.15, 0.15)


func _collide_camera(target_point: Vector3, desired_position: Vector3) -> Vector3:
	if not enable_collision:
		return desired_position
	var world := get_world_3d()
	if world == null:
		return desired_position
	var query := PhysicsRayQueryParameters3D.create(target_point, desired_position)
	query.collision_mask = collision_mask
	query.exclude = [target.get_rid()] if target is CollisionObject3D else []
	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return desired_position
	var hit_position: Vector3 = hit.get("position", desired_position)
	var hit_normal: Vector3 = hit.get("normal", Vector3.UP)
	return hit_position + hit_normal * collision_margin


func _profile_type() -> int:
	if _chase_reverse_held:
		return CameraProfileType.DRIVE_CHASE_REVERSE
	match current_profile:
		1:
			return CameraProfileType.DRIVE_CHASE_CLOSE
		2:
			return CameraProfileType.DRIVE_FIXED_NEAR
		3:
			return CameraProfileType.DRIVE_FIXED_FORWARD
		_:
			return CameraProfileType.DRIVE_CHASE


func _apply_profile_fov(profile := -1) -> void:
	if profile < 0:
		profile = _profile_type()
	if profile == CameraProfileType.DRIVE_FIXED_NEAR or profile == CameraProfileType.DRIVE_FIXED_FORWARD:
		fov = HP2_FOV_WIDE
	else:
		fov = HP2_FOV_NARROW


func _cycle_profile_index(profile: int) -> int:
	return clampi(profile, 0, CYCLE_PROFILE_COUNT - 1)


func _target_forward() -> Vector3:
	if target == null:
		return Vector3.FORWARD
	if target.has_method("get_camera_forward_vector"):
		var custom_forward = target.call("get_camera_forward_vector")
		if custom_forward is Vector3:
			var resolved_forward := custom_forward as Vector3
			resolved_forward.y = 0.0
			if resolved_forward.length_squared() > 0.0001:
				return resolved_forward.normalized()
	var forward := target.global_transform.basis * Vector3(0.0, 0.0, 1.0)
	forward.y = 0.0
	if forward.length_squared() <= 0.0001:
		return Vector3(0.0, 0.0, 1.0)
	return forward.normalized()


func _target_velocity() -> Vector3:
	if target is RigidBody3D:
		return (target as RigidBody3D).linear_velocity
	if target.has_method("get_linear_velocity"):
		return target.call("get_linear_velocity")
	return Vector3.ZERO


func _yaw_from_forward(forward: Vector3) -> float:
	return atan2(forward.x, forward.z)


func _forward_from_yaw(yaw: float) -> Vector3:
	return Vector3(sin(yaw), 0.0, cos(yaw)).normalized()


func _angle_delta(from_angle: float, to_angle: float) -> float:
	return wrapf(to_angle - from_angle, -PI, PI)


func _angle_abs_delta(from_angle: float, to_angle: float) -> float:
	return absf(_angle_delta(from_angle, to_angle))


func _move_angle_toward(from_angle: float, to_angle: float, step: float) -> float:
	var delta := _angle_delta(from_angle, to_angle)
	if absf(delta) <= step:
		return to_angle
	return wrapf(from_angle + signf(delta) * step, -PI, PI)
