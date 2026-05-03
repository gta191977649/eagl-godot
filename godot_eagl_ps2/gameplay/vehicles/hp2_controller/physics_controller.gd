class_name HP2PhysicsController
extends RigidBody3D


const HP2WheelScript = preload("res://gameplay/vehicles/hp2_controller/wheel.gd")
const HP2EngineScript = preload("res://gameplay/vehicles/hp2_controller/engine.gd")
const HP2DrivetrainScript = preload("res://gameplay/vehicles/hp2_controller/drivetrain.gd")
const HP2SteeringSystemScript = preload("res://gameplay/vehicles/hp2_controller/steering_system.gd")
const HP2AssistScript = preload("res://gameplay/vehicles/hp2_controller/hp2_assist.gd")
const HP2PlayerInputScript = preload("res://gameplay/vehicles/hp2_controller/player_input.gd")
const VehicleBodyConfigAdapter = preload("res://eagl/handling/vehicle_body_config_adapter.gd")
const MathUtils = preload("res://eagl/utils/math_utils.gd")

const SLOT_IDS := ["FL", "FR", "RL", "RR"]
const SURFACE_TABLE := {
	"asphalt": 1.0,
	"dirt": 0.7,
	"grass": 0.5,
	"gravel": 0.6,
	"ice": 0.2,
}
const GRAVITY := 9.81
const SUBSTEP_TARGET_DT := 0.0044
const SUSPENSION_DENOM_EPSILON := 0.05
const DEBUG_WHEEL_PHYSICS_SEGMENTS := 20
const MIN_SIDESLIP_SPEED_MS := 5.0 / 3.6
const AUTO_SHIFT_SLIP_LIMIT := 4.0
const AUTO_SHIFT_REDLIMIT_MARGIN_RPM := 100.0
const SUSPENSION_PARAM_FORCE_SCALE := 1000.0
const GROUNDED_HEAVE_DAMPING := 2.5
const GROUNDED_UPRIGHT_STIFFNESS := 1800.0
const GROUNDED_PITCH_DAMPING := 420.0
const GROUNDED_ROLL_DAMPING := 420.0
const GROUNDED_MAX_ANGULAR_SPEED := 8.0
const REST_SETTLE_LINEAR_SPEED := 0.05
const REST_SETTLE_ANGULAR_SPEED := 0.04
const REST_SETTLE_LINEAR_DAMP := 2.5
const REST_SETTLE_ANGULAR_DAMP := 2.0

@export_group("Physical Body")
@export var vehicle_mass_kg := 1450.0
@export var inertia_yaw := 2200.0
@export var wheelbase := 2.60
@export var track_front := 1.60
@export var track_rear := 1.58
@export var cg_height := 0.42
@export_range(0.0, 1.0) var front_weight_bias := 0.58
@export var wheel_radius := 0.32
@export var ride_height := 0.35

@export_group("Tire And Surface")
@export var base_mu := 1.0
@export_enum("asphalt", "dirt", "grass", "gravel", "ice") var surface_type := "asphalt"
@export var front_wheel_grip_scale := 1.0      # longitudinal
@export var rear_wheel_grip_scale := 1.0       # longitudinal
@export var front_wheel_lat_grip_scale := 1.0  # lateral (independent from long)
@export var rear_wheel_lat_grip_scale := 1.0   # lateral
@export var longitudinal_stiffness := 6000.0
@export var lateral_stiffness := 6500.0
@export var longitudinal_speed_damping := 0.0
@export var brake_torque_total := 4200.0
@export_range(0.0, 1.0) var brake_bias_front := 0.65
@export var rolling_resistance := 0.035
@export var aero_drag := 0.42
@export var aero_downforce_ratio := 0.12  # downforce / drag ratio (typical sedan)

@export_group("HP2 Validation Controls")
@export var weight_transfer_coeff := 0.64
@export var substeps := 4
@export var auto_simulate := true
@export var visual_spin_scale := 1.0
@export var visual_suspension_travel_scale := 1.5

@export var config = null
@export var draw_debug := false
@export var drive_area_surface_filter_enabled := true

var input_source = null
var engine = HP2EngineScript.new()
var drivetrain = HP2DrivetrainScript.new()
var steering_system = HP2SteeringSystemScript.new()
var assist = HP2AssistScript.new()
var wheels: Dictionary = {}

var sim_time := 0.0
var speed_ms := 0.0
var speed_kmh := 0.0
var sideslip_deg := 0.0
var accel_long := 0.0
var current_gear := 1
var shift_cut_active := false
var surface_mu := 1.0
var airborne_debug_enabled := false
var surface_sampler = null

var _pos_x := 0.0
var _pos_z := 0.0
var _display_y := 0.35
var _vertical_velocity := 0.0
var _heading := 0.0
var _vx := 0.0
var _vz := 0.0
var _yaw_rate := 0.0
var _last_forward_speed := 0.0
var _last_inputs := {
	"throttle": 0.0,
	"brake": 0.0,
	"steer": 0.0,
}
var _visual_root: Node3D
var _wheel_pivots: Dictionary = {}
var _wheel_suspension_nodes: Dictionary = {}
var _wheel_steer_nodes: Dictionary = {}
var _wheel_spin_nodes: Dictionary = {}
var _wheel_spin_angles: Dictionary = {}
var _debug_mesh := ImmediateMesh.new()
var _debug_mesh_instance: MeshInstance3D
var _debug_material: StandardMaterial3D


func _ready() -> void:
	_visual_root = get_node_or_null("VisualRoot") as Node3D
	if _visual_root != null:
		_visual_root.transform = Transform3D(VehicleBodyConfigAdapter.visual_anchor_basis(), Vector3.ZERO)
	freeze = false
	custom_integrator = true
	gravity_scale = 0.0
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 8
	can_sleep = false
	_configure_chassis_collision_shape()
	if config != null:
		apply_config(config)
	mass = vehicle_mass_kg
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3.ZERO
	drivetrain.engine = engine
	if wheels.is_empty():
		_rebuild_wheels()
	if input_source == null:
		input_source = HP2PlayerInputScript.new()
	_sync_state_from_transform(global_transform)
	_refresh_visual_bindings()
	set_debug_overlay_enabled(draw_debug)


func set_surface_sampler(sampler) -> void:
	surface_sampler = sampler


func _configure_chassis_collision_shape() -> void:
	var shape_node := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape_node == null:
		return
	var position := shape_node.position
	position.y = maxf(position.y, 0.45)
	shape_node.position = position


func _process(delta: float) -> void:
	_update_visuals(delta)
	if draw_debug:
		_rebuild_debug_mesh()


func apply_config(new_config) -> void:
	if new_config == null:
		return
	config = new_config
	vehicle_mass_kg = float(config.mass_kg)
	inertia_yaw = maxf(vehicle_mass_kg * wheelbase * wheelbase * 0.33, 1.0)
	if config.has_method("wheelbase_meters"):
		wheelbase = float(config.wheelbase_meters())
		inertia_yaw = maxf(vehicle_mass_kg * wheelbase * wheelbase * 0.33, 1.0)
	if config.has_method("front_axle_center_x") and config.has_method("rear_axle_center_x"):
		front_weight_bias = _front_load_bias_from_config(config)
	var configured_positions = config.get("wheel_local_positions_ps2")
	if configured_positions != null and configured_positions.size() >= 4:
		var positions: Array = configured_positions
		track_front = absf(float(positions[0].y) - float(positions[1].y))
		track_rear = absf(float(positions[2].y) - float(positions[3].y))
	var configured_radii = config.get("wheel_radii")
	if configured_radii != null and not configured_radii.is_empty():
		var radius_total := 0.0
		for radius in configured_radii:
			radius_total += float(radius)
		wheel_radius = radius_total / float(configured_radii.size())
	ride_height = _configured_ride_height(config)
	mass = vehicle_mass_kg
	_rebuild_wheels()
	_apply_handling_profile_params(config)
	_update_derived_state()


