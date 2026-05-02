class_name EAGLCar
extends RigidBody3D

const CarConfigScript = preload("res://eagl/handling/car_config.gd")
const VehicleBodyConfigAdapter = preload("res://eagl/handling/vehicle_body_config_adapter.gd")
const MathUtils = preload("res://eagl/utils/math_utils.gd")

const SLOT_IDS := ["FL", "FR", "RL", "RR"]
const VEHICLE_FORWARD := Vector3(0.0, 0.0, 1.0)
const SUBSTEP_TARGET_DT := 0.0044
const GRAVITY_MPS2 := 9.8
const SUSPENSION_DENOM_EPSILON := 0.05
const DEBUG_WHEEL_PHYSICS_SEGMENTS := 20
const REST_SETTLE_LINEAR_SPEED := 0.12
const REST_SETTLE_ANGULAR_SPEED := 0.12
const REST_SETTLE_TRAVEL_SPEED := 0.02
const REST_SETTLE_LINEAR_DAMP := 4.0
const REST_SETTLE_ANGULAR_DAMP := 6.0
const REST_FREEZE_LINEAR_SPEED := 0.03
const REST_FREEZE_ANGULAR_SPEED := 0.03
const GROUNDED_HEAVE_DAMPING := 5.5
const GROUNDED_PITCH_DAMPING := 850.0
const GROUNDED_ROLL_DAMPING := 850.0

@export var config = null
@export var draw_debug := true
@export var auto_fit_collision_from_visual := true
@export var drive_area_surface_filter_enabled := true
@export_range(0.0, 1.0) var drive_area_off_surface_friction_scale := 0.25
@export var overtravel_force_scale := 1.0

var current_gear := 1
var engine_rpm := 900.0
var signed_slip_angle := 0.0
var surface_sampler = null
var wheels: Array = []

var _throttle_input := 0.0
var _brake_input := 0.0
var _steering_input := 0.0
var _handbrake_input := 0.0
var _steering_state := 0.0
var _steering_engaged := false
var _debug_snapshot := {}
var _vehicle_setup := {}
var _last_drag_force := Vector3.ZERO
var _reverse_hold_time := 0.0
var _reverse_ready := false
var _shift_lock_time := 0.0
var _shift_cut_time := 0.0
var _wheel_by_slot: Dictionary = {}
var _wheel_pivots: Dictionary = {}
var _wheel_visuals: Dictionary = {}
var _wheel_roll_visuals: Dictionary = {}
var _wheel_suspension_nodes: Dictionary = {}
var _wheel_spin_angles: Dictionary = {}
var _wheel_visual_radii: Dictionary = {}
var _visual_wheel_slots: Dictionary = {}

var _visual_root: Node3D
var _debug_mesh := ImmediateMesh.new()
var _debug_mesh_instance: MeshInstance3D
var _debug_material: StandardMaterial3D


func _ready() -> void:
	if config == null:
		config = CarConfigScript.new()
	_visual_root = get_node_or_null("VisualRoot") as Node3D
	if _visual_root != null:
		_visual_root.transform = Transform3D(VehicleBodyConfigAdapter.visual_anchor_basis(), Vector3.ZERO)
	custom_integrator = true
	gravity_scale = 0.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 8
	apply_config(config)
	set_debug_overlay_enabled(draw_debug)


func _physics_process(_delta: float) -> void:
	_update_inputs()


func _process(delta: float) -> void:
	_update_visuals(delta)
	if draw_debug:
		_rebuild_debug_mesh()
	_update_debug_snapshot()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if config == null or wheels.is_empty():
		return
	var step := maxf(state.step, 0.0001)
	var substeps := int(floor(step / SUBSTEP_TARGET_DT)) + 1
	var sub_dt := step / float(substeps)
	for _index in range(substeps):
		_step_vehicle(state, sub_dt)


func apply_config(new_config) -> void:
	if new_config == null:
		return
	config = new_config
	_vehicle_setup = VehicleBodyConfigAdapter.build_vehicle_setup(config)
	mass = float(_vehicle_setup.get("mass", config.mass_kg))
	center_of_mass = _vehicle_setup.get("center_of_mass", Vector3.ZERO)
	wheels = config.build_wheel_states()
	_rebuild_wheel_slot_map()
	_fit_chassis_collision_shape()
	_sync_scene_component_nodes_from_wheels()
	refresh_visual_bindings()
	_reset_runtime_values()
	_prime_wheels_from_current_transform()
	_update_debug_snapshot()


func reset_runtime_state(target_transform: Transform3D = transform) -> void:
	transform = target_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	sleeping = false
	_reset_runtime_values()
	_prime_wheels_from_current_transform()
	_update_visuals(0.0)
	_update_debug_snapshot()
	if draw_debug:
		_rebuild_debug_mesh()


func refresh_visual_bindings() -> void:
	_wheel_visuals.clear()
	_wheel_roll_visuals.clear()
	_wheel_suspension_nodes.clear()
	_wheel_pivots.clear()
	_wheel_visual_radii.clear()
	_visual_wheel_slots.clear()
	if _visual_root == null:
		return
	var car_visual := _visual_root.get_node_or_null("CarVisual") as Node3D
	if car_visual == null:
		return
	_cache_visual_wheel_slots(car_visual)
	for slot_id in SLOT_IDS:
		var pivot_node := car_visual.get_node_or_null("WheelPivots/%s" % slot_id) as Node3D
		if pivot_node != null:
			_wheel_pivots[slot_id] = pivot_node
		var suspension_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension" % slot_id) as Node3D
		if suspension_node != null:
			_wheel_suspension_nodes[slot_id] = suspension_node
		var steer_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer" % slot_id) as Node3D
		if steer_node != null:
			_wheel_visuals[slot_id] = steer_node
		var roll_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll/Spin" % slot_id) as Node3D
		if roll_node == null:
			roll_node = car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll" % slot_id) as Node3D
		if roll_node != null:
			_wheel_roll_visuals[slot_id] = roll_node
			_wheel_visual_radii[slot_id] = _visual_radius_from_node(roll_node)
	if auto_fit_collision_from_visual:
		_fit_collision_shape_to_visual_bounds()


func set_debug_overlay_enabled(enabled: bool) -> void:
	draw_debug = enabled
	if draw_debug:
		_ensure_debug_mesh()
		if _debug_mesh_instance != null:
			_debug_mesh_instance.visible = true
			_rebuild_debug_mesh()
	elif _debug_mesh_instance != null:
		_debug_mesh.clear_surfaces()
		_debug_mesh_instance.visible = false


func get_debug_snapshot() -> Dictionary:
	return _debug_snapshot.duplicate(true)


func replace_visual(visual: Node3D) -> void:
	if _visual_root == null:
		return
	var existing := _visual_root.get_node_or_null("CarVisual") as Node3D
	if existing == null:
		push_warning("Car.tscn is missing VisualRoot/CarVisual; cannot bind visual content.")
		return
	_clear_scene_visual_content(existing)
	if visual == null:
		refresh_visual_bindings()
		return
	if visual.get_parent() != null:
		visual.get_parent().remove_child(visual)
	_merge_visual_content_into_scene(visual, existing)
	visual.queue_free()
	refresh_visual_bindings()


func sync_wheel_slots_from_visual() -> void:
	_update_visuals(0.0)
	_update_debug_snapshot()


func set_surface_sampler(sampler) -> void:
	surface_sampler = sampler


