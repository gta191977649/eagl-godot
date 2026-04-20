class_name EAGLCarController3D
extends Node3D

const HP2CarRuntimeScript = preload("res://eagl/assets/car/physics/hp2_car_runtime.gd")

const WHEEL_ORDER = ["FL", "FR", "RL", "RR"]
const FRONT_WHEELS = ["FL", "FR"]
const REAR_WHEELS = ["RL", "RR"]

@export var visual_root_path: NodePath
@export var enabled = true
@export var debug_free_drive = false
@export var debug_free_drive_speed = 28.0
@export var debug_free_drive_boost_speed = 64.0
@export var debug_free_drive_accel = 72.0
@export var debug_free_drive_yaw_speed = 2.4

var tuning: Dictionary = {}
var handling_data: Dictionary = {}

var velocity = Vector3.ZERO
var yaw_rate = 0.0
var steer = 0.0
var steering_angle = 0.0
var throttle = 0.0
var brake = 0.0
var handbrake = false
var filtered_throttle = 0.0
var filtered_reverse_throttle = 0.0
var engine_rpm = 850.0
var current_gear = 1
var clutch_engagement = 1.0
var shift_timer = 0.0
var reverse_hold_timer = 0.0
var drivetrain_mode = "forward"
var grounded = false
var movement_mode = "coast"
var local_longitudinal_speed = 0.0
var local_lateral_speed = 0.0
var slip = 0.0
var wheel_angular_speed = 0.0

var last_drive_force = 0.0
var last_brake_force = 0.0
var last_lateral_force = 0.0
var last_drag_force = 0.0
var last_normal_force = 0.0
var last_aero_force = 0.0
var last_rolling_force = 0.0
var last_suspension_force = 0.0
var last_engine_torque = 0.0
var last_wheel_torque = 0.0
var last_engine_brake_force = 0.0
var last_gear_ratio = 0.0
var last_torque_curve = 0.0

var angular_velocity = Vector3.ZERO
var wheel_states: Dictionary = {}

var _runtime


func _ready() -> void:
	_ensure_runtime()
	_runtime.ready(self)


func reset_motion() -> void:
	_ensure_runtime()
	_runtime.reset_motion(self)


func _physics_process(delta: float) -> void:
	if not enabled:
		return
	_ensure_runtime()
	_runtime.physics_process(self, delta)


func debug_state() -> Dictionary:
	_ensure_runtime()
	return _runtime.debug_state(self)


func _ensure_runtime() -> void:
	if _runtime == null:
		_runtime = HP2CarRuntimeScript.new()
	_runtime.configure(self)


func _read_input(delta: float) -> void:
	_ensure_runtime()
	_runtime.input_state.read(self, delta, _runtime.config)


func _read_vehicle_input(delta: float) -> void:
	_ensure_runtime()
	_runtime.input_state._read_vehicle_input(self, delta, _runtime.config)


func _read_free_drive_input(delta: float) -> void:
	_ensure_runtime()
	_runtime.input_state._read_free_drive_input(self, delta, _runtime.config)


func _integrate_hp2_body(body: Node3D, delta: float) -> void:
	_ensure_runtime()
	_runtime.integrator.integrate_hp2_body(self, _runtime, body, delta)


func _integrate_free_drive_body(body: Node3D, delta: float) -> void:
	_ensure_runtime()
	_runtime.integrator.integrate_free_drive_body(self, _runtime, body, delta)


func _resolve_wheel_force(slot_id: String, basis: Basis, mass: float, delta: float) -> Dictionary:
	_ensure_runtime()
	return _runtime.wheel.resolve_force(self, _runtime.config, _runtime.drivetrain, slot_id, basis, mass, delta)


func _update_drivetrain(delta: float) -> void:
	_ensure_runtime()
	_runtime.drivetrain.update(self, _runtime.config, _runtime.engine, delta)


func _update_forward_auto_shift(gear_count: int, delta: float) -> void:
	_ensure_runtime()
	_runtime.drivetrain.update_forward_auto_shift(self, _runtime.config, _runtime.engine, gear_count, delta)


func _drivetrain_force_for_wheel(axle: String, longitudinal_speed: float, mass: float) -> Dictionary:
	_ensure_runtime()
	return _runtime.drivetrain.force_for_wheel(self, _runtime.config, axle, longitudinal_speed, mass)


func _engine_torque_curve(rpm: float, idle: float, peak: float, redline: float) -> float:
	var clamped_rpm = clampf(rpm, idle, redline)
	if clamped_rpm <= peak:
		return clampf(lerpf(0.42, 1.0, (clamped_rpm - idle) / maxf(peak - idle, 1.0)), 0.35, 1.0)
	return clampf(lerpf(1.0, 0.68, (clamped_rpm - peak) / maxf(redline - peak, 1.0)), 0.55, 1.0)