func _apply_handling_profile_params(source_config) -> void:
	engine.idle_rpm = float(source_config.idle_rpm)
	engine.peak_rpm = float(source_config.engine_peak_rpm)
	engine.max_rpm = float(source_config.engine_redline_rpm)
	engine.apply_globalb_samples(source_config.engine_torque_samples, source_config.engine_friction_samples)
	engine.rpm = engine.idle_rpm
	drivetrain.final_drive = float(source_config.final_drive_ratio)
	var ratios: Array[float] = [float(source_config.reverse_gear_ratio)]
	for ratio in source_config.forward_gears:
		ratios.append(float(ratio))
	if ratios.size() > 1:
		drivetrain.gear_ratios = PackedFloat32Array(ratios)
	drivetrain.upshift_rpm = clampf(
		float(source_config.shift_up_rpm),
		float(source_config.engine_peak_rpm) * 0.75,
		float(source_config.engine_redline_rpm) - AUTO_SHIFT_REDLIMIT_MARGIN_RPM
	)
	drivetrain.downshift_rpm = float(source_config.shift_down_rpm)
	drivetrain.build_shift_tables(engine.torque_curve, engine.idle_rpm, engine.max_rpm)
	# HP2-style speed-dependent steering: response_rate × lerp(low_scale, high_scale, (v/v_max)²)
	steering_system.steering_response_rate = maxf(float(source_config.steering_response), 0.1)
	steering_system.max_steer_degrees = float(source_config.steering_max_degrees) * float(source_config.steering_lock_scale)
	steering_system.low_speed_steer_scale = maxf(float(source_config.low_speed_steer_scale), 0.1)
	steering_system.high_speed_steer_scale = maxf(float(source_config.high_speed_steer_scale), 0.05)
	steering_system.high_speed_steer_kph = maxf(float(source_config.high_speed_steer_kph), 50.0)
	# Grip: separate longitudinal and lateral per axle (front/rear differ in HP2)
	front_wheel_grip_scale = maxf(float(source_config.front_longitudinal_grip), 0.1)
	rear_wheel_grip_scale = maxf(float(source_config.rear_longitudinal_grip), 0.1)
	front_wheel_lat_grip_scale = maxf(float(source_config.front_lateral_grip), 0.1)
	rear_wheel_lat_grip_scale = maxf(float(source_config.rear_lateral_grip), 0.1)
	var all_grips := [front_wheel_grip_scale, rear_wheel_grip_scale, front_wheel_lat_grip_scale, rear_wheel_lat_grip_scale]
	base_mu = maxf((front_wheel_grip_scale + rear_wheel_grip_scale + front_wheel_lat_grip_scale + rear_wheel_lat_grip_scale) / float(all_grips.size()), 0.1)
	var average_long_grip := (float(source_config.front_longitudinal_grip) + float(source_config.rear_longitudinal_grip)) * 0.5
	var average_lat_grip := (float(source_config.front_lateral_grip) + float(source_config.rear_lateral_grip)) * 0.5
	longitudinal_stiffness = 6000.0 * maxf(average_long_grip, 0.1)
	lateral_stiffness = 6500.0 * maxf(average_lat_grip, 0.1)
	longitudinal_speed_damping = 0.0
	brake_torque_total = maxf(float(source_config.brake_force) * wheel_radius, 1.0)
	rolling_resistance = maxf(float(source_config.rolling_resistance), 0.0)
	aero_drag = maxf(float(source_config.aero_drag) * vehicle_mass_kg, 0.0)
	assist.sideslip_threshold_deg = float(source_config.stabilization_slip_deg)
	# Push suspension params into wheels so the spring filter uses per-car stiffness
	_apply_suspension_params_to_wheels(source_config)


func _apply_suspension_params_to_wheels(source_config) -> void:
	var wheel_states: Array = []
	if source_config.has_method("build_wheel_states"):
		wheel_states = source_config.build_wheel_states()
	for slot_id in SLOT_IDS:
		var wheel = wheels.get(slot_id, null)
		if wheel == null:
			continue
		for state in wheel_states:
			if String(state.slot_id) != slot_id:
				continue
			wheel.pivot_local_z = float(state.pivot_local_position_ps2.z)
			wheel.progressive_spring_scale = float(state.progressive_spring_scale)
			wheel.bump_stop_coefficient = float(state.bump_stop_coefficient)
			wheel.anti_roll_coefficient = float(state.anti_roll_coefficient)
			wheel.min_travel = float(state.min_travel)
			wheel.max_travel = float(state.max_travel)
			wheel.reference_length = float(state.reference_length)
			wheel.preload_force = float(state.preload_force)
			break
		if slot_id in ["FL", "FR"]:
			wheel.spring_coefficient = maxf(float(source_config.front_spring_coefficient), 0.5)
			wheel.bump_damping = maxf(float(source_config.front_bump_damping), 0.0)
			wheel.rebound_damping = maxf(float(source_config.front_rebound_damping), 0.0)
		else:
			wheel.spring_coefficient = maxf(float(source_config.rear_spring_coefficient), 0.5)
			wheel.bump_damping = maxf(float(source_config.rear_bump_damping), 0.0)
			wheel.rebound_damping = maxf(float(source_config.rear_rebound_damping), 0.0)
		if float(wheel.preload_force) <= 0.0:
			wheel.preload_force = _default_preload_for_slot(slot_id)


func get_reference_params() -> Dictionary:
	return {
		"car_name": String(config.car_name) if config != null else "HP2 Car",
		"row_index": int(config.row_index) if config != null else -1,
		"duplicate_index": int(config.duplicate_index) if config != null else 1,
		"drive_type": String(config.drive_type) if config != null else "RWD",
		"handling_profile_id": int(config.globalb_handling_profile_id) if config != null else -1,
		"handling_profile_sequence": Array(config.globalb_handling_profile_sequence) if config != null else [],
		"mass": vehicle_mass_kg,
		"inertia_yaw": inertia_yaw,
		"wheelbase": wheelbase,
		"track_front": track_front,
		"track_rear": track_rear,
		"cg_height": cg_height,
		"front_weight_bias": front_weight_bias,
		"wheel_radius": wheel_radius,
		"base_mu": base_mu,
		"front_wheel_grip_scale": front_wheel_grip_scale,
		"rear_wheel_grip_scale": rear_wheel_grip_scale,
		"front_wheel_lat_grip_scale": front_wheel_lat_grip_scale,
		"rear_wheel_lat_grip_scale": rear_wheel_lat_grip_scale,
		"longitudinal_stiffness": longitudinal_stiffness,
		"longitudinal_speed_damping": longitudinal_speed_damping,
		"lateral_stiffness": lateral_stiffness,
		"brake_torque_total": brake_torque_total,
		"brake_bias_front": brake_bias_front,
		"rolling_resistance": rolling_resistance,
		"aero_drag": aero_drag,
		"weight_transfer_coeff": weight_transfer_coeff,
		"final_drive": drivetrain.final_drive,
		"gear_ratios": Array(drivetrain.gear_ratios),
		"upshift_rpm": drivetrain.upshift_rpm,
		"downshift_rpm": drivetrain.downshift_rpm,
		"upshift_rpm_per_gear": Array(drivetrain.upshift_rpm_per_gear),
		"downshift_rpm_per_gear": Array(drivetrain.downshift_rpm_per_gear),
		"idle_rpm": engine.idle_rpm,
		"peak_rpm": engine.peak_rpm,
		"max_rpm": engine.max_rpm,
		"torque_curve": _curve_to_array(engine.torque_curve),
		"friction_curve": _curve_to_array(engine.friction_curve),
		"steering_response_rate": steering_system.steering_response_rate,
		"max_steer_degrees": steering_system.max_steer_degrees,
		"assist_sideslip_threshold_deg": assist.sideslip_threshold_deg,
	}