func _sync_scene_component_nodes_from_wheels() -> void:
	var car_visual: Node3D = null
	if _visual_root != null:
		car_visual = _visual_root.get_node_or_null("CarVisual") as Node3D
	if car_visual == null:
		return
	var body_root := car_visual.get_node_or_null("Body") as Node3D
	if body_root != null:
		body_root.position = Vector3.ZERO
	var dummies_root := car_visual.get_node_or_null("Dummies") as Node3D
	for wheel in wheels:
		var visual_position := _ps2_to_godot(wheel.pivot_local_position_ps2)
		var pivot_node := car_visual.get_node_or_null("WheelPivots/%s" % wheel.slot_id) as Node3D
		if pivot_node != null:
			pivot_node.position = visual_position
		var dummy_node: Node3D = null
		if dummies_root != null:
			dummy_node = dummies_root.get_node_or_null("%s_PIVOT" % wheel.slot_id) as Node3D
		if dummy_node != null:
			dummy_node.position = visual_position
	var center_dummy: Node3D = null
	if dummies_root != null:
		center_dummy = dummies_root.get_node_or_null("BODY_CENTER") as Node3D
	if center_dummy != null:
		center_dummy.position = Vector3.ZERO


func _clear_scene_visual_content(car_visual: Node3D) -> void:
	for child in car_visual.get_children():
		if String(child.name) in ["Body", "WheelPivots", "Dummies"]:
			continue
		_remove_child_now(car_visual, child)
	var body_root := car_visual.get_node_or_null("Body") as Node3D
	if body_root != null:
		_remove_all_children(body_root)
	var wheel_pivots := car_visual.get_node_or_null("WheelPivots") as Node3D
	if wheel_pivots != null:
		for child in wheel_pivots.get_children():
			if not (String(child.name) in SLOT_IDS):
				_remove_child_now(wheel_pivots, child)
		for slot_id in SLOT_IDS:
			_clear_wheel_visual_content(wheel_pivots.get_node_or_null(slot_id) as Node3D)
	var dummies_root := car_visual.get_node_or_null("Dummies") as Node3D
	if dummies_root != null:
		var expected_dummies := ["BODY_CENTER"]
		for slot_id in SLOT_IDS:
			expected_dummies.append("%s_PIVOT" % slot_id)
		for child in dummies_root.get_children():
			if not (String(child.name) in expected_dummies):
				_remove_child_now(dummies_root, child)


func _clear_wheel_visual_content(wheel_root: Node3D) -> void:
	if wheel_root == null:
		return
	for child in wheel_root.get_children():
		if String(child.name) != "Suspension":
			_remove_child_now(wheel_root, child)
	var suspension := wheel_root.get_node_or_null("Suspension") as Node3D
	if suspension == null:
		return
	for child in suspension.get_children():
		if String(child.name) != "Steer":
			_remove_child_now(suspension, child)
	var steer := suspension.get_node_or_null("Steer") as Node3D
	if steer == null:
		return
	for child in steer.get_children():
		if String(child.name) != "Roll":
			_remove_child_now(steer, child)
	var roll := steer.get_node_or_null("Roll") as Node3D
	if roll == null:
		return
	for child in roll.get_children():
		if String(child.name) != "Spin":
			_remove_child_now(roll, child)
	var spin := roll.get_node_or_null("Spin") as Node3D
	if spin != null:
		_remove_all_children(spin)


func _merge_visual_content_into_scene(source: Node3D, destination: Node3D) -> void:
	_copy_node_state(source, destination)
	for child in source.get_children():
		var target_child := destination.get_node_or_null(NodePath(String(child.name))) as Node3D
		if child is Node3D and not (child is MeshInstance3D) and target_child != null:
			_merge_visual_content_into_scene(child as Node3D, target_child)
			continue
		source.remove_child(child)
		destination.add_child(child)


func _copy_node_state(source: Node3D, destination: Node3D) -> void:
	destination.transform = source.transform
	for meta_name in source.get_meta_list():
		destination.set_meta(String(meta_name), source.get_meta(String(meta_name)))


func _remove_all_children(parent: Node) -> void:
	for child in parent.get_children():
		_remove_child_now(parent, child)


func _remove_child_now(parent: Node, child: Node) -> void:
	parent.remove_child(child)
	child.queue_free()


func _step_vehicle(state: PhysicsDirectBodyState3D, sub_dt: float) -> void:
	var body_transform := state.transform
	var body_origin_ps2 := _godot_to_ps2(body_transform.origin)
	var body_up_ps2 := _basis_axis_ps2(body_transform.basis, Vector3(0.0, 0.0, 1.0))
	var body_forward_ps2 := _basis_axis_ps2(body_transform.basis, Vector3(1.0, 0.0, 0.0))
	var body_right_ps2 := _basis_axis_ps2(body_transform.basis, Vector3(0.0, 1.0, 0.0))
	var flat_velocity_ps2 := _horizontal_ps2(_godot_to_ps2(state.linear_velocity))
	var speed_mps := flat_velocity_ps2.length()

	state.apply_impulse(Vector3.DOWN * mass * GRAVITY_MPS2 * sub_dt)
	_update_motion_state_for_state(state, body_forward_ps2, body_up_ps2, flat_velocity_ps2, speed_mps, sub_dt)
	_step_suspension(state, body_transform, body_up_ps2, sub_dt)
	_update_engine_state(speed_mps, sub_dt)
	_apply_wheel_contact_forces(state, body_transform, body_up_ps2, speed_mps, sub_dt)
	_apply_impulse_ps2(state, _drag_force_ps2(flat_velocity_ps2, speed_mps) * sub_dt, body_origin_ps2)
	_apply_grounded_chassis_damping(state, body_origin_ps2, body_up_ps2, body_forward_ps2, body_right_ps2, sub_dt)
	_apply_torque_impulse_ps2(state, _yaw_assist_torque_ps2(body_up_ps2, state, speed_mps) * sub_dt)
	_apply_rest_settle(state, sub_dt)
	_last_drag_force = _ps2_to_godot(_drag_force_ps2(flat_velocity_ps2, speed_mps))


func _step_suspension(state: PhysicsDirectBodyState3D, body_transform: Transform3D, body_up_ps2: Vector3, sub_dt: float) -> void:
	for wheel in wheels:
		_step_suspension_for_wheel(state, wheel, body_transform, body_up_ps2, sub_dt)