func _gear_shift_up_rpm(gear: int) -> float:
	_ensure_runtime()
	return _runtime.drivetrain.gear_shift_up_rpm(gear, _runtime.config, _runtime.engine)


func _current_gear_ratio() -> float:
	_ensure_runtime()
	return _runtime.config.current_gear_ratio(current_gear)


func _gear_speed_for_shift(gear: int) -> float:
	_ensure_runtime()
	return _runtime.drivetrain.gear_speed_for_shift(gear, _runtime.config)


func _gear_upshift_speed(gear: int, gear_count: int) -> float:
	_ensure_runtime()
	return _runtime.drivetrain.gear_upshift_speed(gear, gear_count, _runtime.config)


func _gear_downshift_speed(gear: int, gear_count: int) -> float:
	_ensure_runtime()
	return _runtime.drivetrain.gear_downshift_speed(gear, gear_count, _runtime.config)


func _gear_count() -> int:
	_ensure_runtime()
	return _runtime.config.gear_count()


func _final_drive_ratio() -> float:
	_ensure_runtime()
	return _runtime.config.final_drive_ratio()


func _engine_idle_rpm() -> float:
	_ensure_runtime()
	return _runtime.config.engine_idle_rpm()


func _engine_peak_rpm() -> float:
	_ensure_runtime()
	return _runtime.config.engine_peak_rpm()


func _engine_redline_rpm() -> float:
	_ensure_runtime()
	return _runtime.config.engine_redline_rpm()


func _resolve_combined_tire_forces(state: Dictionary, requested_longitudinal: float, requested_lateral: float, longitudinal_limit: float, lateral_limit: float, delta: float) -> Dictionary:
	_ensure_runtime()
	return _runtime.wheel.resolve_combined_tire_forces(state, requested_longitudinal, requested_lateral, longitudinal_limit, lateral_limit, delta, _runtime.config)


func _resolve_drag_force(forward: Vector3 = Vector3.ZERO) -> Vector3:
	_ensure_runtime()
	return _runtime.integrator.resolve_drag_force(self, _runtime.config)


func _update_wheel_contacts(body: Node3D, basis: Basis, delta: float) -> void:
	_ensure_runtime()
	_runtime.suspension.update_wheel_contacts(self, _runtime.config, body, basis, delta)


func _update_body_ground_pose(body: Node3D, delta: float) -> void:
	_ensure_runtime()
	_runtime.suspension.update_body_ground_pose(self, _runtime.config, body, delta)


func _align_to_ground_normal(body: Node3D, normal: Vector3, delta: float) -> void:
	_ensure_runtime()
	_runtime.suspension.align_to_ground_normal(body, normal, delta)


func _update_wheel_visuals(delta: float) -> void:
	_ensure_runtime()
	_runtime.visual_wheel_rig.update(self, _runtime.config, _runtime.steering, delta)


func _cache_visual_parts() -> void:
	_ensure_runtime()
	_runtime.visual_wheel_rig.cache(self)


func _init_wheel_states() -> void:
	_ensure_runtime()
	_runtime.steering.init_wheel_states(self, _runtime.config)


func _wheel_slots() -> Array:
	_ensure_runtime()
	return _runtime.config.wheel_slots()


func _update_ackermann_steering() -> void:
	_ensure_runtime()
	_runtime.steering.update(self, _runtime.config)


func _fallback_wheelbase() -> float:
	_ensure_runtime()
	return _runtime.config.fallback_wheelbase()


func _fallback_track() -> float:
	_ensure_runtime()
	return _runtime.config.fallback_track()


func _slot_position(slot_id: String) -> Vector3:
	_ensure_runtime()
	return _runtime.config.slot_position(slot_id)


func _movement_mode() -> String:
	_ensure_runtime()
	return _runtime.integrator.movement_mode(self)


func _mass() -> float:
	_ensure_runtime()
	return _runtime.config.mass()


func _yaw_inertia(mass: float) -> float:
	_ensure_runtime()
	return _runtime.config.yaw_inertia()


func _aero_drag() -> float:
	_ensure_runtime()
	return _runtime.config.aero_drag()


func _suspension_value(name: String, fallback: float) -> float:
	_ensure_runtime()
	return _runtime.config.suspension_value(name, fallback)


func _field_value(field, fallback: float) -> float:
	_ensure_runtime()
	return _runtime.config.field_value(field, fallback)
