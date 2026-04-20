class_name EAGLCarController3D
extends Node3D

const WHEEL_ORDER := ["FL", "FR", "RL", "RR"]
const FRONT_WHEELS := ["FL", "FR"]
const REAR_WHEELS := ["RL", "RR"]

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
var filtered_throttle := 0.0
var filtered_reverse_throttle := 0.0
var engine_rpm := 850.0
var current_gear := 1
var clutch_engagement := 1.0
var shift_timer := 0.0
var reverse_hold_timer := 0.0
var drivetrain_mode := "forward"
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
var last_normal_force := 0.0
var last_aero_force := 0.0
var last_rolling_force := 0.0
var last_suspension_force := 0.0
var last_engine_torque := 0.0
var last_wheel_torque := 0.0
var last_engine_brake_force := 0.0
var last_gear_ratio := 0.0
var last_torque_curve := 0.0

var angular_velocity := Vector3.ZERO
var wheel_states: Dictionary = {}

var _free_drive_input := Vector2.ZERO
var _free_drive_yaw_input := 0.0
var _free_drive_boost := false
var _spin_pivots: Array[Node3D] = []
var _steer_pivots: Array[Node3D] = []
var _visual_root: Node3D


func _ready() -> void:
	_cache_visual_parts()
	_init_wheel_states()


func reset_motion() -> void:
	velocity = Vector3.ZERO
	yaw_rate = 0.0
	angular_velocity = Vector3.ZERO
	steer = 0.0
	steering_angle = 0.0
	throttle = 0.0
	brake = 0.0
	handbrake = false
	filtered_throttle = 0.0
	filtered_reverse_throttle = 0.0
	engine_rpm = _engine_idle_rpm()
	current_gear = 1
	clutch_engagement = 1.0
	shift_timer = 0.0
	reverse_hold_timer = 0.0
	drivetrain_mode = "forward"
	movement_mode = "coast"
	local_longitudinal_speed = 0.0
	local_lateral_speed = 0.0
	slip = 0.0
	wheel_angular_speed = 0.0
	last_drive_force = 0.0
	last_brake_force = 0.0
	last_lateral_force = 0.0
	last_drag_force = 0.0
	last_normal_force = 0.0
	last_aero_force = 0.0
	last_rolling_force = 0.0
	last_suspension_force = 0.0
	last_engine_torque = 0.0
	last_wheel_torque = 0.0
	last_engine_brake_force = 0.0
	last_gear_ratio = 0.0
	last_torque_curve = 0.0
	_free_drive_input = Vector2.ZERO
	_free_drive_yaw_input = 0.0
	_free_drive_boost = false
	_init_wheel_states()


func _physics_process(delta: float) -> void:
	if not enabled:
		return
	var body := get_parent() as Node3D
	if body == null:
		return
	if _visual_root == null:
		_cache_visual_parts()
	if wheel_states.is_empty():
		_init_wheel_states()

	_read_input(delta)
	if debug_free_drive:
		_integrate_free_drive_body(body, delta)
	else:
		_integrate_hp2_body(body, delta)
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


func _integrate_hp2_body(body: Node3D, delta: float) -> void:
	var basis := body.global_transform.basis.orthonormalized()
	var up := basis.y.normalized()
	var forward := -basis.z.normalized()
	var right := basis.x.normalized()
	local_longitudinal_speed = velocity.dot(forward)
	local_lateral_speed = velocity.dot(right)

	var mass := _mass()
	var inertia_yaw := _yaw_inertia(mass)
	var force := Vector3.ZERO
	var torque_yaw := 0.0

	last_drive_force = 0.0
	last_brake_force = 0.0
	last_lateral_force = 0.0
	last_drag_force = 0.0
	last_normal_force = 0.0
	last_aero_force = 0.0
	last_rolling_force = 0.0
	last_suspension_force = 0.0
	last_engine_torque = 0.0
	last_wheel_torque = 0.0
	last_engine_brake_force = 0.0
	last_gear_ratio = 0.0
	last_torque_curve = 0.0

	_update_drivetrain(delta)

	_update_wheel_contacts(body, basis, delta)
	grounded = false
	for slot_id in WHEEL_ORDER:
		var state: Dictionary = wheel_states.get(slot_id, {})
		if bool(state.get("grounded", false)):
			grounded = true
			break

	force -= Vector3.UP * mass * float(tuning.get("gravity", 28.0))
	if grounded:
		_update_ackermann_steering()
		for slot_id in WHEEL_ORDER:
			var state: Dictionary = wheel_states.get(slot_id, {})
			if bool(state.get("grounded", false)):
				var suspension_force: Vector3 = state.get("suspension_force_vector", Vector3.ZERO)
				force += suspension_force
				last_suspension_force += suspension_force.length()
			var wheel_force := _resolve_wheel_force(slot_id, basis, mass, delta)
			force += wheel_force["force"]
			torque_yaw += float(wheel_force["yaw_torque"])

	var drag := _resolve_drag_force(forward)
	force += drag
	var acceleration := force / maxf(mass, 1.0)
	velocity += acceleration * delta
	body.global_position += velocity * delta
	yaw_rate += (torque_yaw / maxf(inertia_yaw, 1.0)) * delta
	var yaw_damping := float(tuning.get("yaw_damping", 5.5))
	yaw_rate = move_toward(yaw_rate, 0.0, yaw_damping * delta * 0.35)
	angular_velocity = up * yaw_rate
	if absf(yaw_rate) > 0.00001:
		body.global_transform.basis = (Basis(up, yaw_rate * delta) * body.global_transform.basis).orthonormalized()

	_update_body_ground_pose(body, delta)
	basis = body.global_transform.basis.orthonormalized()
	forward = -basis.z.normalized()
	right = basis.x.normalized()
	local_longitudinal_speed = velocity.dot(forward)
	local_lateral_speed = velocity.dot(right)
	slip = absf(local_lateral_speed) / maxf(absf(local_longitudinal_speed), 1.0)
	movement_mode = _movement_mode()