func _step_suspension_for_wheel(
	state: PhysicsDirectBodyState3D,
	wheel,
	body_transform: Transform3D,
	body_up_ps2: Vector3,
	sub_dt: float
) -> void:
	var sample_world_ps2 := _transform_point_ps2(body_transform, wheel.local_position_ps2)
	var pivot_world_ps2 := _transform_point_ps2(body_transform, wheel.pivot_local_position_ps2)
	var length_min := minf(wheel.min_travel, wheel.max_travel)
	var length_max := maxf(wheel.min_travel, wheel.max_travel)
	var travel_range := maxf(length_max - length_min, 0.0001)
	var previous_length := clampf(wheel.previous_length, length_min, length_max)

	wheel.world_pivot_ps2 = pivot_world_ps2
	wheel.world_attachment_ps2 = sample_world_ps2
	wheel.prev_compression = wheel.compression
	wheel.grounded = false
	wheel.material_id = -1
	wheel.normal_ps2 = body_up_ps2
	wheel.contact_point_ps2 = sample_world_ps2
	wheel.world_wheel_center_ps2 = sample_world_ps2 + body_up_ps2 * previous_length
	wheel.raw_length = previous_length
	wheel.suspension_distance = previous_length
	wheel.center_offset = previous_length
	wheel.overtravel = 0.0
	wheel.over_limit = 0.0
	wheel.spring_force = 0.0
	wheel.damper_force = 0.0
	wheel.suspension_force = 0.0
	wheel.normal_load = 0.0
	wheel.load_ratio = 0.0
	wheel.force_long = 0.0
	wheel.force_lat = 0.0
	wheel.slip_long = 0.0
	wheel.slip_lat = 0.0
	wheel.grip_utilization = 0.0

	var local_pivot := _vehicle_from_local_ps2(wheel.pivot_local_position_ps2)
	var wheel_velocity_ps2 := _godot_to_ps2(state.get_velocity_at_local_position(local_pivot))
	var wheel_heading_ps2 := _wheel_heading_ps2(body_transform.basis, body_up_ps2, wheel)
	var wheel_right_ps2 := body_up_ps2.cross(wheel_heading_ps2).normalized()
	wheel.forward_speed = wheel_velocity_ps2.dot(wheel_heading_ps2)
	wheel.lateral_speed = wheel_velocity_ps2.dot(wheel_right_ps2)

	if surface_sampler == null:
		_set_airborne_wheel_length(wheel, previous_length)
		return

	var surface: Dictionary = surface_sampler.sample_surface(sample_world_ps2)
	if surface.is_empty():
		_set_airborne_wheel_length(wheel, previous_length)
		return

	var surface_normal: Vector3 = surface.get("normal", body_up_ps2)
	var surface_point: Vector3 = surface.get("point", sample_world_ps2)
	var denom := surface_normal.dot(body_up_ps2)
	if denom <= SUSPENSION_DENOM_EPSILON:
		_set_airborne_wheel_length(wheel, previous_length)
		return

	var plane_t: float = surface_normal.dot(surface_point - sample_world_ps2) / denom
	var raw_length: float = plane_t + float(wheel.wheel_radius)
	var clamped_length: float = clampf(raw_length, length_min, length_max)
	var travel_velocity: float = (clamped_length - previous_length) / maxf(sub_dt, 0.0001)

	wheel.raw_length = raw_length
	wheel.suspension_distance = raw_length
	wheel.current_length = clamped_length
	wheel.previous_length = clamped_length
	wheel.travel_velocity = travel_velocity
	wheel.compression_velocity = travel_velocity
	wheel.center_offset = clamped_length
	wheel.compression = clampf((clamped_length - length_min) / travel_range, 0.0, 1.0)
	wheel.over_limit = maxf(raw_length - length_max, 0.0)
	wheel.overtravel = wheel.over_limit
	wheel.grounded = raw_length >= length_min
	wheel.material_id = int(surface.get("material_id", -1))
	wheel.normal_ps2 = surface_normal
	wheel.contact_point_ps2 = sample_world_ps2 + body_up_ps2 * plane_t
	wheel.world_wheel_center_ps2 = sample_world_ps2 + body_up_ps2 * clamped_length

	if not wheel.grounded:
		wheel.spring_force = 0.0
		wheel.damper_force = 0.0
		wheel.suspension_force = 0.0
		wheel.normal_load = 0.0
		return

	var spring_progress: float = maxf(clamped_length, 0.0)
	var spring_force: float = clamped_length * float(wheel.spring_coefficient) * (1.0 + float(wheel.progressive_spring_scale) * spring_progress)
	var damping: float = float(wheel.bump_damping) if travel_velocity > 0.0 else float(wheel.rebound_damping)
	var damper_force: float = damping * travel_velocity
	var anti_roll_force := 0.0
	var pair = _paired_axle_wheel(wheel)
	if pair != null:
		anti_roll_force = wheel.anti_roll_coefficient * (clamped_length - pair.current_length)
	var reference_force: float = float(wheel.bump_stop_coefficient) * (clamped_length - float(wheel.reference_length))
	var overtravel_force: float = float(wheel.bump_stop_coefficient) * float(wheel.over_limit) * overtravel_force_scale
	var force: float = float(wheel.preload_force) + spring_force + damper_force + anti_roll_force + reference_force + overtravel_force
	wheel.spring_force = spring_force
	wheel.damper_force = damper_force
	wheel.suspension_force = maxf(force, 0.0)
	wheel.normal_load = wheel.suspension_force
	wheel.load_ratio = wheel.suspension_force / maxf(wheel.preload_force, 1.0)
	_apply_impulse_ps2(state, body_up_ps2 * wheel.suspension_force * sub_dt, pivot_world_ps2)


func _set_airborne_wheel_length(wheel, previous_length: float) -> void:
	wheel.current_length = previous_length
	wheel.previous_length = previous_length
	wheel.travel_velocity = 0.0
	wheel.compression_velocity = 0.0
	wheel.compression = 0.0
	wheel.spring_force = 0.0
	wheel.damper_force = 0.0
	wheel.suspension_force = 0.0
	wheel.normal_load = 0.0
	wheel.grounded = false


func _apply_wheel_contact_forces(
	state: PhysicsDirectBodyState3D,
	body_transform: Transform3D,
	body_up_ps2: Vector3,
	speed_mps: float,
	sub_dt: float
) -> void:
	var drive_force_total := _drive_force_total(speed_mps)
	var brake_totals := _brake_force_totals(speed_mps)
	var slip_reduction := _slip_grip_reduction()
	for wheel in wheels:
		var drive_bias: float = config.drive_bias_for_slot(wheel.slot_id)
		wheel.drive_force = drive_force_total * drive_bias
		wheel.brake_force = _brake_force_for_wheel(wheel, brake_totals)
		wheel.steer_angle = _steering_state if wheel.is_front() else 0.0
		if not wheel.grounded or wheel.suspension_force <= 0.0:
			_update_airborne_wheel_spin(wheel, sub_dt)
			continue
		if drive_area_surface_filter_enabled and surface_sampler != null and not surface_sampler.has_driveable_surface(wheel.world_attachment_ps2):
			wheel.drive_force = 0.0
			wheel.brake_force *= drive_area_off_surface_friction_scale

		var normal_ps2: Vector3 = wheel.normal_ps2.normalized()
		var heading_ps2 := _wheel_heading_ps2(body_transform.basis, body_up_ps2, wheel)
		heading_ps2 = (heading_ps2 - normal_ps2 * heading_ps2.dot(normal_ps2)).normalized()
		if heading_ps2.length_squared() <= 0.0001:
			heading_ps2 = _basis_axis_ps2(body_transform.basis, Vector3(1.0, 0.0, 0.0))
		var right_ps2 := normal_ps2.cross(heading_ps2).normalized()
		var contact_global := _ps2_to_godot(wheel.contact_point_ps2)
		var contact_local := body_transform.affine_inverse() * contact_global
		var contact_velocity_ps2 := _godot_to_ps2(state.get_velocity_at_local_position(contact_local))
		var v_long := contact_velocity_ps2.dot(heading_ps2)
		var v_lat := contact_velocity_ps2.dot(right_ps2)
		wheel.forward_speed = v_long
		wheel.lateral_speed = v_lat

		var brake_direction := signf(v_long)
		if brake_direction == 0.0:
			brake_direction = signf(wheel.angular_speed)
		var requested_long: float = float(wheel.drive_force) - float(wheel.brake_force) * brake_direction
		var requested_lat: float = -v_lat * float(wheel.lateral_grip) * mass * 0.25 / maxf(sub_dt, 0.0001)
		var max_long: float = maxf(float(wheel.suspension_force) * float(wheel.longitudinal_grip), 0.0001)
		var max_lat: float = maxf(float(wheel.suspension_force) * float(wheel.lateral_grip) * slip_reduction, 0.0001)
		var nx: float = requested_long / max_long
		var ny: float = requested_lat / max_lat
		var combined := sqrt(nx * nx + ny * ny)
		var force_scale := minf(1.0, 1.0 / maxf(combined, 0.0001))
		wheel.force_long = nx * force_scale * max_long
		wheel.force_lat = ny * force_scale * max_lat
		wheel.slip_long = requested_long
		wheel.slip_lat = requested_lat
		wheel.grip_utilization = clampf(combined, 0.0, 1.0)

		var tire_force_ps2: Vector3 = heading_ps2 * float(wheel.force_long) + right_ps2 * float(wheel.force_lat)
		_apply_impulse_ps2(state, tire_force_ps2 * sub_dt, wheel.contact_point_ps2)
		_update_grounded_wheel_spin(wheel, v_long, sub_dt)