func _front_load_bias_from_config(source_config) -> float:
	var load_origin_x: float = source_config.physics_origin_offset_ps2.x
	if absf(load_origin_x) <= 0.0001:
		load_origin_x = source_config.center_of_mass_ps2.x
	var front_x: float = source_config.front_axle_center_x() - load_origin_x
	var rear_x: float = source_config.rear_axle_center_x() - load_origin_x
	var denom: float = front_x - rear_x
	if absf(denom) <= 0.0001:
		return front_weight_bias
	var rear_each_fraction: float = (front_x / denom) * 0.5
	var front_each_fraction: float = 0.5 - rear_each_fraction
	return clampf(front_each_fraction * 2.0, 0.25, 0.75)


func _curve_to_array(curve: Array[Vector2]) -> Array:
	var out: Array = []
	for point in curve:
		out.append([point.x, point.y])
	return out


func replace_visual(visual: Node3D) -> void:
	if _visual_root == null:
		_visual_root = get_node_or_null("VisualRoot") as Node3D
	if _visual_root == null:
		return
	var existing := _visual_root.get_node_or_null("CarVisual") as Node3D
	if existing == null:
		existing = Node3D.new()
		existing.name = "CarVisual"
		_visual_root.add_child(existing)
	_ensure_scene_visual_components(existing)
	_clear_scene_visual_content(existing)
	if visual == null:
		_refresh_visual_bindings()
		return
	if visual.get_parent() != null:
		visual.get_parent().remove_child(visual)
	_merge_visual_content_into_scene(visual, existing)
	visual.queue_free()
	_refresh_visual_bindings()


func sync_wheel_slots_from_visual() -> void:
	var car_visual: Node3D = null
	if _visual_root != null:
		car_visual = _visual_root.get_node_or_null("CarVisual") as Node3D
	if car_visual != null:
		_ensure_scene_visual_components(car_visual)
	_refresh_visual_bindings()
	_update_visuals(0.0)


func _ensure_scene_visual_components(car_visual: Node3D) -> void:
	var body := _ensure_node3d(car_visual, "Body")
	body.position = Vector3.ZERO
	var wheel_pivots := _ensure_node3d(car_visual, "WheelPivots")
	for slot_id in SLOT_IDS:
		var wheel = wheels.get(slot_id, null)
		var pivot := _ensure_node3d(wheel_pivots, slot_id)
		if wheel != null:
			pivot.position = _visual_pivot_position_for_wheel(wheel)
		var suspension := _ensure_node3d(pivot, "Suspension")
		var steer := _ensure_node3d(suspension, "Steer")
		var roll := _ensure_node3d(steer, "Roll")
		_ensure_node3d(roll, "Spin")
	var dummies := _ensure_node3d(car_visual, "Dummies")
	_ensure_node3d(dummies, "BODY_CENTER")
	for slot_id in SLOT_IDS:
		var dummy := _ensure_node3d(dummies, "%s_PIVOT" % slot_id)
		var wheel = wheels.get(slot_id, null)
		if wheel != null:
			dummy.position = _visual_pivot_position_for_wheel(wheel)


func _visual_pivot_position_for_wheel(wheel) -> Vector3:
	return Vector3(float(wheel.local_position.y), float(wheel.pivot_local_z), float(wheel.local_position.x))


func _ensure_node3d(parent: Node, child_name: String) -> Node3D:
	var existing := parent.get_node_or_null(NodePath(child_name)) as Node3D
	if existing != null:
		return existing
	var node := Node3D.new()
	node.name = child_name
	parent.add_child(node)
	return node


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


func set_airborne_debug_enabled(enabled: bool, airborne_height: float) -> void:
	airborne_debug_enabled = enabled
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	sleeping = false
	if enabled:
		var airborne_transform := global_transform
		airborne_transform.origin.y = airborne_height
		global_transform = airborne_transform
	_sync_state_from_transform(global_transform)


func set_forward_speed(speed_mps: float) -> void:
	var forward := -global_transform.basis.z.normalized()
	linear_velocity = Vector3(forward.x * speed_mps, linear_velocity.y, forward.z * speed_mps)
	_last_forward_speed = speed_mps
	_update_derived_state()


func _physics_process(delta: float) -> void:
	if not auto_simulate:
		return
	var throttle: float = input_source.get_throttle() if input_source != null else 0.0
	var brake: float = input_source.get_brake() if input_source != null else 0.0
	var steer: float = input_source.get_steer() if input_source != null else 0.0
	_store_inputs(throttle, brake, steer)
	if throttle > 0.001 or brake > 0.001 or absf(steer) > 0.001:
		sleeping = false


func _store_inputs(throttle: float, brake: float, steer: float) -> void:
	_last_inputs = {
		"throttle": clampf(throttle, 0.0, 1.0),
		"brake": clampf(brake, 0.0, 1.0),
		"steer": clampf(steer, -1.0, 1.0),
	}


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if wheels.is_empty():
		return
	var step := maxf(state.step, 0.0001)
	var step_count := int(floor(step / SUBSTEP_TARGET_DT)) + 1
	var sub_dt := step / float(step_count)
	for _index in range(step_count):
		_step_physical_vehicle(state, sub_dt)
	sim_time += step
	_update_derived_state_from_state(state)


func simulate(delta: float, throttle: float, brake: float, steer: float) -> void:
	_store_inputs(throttle, brake, steer)
	sim_time += delta
	_update_derived_state()


func simulate_airborne(delta: float, throttle: float, brake: float, steer: float) -> void:
	_store_inputs(throttle, brake, steer)
	sim_time += delta
	_update_derived_state()


func reset_runtime_state(target_transform: Transform3D = Transform3D.IDENTITY) -> void:
	var resolved_transform := target_transform
	if resolved_transform == Transform3D.IDENTITY:
		resolved_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, ride_height, 0.0))
	_sync_state_from_transform(resolved_transform)
	global_transform = resolved_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	sleeping = false
	sim_time = 0.0
	accel_long = 0.0
	_last_forward_speed = 0.0
	engine.reset_runtime()
	drivetrain.reset_runtime()
	steering_system.reset_runtime()
	assist.reset_runtime()
	for wheel in wheels.values():
		wheel.reset_runtime()
		wheel.previous_length = clampf(wheel.wheel_radius - (global_position.y + wheel.pivot_local_z), wheel.min_travel, wheel.max_travel)
		wheel.current_length = wheel.previous_length
	_update_derived_state()
	_update_visuals(0.0)
	if draw_debug:
		_rebuild_debug_mesh()