func _resolve_wheel_force(slot_id: String, basis: Basis, mass: float, delta: float) -> Dictionary:
	var state: Dictionary = wheel_states.get(slot_id, {})
	if not bool(state.get("grounded", false)):
		return {"force": Vector3.ZERO, "yaw_torque": 0.0}
	var slot: Dictionary = state.get("slot", {})
	var axle := String(slot.get("axle", "front"))
	var local_pos: Vector3 = slot.get("position_godot", Vector3.ZERO)
	var steer_angle := float(state.get("steering_angle", 0.0))
	var contact_normal: Vector3 = state.get("contact_normal", basis.y.normalized())
	contact_normal = contact_normal.normalized() if contact_normal.length_squared() > 0.001 else basis.y.normalized()
	var forward := (-basis.z).rotated(basis.y.normalized(), steer_angle).slide(contact_normal)
	if forward.length_squared() <= 0.001:
		forward = (-basis.z).rotated(basis.y.normalized(), steer_angle)
	forward = forward.normalized()
	var right := forward.cross(contact_normal).normalized()
	if right.dot(basis.x) < 0.0:
		right = -right
	var contact_velocity := velocity + angular_velocity.cross(basis * local_pos)
	var longitudinal_speed := contact_velocity.dot(forward)
	var lateral_speed := contact_velocity.dot(right)
	var normal_force := float(state.get("normal_force", mass * float(tuning.get("gravity", 28.0)) * 0.25))
	var longitudinal_grip := float(tuning.get("%s_longitudinal_grip" % axle, tuning.get("rear_longitudinal_grip", 7.0)))
	var lateral_grip := float(tuning.get("%s_lateral_grip" % axle, tuning.get("lateral_grip", 8.0)))
	if handbrake and axle == "rear":
		lateral_grip *= float(tuning.get("handbrake_grip_scale", 0.38))
	var drivetrain_force := _drivetrain_force_for_wheel(axle, longitudinal_speed, mass)
	var drive_force := float(drivetrain_force.get("drive_force", 0.0))
	var engine_brake_force := float(drivetrain_force.get("engine_brake_force", 0.0))
	var service_brake := brake
	if current_gear < 0 and filtered_reverse_throttle > 0.0 and local_longitudinal_speed < float(tuning.get("reverse_engage_speed", 1.2)):
		service_brake = 0.0
	var brake_force := float(tuning.get("brake_accel", 48.0)) * mass * service_brake * 0.25
	if handbrake and axle == "rear":
		brake_force += float(tuning.get("brake_accel", 48.0)) * mass * 0.20
	var tire_longitudinal_limit := normal_force * longitudinal_grip
	var tire_lateral_limit := normal_force * lateral_grip
	var rolling := -signf(longitudinal_speed) * minf(absf(longitudinal_speed) * float(tuning.get("rolling_drag", 2.0)) * mass * 0.03, tire_longitudinal_limit * 0.25)
	var requested_longitudinal := drive_force + engine_brake_force - signf(longitudinal_speed) * brake_force + rolling
	var requested_lateral := -lateral_speed * mass * lateral_grip * 0.28
	var slip_angle := atan2(lateral_speed, maxf(absf(longitudinal_speed), 0.5))
	var slip_falloff := lerpf(1.0, float(tuning.get("tire_high_slip_grip_scale", 0.72)), clampf((absf(slip_angle) - 0.35) / 0.65, 0.0, 1.0))
	tire_lateral_limit *= slip_falloff
	var combined := _resolve_combined_tire_forces(state, requested_longitudinal, requested_lateral, tire_longitudinal_limit, tire_lateral_limit, delta)
	var longitudinal_force := float(combined.get("longitudinal_force", 0.0))
	var lateral_force := float(combined.get("lateral_force", 0.0))
	var total := forward * longitudinal_force + right * lateral_force
	var yaw_torque := (basis * local_pos).cross(total).dot(basis.y.normalized())
	var radius := float(slot.get("wheel_radius", tuning.get("wheel_radius", 0.36)))
	var angular_speed := longitudinal_speed / maxf(radius, 0.01)
	var slip_ratio := absf(requested_longitudinal - longitudinal_force) / maxf(tire_longitudinal_limit, 1.0)
	state["longitudinal_speed"] = longitudinal_speed
	state["lateral_speed"] = lateral_speed
	state["requested_longitudinal_force"] = requested_longitudinal
	state["requested_lateral_force"] = requested_lateral
	state["longitudinal_force"] = longitudinal_force
	state["lateral_force"] = lateral_force
	state["combined_tire_saturation"] = combined.get("saturation", 0.0)
	state["tire_slip_falloff"] = slip_falloff
	state["drive_force"] = drive_force
	state["engine_brake_force"] = engine_brake_force
	state["brake_force"] = brake_force
	state["rolling_force"] = rolling
	state["slip_ratio"] = slip_ratio
	state["slip_angle"] = slip_angle
	state["angular_speed"] = angular_speed
	state["skidding"] = absf(slip_angle) > 0.28 or slip_ratio > 0.18
	wheel_states[slot_id] = state
	last_drive_force += absf(drive_force)
	last_engine_brake_force += absf(engine_brake_force)
	last_brake_force += absf(brake_force)
	last_lateral_force += absf(lateral_force)
	last_normal_force += normal_force
	last_rolling_force += absf(rolling)
	return {"force": total, "yaw_torque": yaw_torque}