func _drive_force_total(speed_mps: float) -> float:
	var throttle_command := _hp2_throttle_command(speed_mps)
	var reverse_command := 0.0
	if current_gear < 0:
		reverse_command = _brake_input
		throttle_command = 0.0
	var drive_input := throttle_command - reverse_command
	var drive_force_total := _godot_engine_force_total(speed_mps, engine_rpm, current_gear) * drive_input
	drive_force_total *= _shift_cut_scale()
	if current_gear >= 0 and throttle_command <= 0.02 and reverse_command <= 0.0 and _brake_input <= 0.05:
		drive_force_total -= _engine_braking_force_total(speed_mps, engine_rpm, current_gear)
	return drive_force_total


func _brake_force_totals(speed_mps: float) -> Dictionary:
	var brake_alpha := clampf(_brake_input, 0.0, 1.0) if current_gear >= 0 else 0.0
	var lock_entry := float(_vehicle_setup.get("brake_lock_entry", 0.78))
	var rear_lock_alpha := clampf((brake_alpha - lock_entry) / maxf(1.0 - lock_entry, 0.001), 0.0, 1.0)
	var brake_speed_scale := clampf((speed_mps * 3.6) / 40.0, 0.32, 1.0)
	var service_total := maxf(config.brake_force, 0.0) * brake_alpha * brake_speed_scale
	return {
		"front": service_total * 0.58,
		"rear": service_total * 0.18 + service_total * 0.24 * rear_lock_alpha,
		"handbrake": maxf(config.handbrake_force, 0.0) * clampf(_handbrake_input, 0.0, 1.0),
	}


func _brake_force_for_wheel(wheel, brake_totals: Dictionary) -> float:
	if current_gear < 0 and _brake_input > 0.0:
		return 0.0
	if wheel.is_front():
		return float(brake_totals.get("front", 0.0)) * 0.5
	return float(brake_totals.get("rear", 0.0)) * 0.5 + float(brake_totals.get("handbrake", 0.0)) * 0.5


func _update_grounded_wheel_spin(wheel, longitudinal_velocity: float, sub_dt: float) -> void:
	var target := longitudinal_velocity / maxf(wheel.wheel_radius, 0.0001)
	if wheel.brake_force > 0.0:
		target = lerpf(target, 0.0, clampf(wheel.brake_force / maxf(config.brake_force * 0.5, 1.0), 0.0, 0.9))
	if absf(wheel.drive_force) > 0.0 and wheel.grip_utilization > 0.98:
		target += wheel.drive_force * 0.002
	wheel.angular_speed = lerpf(wheel.angular_speed, target, clampf(sub_dt * 18.0, 0.0, 1.0))
	wheel.angular_speed = clampf(wheel.angular_speed, -450.0, 450.0)
	wheel.roll_angle += wheel.angular_speed * sub_dt


func _update_airborne_wheel_spin(wheel, sub_dt: float) -> void:
	var brake_direction := signf(wheel.angular_speed)
	var net_torque: float = float(wheel.drive_force) * float(wheel.wheel_radius) - float(wheel.brake_force) * float(wheel.wheel_radius) * brake_direction
	var wheel_inertia := 1.8
	wheel.angular_speed = clampf(wheel.angular_speed + (net_torque / wheel_inertia) * sub_dt, -900.0, 900.0)
	if absf(net_torque) <= 0.0001:
		wheel.angular_speed = move_toward(wheel.angular_speed, 0.0, 0.35 * sub_dt)
	wheel.roll_angle += wheel.angular_speed * sub_dt


func _update_motion_state_for_state(
	state: PhysicsDirectBodyState3D,
	body_forward_ps2: Vector3,
	body_up_ps2: Vector3,
	flat_velocity_ps2: Vector3,
	speed_mps: float,
	sub_dt: float
) -> void:
	_shift_lock_time = maxf(_shift_lock_time - sub_dt, 0.0)
	_shift_cut_time = maxf(_shift_cut_time - sub_dt, 0.0)
	if flat_velocity_ps2.length() > 0.25:
		signed_slip_angle = _signed_angle_on_axis(body_forward_ps2, flat_velocity_ps2.normalized(), body_up_ps2)
	else:
		signed_slip_angle = 0.0
	_update_steering_state(speed_mps, sub_dt)
	_update_gear_state(speed_mps, sub_dt)
	linear_velocity = state.linear_velocity
	angular_velocity = state.angular_velocity


func _update_engine_state(speed_mps: float, sub_dt: float) -> void:
	var driven_rpm := _average_driven_wheel_rpm()
	if driven_rpm <= 0.01:
		driven_rpm = _speed_rpm_estimate(speed_mps)
	var drivetrain_ratio := absf(_active_gear_ratio() * config.final_drive_ratio)
	var target_rpm := clampf(driven_rpm * drivetrain_ratio, config.idle_rpm, config.engine_redline_rpm)
	if absf(speed_mps) <= 0.25:
		var free_rev_target = lerpf(config.idle_rpm, config.engine_redline_rpm, _hp2_throttle_command(speed_mps))
		target_rpm = maxf(target_rpm, free_rev_target * (0.45 + clampf(speed_mps / 30.0, 0.0, 0.55)))
	engine_rpm = move_toward(engine_rpm, target_rpm, maxf(config.engine_redline_rpm, 1000.0) * sub_dt)


func _update_gear_state(speed_mps: float, sub_dt: float) -> void:
	var speed_kph := speed_mps * 3.6
	if current_gear >= 0:
		if speed_kph < 0.75:
			if _brake_input < 0.15:
				_reverse_ready = true
				_reverse_hold_time = 0.0
			elif _reverse_ready and _brake_input > 0.97 and _throttle_input < 0.05:
				_reverse_hold_time += sub_dt
				if _reverse_hold_time >= 0.25:
					current_gear = -1
					_reverse_hold_time = 0.0
					_reverse_ready = false
					return
			else:
				_reverse_hold_time = 0.0
		else:
			_reverse_hold_time = 0.0
			_reverse_ready = false
	if current_gear < 0:
		if _throttle_input > 0.15 or (_brake_input < 0.2 and speed_kph < 0.5):
			current_gear = 1
			_reverse_hold_time = 0.0
			_reverse_ready = false
		return
	if _shift_lock_time > 0.0:
		return
	var throttle_alpha := pow(clampf(_throttle_input, 0.0, 1.0), 0.75)
	var brake_alpha := clampf(_brake_input, 0.0, 1.0)
	var upshift_rpm := lerpf(config.engine_peak_rpm * 0.88, config.engine_redline_rpm * 0.985, throttle_alpha)
	var downshift_rpm := lerpf(config.idle_rpm * 2.1, config.engine_peak_rpm * 0.7, maxf(throttle_alpha, brake_alpha))
	if brake_alpha > 0.25:
		downshift_rpm = maxf(downshift_rpm, config.engine_peak_rpm * 0.78)
	if current_gear < config.top_gear():
		var post_shift_rpm := _estimated_engine_rpm_for_gear(speed_mps, current_gear + 1)
		if engine_rpm >= upshift_rpm and post_shift_rpm >= config.idle_rpm * 1.35:
			current_gear += 1
			_shift_lock_time = 0.22
			_shift_cut_time = 0.11
			return
	if current_gear > 1:
		var lower_gear_rpm := _estimated_engine_rpm_for_gear(speed_mps, current_gear - 1)
		if engine_rpm <= downshift_rpm and lower_gear_rpm <= config.engine_redline_rpm * 0.98:
			current_gear -= 1
			_shift_lock_time = 0.14
			_shift_cut_time = 0.04