func get_debug_snapshot() -> Dictionary:
	var wheel_rows: Array[Dictionary] = []
	for slot_id in SLOT_IDS:
		var wheel = wheels.get(slot_id, null)
		if wheel == null:
			continue
		wheel_rows.append({
			"slot": slot_id,
			"grounded": wheel.grounded,
			"rpm": wheel.angular_velocity * 60.0 / TAU,
			"skid": wheel.grip_utilization,
			"steering_deg": rad_to_deg(wheel.steer_angle),
			"engine_force": wheel.force_long,
			"brake_force": wheel.brake_torque,
			"load": wheel.normal_load,
			"raw_length": wheel.raw_length,
			"current_length": wheel.current_length,
			"travel_velocity": wheel.travel_velocity,
			"spring_force": wheel.spring_force,
			"damper_force": wheel.damper_force,
			"suspension_force": wheel.suspension_force,
			"normal_load": wheel.normal_load,
			"world_pivot_ps2": wheel.world_pivot_ps2,
			"world_wheel_center_ps2": wheel.world_wheel_center_ps2,
			"contact_point_ps2": wheel.contact_point_ps2,
			"normal_ps2": wheel.normal_ps2,
			"grip": wheel.grip_utilization,
			"slip_long": wheel.slip_long,
			"slip_lat": wheel.slip_lat,
			"force_long": wheel.force_long,
			"force_lat": wheel.force_lat,
			"drive_torque": wheel.drive_torque,
			"brake_torque": wheel.brake_torque,
			"angular_velocity": wheel.angular_velocity,
		})
	return {
		"speed_kmh": speed_kmh,
		"speed_ms": speed_ms,
		"rpm": engine.rpm,
		"gear": drivetrain.current_gear,
		"slip_angle_deg": sideslip_deg,
		"steering_deg": rad_to_deg(steering_system.current_angle()),
		"mass_kg": vehicle_mass_kg,
		"mass_is_estimate": false,
		"driven_wheel_count": 2,
		"engine_force_gain": 1.0,
		"hp2_launch_accel_reference": accel_long,
		"drag_force": aero_drag * speed_ms * speed_ms,
		"engine_force_total": wheels["RL"].force_long + wheels["RR"].force_long,
		"engine_brake_total": wheels["FL"].brake_torque + wheels["FR"].brake_torque + wheels["RL"].brake_torque + wheels["RR"].brake_torque,
		"yaw_rate": rad_to_deg(_yaw_rate),
		"sideslip": sideslip_deg,
		"heading": rad_to_deg(_heading),
		"accel_long": accel_long,
		"surface_type": surface_type,
		"surface_mu": surface_mu,
		"assist_wheel": assist.active_wheel,
		"inputs": _last_inputs.duplicate(),
		"wheels": wheel_rows,
	}


func get_telemetry_row() -> Dictionary:
	return {
		"t": sim_time,
		"speed_kmh": speed_kmh,
		"speed_ms": speed_ms,
		"yaw_rate": rad_to_deg(_yaw_rate),
		"sideslip": sideslip_deg,
		"heading": rad_to_deg(_heading),
		"vx": _vx,
		"vy": _vz,
		"pos_x": _pos_x,
		"pos_y": _pos_z,
		"accel_long": accel_long,
		"rpm": engine.rpm,
		"gear": drivetrain.current_gear,
		"shift_cut": 1 if engine.shift_cut_active else 0,
		"grip_FL": _wheel_value("FL", "grip_utilization"),
		"grip_FR": _wheel_value("FR", "grip_utilization"),
		"grip_RL": _wheel_value("RL", "grip_utilization"),
		"grip_RR": _wheel_value("RR", "grip_utilization"),
		"load_FL": _wheel_value("FL", "normal_load"),
		"load_FR": _wheel_value("FR", "normal_load"),
		"load_RL": _wheel_value("RL", "normal_load"),
		"load_RR": _wheel_value("RR", "normal_load"),
		"surface_type": surface_type,
		"surface_mu": surface_mu,
	}


func _step_physical_vehicle(state: PhysicsDirectBodyState3D, delta: float) -> void:
	surface_mu = base_mu * float(SURFACE_TABLE.get(surface_type, 1.0))
	var body_transform := state.transform
	var body_origin_ps2 := _godot_to_ps2(body_transform.origin)
	var body_up_ps2 := _basis_axis_ps2(body_transform.basis, Vector3(0.0, 0.0, 1.0))
	var body_forward_ps2 := _basis_axis_ps2(body_transform.basis, Vector3(1.0, 0.0, 0.0))
	var body_right_ps2 := body_up_ps2.cross(body_forward_ps2).normalized()
	var flat_velocity_ps2 := _horizontal_ps2(_godot_to_ps2(state.linear_velocity))
	var current_speed := flat_velocity_ps2.length()
	var forward_speed := flat_velocity_ps2.dot(body_forward_ps2)
	var throttle := float(_last_inputs.get("throttle", 0.0))
	var brake := float(_last_inputs.get("brake", 0.0))
	var steer := float(_last_inputs.get("steer", 0.0))
	var reverse_active: bool = throttle <= 0.05 and brake > 0.05 and (
		(drivetrain.current_gear == 0 and forward_speed <= 0.35) or
		(forward_speed <= 0.35 and current_speed * 3.6 <= 4.5)
	)
	var drive_input := throttle
	var brake_input := brake
	if reverse_active:
		drivetrain.current_gear = 0
		drive_input = brake
		brake_input = 0.0
	elif drivetrain.current_gear == 0:
		drivetrain.current_gear = 1

	state.apply_impulse(Vector3.DOWN * vehicle_mass_kg * GRAVITY * delta)
	var steer_angle := steering_system.update(steer, delta, current_speed * 3.6)
	var steer_angles := _ackermann_angles(steer_angle)
	engine.update(delta, _average_rear_wheel_angular_velocity(), drivetrain.effective_ratio())
	if drivetrain.current_gear > 0:
		_update_auto_shift(delta)

	_step_physical_suspension(state, body_transform, body_up_ps2, delta)
	var aero_load_per_wheel := aero_drag * current_speed * current_speed * aero_downforce_ratio * 0.25
	if aero_load_per_wheel > 0.0:
		_apply_impulse_ps2(state, -body_up_ps2 * aero_load_per_wheel * 4.0 * delta, body_origin_ps2)
	var loads := {}
	for slot_id in SLOT_IDS:
		var wheel = wheels[slot_id]
		var target := 0.0
		if wheel.grounded:
			target = maxf(float(wheel.suspension_force) + aero_load_per_wheel, 0.0)
			if drive_area_surface_filter_enabled and surface_sampler != null and not surface_sampler.has_driveable_surface(wheel.contact_point_ps2):
				target = 0.0
		loads[slot_id] = target
	var drive_torques := drivetrain.calculate_rear_wheel_torques(drive_input, float(loads["RL"]), float(loads["RR"]))
	for slot_id in SLOT_IDS:
		var wheel = wheels[slot_id]
		wheel.normal_load = float(loads[slot_id])
		wheel.surface_mu = surface_mu
		wheel.grip_scale = _wheel_grip_scale(slot_id)
		wheel.lat_grip_scale = _wheel_lat_grip_scale(slot_id)
		var drive_torque: float = float(drive_torques[slot_id])
		if reverse_active:
			drive_torque = -absf(drive_torque)
		elif drivetrain.current_gear > 0 and drive_input > 0.001:
			drive_torque = absf(drive_torque)
		wheel.drive_torque = drive_torque
		wheel.brake_torque = _brake_torque_for_slot(slot_id, brake_input)
		wheel.steer_angle = float(steer_angles.get(slot_id, 0.0))

	_update_derived_state_from_state(state)
	assist.apply(wheels, speed_kmh, sideslip_deg)
	_apply_physical_tire_forces(state, body_transform, body_up_ps2, delta, reverse_active)
	_apply_drag_impulse(state, flat_velocity_ps2, current_speed, body_origin_ps2, delta)
	_apply_grounded_chassis_damping(state, body_origin_ps2, body_up_ps2, body_forward_ps2, body_right_ps2, delta)
	_apply_rest_settle(state, delta)
	var new_forward_speed := _horizontal_ps2(_godot_to_ps2(state.linear_velocity)).dot(body_forward_ps2)
	accel_long = (new_forward_speed - _last_forward_speed) / maxf(delta, 0.0001)
	_last_forward_speed = new_forward_speed
	current_gear = drivetrain.current_gear
	shift_cut_active = engine.shift_cut_active


func _step_physical_suspension(
	state: PhysicsDirectBodyState3D,
	body_transform: Transform3D,
	body_up_ps2: Vector3,
	delta: float
) -> void:
	for slot_id in SLOT_IDS:
		var wheel = wheels.get(slot_id, null)
		if wheel == null:
			continue
		_step_physical_suspension_for_wheel(state, body_transform, body_up_ps2, slot_id, wheel, delta)