func _update_drivetrain(delta: float) -> void:
	var idle := _engine_idle_rpm()
	var peak := _engine_peak_rpm()
	var redline := _engine_redline_rpm()
	var gear_count := _gear_count()
	var max_forward_speed := float(tuning.get("max_forward_speed", 86.0))
	var max_reverse_speed := float(tuning.get("max_reverse_speed", 18.0))
	var response := float(tuning.get("throttle_response_rate", 7.5))
	filtered_throttle = move_toward(filtered_throttle, throttle, response * delta)
	var reverse_requested := brake > 0.0 and throttle <= 0.0 and local_longitudinal_speed <= float(tuning.get("reverse_engage_speed", 1.2))
	reverse_hold_timer = reverse_hold_timer + delta if reverse_requested else 0.0
	var reverse_ready := reverse_hold_timer >= float(tuning.get("reverse_hold_delay", 0.10))
	if reverse_ready:
		current_gear = -1
	elif throttle > 0.0 and local_longitudinal_speed > -0.6:
		current_gear = maxi(current_gear, 1)
	var target_reverse_throttle := brake if current_gear < 0 and reverse_ready else 0.0
	filtered_reverse_throttle = move_toward(filtered_reverse_throttle, target_reverse_throttle, response * delta)
	if current_gear > 0:
		_update_forward_auto_shift(gear_count, delta)

	if shift_timer > 0.0:
		shift_timer = maxf(0.0, shift_timer - delta)
	var shift_duration := maxf(float(tuning.get("shift_duration", 0.18)), 0.01)
	clutch_engagement = 1.0 - clampf(shift_timer / shift_duration, 0.0, 1.0)

	var ratio := _current_gear_ratio()
	last_gear_ratio = ratio
	var wheel_radius := maxf(float(tuning.get("rear_wheel_radius", tuning.get("wheel_radius", 0.36))), 0.01)
	var wheel_rpm := absf(local_longitudinal_speed) / wheel_radius * 60.0 / TAU
	var coupled_rpm := wheel_rpm * absf(ratio) * _final_drive_ratio()
	var input_amount := filtered_reverse_throttle if current_gear < 0 else filtered_throttle
	var free_rev_target := lerpf(idle, redline * 0.72, input_amount)
	var target_rpm := maxf(coupled_rpm, free_rev_target if absf(local_longitudinal_speed) < 1.0 else idle)
	engine_rpm = move_toward(engine_rpm, clampf(target_rpm, idle, redline * 1.04), maxf(redline * 2.4, 1.0) * delta)
	if engine_rpm > redline:
		engine_rpm = move_toward(engine_rpm, redline, redline * 4.0 * delta)
	last_torque_curve = _engine_torque_curve(engine_rpm, idle, peak, redline)
	if current_gear < 0:
		drivetrain_mode = "reverse"
	elif shift_timer > 0.0:
		drivetrain_mode = "shift"
	elif throttle > 0.0:
		drivetrain_mode = "drive"
	elif brake > 0.0 and local_longitudinal_speed > 1.0:
		drivetrain_mode = "brake"
	else:
		drivetrain_mode = "coast"
	if current_gear < 0 and absf(local_longitudinal_speed) > max_reverse_speed:
		filtered_reverse_throttle = 0.0
	if current_gear > 0 and local_longitudinal_speed > max_forward_speed:
		filtered_throttle = 0.0