func _update_steering_state(speed_mps: float, sub_dt: float) -> void:
	var speed_kph := speed_mps * 3.6
	var speed_alpha := clampf(speed_kph / maxf(config.high_speed_steer_kph, 1.0), 0.0, 1.0)
	var speed_scale := lerpf(config.low_speed_steer_scale, config.high_speed_steer_scale, speed_alpha)
	if not _steering_engaged and absf(_steering_input) >= config.steering_hysteresis_enter:
		_steering_engaged = true
	elif _steering_engaged and absf(_steering_input) <= config.steering_hysteresis_exit:
		_steering_engaged = false
	var engaged_scale := 1.0 if _steering_engaged else 0.7
	var target_angle := deg_to_rad(config.steering_max_degrees * config.steering_lock_scale)
	target_angle *= _steering_input * speed_scale * engaged_scale
	var response: float = config.steering_response if absf(_steering_input) > 0.01 else config.steering_return
	_steering_state = move_toward(_steering_state, target_angle, response * sub_dt)


func _average_driven_wheel_rpm() -> float:
	var total := 0.0
	var count := 0
	for wheel in wheels:
		if config.drive_bias_for_slot(wheel.slot_id) <= 0.0:
			continue
		total += absf(wheel.angular_speed * 60.0 / TAU)
		count += 1
	return total / float(count) if count > 0 else 0.0


func _speed_rpm_estimate(speed_mps: float) -> float:
	var radius := maxf(config.driven_average_radius(), 0.1)
	return absf(speed_mps / (TAU * radius) * 60.0)


func _active_gear_ratio() -> float:
	if current_gear < 0:
		return config.reverse_gear_ratio
	return config.get_gear_ratio(current_gear)


func _update_inputs() -> void:
	_throttle_input = _read_action_pair("car_accelerate", "ui_up")
	_brake_input = _read_action_pair("car_brake", "ui_down")
	_handbrake_input = _read_action_pair("car_handbrake", "")
	_steering_input = _read_action_pair("car_steer_left", "ui_left") - _read_action_pair("car_steer_right", "ui_right")


func _read_action_pair(primary_action: String, fallback_action: String) -> float:
	if primary_action != "" and InputMap.has_action(primary_action):
		return Input.get_action_strength(primary_action)
	if fallback_action != "" and InputMap.has_action(fallback_action):
		return Input.get_action_strength(fallback_action)
	return 0.0


func _hp2_drive_force_total(speed_mps: float, rpm: float, gear: int) -> float:
	var gear_ratio := _gear_ratio_for_force(gear)
	return config.sample_engine_force(speed_mps, rpm) * absf(gear_ratio * config.final_drive_ratio)


func _godot_engine_force_total(speed_mps: float, rpm: float, gear: int) -> float:
	var fade_kph := maxf(float(_vehicle_setup.get("low_speed_torque_fade_kph", 90.0)), 1.0)
	var speed_alpha := clampf((speed_mps * 3.6) / fade_kph, 0.0, 1.0)
	var launch_boost := lerpf(float(_vehicle_setup.get("low_speed_torque_boost", 1.0)), 1.0, speed_alpha)
	return _hp2_drive_force_total(speed_mps, rpm, gear) * float(_vehicle_setup.get("engine_force_normalization_gain", 0.0)) * launch_boost


func _engine_braking_force_total(speed_mps: float, rpm: float, gear: int) -> float:
	if gear < 0 or speed_mps <= 0.1:
		return 0.0
	var rpm_alpha := clampf(inverse_lerp(config.idle_rpm, config.engine_redline_rpm, rpm), 0.0, 1.0)
	var hp2_force := _hp2_drive_force_total(speed_mps, rpm, gear)
	var engine_brake_gain := float(_vehicle_setup.get("engine_brake_gain", 0.09))
	var coast_drag_gain := float(_vehicle_setup.get("coast_drag_gain", 0.025))
	var engine_brake := hp2_force * engine_brake_gain * lerpf(0.45, 1.0, rpm_alpha)
	var coast_drag := speed_mps * mass * coast_drag_gain
	return engine_brake + coast_drag


func _hp2_throttle_command(speed_mps: float) -> float:
	var throttle_alpha := clampf(_throttle_input, 0.0, 1.0)
	var shaped := pow(throttle_alpha, 0.72)
	var launch_alpha := clampf(1.0 - (speed_mps * 3.6) / 95.0, 0.0, 1.0)
	if current_gear == 1:
		shaped = lerpf(shaped, minf(shaped * 1.18 + throttle_alpha * 0.1, 1.0), launch_alpha)
	return shaped


func _shift_cut_scale() -> float:
	if _shift_cut_time <= 0.0:
		return 1.0
	var alpha := clampf(_shift_cut_time / 0.11, 0.0, 1.0)
	return lerpf(1.0, 0.2, alpha)


func _estimated_engine_rpm_for_gear(speed_mps: float, gear: int) -> float:
	var wheel_rpm := _speed_rpm_estimate(speed_mps)
	var drivetrain_ratio := absf(_gear_ratio_for_force(gear) * config.final_drive_ratio)
	return clampf(wheel_rpm * drivetrain_ratio, config.idle_rpm, config.engine_redline_rpm)


func _gear_ratio_for_force(gear: int) -> float:
	if gear < 0:
		return config.reverse_gear_ratio
	return config.get_gear_ratio(maxi(gear, 1))


func _drag_force_ps2(flat_velocity_ps2: Vector3, speed_mps: float) -> Vector3:
	if speed_mps <= 0.001:
		return Vector3.ZERO
	var direction := flat_velocity_ps2.normalized()
	var rolling_coeff := float(_vehicle_setup.get("rolling_resistance", config.rolling_resistance))
	var aero_coeff := float(_vehicle_setup.get("aero_drag", config.aero_drag))
	var rolling_force := -direction * rolling_coeff * mass * GRAVITY_MPS2
	var aero_force := -direction * aero_coeff * speed_mps * speed_mps * mass
	return rolling_force + aero_force


func _slip_grip_reduction() -> float:
	var slip_abs := absf(rad_to_deg(signed_slip_angle))
	var reduction_range := maxf(config.slip_grip_reduction_end_deg - config.slip_grip_reduction_start_deg, 0.001)
	var reduction_alpha := clampf((slip_abs - config.slip_grip_reduction_start_deg) / reduction_range, 0.0, 1.0)
	return lerpf(1.0, config.drift_grip_scale, reduction_alpha)


func _apply_grounded_chassis_damping(
	state: PhysicsDirectBodyState3D,
	body_origin_ps2: Vector3,
	body_up_ps2: Vector3,
	body_forward_ps2: Vector3,
	body_right_ps2: Vector3,
	sub_dt: float
) -> void:
	var grounded_count := 0
	for wheel in wheels:
		if wheel.grounded:
			grounded_count += 1
	if grounded_count == 0:
		return
	var grounded_alpha := float(grounded_count) / float(maxi(wheels.size(), 1))
	var linear_velocity_ps2 := _godot_to_ps2(state.linear_velocity)
	var vertical_speed := linear_velocity_ps2.dot(body_up_ps2)
	var heave_force_ps2 := body_up_ps2 * (-vertical_speed * mass * GROUNDED_HEAVE_DAMPING * grounded_alpha)
	_apply_impulse_ps2(state, heave_force_ps2 * sub_dt, body_origin_ps2)
	var angular_velocity_ps2 := _godot_to_ps2(state.angular_velocity)
	var pitch_rate := angular_velocity_ps2.dot(body_right_ps2)
	var roll_rate := angular_velocity_ps2.dot(body_forward_ps2)
	var attitude_torque_ps2 := body_right_ps2 * (-pitch_rate * GROUNDED_PITCH_DAMPING * grounded_alpha)
	attitude_torque_ps2 += body_forward_ps2 * (-roll_rate * GROUNDED_ROLL_DAMPING * grounded_alpha)
	_apply_torque_impulse_ps2(state, attitude_torque_ps2 * sub_dt)


