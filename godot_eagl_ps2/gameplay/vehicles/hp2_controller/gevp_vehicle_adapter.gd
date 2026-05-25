class_name HP2GevpVehicleAdapter
extends Vehicle


const CarConfigScript = preload("res://eagl/handling/car_config.gd")
const VehicleBodyConfigAdapter = preload("res://eagl/handling/vehicle_body_config_adapter.gd")
const MathUtils = preload("res://eagl/utils/math_utils.gd")
const HP2PlayerInputScript = preload("res://gameplay/vehicles/hp2_controller/player_input.gd")

const SLOT_IDS := ["FL", "FR", "RL", "RR"]

@export var config = null
@export var draw_debug := true
@export_enum("Road", "Dirt", "Grass") var surface_type := "Road"
@export var auto_fit_collision_from_visual := true
@export var drive_area_surface_filter_enabled := true
@export_range(0.0, 1.0) var drive_area_off_surface_friction_scale := 0.25
@export var ride_height := 0.35

var input_source = null
var surface_sampler = null

var _visual_root: Node3D
var _wheel_nodes := {}
var _wheel_helpers := {}
var _wheel_pivots := {}
var _wheel_suspension_nodes := {}
var _wheel_steer_nodes := {}
var _wheel_roll_nodes := {}
var _wheel_spin_nodes := {}
var _airborne_debug_enabled := false
var _airborne_debug_height := 0.0


func _ready() -> void:
	_visual_root = get_node_or_null("VisualRoot") as Node3D
	if _visual_root != null:
		_visual_root.transform = Transform3D(VehicleBodyConfigAdapter.gevp_visual_anchor_basis(), Vector3.ZERO)
	surface_type = _normalize_surface_name(surface_type)
	if config == null:
		config = CarConfigScript.new()
	if input_source == null:
		input_source = HP2PlayerInputScript.new()
	_cache_wheel_nodes()
	apply_config(config)
	set_debug_overlay_enabled(draw_debug)


func _physics_process(delta: float) -> void:
	_update_inputs()
	super._physics_process(delta)
	if _airborne_debug_enabled:
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		global_position.y = _airborne_debug_height


func _process(_delta: float) -> void:
	_sync_visual_wheels_from_helpers()


func apply_config(new_config) -> void:
	if new_config == null:
		return
	config = new_config
	_cache_wheel_nodes()
	_ensure_default_gevp_curve()
	_apply_demo_arcade_defaults()
	_apply_config_to_vehicle()
	_sync_scene_component_nodes_from_config()
	refresh_visual_bindings()
	_fit_chassis_collision_shape()
	if auto_fit_collision_from_visual:
		_fit_collision_shape_to_visual_bounds()
	ride_height = _configured_ride_height(config)
	_reinitialize_vehicle_runtime()
	_apply_default_surface_type()


func reset_runtime_state(target_transform: Transform3D = Transform3D.IDENTITY) -> void:
	if target_transform == Transform3D.IDENTITY:
		target_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, ride_height, 0.0))
	transform = target_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	sleeping = false
	previous_global_position = global_position
	delta_time = 0.0
	current_gear = 0
	requested_gear = 0
	steering_amount = 0.0
	true_steering_amount = 0.0
	steering_exponent_amount = 0.0
	throttle_amount = 0.0
	brake_amount = 0.0
	clutch_amount = 1.0
	torque_output = 0.0
	clutch_torque = 0.0
	max_clutch_torque = max_torque * max_clutch_torque_ratio
	handbrake_force = 0.0
	brake_force = 0.0
	motor_rpm = idle_rpm
	complete_shift_delta_time = 0.0
	last_shift_delta_time = 0.0
	current_torque_split = 0.0
	true_torque_split = front_torque_split
	is_shifting = false
	is_up_shifting = false
	need_clutch = true
	tcs_active = false
	stability_active = false
	stability_yaw_torque = 0.0
	stability_torque_vector = Vector3.ZERO
	for wheel in wheel_array:
		wheel.spin = 0.0
		wheel.force_vector = Vector2.ZERO
		wheel.slip_vector = Vector2.ZERO
		wheel.spring_force = 0.0
		wheel.damping_force = 0.0
		wheel.previous_velocity = Vector3.ZERO
		wheel.previous_global_position = wheel.global_position
		wheel.spring_current_length = wheel.spring_length
		wheel.last_collider = null
	_sync_visual_wheels_from_helpers()


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
		refresh_visual_bindings()
		return
	if visual.get_parent() != null:
		visual.get_parent().remove_child(visual)
	_merge_visual_content_into_scene(visual, existing)
	visual.queue_free()
	refresh_visual_bindings()
	if auto_fit_collision_from_visual:
		_fit_collision_shape_to_visual_bounds()