func _update_forward_auto_shift(gear_count: int, delta: float) -> void:
	if shift_timer > 0.0:
		return
	var up_rpm := _gear_shift_up_rpm(current_gear)
	var down_rpm := float(tuning.get("shift_down_rpm", _engine_peak_rpm() * 0.58))
	var up_speed := _gear_upshift_speed(current_gear, gear_count)
	var down_speed := _gear_downshift_speed(current_gear - 1, gear_count)
	var wants_upshift := engine_rpm >= up_rpm or local_longitudinal_speed >= up_speed
	var wants_downshift := engine_rpm < down_rpm and local_longitudinal_speed < down_speed
	if throttle > 0.2 and wants_upshift and current_gear < gear_count:
		current_gear += 1
		shift_timer = float(tuning.get("shift_duration", 0.18))
	elif throttle < 0.35 and wants_downshift and current_gear > 1:
		current_gear -= 1
		shift_timer = float(tuning.get("shift_duration", 0.18))
	elif throttle > 0.65 and engine_rpm < down_rpm * 0.82 and current_gear > 1:
		current_gear -= 1
		shift_timer = float(tuning.get("shift_duration", 0.18))


func _drivetrain_force_for_wheel(axle: String, longitudinal_speed: float, mass: float) -> Dictionary:
	if axle != "rear":
		return {"drive_force": 0.0, "engine_brake_force": 0.0}
	var drive_share := 0.5
	var input_amount := filtered_reverse_throttle if current_gear < 0 else filtered_throttle
	var direction := -1.0 if current_gear < 0 else 1.0
	var speed_limit := float(tuning.get("max_reverse_speed", 18.0)) if current_gear < 0 else float(tuning.get("max_forward_speed", 86.0))
	var signed_speed := -local_longitudinal_speed if current_gear < 0 else local_longitudinal_speed
	var speed_scale := clampf((speed_limit - signed_speed) / maxf(speed_limit * 0.16, 1.0), 0.0, 1.0)
	var gear_ratio_scale := clampf(absf(_current_gear_ratio()) / 3.10, 0.45, 1.20)
	var base_accel := float(tuning.get("reverse_accel", 18.0)) if current_gear < 0 else float(tuning.get("engine_accel", 34.0))
	var drive_force := direction * base_accel * mass * input_amount * last_torque_curve * gear_ratio_scale * clutch_engagement * speed_scale * drive_share
	var engine_brake := 0.0
	if input_amount < 0.05 and absf(longitudinal_speed) > 0.8 and current_gear != 0:
		var brake_scale := clampf((engine_rpm - _engine_idle_rpm()) / maxf(_engine_redline_rpm() - _engine_idle_rpm(), 1.0), 0.0, 1.0)
		engine_brake = -signf(longitudinal_speed) * float(tuning.get("engine_brake_accel", 7.0)) * mass * brake_scale * clutch_engagement * drive_share
	last_engine_torque += absf(drive_force) * maxf(float(tuning.get("rear_wheel_radius", tuning.get("wheel_radius", 0.36))), 0.01) / maxf(absf(_current_gear_ratio()) * _final_drive_ratio(), 0.01)
	last_wheel_torque += absf(drive_force) * maxf(float(tuning.get("rear_wheel_radius", tuning.get("wheel_radius", 0.36))), 0.01)
	return {
		"drive_force": drive_force,
		"engine_brake_force": engine_brake,
	}


func _engine_torque_curve(rpm: float, idle: float, peak: float, redline: float) -> float:
	var clamped_rpm := clampf(rpm, idle, redline)
	if clamped_rpm <= peak:
		return clampf(lerpf(0.42, 1.0, (clamped_rpm - idle) / maxf(peak - idle, 1.0)), 0.35, 1.0)
	return clampf(lerpf(1.0, 0.68, (clamped_rpm - peak) / maxf(redline - peak, 1.0)), 0.55, 1.0)


func _gear_shift_up_rpm(gear: int) -> float:
	var ratios: Array = tuning.get("gear_ratios", [])
	var gear_count := _gear_count()
	if gear <= 0 or gear >= gear_count or gear >= ratios.size():
		return INF
	var current_ratio := maxf(absf(float(ratios[gear - 1])), 0.01)
	var next_ratio := maxf(absf(float(ratios[gear])), 0.01)
	var idle := _engine_idle_rpm()
	var peak := _engine_peak_rpm()
	var redline := _engine_redline_rpm()
	var end_rpm := maxf(idle, redline - float(tuning.get("shift_redline_margin_rpm", 200.0)))
	var rpm := clampf((idle + redline) * 0.5, idle, end_rpm)
	var step := maxf(float(tuning.get("shift_scan_step_rpm", 50.0)), 1.0)
	while rpm < end_rpm:
		var current_torque := _engine_torque_curve(rpm, idle, peak, redline)
		var next_rpm := rpm * next_ratio / current_ratio
		var next_wheel_torque := _engine_torque_curve(next_rpm, idle, peak, redline) * next_ratio / current_ratio
		if current_torque < next_wheel_torque:
			return rpm
		rpm += step
	return end_rpm