func _apply_rest_settle(state: PhysicsDirectBodyState3D, sub_dt: float) -> void:
	if not _can_rest_settle(state):
		return
	state.linear_velocity = state.linear_velocity.move_toward(Vector3.ZERO, REST_SETTLE_LINEAR_DAMP * sub_dt)
	state.angular_velocity = state.angular_velocity.move_toward(Vector3.ZERO, REST_SETTLE_ANGULAR_DAMP * sub_dt)
	if state.linear_velocity.length() <= REST_FREEZE_LINEAR_SPEED:
		state.linear_velocity = Vector3.ZERO
	if state.angular_velocity.length() <= REST_FREEZE_ANGULAR_SPEED:
		state.angular_velocity = Vector3.ZERO
	for wheel in wheels:
		if absf(wheel.travel_velocity) > REST_SETTLE_TRAVEL_SPEED:
			continue
		wheel.travel_velocity = 0.0
		wheel.compression_velocity = 0.0
		wheel.previous_length = wheel.current_length


func _can_rest_settle(state: PhysicsDirectBodyState3D) -> bool:
	if absf(_throttle_input) > 0.01 or absf(_brake_input) > 0.01:
		return false
	if absf(_handbrake_input) > 0.01 or absf(_steering_input) > 0.01:
		return false
	if state.linear_velocity.length() > REST_SETTLE_LINEAR_SPEED:
		return false
	if state.angular_velocity.length() > REST_SETTLE_ANGULAR_SPEED:
		return false
	for wheel in wheels:
		if not wheel.grounded:
			return false
		if absf(wheel.travel_velocity) > REST_SETTLE_TRAVEL_SPEED:
			return false
	return not wheels.is_empty()


func _yaw_assist_torque_ps2(body_up_ps2: Vector3, state: PhysicsDirectBodyState3D, speed_mps: float) -> Vector3:
	var yaw_rate := _godot_to_ps2(state.angular_velocity).dot(body_up_ps2)
	var torque: float = -yaw_rate * config.yaw_damping * 40.0
	if speed_mps * 3.6 >= config.stabilization_min_speed_kph:
		var slip_deg := absf(rad_to_deg(signed_slip_angle))
		var drift_range := maxf(config.drift_slip_deg - config.stabilization_slip_deg, 0.001)
		var slip_alpha := clampf((slip_deg - config.stabilization_slip_deg) / drift_range, 0.0, 1.0)
		torque += -signf(signed_slip_angle) * config.yaw_assist * slip_alpha * 0.35
		torque += _steering_state * config.steering_yaw_assist * clampf(speed_mps / 30.0, 0.0, 1.0) * 0.25
	return body_up_ps2 * torque


func _wheel_heading_ps2(basis: Basis, body_up_ps2: Vector3, wheel) -> Vector3:
	var base_forward_ps2 := _basis_axis_ps2(basis, Vector3(1.0, 0.0, 0.0))
	if wheel.is_front():
		wheel.steer_angle = _steering_state
		return base_forward_ps2.rotated(body_up_ps2, wheel.steer_angle).normalized()
	wheel.steer_angle = 0.0
	return base_forward_ps2


func _wheel_axle_ps2(basis: Basis, wheel) -> Vector3:
	var body_up_ps2 := _basis_axis_ps2(basis, Vector3(0.0, 0.0, 1.0))
	var heading_ps2 := _wheel_heading_ps2(basis, body_up_ps2, wheel)
	var axle_ps2 := body_up_ps2.cross(heading_ps2)
	if axle_ps2.length_squared() <= 0.0001:
		axle_ps2 = _basis_axis_ps2(basis, Vector3(0.0, 1.0, 0.0))
	return axle_ps2.normalized()


func _apply_impulse_ps2(state: PhysicsDirectBodyState3D, impulse_ps2: Vector3, world_position_ps2: Vector3) -> void:
	if impulse_ps2.length_squared() <= 0.000001:
		return
	var impulse_godot := _ps2_to_godot(impulse_ps2)
	var world_position_godot := _ps2_to_godot(world_position_ps2)
	var offset := world_position_godot - state.transform.origin
	state.apply_impulse(impulse_godot)
	state.apply_torque_impulse(offset.cross(impulse_godot))


func _apply_torque_impulse_ps2(state: PhysicsDirectBodyState3D, torque_ps2: Vector3) -> void:
	if torque_ps2.length_squared() <= 0.000001:
		return
	state.apply_torque_impulse(_ps2_to_godot(torque_ps2))


func _cache_visual_wheel_slots(car_visual: Node3D) -> void:
	var wheel_slots: Array = car_visual.get_meta("eagl_wheel_slots", [])
	for slot in wheel_slots:
		var slot_dict: Dictionary = slot
		var slot_id := String(slot_dict.get("slot_id", ""))
		if slot_id == "":
			continue
		_visual_wheel_slots[slot_id] = slot_dict.duplicate(true)


func _reset_runtime_values() -> void:
	current_gear = 1
	engine_rpm = maxf(config.idle_rpm, 900.0)
	signed_slip_angle = 0.0
	_throttle_input = 0.0
	_brake_input = 0.0
	_steering_input = 0.0
	_handbrake_input = 0.0
	_steering_state = 0.0
	_steering_engaged = false
	_reverse_hold_time = 0.0
	_reverse_ready = false
	_shift_lock_time = 0.0
	_shift_cut_time = 0.0
	for wheel in wheels:
		wheel.reset_runtime()
		_wheel_spin_angles[wheel.slot_id] = 0.0


func _rebuild_wheel_slot_map() -> void:
	_wheel_by_slot.clear()
	for wheel in wheels:
		_wheel_by_slot[wheel.slot_id] = wheel


func _update_visuals(delta: float) -> void:
	for wheel in wheels:
		var suspension_node := _wheel_suspension_nodes.get(wheel.slot_id, null) as Node3D
		var steer_node := _wheel_visuals.get(wheel.slot_id, null) as Node3D
		var roll_node := _wheel_roll_visuals.get(wheel.slot_id, null) as Node3D
		if suspension_node != null:
			suspension_node.position = VehicleBodyConfigAdapter.visual_space_from_vehicle(_current_visual_wheel_offset_vehicle(wheel))
		if steer_node != null:
			var steer_rotation := steer_node.rotation
			steer_rotation.y = -wheel.steer_angle
			steer_node.rotation = steer_rotation
		if roll_node != null:
			_wheel_spin_angles[wheel.slot_id] = float(_wheel_spin_angles.get(wheel.slot_id, 0.0)) + wheel.angular_speed * delta
			var roll_rotation := roll_node.rotation
			roll_rotation.x = float(_wheel_spin_angles.get(wheel.slot_id, 0.0)) * float(roll_node.get_meta("eagl_spin_direction", 1.0))
			roll_node.rotation = roll_rotation


func _current_visual_wheel_offset_vehicle(wheel) -> Vector3:
	var pivot := _current_wheel_pivot_vehicle(wheel.slot_id)
	var center := to_local(_ps2_to_godot(wheel.world_wheel_center_ps2))
	return Vector3(0.0, center.y - pivot.y, 0.0)


func _current_wheel_pivot_vehicle(slot_id: String) -> Vector3:
	var pivot_node := _wheel_pivots.get(slot_id, null) as Node3D
	if pivot_node != null:
		return to_local(pivot_node.global_position)
	var wheel = _wheel_by_slot.get(slot_id, null)
	if wheel != null:
		return VehicleBodyConfigAdapter.vehicle_space_from_ps2(wheel.pivot_local_position_ps2)
	return Vector3.ZERO