func _step_physical_suspension_for_wheel(
	state: PhysicsDirectBodyState3D,
	body_transform: Transform3D,
	body_up_ps2: Vector3,
	slot_id: String,
	wheel,
	delta: float
) -> void:
	var pivot_world_ps2 := _transform_wheel_point_ps2(body_transform, wheel, true)
	var length_min: float = minf(wheel.min_travel, wheel.max_travel)
	var length_max: float = maxf(wheel.min_travel, wheel.max_travel)
	var previous_length: float = clampf(wheel.previous_length, length_min, length_max)
	wheel.world_pivot_ps2 = pivot_world_ps2
	wheel.contact_point_ps2 = pivot_world_ps2
	wheel.world_wheel_center_ps2 = pivot_world_ps2 + body_up_ps2 * previous_length
	wheel.normal_ps2 = body_up_ps2
	wheel.raw_length = previous_length
	wheel.current_length = previous_length
	wheel.travel_velocity = 0.0
	wheel.overtravel = 0.0
	wheel.spring_force = 0.0
	wheel.damper_force = 0.0
	wheel.suspension_force = 0.0
	wheel.normal_load = 0.0
	wheel.grounded = false
	wheel.visual_suspension_offset = previous_length

	var surface := _sample_surface_for_suspension(pivot_world_ps2)
	if surface.is_empty():
		return
	var surface_normal: Vector3 = surface.get("normal", body_up_ps2)
	if surface_normal.length_squared() <= 0.000001:
		return
	surface_normal = surface_normal.normalized()
	var denom := surface_normal.dot(body_up_ps2)
	if denom <= SUSPENSION_DENOM_EPSILON:
		return
	var surface_point: Vector3 = surface.get("point", pivot_world_ps2)
	var plane_t: float = surface_normal.dot(surface_point - pivot_world_ps2) / denom
	var raw_length: float = plane_t + float(wheel.wheel_radius)
	var clamped_length: float = clampf(raw_length, length_min, length_max)
	var travel_velocity: float = (clamped_length - previous_length) / maxf(delta, 0.0001)
	wheel.raw_length = raw_length
	wheel.current_length = clamped_length
	wheel.previous_length = clamped_length
	wheel.travel_velocity = travel_velocity
	wheel.overtravel = maxf(raw_length - length_max, 0.0)
	wheel.grounded = raw_length >= length_min
	wheel.normal_ps2 = surface_normal
	wheel.contact_point_ps2 = pivot_world_ps2 + body_up_ps2 * plane_t
	wheel.world_wheel_center_ps2 = pivot_world_ps2 + body_up_ps2 * clamped_length
	wheel.visual_suspension_offset = clamped_length
	if not wheel.grounded:
		return

	var spring_progress: float = maxf(clamped_length, 0.0)
	var spring_force: float = clamped_length * float(wheel.spring_coefficient) * SUSPENSION_PARAM_FORCE_SCALE * (1.0 + float(wheel.progressive_spring_scale) * spring_progress)
	var damping: float = (float(wheel.bump_damping) if travel_velocity > 0.0 else float(wheel.rebound_damping)) * SUSPENSION_PARAM_FORCE_SCALE
	var damper_force: float = damping * travel_velocity
	var anti_roll_force := 0.0
	var pair = _paired_axle_wheel(slot_id)
	if pair != null:
		anti_roll_force = float(wheel.anti_roll_coefficient) * SUSPENSION_PARAM_FORCE_SCALE * (clamped_length - float(pair.current_length))
	var reference_force: float = float(wheel.bump_stop_coefficient) * SUSPENSION_PARAM_FORCE_SCALE * (clamped_length - float(wheel.reference_length))
	var overtravel_force: float = float(wheel.bump_stop_coefficient) * SUSPENSION_PARAM_FORCE_SCALE * float(wheel.overtravel)
	var force: float = float(wheel.preload_force) + spring_force + damper_force + anti_roll_force + reference_force + overtravel_force
	wheel.spring_force = spring_force
	wheel.damper_force = damper_force
	wheel.suspension_force = maxf(force, 0.0)
	wheel.normal_load = wheel.suspension_force
	_apply_impulse_ps2(state, body_up_ps2 * wheel.suspension_force * delta, pivot_world_ps2)


func _apply_physical_tire_forces(
	state: PhysicsDirectBodyState3D,
	body_transform: Transform3D,
	body_up_ps2: Vector3,
	delta: float,
	reverse_active: bool
) -> void:
	for slot_id in SLOT_IDS:
		var wheel = wheels.get(slot_id, null)
		if wheel == null:
			continue
		if not wheel.grounded or wheel.normal_load <= 0.0:
			wheel.compute_contact_forces(0.0, 0.0)
			wheel.update_airborne_angular_velocity(delta)
			continue
		var normal_ps2: Vector3 = wheel.normal_ps2.normalized()
		var heading_ps2 := _wheel_heading_ps2(body_transform.basis, body_up_ps2, wheel)
		heading_ps2 = (heading_ps2 - normal_ps2 * heading_ps2.dot(normal_ps2))
		if heading_ps2.length_squared() <= 0.0001:
			heading_ps2 = _basis_axis_ps2(body_transform.basis, Vector3(1.0, 0.0, 0.0))
		heading_ps2 = heading_ps2.normalized()
		var right_ps2 := normal_ps2.cross(heading_ps2).normalized()
		var contact_global := _ps2_to_godot(wheel.contact_point_ps2)
		var contact_local := body_transform.affine_inverse() * contact_global
		var contact_velocity_ps2 := _godot_to_ps2(state.get_velocity_at_local_position(contact_local))
		var v_long := contact_velocity_ps2.dot(heading_ps2)
		var v_lat := contact_velocity_ps2.dot(right_ps2)
		var brake_direction := signf(v_long)
		if is_zero_approx(v_long):
			brake_direction = 0.0 if is_zero_approx(wheel.angular_velocity) else signf(wheel.angular_velocity)
		var raw_drive: float = wheel.drive_torque / maxf(wheel.wheel_radius, 0.0001)
		var engine_brake := 0.0
		var drive_force_request := raw_drive
		if raw_drive < 0.0 and not reverse_active:
			var wheel_effective_mass := maxf(float(wheel.normal_load) / GRAVITY, 0.0)
			var stop_force := wheel_effective_mass * absf(v_long) / maxf(delta, 0.0001)
			engine_brake = minf(-raw_drive, stop_force)
			drive_force_request = 0.0
		var brake_force_request: float = (wheel.brake_torque / maxf(wheel.wheel_radius, 0.0001) + engine_brake) * brake_direction
		wheel.compute_contact_forces(
			drive_force_request - brake_force_request - v_long * longitudinal_stiffness * longitudinal_speed_damping,
			_lateral_contact_force_request(wheel, v_lat, delta)
		)
		wheel.update_angular_velocity(delta, v_long)
		var tire_force_ps2: Vector3 = heading_ps2 * float(wheel.force_long) + right_ps2 * float(wheel.force_lat)
		_apply_impulse_ps2(state, tire_force_ps2 * delta, wheel.contact_point_ps2)
	_apply_coast_yaw_friction_limit(state, _godot_to_ps2(body_transform.origin), body_up_ps2, delta)


func _apply_drag_impulse(
	state: PhysicsDirectBodyState3D,
	flat_velocity_ps2: Vector3,
	current_speed: float,
	body_origin_ps2: Vector3,
	delta: float
) -> void:
	if current_speed <= 0.01:
		return
	var drag_magnitude := aero_drag * current_speed * current_speed + rolling_resistance * vehicle_mass_kg * GRAVITY
	_apply_impulse_ps2(state, -flat_velocity_ps2.normalized() * drag_magnitude * delta, body_origin_ps2)