func _current_gear_ratio() -> float:
	if current_gear < 0:
		return float(tuning.get("reverse_gear_ratio", -3.10))
	var ratios: Array = tuning.get("gear_ratios", [])
	var index := clampi(current_gear - 1, 0, max(ratios.size() - 1, 0))
	if ratios.is_empty():
		return 1.0
	return float(ratios[index])


func _gear_speed_for_shift(gear: int) -> float:
	var ratios: Array = tuning.get("gear_ratios", [])
	if ratios.is_empty():
		return float(tuning.get("max_forward_speed", 86.0))
	var top_ratio := maxf(absf(float(ratios[ratios.size() - 1])), 0.01)
	var ratio := maxf(absf(float(ratios[clampi(gear - 1, 0, ratios.size() - 1)])), 0.01)
	return float(tuning.get("max_forward_speed", 86.0)) * top_ratio / ratio


func _gear_upshift_speed(gear: int, gear_count: int) -> float:
	if gear <= 0 or gear >= gear_count:
		return INF
	var max_speed := float(tuning.get("max_forward_speed", 86.0))
	var ratio_hint := _gear_speed_for_shift(gear) * float(tuning.get("shift_up_speed_scale", 0.82))
	var arcade_hint := max_speed * (float(gear) / float(maxi(gear_count, 1))) * 0.82
	return maxf(4.0, minf(ratio_hint, arcade_hint))


func _gear_downshift_speed(gear: int, gear_count: int) -> float:
	if gear <= 0 or gear >= gear_count:
		return 0.0
	var max_speed := float(tuning.get("max_forward_speed", 86.0))
	var ratio_hint := _gear_speed_for_shift(gear) * float(tuning.get("shift_down_speed_scale", 0.62))
	var arcade_hint := max_speed * (float(gear) / float(maxi(gear_count, 1))) * 0.62
	return maxf(2.0, minf(ratio_hint, arcade_hint))


func _gear_count() -> int:
	var ratios: Array = tuning.get("gear_ratios", [])
	var count := int(tuning.get("gear_count", ratios.size() if not ratios.is_empty() else 5))
	if not ratios.is_empty():
		count = mini(count, ratios.size())
	return clampi(count, 3, 7)


func _final_drive_ratio() -> float:
	return maxf(float(tuning.get("final_drive_ratio", 3.42)), 0.1)


func _engine_idle_rpm() -> float:
	return clampf(float(tuning.get("engine_idle_rpm", 850.0)), 500.0, 1600.0)


func _engine_peak_rpm() -> float:
	return clampf(float(tuning.get("engine_peak_rpm", 6500.0)), 1500.0, _engine_redline_rpm())


func _engine_redline_rpm() -> float:
	return clampf(float(tuning.get("engine_redline_rpm", 7600.0)), 3000.0, 14000.0)


func _resolve_combined_tire_forces(state: Dictionary, requested_longitudinal: float, requested_lateral: float, longitudinal_limit: float, lateral_limit: float, delta: float) -> Dictionary:
	var safe_longitudinal_limit := maxf(longitudinal_limit, 0.0)
	var safe_lateral_limit := maxf(lateral_limit, 0.0)
	if safe_longitudinal_limit <= 0.001 or safe_lateral_limit <= 0.001:
		return {
			"longitudinal_force": 0.0,
			"lateral_force": 0.0,
			"saturation": 0.0,
		}
	var longitudinal_force := clampf(requested_longitudinal, -safe_longitudinal_limit, safe_longitudinal_limit)
	var lateral_force := clampf(requested_lateral, -safe_lateral_limit, safe_lateral_limit)
	var saturation := sqrt(pow(longitudinal_force / safe_longitudinal_limit, 2.0) + pow(lateral_force / safe_lateral_limit, 2.0))
	if saturation > 1.0:
		var scale := 1.0 / saturation
		longitudinal_force *= scale
		lateral_force *= scale
		saturation = 1.0
	var response := float(tuning.get("tire_force_response", 16.0))
	var previous_longitudinal := float(state.get("longitudinal_force", 0.0))
	var previous_lateral := float(state.get("lateral_force", 0.0))
	longitudinal_force = move_toward(previous_longitudinal, longitudinal_force, safe_longitudinal_limit * response * delta)
	lateral_force = move_toward(previous_lateral, lateral_force, safe_lateral_limit * response * delta)
	saturation = sqrt(pow(longitudinal_force / safe_longitudinal_limit, 2.0) + pow(lateral_force / safe_lateral_limit, 2.0))
	if saturation > 1.0:
		var relaxed_scale := 1.0 / saturation
		longitudinal_force *= relaxed_scale
		lateral_force *= relaxed_scale
		saturation = 1.0
	return {
		"longitudinal_force": longitudinal_force,
		"lateral_force": lateral_force,
		"saturation": saturation,
	}