func _update_debug_snapshot() -> void:
	var flat_velocity := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var wheel_rows: Array[Dictionary] = []
	for wheel in wheels:
		wheel_rows.append({
			"slot": wheel.slot_id,
			"grounded": wheel.grounded,
			"rpm": wheel.angular_speed * 60.0 / TAU,
			"skid": wheel.grip_utilization,
			"steering_deg": rad_to_deg(wheel.steer_angle),
			"engine_force": wheel.drive_force,
			"brake_force": wheel.brake_force,
			"suspension_length": wheel.current_length,
			"raw_length": wheel.raw_length,
			"current_length": wheel.current_length,
			"travel_velocity": wheel.travel_velocity,
			"spring_force": wheel.spring_force,
			"damper_force": wheel.damper_force,
			"suspension_force": wheel.suspension_force,
			"normal_load": wheel.normal_load,
			"slip_long": wheel.slip_long,
			"slip_lat": wheel.slip_lat,
			"force_long": wheel.force_long,
			"force_lat": wheel.force_lat,
			"grip": wheel.grip_utilization,
			"material_id": wheel.material_id,
		})
	_debug_snapshot = {
		"speed_kph": flat_velocity.length() * 3.6,
		"rpm": engine_rpm,
		"gear": current_gear,
		"slip_angle_deg": rad_to_deg(signed_slip_angle),
		"steering_deg": rad_to_deg(_steering_state),
		"mass_kg": mass,
		"mass_is_estimate": bool(_vehicle_setup.get("mass_is_estimate", false)),
		"driven_wheel_count": int(_vehicle_setup.get("driven_wheel_count", 0)),
		"engine_force_gain": float(_vehicle_setup.get("engine_force_normalization_gain", 0.0)),
		"hp2_launch_accel_reference": float(_vehicle_setup.get("hp2_launch_accel_reference", 0.0)),
		"drag_force": _last_drag_force.length(),
		"engine_force_total": _godot_engine_force_total(flat_velocity.length(), engine_rpm, current_gear),
		"engine_brake_total": _engine_braking_force_total(flat_velocity.length(), engine_rpm, current_gear),
		"wheels": wheel_rows,
	}


func _ensure_debug_mesh() -> void:
	_debug_mesh_instance = get_node_or_null("DebugLines") as MeshInstance3D
	if _debug_mesh_instance == null:
		push_warning("Car.tscn is missing DebugLines; debug suspension vectors are disabled.")
		return
	if _debug_material == null:
		_debug_material = StandardMaterial3D.new()
		_debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_debug_material.vertex_color_use_as_albedo = true
		_debug_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_debug_material.no_depth_test = true
	_debug_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_debug_mesh_instance.material_override = _debug_material
	_debug_mesh_instance.mesh = _debug_mesh


func _rebuild_debug_mesh() -> void:
	if _debug_mesh_instance == null:
		return
	_debug_mesh.clear_surfaces()
	_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_add_collision_wireframe()
	for wheel in wheels:
		var pivot := _debug_local_from_ps2(wheel.world_pivot_ps2)
		var attachment := _debug_local_from_ps2(wheel.world_attachment_ps2)
		var center := _debug_local_from_ps2(wheel.world_wheel_center_ps2)
		var contact := _debug_local_from_ps2(wheel.contact_point_ps2)
		var normal_end := _debug_local_from_ps2(wheel.contact_point_ps2 + wheel.normal_ps2 * 0.45)
		_debug_mesh.surface_set_color(Color(0.15, 0.9, 0.95, 0.95))
		_debug_mesh.surface_add_vertex(pivot)
		_debug_mesh.surface_add_vertex(attachment)
		_debug_mesh.surface_set_color(Color(0.0, 0.85, 1.0, 1.0))
		_debug_mesh.surface_add_vertex(attachment)
		_debug_mesh.surface_add_vertex(center)
		_debug_mesh.surface_set_color(Color(1.0, 0.75, 0.2, 0.95))
		_add_cross_vertices(center, 0.08)
		_add_physics_wheel_outline(center, wheel, Color(0.15, 0.65, 1.0, 0.9))
		if wheel.grounded:
			_debug_mesh.surface_set_color(Color(0.25, 1.0, 0.3, 0.95))
			_debug_mesh.surface_add_vertex(center)
			_debug_mesh.surface_add_vertex(contact)
			_add_cross_vertices(contact, 0.06)
			_debug_mesh.surface_set_color(Color(0.25, 1.0, 0.3, 0.95))
			_debug_mesh.surface_add_vertex(contact)
			_debug_mesh.surface_add_vertex(normal_end)
			_add_suspension_force_markers(pivot, wheel)
			_add_tire_force_marker(contact, wheel)
	_debug_mesh.surface_set_color(Color(1.0, 0.15, 0.15, 1.0))
	_debug_mesh.surface_add_vertex(Vector3.ZERO)
	_debug_mesh.surface_add_vertex(VEHICLE_FORWARD * 1.5)
	var com_local := center_of_mass
	_debug_mesh.surface_set_color(Color(0.85, 0.35, 1.0, 0.95))
	_add_cross_vertices(com_local, 0.09)
	_debug_mesh.surface_end()


func _add_cross_vertices(center: Vector3, radius: float) -> void:
	_debug_mesh.surface_add_vertex(center + Vector3.LEFT * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.RIGHT * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.UP * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.DOWN * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.FORWARD * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.BACK * radius)


func _add_physics_wheel_outline(center: Vector3, wheel, color: Color) -> void:
	var radius := maxf(wheel.wheel_radius, 0.01)
	var axle := _debug_local_direction_ps2(_wheel_axle_ps2(global_transform.basis, wheel)).normalized()
	var up_axis := _debug_local_direction_ps2(_basis_axis_ps2(global_transform.basis, Vector3(0.0, 0.0, 1.0))).normalized()
	var forward_axis := axle.cross(up_axis).normalized()
	_debug_mesh.surface_set_color(color)
	for index in range(DEBUG_WHEEL_PHYSICS_SEGMENTS):
		var angle_0 := TAU * float(index) / float(DEBUG_WHEEL_PHYSICS_SEGMENTS)
		var angle_1 := TAU * float(index + 1) / float(DEBUG_WHEEL_PHYSICS_SEGMENTS)
		var point_0 := center + (up_axis * cos(angle_0) + forward_axis * sin(angle_0)) * radius
		var point_1 := center + (up_axis * cos(angle_1) + forward_axis * sin(angle_1)) * radius
		_debug_mesh.surface_add_vertex(point_0)
		_debug_mesh.surface_add_vertex(point_1)


func _add_suspension_force_markers(pivot: Vector3, wheel) -> void:
	var force_axis := _debug_local_direction_ps2(_basis_axis_ps2(global_transform.basis, Vector3(0.0, 0.0, 1.0))).normalized()
	var axle_axis := _debug_local_direction_ps2(_wheel_axle_ps2(global_transform.basis, wheel)).normalized()
	if axle_axis.length_squared() <= 0.000001:
		axle_axis = Vector3.RIGHT
	var force_reference: float = maxf(maxf(absf(wheel.spring_force), absf(wheel.damper_force)), absf(wheel.suspension_force))
	force_reference = maxf(force_reference, maxf(wheel.preload_force, 1.0))
	_add_suspension_force_component(pivot - axle_axis * 0.1, force_axis, wheel.spring_force, force_reference, Color(0.1, 1.0, 0.35, 0.9))
	_add_suspension_force_component(pivot, force_axis, wheel.damper_force, force_reference, Color(0.25, 0.55, 1.0, 0.9))
	_add_suspension_force_component(pivot + axle_axis * 0.1, force_axis, wheel.suspension_force, force_reference, Color(1.0, 0.08, 0.08, 0.9))


func _add_suspension_force_component(origin: Vector3, axis: Vector3, force: float, reference_force: float, color: Color) -> void:
	if absf(force) <= 0.5:
		return
	var direction := 1.0 if force >= 0.0 else -1.0
	var force_alpha := clampf(absf(force) / maxf(reference_force, 1.0), 0.0, 1.0)
	var force_end := origin + axis * direction * lerpf(0.05, 0.6, force_alpha)
	_debug_mesh.surface_set_color(color)
	_debug_mesh.surface_add_vertex(origin)
	_debug_mesh.surface_add_vertex(force_end)