func _apply_grounded_chassis_damping(
	state: PhysicsDirectBodyState3D,
	body_origin_ps2: Vector3,
	body_up_ps2: Vector3,
	body_forward_ps2: Vector3,
	body_right_ps2: Vector3,
	delta: float
) -> void:
	var grounded_count := 0
	for wheel in wheels.values():
		if wheel.grounded:
			grounded_count += 1
	if grounded_count == 0:
		return
	var grounded_alpha := float(grounded_count) / float(maxi(wheels.size(), 1))
	var linear_velocity_ps2 := _godot_to_ps2(state.linear_velocity)
	var vertical_speed := linear_velocity_ps2.dot(body_up_ps2)
	_apply_impulse_ps2(state, body_up_ps2 * (-vertical_speed * vehicle_mass_kg * GROUNDED_HEAVE_DAMPING * grounded_alpha) * delta, body_origin_ps2)
	var angular_velocity_ps2 := _godot_to_ps2(state.angular_velocity)
	var pitch_rate := angular_velocity_ps2.dot(body_right_ps2)
	var roll_rate := angular_velocity_ps2.dot(body_forward_ps2)
	var attitude_torque_ps2 := body_right_ps2 * (-pitch_rate * GROUNDED_PITCH_DAMPING * grounded_alpha)
	attitude_torque_ps2 += body_forward_ps2 * (-roll_rate * GROUNDED_ROLL_DAMPING * grounded_alpha)
	var average_normal := Vector3.ZERO
	for wheel in wheels.values():
		if wheel.grounded:
			average_normal += wheel.normal_ps2.normalized()
	if average_normal.length_squared() > 0.0001:
		average_normal = average_normal.normalized()
		var upright_axis := body_up_ps2.cross(average_normal)
		attitude_torque_ps2 += upright_axis * GROUNDED_UPRIGHT_STIFFNESS * grounded_alpha
	_apply_torque_impulse_ps2(state, attitude_torque_ps2 * delta)
	if state.angular_velocity.length() > GROUNDED_MAX_ANGULAR_SPEED:
		state.angular_velocity = state.angular_velocity.normalized() * GROUNDED_MAX_ANGULAR_SPEED


func _lateral_contact_force_request(wheel, lateral_velocity: float, delta: float) -> float:
	# HP2 FUN_001a4930 solves wheel contact as an impulse (lambda) clipped by friction.
	# This is the force equivalent of cancelling lateral contact velocity this substep.
	var wheel_effective_mass := maxf(float(wheel.normal_load) / GRAVITY, 0.0)
	return lateral_velocity * wheel_effective_mass / maxf(delta, 0.0001)


func _apply_coast_yaw_friction_limit(
	state: PhysicsDirectBodyState3D,
	body_origin_ps2: Vector3,
	body_up_ps2: Vector3,
	delta: float
) -> void:
	if not is_zero_approx(float(_last_inputs.get("throttle", 0.0))):
		return
	if not is_zero_approx(float(_last_inputs.get("brake", 0.0))):
		return
	if not is_zero_approx(float(_last_inputs.get("steer", 0.0))):
		return
	var angular_velocity_ps2 := _godot_to_ps2(state.angular_velocity)
	var yaw_rate := angular_velocity_ps2.dot(body_up_ps2)
	if is_zero_approx(yaw_rate):
		return
	var yaw_axis_ps2 := body_up_ps2 * yaw_rate
	var max_yaw_torque := 0.0
	for wheel in wheels.values():
		if not wheel.grounded or wheel.normal_load <= 0.0:
			continue
		var r_ps2: Vector3 = wheel.contact_point_ps2 - body_origin_ps2
		var yaw_contact_velocity := yaw_axis_ps2.cross(r_ps2)
		if yaw_contact_velocity.length_squared() <= 0.000001:
			continue
		var friction_direction := -yaw_contact_velocity.normalized()
		var max_force := float(wheel.surface_mu) * float(wheel.lat_grip_scale) * float(wheel.normal_load)
		max_yaw_torque += absf(r_ps2.cross(friction_direction * max_force).dot(body_up_ps2))
	if max_yaw_torque <= 0.0:
		return
	var new_yaw_rate := move_toward(yaw_rate, 0.0, max_yaw_torque / maxf(inertia_yaw, 1.0) * delta)
	state.angular_velocity = _ps2_to_godot(angular_velocity_ps2 - yaw_axis_ps2 + body_up_ps2 * new_yaw_rate)


func _apply_rest_settle(state: PhysicsDirectBodyState3D, delta: float) -> void:
	if absf(float(_last_inputs.get("throttle", 0.0))) > 0.01:
		return
	if absf(float(_last_inputs.get("brake", 0.0))) > 0.01:
		return
	if absf(float(_last_inputs.get("steer", 0.0))) > 0.01:
		return
	if state.linear_velocity.length() > REST_SETTLE_LINEAR_SPEED:
		return
	if state.angular_velocity.length() > REST_SETTLE_ANGULAR_SPEED:
		return
	for wheel in wheels.values():
		if not wheel.grounded or absf(wheel.travel_velocity) > 0.05:
			return
	state.linear_velocity = state.linear_velocity.move_toward(Vector3.ZERO, REST_SETTLE_LINEAR_DAMP * delta)
	state.angular_velocity = state.angular_velocity.move_toward(Vector3.ZERO, REST_SETTLE_ANGULAR_DAMP * delta)


func _sample_surface_for_suspension(sample_point_ps2: Vector3) -> Dictionary:
	if surface_sampler == null:
		return {
			"height_z": 0.0,
			"point": Vector3(sample_point_ps2.x, sample_point_ps2.y, 0.0),
			"normal": Vector3(0.0, 0.0, 1.0),
			"material_id": 0,
		}
	return surface_sampler.sample_surface(sample_point_ps2)


func _paired_axle_wheel(slot_id: String):
	match slot_id:
		"FL":
			return wheels.get("FR", null)
		"FR":
			return wheels.get("FL", null)
		"RL":
			return wheels.get("RR", null)
		"RR":
			return wheels.get("RL", null)
	return null


func _rebuild_wheels() -> void:
	wheels.clear()
	var front_z := wheelbase * (1.0 - front_weight_bias)
	var rear_z := -wheelbase * front_weight_bias
	var positions := {
		"FL": Vector2(-track_front * 0.5, front_z),
		"FR": Vector2(track_front * 0.5, front_z),
		"RL": Vector2(-track_rear * 0.5, rear_z),
		"RR": Vector2(track_rear * 0.5, rear_z),
	}
	if config != null:
		var configured_positions = config.get("wheel_local_positions_ps2")
		if configured_positions != null and configured_positions.size() >= SLOT_IDS.size():
			for index in range(SLOT_IDS.size()):
				var slot_id: String = SLOT_IDS[index]
				var ps2_position: Vector3 = configured_positions[index]
				positions[slot_id] = Vector2(-ps2_position.y, ps2_position.x)
	for slot_id in SLOT_IDS:
		var wheel = HP2WheelScript.new()
		wheel.slot_id = slot_id
		wheel.local_position = positions[slot_id]
		wheel.wheel_radius = wheel_radius
		if config != null:
			var slot_index := SLOT_IDS.find(slot_id)
			var wheel_positions = config.get("wheel_local_positions_ps2")
			if wheel_positions != null and slot_index >= 0 and slot_index < wheel_positions.size():
				wheel.pivot_local_z = float(wheel_positions[slot_index].z)
			var wheel_radii = config.get("wheel_radii")
			if wheel_radii != null and slot_index >= 0 and slot_index < wheel_radii.size():
				wheel.wheel_radius = float(wheel_radii[slot_index])
		wheel.previous_length = clampf(wheel.wheel_radius - (_display_y + wheel.pivot_local_z), wheel.min_travel, wheel.max_travel)
		wheel.current_length = wheel.previous_length
		wheel.preload_force = _default_preload_for_slot(slot_id)
		wheels[slot_id] = wheel
		_wheel_spin_angles[slot_id] = 0.0