func _resolve_drag_force(forward: Vector3) -> Vector3:
	var speed := velocity.length()
	if speed <= 0.001:
		return Vector3.ZERO
	var linear_drag := float(tuning.get("linear_drag", 0.42))
	var aero_drag := _aero_drag()
	var drag_magnitude := speed * linear_drag * _mass() + speed * speed * aero_drag * _mass()
	last_drag_force = drag_magnitude
	last_aero_force = speed * speed * aero_drag * _mass()
	return -velocity.normalized() * drag_magnitude


func _update_wheel_contacts(body: Node3D, basis: Basis, delta: float) -> void:
	var world := get_world_3d()
	var mass := _mass()
	var gravity := float(tuning.get("gravity", 28.0))
	var rest_length := _suspension_value("runtime_rest_length", 0.45)
	var travel := _suspension_value("runtime_travel", 0.28)
	var spring_rate := _suspension_value("spring_rate", mass * 5.5)
	var damping := _suspension_value("damping", mass * 0.75)
	var full_droop := rest_length + travel
	for slot_id in WHEEL_ORDER:
		var state: Dictionary = wheel_states.get(slot_id, {})
		var slot: Dictionary = state.get("slot", {})
		var local_pos: Vector3 = slot.get("position_godot", Vector3.ZERO)
		var radius := float(slot.get("wheel_radius", tuning.get("wheel_radius", 0.36)))
		var mount := body.global_transform * local_pos
		var suspension_axis := basis.y.normalized()
		var from := mount + suspension_axis * travel
		var to := mount - suspension_axis * (full_droop + radius)
		var hit := {}
		if world != null:
			var query := PhysicsRayQueryParameters3D.create(from, to)
			hit = world.direct_space_state.intersect_ray(query)
		var previous_length := float(state.get("suspension_length", full_droop))
		if hit.is_empty():
			state["grounded"] = false
			state["compression"] = 0.0
			state["compression_length"] = 0.0
			state["compression_velocity"] = 0.0
			state["suspension_length"] = full_droop
			state["normal_force"] = 0.0
			state["spring_force"] = 0.0
			state["damper_force"] = 0.0
			state["suspension_force_vector"] = Vector3.ZERO
			state["contact_position"] = to
			state["contact_normal"] = Vector3.UP
		else:
			var hit_position: Vector3 = hit.get("position", to)
			var hit_normal: Vector3 = hit.get("normal", Vector3.UP)
			var distance := from.distance_to(hit_position)
			var suspension_length := clampf(distance - radius, 0.0, full_droop)
			var compression_length := clampf(full_droop - suspension_length, 0.0, travel)
			var compression := compression_length / maxf(travel, 0.01)
			var compression_velocity := (previous_length - suspension_length) / maxf(delta, 0.0001)
			var static_load := mass * gravity * 0.25
			var spring_force := compression * spring_rate
			var damper_force := clampf(compression_velocity * damping, -static_load * 0.65, static_load * 1.25)
			var normal_force := maxf(0.0, static_load + spring_force + damper_force)
			var normal := hit_normal.normalized() if hit_normal.length_squared() > 0.001 else Vector3.UP
			state["grounded"] = true
			state["compression"] = compression
			state["compression_length"] = compression_length
			state["compression_velocity"] = compression_velocity
			state["suspension_length"] = suspension_length
			state["normal_force"] = normal_force
			state["spring_force"] = spring_force
			state["damper_force"] = damper_force
			state["suspension_force_vector"] = normal * normal_force
			state["contact_position"] = hit_position
			state["contact_normal"] = normal
			state["surface"] = hit.get("collider", null)
		state["rest_length"] = rest_length
		state["travel"] = travel
		state["full_droop"] = full_droop
		state["wheel_radius"] = radius
		wheel_states[slot_id] = state