func sync_wheel_slots_from_visual() -> void:
	var car_visual: Node3D = null
	if _visual_root != null:
		car_visual = _visual_root.get_node_or_null("CarVisual") as Node3D
	if car_visual != null:
		_ensure_scene_visual_components(car_visual)
	refresh_visual_bindings()
	_sync_visual_wheels_from_helpers()


func refresh_visual_bindings() -> void:
	_wheel_pivots.clear()
	_wheel_suspension_nodes.clear()
	_wheel_steer_nodes.clear()
	_wheel_roll_nodes.clear()
	_wheel_spin_nodes.clear()
	if _visual_root == null:
		return
	var car_visual := _visual_root.get_node_or_null("CarVisual") as Node3D
	if car_visual == null:
		return
	for slot_id in SLOT_IDS:
		var pivot_node := car_visual.get_node_or_null("WheelPivots/%s" % slot_id) as Node3D
		var suspension_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension" % slot_id) as Node3D
		var steer_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer" % slot_id) as Node3D
		var roll_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll" % slot_id) as Node3D
		var spin_node := car_visual.get_node_or_null("WheelPivots/%s/Suspension/Steer/Roll/Spin" % slot_id) as Node3D
		if pivot_node != null:
			_wheel_pivots[slot_id] = pivot_node
		if suspension_node != null:
			_wheel_suspension_nodes[slot_id] = suspension_node
		if steer_node != null:
			_wheel_steer_nodes[slot_id] = steer_node
		if roll_node != null:
			_wheel_roll_nodes[slot_id] = roll_node
		if spin_node != null:
			_wheel_spin_nodes[slot_id] = spin_node


func set_surface_sampler(sampler) -> void:
	surface_sampler = sampler


func set_debug_overlay_enabled(enabled: bool) -> void:
	draw_debug = enabled
	var debug_lines := get_node_or_null("DebugLines") as VisualInstance3D
	if debug_lines != null:
		debug_lines.visible = enabled


func get_debug_snapshot() -> Dictionary:
	var wheels: Array[Dictionary] = []
	var dominant_surface := surface_type
	var surface_mu := 0.0
	var grounded_count := 0
	for slot_id in SLOT_IDS:
		var wheel := _wheel_nodes.get(slot_id, null) as Wheel
		if wheel == null:
			continue
		var grounded := wheel.is_colliding()
		var wheel_surface := _normalize_surface_name(String(wheel.surface_type if wheel.surface_type != "" else surface_type))
		if grounded:
			dominant_surface = wheel_surface
			surface_mu += float(wheel.current_cof)
			grounded_count += 1
		wheels.append({
			"slot": slot_id,
			"grounded": grounded,
			"surface_type": wheel_surface,
			"force_regime": "default_gevp",
			"lambda_long": float(wheel.force_vector.y),
			"lambda_lat": float(wheel.force_vector.x),
			"skid": float(absf(wheel.slip_vector.y)),
			"slip_locked": bool(wheel.limit_spin),
			"rpm": float(wheel.spin * 60.0 / TAU),
			"normal_load": float(wheel.spring_force),
		})
	if grounded_count > 0:
		surface_mu /= float(grounded_count)
	var speed_ms := speed
	var speed_kmh := speed_ms * 3.6
	var slip_angle_deg := 0.0
	if absf(local_velocity.z) > 0.25 or absf(local_velocity.x) > 0.25:
		slip_angle_deg = rad_to_deg(atan2(local_velocity.x, -local_velocity.z))
	return {
		"speed_ms": speed_ms,
		"speed_kmh": speed_kmh,
		"rpm": motor_rpm,
		"gear": current_gear,
		"slip_angle_deg": slip_angle_deg,
		"surface_type": dominant_surface,
		"surface_mu": surface_mu,
		"traction_control_active": tcs_active,
		"stability_active": stability_active,
		"mass_kg": vehicle_mass,
		"grip_solver": "gevp_default",
		"wheels": wheels,
	}