func _ackermann_angles(center_angle: float) -> Dictionary:
	if absf(center_angle) < 0.0001:
		return {
			"FL": 0.0,
			"FR": 0.0,
			"RL": 0.0,
			"RR": 0.0,
		}
	var sign := signf(center_angle)
	var turn_radius := wheelbase / maxf(tan(absf(center_angle)), 0.0001)
	var inner := atan(wheelbase / maxf(turn_radius - track_front * 0.5, 0.0001)) * sign
	var outer := atan(wheelbase / (turn_radius + track_front * 0.5)) * sign
	if center_angle > 0.0:
		return {
			"FL": outer,
			"FR": inner,
			"RL": 0.0,
			"RR": 0.0,
		}
	return {
		"FL": inner,
		"FR": outer,
		"RL": 0.0,
		"RR": 0.0,
	}


func _configured_ride_height(source_config) -> float:
	if source_config == null:
		return ride_height
	var configured_positions = source_config.get("wheel_local_positions_ps2")
	var configured_radii = source_config.get("wheel_radii")
	if configured_positions == null or configured_radii == null:
		return ride_height
	var count = mini(configured_positions.size(), configured_radii.size())
	if count <= 0:
		return ride_height
	var target_height := 0.0
	for index in range(count):
		var pivot_local_z: float = configured_positions[index].z
		target_height = maxf(target_height, float(configured_radii[index]) - pivot_local_z)
	return target_height + 0.02


func _brake_torque_for_slot(slot_id: String, brake: float) -> float:
	if slot_id in ["FL", "FR"]:
		return brake * brake_torque_total * brake_bias_front * 0.5
	return brake * brake_torque_total * (1.0 - brake_bias_front) * 0.5


func _default_preload_for_slot(slot_id: String) -> float:
	var axle_bias := front_weight_bias if slot_id in ["FL", "FR"] else (1.0 - front_weight_bias)
	return vehicle_mass_kg * GRAVITY * axle_bias * 0.5


func _wheel_grip_scale(slot_id: String) -> float:
	return front_wheel_grip_scale if slot_id in ["FL", "FR"] else rear_wheel_grip_scale


func _wheel_lat_grip_scale(slot_id: String) -> float:
	return front_wheel_lat_grip_scale if slot_id in ["FL", "FR"] else rear_wheel_lat_grip_scale


func _update_auto_shift(delta: float) -> void:
	drivetrain.update_shift_timers(delta)
	if drivetrain.auto_shift_timer < drivetrain.min_shift_interval:
		return
	var shift_rpm := minf(engine.rpm, _road_speed_engine_rpm())
	if (
		shift_rpm > drivetrain.upshift_rpm_for_current_gear()
		and drivetrain.current_gear < drivetrain.gear_ratios.size() - 1
		and _can_auto_upshift()
		and not drivetrain.blocks_hunt_upshift(shift_rpm, engine.max_rpm)
	):
		drivetrain.record_auto_shift(drivetrain.current_gear, drivetrain.current_gear + 1)
		engine.trigger_shift_cut()
	elif shift_rpm < drivetrain.downshift_rpm_for_current_gear() and drivetrain.current_gear > 1:
		drivetrain.record_auto_shift(drivetrain.current_gear, drivetrain.current_gear - 1)


func _road_speed_engine_rpm() -> float:
	var ratio := absf(drivetrain.effective_ratio())
	return speed_ms / maxf(wheel_radius, 0.0001) * ratio * 60.0 / TAU


func _can_auto_upshift() -> bool:
	for slot_id in SLOT_IDS:
		var wheel = wheels.get(slot_id, null)
		if wheel == null:
			continue
		if float(wheel.normal_load) <= 0.001:
			return false
		if absf(float(wheel.grip_utilization)) >= AUTO_SHIFT_SLIP_LIMIT:
			return false
	return true


func _update_derived_state() -> void:
	_sync_state_from_transform(global_transform)
	_vx = linear_velocity.x
	_vz = linear_velocity.z
	_yaw_rate = angular_velocity.y
	speed_ms = Vector2(_vx, _vz).length()
	speed_kmh = speed_ms * 3.6
	sideslip_deg = _compute_sideslip()
	current_gear = drivetrain.current_gear
	shift_cut_active = engine.shift_cut_active


func _update_derived_state_from_state(state: PhysicsDirectBodyState3D) -> void:
	_sync_state_from_transform(state.transform)
	_vx = state.linear_velocity.x
	_vz = state.linear_velocity.z
	_yaw_rate = state.angular_velocity.y
	speed_ms = Vector2(_vx, _vz).length()
	speed_kmh = speed_ms * 3.6
	sideslip_deg = _compute_sideslip()
	current_gear = drivetrain.current_gear
	shift_cut_active = engine.shift_cut_active


func _compute_sideslip() -> float:
	if speed_ms < MIN_SIDESLIP_SPEED_MS:
		return 0.0
	var velocity_heading := atan2(_vx, _vz)
	return rad_to_deg(wrapf(velocity_heading - _heading, -PI, PI))


func _average_rear_wheel_angular_velocity() -> float:
	var rl = wheels.get("RL", null)
	var rr = wheels.get("RR", null)
	if rl == null or rr == null:
		return 0.0
	return (rl.angular_velocity + rr.angular_velocity) * 0.5


func _wheel_value(slot_id: String, property_name: String) -> float:
	var wheel = wheels.get(slot_id, null)
	if wheel == null:
		return 0.0
	return float(wheel.get(property_name))


func _sync_state_from_transform(source_transform: Transform3D) -> void:
	var origin := source_transform.origin
	_pos_x = origin.x
	_pos_z = origin.z
	_display_y = origin.y
	_vertical_velocity = 0.0
	var forward := source_transform.basis.z.normalized()
	_heading = atan2(forward.x, forward.z)


func _wheel_heading_ps2(basis: Basis, body_up_ps2: Vector3, wheel) -> Vector3:
	var base_forward_ps2 := _basis_axis_ps2(basis, Vector3(1.0, 0.0, 0.0))
	if String(wheel.slot_id).begins_with("F"):
		return base_forward_ps2.rotated(body_up_ps2, float(wheel.steer_angle)).normalized()
	return base_forward_ps2.normalized()


func _transform_wheel_point_ps2(body_transform: Transform3D, wheel, include_pivot_z: bool) -> Vector3:
	var local_z_ps2 := float(wheel.pivot_local_z) if include_pivot_z else 0.0
	var local_point_ps2 := Vector3(float(wheel.local_position.y), -float(wheel.local_position.x), local_z_ps2)
	return _godot_to_ps2(body_transform * VehicleBodyConfigAdapter.vehicle_space_from_ps2(local_point_ps2))


func _basis_axis_ps2(basis: Basis, local_axis_ps2: Vector3) -> Vector3:
	return _godot_to_ps2(basis * VehicleBodyConfigAdapter.vehicle_space_from_ps2(local_axis_ps2)).normalized()


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


func _ps2_to_godot(value: Vector3) -> Vector3:
	return MathUtils.ps2_to_godot_vec3(value)


func _godot_to_ps2(value: Vector3) -> Vector3:
	return Vector3(value.x, -value.z, value.y)


func _horizontal_ps2(value: Vector3) -> Vector3:
	return Vector3(value.x, value.y, 0.0)


func _refresh_visual_bindings() -> void:
	_wheel_pivots.clear()
	_wheel_suspension_nodes.clear()
	_wheel_steer_nodes.clear()
	_wheel_spin_nodes.clear()
	if _visual_root == null:
		return
	var car_visual := _visual_root.get_node_or_null("CarVisual") as Node3D
	if car_visual == null:
		return
	for slot_id in SLOT_IDS:
		var pivot_node := car_visual.get_node_or_null("WheelPivots/%s" % slot_id) as Node3D
		if pivot_node != null:
			_wheel_pivots[slot_id] = pivot_node
		var suspension_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension" % slot_id) as Node3D
		if suspension_node != null:
			_wheel_suspension_nodes[slot_id] = suspension_node
		var steer_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer" % slot_id) as Node3D
		if steer_node != null:
			_wheel_steer_nodes[slot_id] = steer_node
		var spin_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll/Spin" % slot_id) as Node3D
		if spin_node == null:
			spin_node = car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll" % slot_id) as Node3D
		if spin_node != null:
			_wheel_spin_nodes[slot_id] = spin_node