func _update_body_ground_pose(body: Node3D, delta: float) -> void:
	var grounded_positions: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var radius_total := 0.0
	var radius_count := 0
	for slot_id in WHEEL_ORDER:
		var state: Dictionary = wheel_states.get(slot_id, {})
		if not bool(state.get("grounded", false)):
			continue
		grounded_positions.append(state.get("contact_position", body.global_position))
		normals.append(state.get("contact_normal", Vector3.UP))
		radius_total += float(state.get("wheel_radius", tuning.get("wheel_radius", 0.36)))
		radius_count += 1
	if grounded_positions.is_empty():
		return
	var average_y := 0.0
	var average_normal := Vector3.ZERO
	for p in grounded_positions:
		average_y += p.y
	for n in normals:
		average_normal += n
	average_y /= float(grounded_positions.size())
	average_normal = average_normal.normalized() if average_normal.length_squared() > 0.001 else Vector3.UP
	var minimum_y := average_y + maxf(radius_total / maxf(float(radius_count), 1.0), 0.2)
	if body.global_position.y < minimum_y:
		body.global_position.y = lerpf(body.global_position.y, minimum_y, clampf(delta * 16.0, 0.0, 1.0))
	_align_to_ground_normal(body, average_normal, delta)
	if body.global_position.y <= minimum_y + 0.01 and velocity.y < 0.0:
		velocity.y = 0.0


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
	angular_velocity = up * yaw_rate
	if absf(yaw_rate) > 0.0001:
		body.global_transform.basis = Basis(up, yaw_rate * delta) * body.global_transform.basis

	body.global_position += velocity * delta
	_update_wheel_contacts(body, body.global_transform.basis.orthonormalized(), delta)
	_update_body_ground_pose(body, delta)

	basis = body.global_transform.basis.orthonormalized()
	forward = -basis.z.normalized()
	right = basis.x.normalized()
	local_longitudinal_speed = velocity.dot(forward)
	local_lateral_speed = velocity.dot(right)
	slip = absf(local_lateral_speed) / maxf(absf(local_longitudinal_speed), 1.0)


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
	_update_ackermann_steering()
	var max_steer := float(tuning.get("max_steer_angle", 0.62))
	wheel_angular_speed = local_longitudinal_speed / maxf(float(tuning.get("wheel_radius", 0.36)), 0.01)
	steering_angle = steer * max_steer
	for spin_pivot in _spin_pivots:
		if spin_pivot == null or not is_instance_valid(spin_pivot):
			continue
		var slot_id := String(spin_pivot.get_meta("eagl_wheel_slot_id", ""))
		var state: Dictionary = wheel_states.get(slot_id, {})
		var spin_direction := float(spin_pivot.get_meta("eagl_spin_direction", 1.0))
		var visual_angular_speed := float(state.get("angular_speed", wheel_angular_speed))
		if absf(visual_angular_speed) <= 0.0001:
			visual_angular_speed = wheel_angular_speed
		spin_pivot.rotation.x += visual_angular_speed * spin_direction * delta
		spin_pivot.position.y = -float(state.get("compression", 0.0)) * float(state.get("travel", 0.0)) * 0.25
	for steer_pivot in _steer_pivots:
		if steer_pivot == null or not is_instance_valid(steer_pivot):
			continue
		var slot_id := String(steer_pivot.get_meta("eagl_wheel_slot_id", ""))
		var state: Dictionary = wheel_states.get(slot_id, {})
		var angle := float(state.get("steering_angle", steering_angle))
		steer_pivot.rotation.y = angle
		steer_pivot.set_meta("eagl_visual_steer", steer)
		steer_pivot.set_meta("eagl_visual_steering_angle", angle)


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


func _init_wheel_states() -> void:
	wheel_states.clear()
	for slot in _wheel_slots():
		var slot_dict: Dictionary = slot
		var slot_id := String(slot_dict.get("slot_id", ""))
		if slot_id == "":
			continue
		wheel_states[slot_id] = {
			"slot": slot_dict.duplicate(true),
			"grounded": false,
			"compression": 0.0,
			"normal_force": 0.0,
			"longitudinal_force": 0.0,
			"lateral_force": 0.0,
			"slip_ratio": 0.0,
			"slip_angle": 0.0,
			"combined_tire_saturation": 0.0,
			"angular_speed": 0.0,
			"steering_angle": 0.0,
			"skidding": false,
		}
	_update_ackermann_steering()


func _wheel_slots() -> Array:
	var slots: Array = handling_data.get("wheel_slots", [])
	if slots.is_empty():
		slots = handling_data.get("globalb_row", {}).get("wheel_slots", [])
	if slots.is_empty():
		return []
	return slots


func _update_ackermann_steering() -> void:
	var dimensions: Dictionary = handling_data.get("vehicle_dimensions", {})
	var wheelbase := _field_value(dimensions.get("wheelbase", {}), _fallback_wheelbase())
	var front_track := _field_value(dimensions.get("front_track", {}), _fallback_track())
	var max_steer := float(tuning.get("max_steer_angle", 0.62))
	var requested := steer * max_steer
	for slot_id in WHEEL_ORDER:
		var state: Dictionary = wheel_states.get(slot_id, {})
		if not FRONT_WHEELS.has(slot_id):
			state["steering_angle"] = 0.0
			wheel_states[slot_id] = state
			continue
		if absf(requested) < 0.0001:
			state["steering_angle"] = 0.0
			wheel_states[slot_id] = state
			continue
		var turn_radius := wheelbase / tan(absf(requested))
		var inner := atan(wheelbase / maxf(turn_radius - front_track * 0.5, 0.1))
		var outer := atan(wheelbase / (turn_radius + front_track * 0.5))
		var turning_left: bool = requested > 0.0
		var is_left: bool = slot_id.ends_with("L")
		var magnitude := inner if is_left == turning_left else outer
		state["steering_angle"] = signf(requested) * magnitude
		state["ackermann_inner"] = is_left == turning_left
		wheel_states[slot_id] = state


func _fallback_wheelbase() -> float:
	var fl := _slot_position("FL")
	var rl := _slot_position("RL")
	if fl != Vector3.ZERO or rl != Vector3.ZERO:
		return maxf(absf(fl.z - rl.z), 1.0)
	return 2.65