func get_telemetry_row() -> Dictionary:
	var snapshot := get_debug_snapshot()
	var row := {
		"t": delta_time,
		"speed_kmh": float(snapshot.get("speed_kmh", 0.0)),
		"speed_ms": float(snapshot.get("speed_ms", 0.0)),
		"yaw_rate": rad_to_deg(angular_velocity.y),
		"sideslip": float(snapshot.get("slip_angle_deg", 0.0)),
		"heading": rad_to_deg(rotation.y),
		"vx": linear_velocity.x,
		"vy": linear_velocity.z,
		"pos_x": global_position.x,
		"pos_y": global_position.z,
		"accel_long": 0.0,
		"rpm": float(snapshot.get("rpm", 0.0)),
		"gear": int(snapshot.get("gear", 0)),
		"shift_cut": 1 if is_shifting else 0,
		"surface_type": String(snapshot.get("surface_type", "")),
		"surface_mu": float(snapshot.get("surface_mu", 0.0)),
	}
	for wheel in snapshot.get("wheels", []):
		var slot_id := String(wheel.get("slot", ""))
		row["grip_%s" % slot_id] = float(wheel.get("skid", 0.0))
		row["load_%s" % slot_id] = float(wheel.get("normal_load", 0.0))
	return row


func get_reference_params() -> Dictionary:
	return {
		"controller": "gevp_default",
		"vehicle_mass": vehicle_mass,
		"front_tire_radius": front_tire_radius,
		"rear_tire_radius": rear_tire_radius,
		"wheelbase": absf(rear_left_wheel.position.z - front_left_wheel.position.z),
		"front_track_width": absf(front_right_wheel.position.x - front_left_wheel.position.x),
		"rear_track_width": absf(rear_right_wheel.position.x - rear_left_wheel.position.x),
		"gear_ratios": gear_ratios.duplicate(),
		"final_drive": final_drive,
		"max_rpm": max_rpm,
		"idle_rpm": idle_rpm,
		"surface_type": surface_type,
	}


func set_forward_speed(speed_mps: float) -> void:
	linear_velocity = -global_transform.basis.z.normalized() * speed_mps
	angular_velocity = Vector3.ZERO
	sleeping = false
	previous_global_position = global_position


func get_camera_forward_vector() -> Vector3:
	var forward := -global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() <= 0.0001:
		return Vector3(0.0, 0.0, -1.0)
	return forward.normalized()


func set_airborne_debug_enabled(enabled: bool, airborne_height: float) -> void:
	_airborne_debug_enabled = enabled
	_airborne_debug_height = airborne_height
	for wheel in _wheel_nodes.values():
		if wheel is RayCast3D:
			(wheel as RayCast3D).enabled = not enabled
	if enabled:
		var airborne_transform := transform
		airborne_transform.origin.y = airborne_height
		reset_runtime_state(airborne_transform)
	else:
		reset_runtime_state(transform)


func set_debug_surface_type(new_surface: String) -> void:
	surface_type = _normalize_surface_name(new_surface)
	_apply_default_surface_type()


func default_wheel_surface_name() -> String:
	return _normalize_surface_name(surface_type)


func _apply_config_to_vehicle() -> void:
	var wheel_positions := _vehicle_wheel_positions_from_config()
	front_left_wheel.position = wheel_positions["FL"]
	front_right_wheel.position = wheel_positions["FR"]
	rear_left_wheel.position = wheel_positions["RL"]
	rear_right_wheel.position = wheel_positions["RR"]
	if config != null and config.wheel_radii.size() > 0:
		front_tire_radius = float(config.wheel_radii[0])
		rear_tire_radius = float(config.wheel_radii[2]) if config.wheel_radii.size() > 2 else front_tire_radius


func _reinitialize_vehicle_runtime() -> void:
	is_ready = false
	wheel_array.clear()
	axles.clear()
	drive_wheels.clear()
	front_axle = null
	rear_axle = null
	previous_global_position = global_position
	vehicle_inertia = Vector3.ZERO
	current_gravity = ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3.DOWN) * ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	initialize()
	motor_rpm = idle_rpm
	current_gear = 0
	requested_gear = 0
	need_clutch = true
	is_shifting = false
	is_up_shifting = false
	current_torque_split = 0.0
	true_torque_split = front_torque_split
	_sync_visual_wheels_from_helpers()