func _add_tire_force_marker(contact: Vector3, wheel) -> void:
	var heading := _debug_local_direction_ps2(_wheel_heading_ps2(global_transform.basis, _basis_axis_ps2(global_transform.basis, Vector3(0.0, 0.0, 1.0)), wheel)).normalized()
	var right := _debug_local_direction_ps2(_wheel_axle_ps2(global_transform.basis, wheel)).normalized()
	var scale := 0.00008
	_debug_mesh.surface_set_color(Color(1.0, 0.55, 0.1, 0.9))
	_debug_mesh.surface_add_vertex(contact)
	_debug_mesh.surface_add_vertex(contact + heading * wheel.force_long * scale)
	_debug_mesh.surface_set_color(Color(0.4, 0.8, 1.0, 0.9))
	_debug_mesh.surface_add_vertex(contact)
	_debug_mesh.surface_add_vertex(contact + right * wheel.force_lat * scale)


func _add_collision_wireframe() -> void:
	var collision_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision_shape == null:
		return
	var box_shape := collision_shape.shape as BoxShape3D
	if box_shape == null:
		return
	var extents := box_shape.size * 0.5
	var corners := [
		Vector3(-extents.x, -extents.y, -extents.z),
		Vector3(extents.x, -extents.y, -extents.z),
		Vector3(extents.x, extents.y, -extents.z),
		Vector3(-extents.x, extents.y, -extents.z),
		Vector3(-extents.x, -extents.y, extents.z),
		Vector3(extents.x, -extents.y, extents.z),
		Vector3(extents.x, extents.y, extents.z),
		Vector3(-extents.x, extents.y, extents.z),
	]
	var edges := [
		Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3), Vector2i(3, 0),
		Vector2i(4, 5), Vector2i(5, 6), Vector2i(6, 7), Vector2i(7, 4),
		Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
	]
	_debug_mesh.surface_set_color(Color(1.0, 1.0, 1.0, 0.9))
	for edge in edges:
		var start: Vector3 = collision_shape.transform * corners[edge.x]
		var finish: Vector3 = collision_shape.transform * corners[edge.y]
		_debug_mesh.surface_add_vertex(start)
		_debug_mesh.surface_add_vertex(finish)


func _fit_chassis_collision_shape() -> void:
	var collision_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision_shape == null:
		return
	var box_shape := collision_shape.shape as BoxShape3D
	if box_shape == null:
		box_shape = BoxShape3D.new()
		collision_shape.shape = box_shape
	var body_size: Vector3 = _vehicle_setup.get("body_size", Vector3(1.9, 1.2, 4.6))
	var collision_center: Vector3 = _vehicle_setup.get("collision_center", Vector3(0.0, body_size.y * 0.5, 0.0))
	box_shape.size = body_size
	collision_shape.position = collision_center


func _fit_collision_shape_to_visual_bounds() -> void:
	var collision_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision_shape == null:
		return
	var box_shape := collision_shape.shape as BoxShape3D
	if box_shape == null or _visual_root == null:
		return
	var body_root := _visual_root.get_node_or_null("CarVisual/Body") as Node3D
	if body_root == null:
		return
	var has_bounds := false
	var min_point := Vector3.ZERO
	var max_point := Vector3.ZERO
	for child in body_root.get_children():
		if not (child is MeshInstance3D):
			continue
		var mesh_instance := child as MeshInstance3D
		var local_aabb := mesh_instance.get_aabb()
		var corners := [
			local_aabb.position,
			local_aabb.position + Vector3(local_aabb.size.x, 0.0, 0.0),
			local_aabb.position + Vector3(0.0, local_aabb.size.y, 0.0),
			local_aabb.position + Vector3(0.0, 0.0, local_aabb.size.z),
			local_aabb.position + Vector3(local_aabb.size.x, local_aabb.size.y, 0.0),
			local_aabb.position + Vector3(local_aabb.size.x, 0.0, local_aabb.size.z),
			local_aabb.position + Vector3(0.0, local_aabb.size.y, local_aabb.size.z),
			local_aabb.position + local_aabb.size,
		]
		for corner in corners:
			var point := to_local(mesh_instance.global_transform * corner)
			if not has_bounds:
				min_point = point
				max_point = point
				has_bounds = true
			else:
				min_point = min_point.min(point)
				max_point = max_point.max(point)
	if not has_bounds:
		return
	box_shape.size = (max_point - min_point).abs()
	collision_shape.position = (min_point + max_point) * 0.5


func _visual_radius_from_node(node: Node3D) -> float:
	var max_radius := 0.0
	for child in node.get_children():
		if not (child is MeshInstance3D):
			continue
		var mesh_instance := child as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var local_aabb := mesh_instance.transform * mesh_instance.mesh.get_aabb()
		var diameter := maxf(local_aabb.size.y, local_aabb.size.z)
		max_radius = maxf(max_radius, diameter * 0.5)
	return max_radius


func _prime_wheels_from_current_transform() -> void:
	var body_up_ps2 := _basis_axis_ps2(global_transform.basis, Vector3(0.0, 0.0, 1.0))
	for wheel in wheels:
		var length_min := minf(wheel.min_travel, wheel.max_travel)
		var pivot_world_ps2 := _transform_point_ps2(global_transform, wheel.pivot_local_position_ps2)
		var attachment_world_ps2 := _transform_point_ps2(global_transform, wheel.local_position_ps2)
		wheel.world_pivot_ps2 = pivot_world_ps2
		wheel.world_attachment_ps2 = attachment_world_ps2
		wheel.world_wheel_center_ps2 = attachment_world_ps2 + body_up_ps2 * length_min
		wheel.contact_point_ps2 = attachment_world_ps2
		wheel.normal_ps2 = body_up_ps2
		wheel.raw_length = length_min
		wheel.suspension_distance = length_min
		wheel.center_offset = length_min
		wheel.current_length = length_min
		wheel.previous_length = length_min


func _paired_axle_wheel(wheel):
	for other in wheels:
		if other == wheel:
			continue
		if other.axle != wheel.axle:
			continue
		if other.side == wheel.side:
			continue
		return other
	return null


func _debug_local_from_ps2(world_point_ps2: Vector3) -> Vector3:
	return to_local(_ps2_to_godot(world_point_ps2))


func _debug_local_direction_ps2(direction_ps2: Vector3) -> Vector3:
	return global_transform.basis.inverse() * _ps2_to_godot(direction_ps2)


func _transform_point_ps2(body_transform: Transform3D, local_point_ps2: Vector3) -> Vector3:
	return _godot_to_ps2(body_transform * _vehicle_from_local_ps2(local_point_ps2))


func _basis_axis_ps2(basis: Basis, local_axis_ps2: Vector3) -> Vector3:
	return _godot_to_ps2(basis * _vehicle_from_local_ps2(local_axis_ps2)).normalized()


func _vehicle_from_local_ps2(value: Vector3) -> Vector3:
	return VehicleBodyConfigAdapter.vehicle_space_from_ps2(value)


func _ps2_to_godot(value: Vector3) -> Vector3:
	return MathUtils.ps2_to_godot_vec3(value)


func _godot_to_ps2(value: Vector3) -> Vector3:
	return Vector3(value.x, -value.z, value.y)


func _horizontal_ps2(value: Vector3) -> Vector3:
	return Vector3(value.x, value.y, 0.0)


func _signed_angle_on_axis(from_vector: Vector3, to_vector: Vector3, axis: Vector3) -> float:
	var cross_value := from_vector.cross(to_vector)
	return atan2(axis.dot(cross_value), from_vector.dot(to_vector))