func _fallback_track() -> float:
	var fl := _slot_position("FL")
	var fr := _slot_position("FR")
	if fl != Vector3.ZERO or fr != Vector3.ZERO:
		return maxf(absf(fl.x - fr.x), 1.0)
	return 1.55


func _slot_position(slot_id: String) -> Vector3:
	for slot in _wheel_slots():
		var dict: Dictionary = slot
		if String(dict.get("slot_id", "")) == slot_id:
			return dict.get("position_godot", Vector3.ZERO)
	return Vector3.ZERO


func _movement_mode() -> String:
	if not grounded:
		return "airborne"
	if drivetrain_mode == "reverse":
		return "reverse"
	if drivetrain_mode == "shift":
		return "shift"
	if throttle > 0.0:
		return "drive"
	if brake > 0.0 and local_longitudinal_speed > 1.0:
		return "brake"
	if brake > 0.0:
		return "reverse"
	if handbrake:
		return "handbrake"
	return "coast"


func _mass() -> float:
	return maxf(float(tuning.get("mass", 1200.0)), 1.0)


func _yaw_inertia(mass: float) -> float:
	var dimensions: Dictionary = handling_data.get("vehicle_dimensions", {})
	var wheelbase := _field_value(dimensions.get("wheelbase", {}), _fallback_wheelbase())
	var track := _field_value(dimensions.get("front_track", {}), _fallback_track())
	return mass * (wheelbase * wheelbase + track * track) / 12.0


func _aero_drag() -> float:
	var aero: Dictionary = tuning.get("aero", {})
	var field: Dictionary = aero.get("aero_drag", {})
	return maxf(_field_value(field, float(tuning.get("linear_drag", 0.42)) / 900.0), 0.00001)


func _suspension_value(name: String, fallback: float) -> float:
	var suspension: Dictionary = tuning.get("suspension", {})
	var field: Dictionary = suspension.get(name, {})
	return _field_value(field, fallback)


func _field_value(field, fallback: float) -> float:
	if field is Dictionary:
		return float((field as Dictionary).get("value", fallback))
	return fallback


func debug_state() -> Dictionary:
	_update_ackermann_steering()
	var next_shift_rpm := _gear_shift_up_rpm(current_gear)
	if not is_finite(next_shift_rpm):
		next_shift_rpm = 0.0
	return {
		"speed_mps": velocity.length(),
		"speed_kmh": velocity.length() * 3.6,
		"longitudinal_speed": local_longitudinal_speed,
		"lateral_speed": local_lateral_speed,
		"yaw_rate": yaw_rate,
		"steer": steer,
		"steering_angle": steering_angle,
		"throttle": throttle,
		"filtered_throttle": filtered_throttle,
		"brake": brake,
		"filtered_reverse_throttle": filtered_reverse_throttle,
		"handbrake": handbrake,
		"engine_rpm": engine_rpm,
		"engine_idle_rpm": _engine_idle_rpm(),
		"engine_peak_rpm": _engine_peak_rpm(),
		"engine_redline_rpm": _engine_redline_rpm(),
		"gear": current_gear,
		"gear_label": "R" if current_gear < 0 else str(current_gear),
		"gear_count": _gear_count(),
		"gear_ratio": last_gear_ratio,
		"final_drive_ratio": _final_drive_ratio(),
		"shift_up_rpm": next_shift_rpm,
		"shift_up_speed": _gear_upshift_speed(current_gear, _gear_count()),
		"shift_down_speed": _gear_downshift_speed(current_gear - 1, _gear_count()),
		"clutch_engagement": clutch_engagement,
		"shift_timer": shift_timer,
		"drivetrain_mode": drivetrain_mode,
		"torque_curve": last_torque_curve,
		"engine_torque": last_engine_torque,
		"wheel_torque": last_wheel_torque,
		"engine_brake_force": last_engine_brake_force,
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
		"normal_force": last_normal_force,
		"aero_force": last_aero_force,
		"rolling_force": last_rolling_force,
		"suspension_force": last_suspension_force,
		"debug_free_drive": debug_free_drive,
		"debug_free_drive_boost": _free_drive_boost,
		"debug_free_drive_input": _free_drive_input,
		"handling_source": handling_data.get("handling_source", tuning.get("source", "unknown")),
		"exact_handling_status": handling_data.get("exact_handling_status", tuning.get("exact_handling_status", "unknown")),
		"decoded_car_id": handling_data.get("car_id", tuning.get("car_id", "")),
		"tuning_source": tuning.get("source", "unknown"),
		"tuning_status": tuning.get("status", "unknown"),
		"globalb_row_index": handling_data.get("globalb_row_index", tuning.get("globalb_row_index", -1)),
		"wheel_states": wheel_states.duplicate(true),
		"ackermann": {
			"FL": wheel_states.get("FL", {}).get("steering_angle", 0.0),
			"FR": wheel_states.get("FR", {}).get("steering_angle", 0.0),
			"RL": wheel_states.get("RL", {}).get("steering_angle", 0.0),
			"RR": wheel_states.get("RR", {}).get("steering_angle", 0.0),
		},
	}