func _vehicle_wheel_positions_from_config() -> Dictionary:
	if config == null:
		return {
			"FL": Vector3(-0.72, 0.2, -1.3),
			"FR": Vector3(0.72, 0.2, -1.3),
			"RL": Vector3(-0.72, 0.2, 1.36),
			"RR": Vector3(0.72, 0.2, 1.36),
		}
	var out := {}
	var positions: Array = config.wheel_local_positions_ps2
	for index in range(mini(SLOT_IDS.size(), positions.size())):
		var slot_id: String = SLOT_IDS[index]
		out[slot_id] = VehicleBodyConfigAdapter.gevp_vehicle_space_from_ps2(positions[index])
	return {
		"FL": out.get("FL", Vector3(-0.72, 0.2, -1.3)),
		"FR": out.get("FR", Vector3(0.72, 0.2, -1.3)),
		"RL": out.get("RL", Vector3(-0.72, 0.2, 1.36)),
		"RR": out.get("RR", Vector3(0.72, 0.2, 1.36)),
	}


func _sync_scene_component_nodes_from_config() -> void:
	var car_visual: Node3D = null
	if _visual_root != null:
		car_visual = _visual_root.get_node_or_null("CarVisual") as Node3D
	if car_visual == null or config == null:
		return
	_ensure_scene_visual_components(car_visual)
	var body_root := car_visual.get_node_or_null("Body") as Node3D
	if body_root != null:
		body_root.position = Vector3.ZERO
	var dummies_root := car_visual.get_node_or_null("Dummies") as Node3D
	for index in range(mini(SLOT_IDS.size(), config.wheel_local_positions_ps2.size())):
		var slot_id: String = SLOT_IDS[index]
		var visual_position := MathUtils.ps2_to_godot_vec3(config.wheel_local_positions_ps2[index])
		var pivot_node := car_visual.get_node_or_null("WheelPivots/%s" % slot_id) as Node3D
		if pivot_node != null:
			pivot_node.position = visual_position
		if dummies_root != null:
			var dummy_node := dummies_root.get_node_or_null("%s_PIVOT" % slot_id) as Node3D
			if dummy_node != null:
				dummy_node.position = visual_position
	var center_dummy: Node3D = null
	if dummies_root != null:
		center_dummy = dummies_root.get_node_or_null("BODY_CENTER") as Node3D
	if center_dummy != null:
		center_dummy.position = Vector3.ZERO


func _update_inputs() -> void:
	if input_source != null:
		if input_source.has_method("get_throttle"):
			throttle_input = float(input_source.get_throttle())
		else:
			throttle_input = _read_action_pair("car_accelerate", "ui_up")
		if input_source.has_method("get_brake"):
			brake_input = float(input_source.get_brake())
		else:
			brake_input = _read_action_pair("car_brake", "ui_down")
		if input_source.has_method("get_steer"):
			steering_input = float(input_source.get_steer())
		else:
			steering_input = _read_action_pair("car_steer_left", "ui_left") - _read_action_pair("car_steer_right", "ui_right")
		if input_source.has_method("get_handbrake"):
			handbrake_input = float(input_source.get_handbrake())
		else:
			handbrake_input = _read_action_pair("car_handbrake", "")
		return
	throttle_input = _read_action_pair("car_accelerate", "ui_up")
	brake_input = _read_action_pair("car_brake", "ui_down")
	steering_input = _read_action_pair("car_steer_left", "ui_left") - _read_action_pair("car_steer_right", "ui_right")
	handbrake_input = _read_action_pair("car_handbrake", "")


func _read_action_pair(primary_action: String, fallback_action: String) -> float:
	if primary_action != "" and InputMap.has_action(primary_action):
		return Input.get_action_strength(primary_action)
	if fallback_action != "" and InputMap.has_action(fallback_action):
		return Input.get_action_strength(fallback_action)
	return 0.0


func _cache_wheel_nodes() -> void:
	_wheel_nodes = {
		"FL": front_left_wheel,
		"FR": front_right_wheel,
		"RL": rear_left_wheel,
		"RR": rear_right_wheel,
	}
	_wheel_helpers.clear()
	for slot_id in SLOT_IDS:
		var wheel := _wheel_nodes.get(slot_id, null) as Wheel
		if wheel == null or wheel.wheel_node == null:
			continue
		_wheel_helpers[slot_id] = wheel.wheel_node