func _update_visuals(delta: float) -> void:
	for slot_id in SLOT_IDS:
		var wheel = wheels.get(slot_id, null)
		if wheel == null:
			continue
		var suspension_node := _wheel_suspension_nodes.get(slot_id, null) as Node3D
		if suspension_node != null:
			var suspension_position := suspension_node.position
			suspension_position.y = wheel.visual_suspension_offset * visual_suspension_travel_scale
			suspension_node.position = suspension_position
		var steer_node := _wheel_steer_nodes.get(slot_id, null) as Node3D
		if steer_node != null:
			var steer_rotation := steer_node.rotation
			steer_rotation.y = -wheel.steer_angle
			steer_node.rotation = steer_rotation
		var spin_node := _wheel_spin_nodes.get(slot_id, null) as Node3D
		if spin_node != null:
			var visual_angular_velocity := _visual_wheel_angular_velocity(slot_id, wheel)
			_wheel_spin_angles[slot_id] = float(_wheel_spin_angles.get(slot_id, 0.0)) + visual_angular_velocity * delta * visual_spin_scale
			var spin_rotation := spin_node.rotation
			spin_rotation.x = float(_wheel_spin_angles[slot_id]) * float(spin_node.get_meta("eagl_spin_direction", 1.0))
			spin_node.rotation = spin_rotation


func _ensure_debug_mesh() -> void:
	_debug_mesh_instance = get_node_or_null("DebugLines") as MeshInstance3D
	if _debug_mesh_instance == null:
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
		_ensure_debug_mesh()
	if _debug_mesh_instance == null:
		return
	_debug_mesh.clear_surfaces()
	_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for slot_id in SLOT_IDS:
		var wheel = wheels.get(slot_id, null)
		if wheel == null:
			continue
		var pivot := _debug_local_from_ps2(wheel.world_pivot_ps2)
		var center := _debug_local_from_ps2(wheel.world_wheel_center_ps2)
		var contact := _debug_local_from_ps2(wheel.contact_point_ps2)
		_debug_mesh.surface_set_color(Color(0.0, 0.85, 1.0, 1.0))
		_debug_mesh.surface_add_vertex(pivot)
		_debug_mesh.surface_add_vertex(center)
		_debug_mesh.surface_set_color(Color(1.0, 0.75, 0.2, 0.95))
		_add_debug_cross(center, 0.07)
		_add_debug_wheel_outline(center, wheel, Color(0.15, 0.65, 1.0, 0.9))
		if wheel.grounded:
			var normal_end := _debug_local_from_ps2(wheel.contact_point_ps2 + wheel.normal_ps2 * 0.45)
			_debug_mesh.surface_set_color(Color(0.25, 1.0, 0.3, 0.95))
			_debug_mesh.surface_add_vertex(center)
			_debug_mesh.surface_add_vertex(contact)
			_add_debug_cross(contact, 0.05)
			_debug_mesh.surface_add_vertex(contact)
			_debug_mesh.surface_add_vertex(normal_end)
			_add_suspension_force_markers(pivot, wheel)
			_add_tire_force_markers(contact, wheel)
	_debug_mesh.surface_end()


func _add_debug_cross(center: Vector3, radius: float) -> void:
	_debug_mesh.surface_add_vertex(center + Vector3.LEFT * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.RIGHT * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.UP * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.DOWN * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.FORWARD * radius)
	_debug_mesh.surface_add_vertex(center + Vector3.BACK * radius)


func _add_debug_wheel_outline(center: Vector3, wheel, color: Color) -> void:
	var radius: float = maxf(wheel.wheel_radius, 0.01)
	_debug_mesh.surface_set_color(color)
	for index in range(DEBUG_WHEEL_PHYSICS_SEGMENTS):
		var angle_0 := TAU * float(index) / float(DEBUG_WHEEL_PHYSICS_SEGMENTS)
		var angle_1 := TAU * float(index + 1) / float(DEBUG_WHEEL_PHYSICS_SEGMENTS)
		var point_0 := center + (Vector3.UP * cos(angle_0) + Vector3.FORWARD * sin(angle_0)) * radius
		var point_1 := center + (Vector3.UP * cos(angle_1) + Vector3.FORWARD * sin(angle_1)) * radius
		_debug_mesh.surface_add_vertex(point_0)
		_debug_mesh.surface_add_vertex(point_1)


func _add_suspension_force_markers(pivot: Vector3, wheel) -> void:
	var reference_force: float = maxf(maxf(absf(wheel.spring_force), absf(wheel.damper_force)), absf(wheel.suspension_force))
	reference_force = maxf(reference_force, maxf(wheel.preload_force, 1.0))
	_add_force_component(pivot + Vector3.LEFT * 0.10, Vector3.UP, wheel.spring_force, reference_force, Color(0.1, 1.0, 0.35, 0.9))
	_add_force_component(pivot, Vector3.UP, wheel.damper_force, reference_force, Color(0.25, 0.55, 1.0, 0.9))
	_add_force_component(pivot + Vector3.RIGHT * 0.10, Vector3.UP, wheel.suspension_force, reference_force, Color(1.0, 0.08, 0.08, 0.9))


func _add_force_component(origin: Vector3, axis: Vector3, force: float, reference_force: float, color: Color) -> void:
	if absf(force) <= 0.5:
		return
	var direction := 1.0 if force >= 0.0 else -1.0
	var alpha := clampf(absf(force) / maxf(reference_force, 1.0), 0.0, 1.0)
	_debug_mesh.surface_set_color(color)
	_debug_mesh.surface_add_vertex(origin)
	_debug_mesh.surface_add_vertex(origin + axis * direction * lerpf(0.05, 0.6, alpha))


func _add_tire_force_markers(contact: Vector3, wheel) -> void:
	var heading := Vector3(sin(_heading + wheel.steer_angle), 0.0, cos(_heading + wheel.steer_angle))
	var right := Vector3(cos(_heading + wheel.steer_angle), 0.0, -sin(_heading + wheel.steer_angle))
	var heading_local := (global_transform.basis.inverse() * heading).normalized()
	var right_local := (global_transform.basis.inverse() * right).normalized()
	var scale := 0.00008
	_debug_mesh.surface_set_color(Color(1.0, 0.55, 0.1, 0.9))
	_debug_mesh.surface_add_vertex(contact)
	_debug_mesh.surface_add_vertex(contact + heading_local * wheel.force_long * scale)
	_debug_mesh.surface_set_color(Color(0.4, 0.8, 1.0, 0.9))
	_debug_mesh.surface_add_vertex(contact)
	_debug_mesh.surface_add_vertex(contact + right_local * wheel.force_lat * scale)


func _debug_local_from_ps2(point_ps2: Vector3) -> Vector3:
	return to_local(Vector3(point_ps2.x, point_ps2.z, -point_ps2.y))


func _visual_wheel_angular_velocity(slot_id: String, wheel) -> float:
	var visual_angular_velocity: float = wheel.angular_velocity
	if slot_id in ["RL", "RR"]:
		if drivetrain.current_gear == 0:
			return visual_angular_velocity
		var brake_input := float(_last_inputs.get("brake", 0.0))
		if brake_input > 0.05 and speed_kmh > 5.0:
			var brake_lock := clampf((brake_input - 0.05) / 0.65, 0.0, 1.0)
			var hard_lock := clampf((brake_input - 0.72) / 0.28, 0.0, 1.0)
			var lock_alpha := maxf(brake_lock * 0.92, hard_lock)
			visual_angular_velocity = lerpf(visual_angular_velocity, 0.0, lock_alpha)
	return visual_angular_velocity