func _sync_visual_wheels_from_helpers() -> void:
	for slot_id in SLOT_IDS:
		var wheel := _wheel_nodes.get(slot_id, null) as Wheel
		var helper := _wheel_helpers.get(slot_id, null) as Node3D
		if wheel == null or helper == null:
			continue
		var suspension_node := _wheel_suspension_nodes.get(slot_id, null) as Node3D
		var steer_node := _wheel_steer_nodes.get(slot_id, null) as Node3D
		var roll_node := _wheel_roll_nodes.get(slot_id, null) as Node3D
		var spin_node := _wheel_spin_nodes.get(slot_id, null) as Node3D
		if suspension_node != null:
			suspension_node.position.y = helper.position.y
		if steer_node != null:
			steer_node.rotation.y = wheel.rotation.y
		if roll_node != null:
			roll_node.rotation.z = wheel.rotation.z
		if spin_node != null:
			spin_node.rotation.x = helper.rotation.x


func _apply_default_surface_type() -> void:
	for wheel in _wheel_nodes.values():
		if wheel is Wheel:
			(wheel as Wheel).surface_type = surface_type


func _apply_demo_arcade_defaults() -> void:
	stability_yaw_ground_multiplier = 6.0
	variable_torque_split = true
	front_variable_split = 0.5
	center_of_gravity_height_offset = -0.25
	front_damping_ratio = 0.6
	rear_damping_ratio = 0.6
	braking_grip_multiplier = 2.0


func _ensure_default_gevp_curve() -> void:
	if torque_curve != null:
		return
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.494505))
	curve.add_point(Vector2(0.617978, 1.0))
	curve.add_point(Vector2(1.0, 0.692308))
	torque_curve = curve


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


func _fit_chassis_collision_shape() -> void:
	var collision_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision_shape == null:
		return
	var box_shape := collision_shape.shape as BoxShape3D
	if box_shape == null:
		box_shape = BoxShape3D.new()
		collision_shape.shape = box_shape
	var body_size := VehicleBodyConfigAdapter.body_size_vehicle(config) if config != null else Vector3(1.9, 1.2, 4.6)
	box_shape.size = body_size
	collision_shape.position = Vector3(0.0, body_size.y * 0.5, 0.0)


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
	var bounds := AABB()
	var has_bounds := false
	for child in body_root.get_children():
		if not (child is MeshInstance3D):
			continue
		var mesh_instance := child as MeshInstance3D
		var mesh_aabb := mesh_instance.get_aabb()
		var mesh_corners := [
			mesh_aabb.position,
			mesh_aabb.position + Vector3(mesh_aabb.size.x, 0.0, 0.0),
			mesh_aabb.position + Vector3(0.0, mesh_aabb.size.y, 0.0),
			mesh_aabb.position + Vector3(0.0, 0.0, mesh_aabb.size.z),
			mesh_aabb.position + Vector3(mesh_aabb.size.x, mesh_aabb.size.y, 0.0),
			mesh_aabb.position + Vector3(mesh_aabb.size.x, 0.0, mesh_aabb.size.z),
			mesh_aabb.position + Vector3(0.0, mesh_aabb.size.y, mesh_aabb.size.z),
			mesh_aabb.position + mesh_aabb.size,
		]
		for corner in mesh_corners:
			var point_local := to_local(mesh_instance.to_global(corner))
			if not has_bounds:
				bounds = AABB(point_local, Vector3.ZERO)
				has_bounds = true
			else:
				bounds = bounds.expand(point_local)
	if not has_bounds:
		return
	box_shape.size = Vector3(
		maxf(bounds.size.x, 0.4),
		maxf(bounds.size.y, 0.4),
		maxf(bounds.size.z, 0.8)
	)
	collision_shape.position = bounds.position + bounds.size * 0.5


func _ensure_scene_visual_components(car_visual: Node3D) -> void:
	var body := _ensure_node3d(car_visual, "Body")
	body.position = Vector3.ZERO
	var wheel_pivots := _ensure_node3d(car_visual, "WheelPivots")
	for slot_id in SLOT_IDS:
		var pivot := _ensure_node3d(wheel_pivots, slot_id)
		var suspension := _ensure_node3d(pivot, "Suspension")
		var steer := _ensure_node3d(suspension, "Steer")
		var roll := _ensure_node3d(steer, "Roll")
		_ensure_node3d(roll, "Spin")
	var dummies := _ensure_node3d(car_visual, "Dummies")
	_ensure_node3d(dummies, "BODY_CENTER")
	for slot_id in SLOT_IDS:
		_ensure_node3d(dummies, "%s_PIVOT" % slot_id)


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


func _normalize_surface_name(value: String) -> String:
	match value.to_lower():
		"asphalt", "road":
			return "Road"
		"terrain", "dirt":
			return "Dirt"
		"grass":
			return "Grass"
		_:
			return "Road"
