class_name TrackBoundaryLimiterComponent
extends Node

const TrackRouteBuilderScript := preload("res://eagl/rendering/track_route_builder.gd")

const BOUNDARY_CONTACT_EPSILON := 0.05
const BOUNDARY_PROBE_FORWARD_BIAS := 0.02
const SOFT_MAX_CORRECTION_PER_STEP := 0.6
const HARD_RECOVERY_DISTANCE := 3.5
const HARD_RECOVERY_MISSING_FRAMES := 8
const RECOVERY_VERTICAL_OFFSET := 0.25
const DEFAULT_HALF_WIDTH := 1.05
const DEFAULT_HALF_LENGTH := 1.75

@export var player_parent_path: NodePath
@export var race_ai_parent_path: NodePath
@export var police_ai_parent_path: NodePath

var track_root: Node3D
var _boundary_root: Node3D
var _boundary_segments: Array[Dictionary] = []
var _boundary_grid := {}
var _boundary_cell_size := 16.0
var _route_points: Array = []
var _disabled_logged := false
var _outside_missing_frames := {}
var _vehicle_footprints := {}


func set_track_root(next_track_root: Node3D) -> void:
	track_root = next_track_root
	_boundary_root = _find_boundary_root(next_track_root)
	_boundary_segments.clear()
	_boundary_grid.clear()
	_route_points.clear()
	_outside_missing_frames.clear()
	_vehicle_footprints.clear()
	_disabled_logged = false
	if _boundary_root == null:
		return
	_boundary_cell_size = maxf(float(_boundary_root.get_meta("eagl_boundary_cell_size", 16.0)), 0.001)
	_boundary_segments = _dictionary_array(_boundary_root.get_meta("eagl_boundary_segments", []))
	_boundary_grid = _boundary_root.get_meta("eagl_boundary_grid", {})
	_route_points = _array_value(_boundary_root.get_meta("eagl_route_points", []))


func _physics_process(_delta: float) -> void:
	if _boundary_root == null:
		return
	var boundary_enabled := bool(_boundary_root.get_meta("eagl_boundary_enabled", false))
	var route_enabled := bool(_boundary_root.get_meta("eagl_route_enabled", false))
	if not boundary_enabled or _boundary_segments.is_empty() or not route_enabled or _route_points.is_empty():
		_log_disabled_once(boundary_enabled, route_enabled)
		return

	for vehicle in _collect_vehicle_targets():
		var vehicle_root := vehicle.get("root", null) as Node3D
		var body := vehicle.get("body", null) as RigidBody3D
		if vehicle_root == null or body == null or not is_instance_valid(body):
			continue
		_constrain_vehicle(vehicle_root, body)


func _collect_vehicle_targets() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for parent_path in [player_parent_path, race_ai_parent_path, police_ai_parent_path]:
		var parent := get_node_or_null(parent_path) as Node3D
		if parent == null:
			continue
		for child in parent.get_children():
			var vehicle_root := child as Node3D
			if vehicle_root == null:
				continue
			var body := _find_rigid_body(vehicle_root)
			if body == null:
				continue
			out.append({
				"root": vehicle_root,
				"body": body,
			})
	return out


func _find_rigid_body(node: Node) -> RigidBody3D:
	if node is RigidBody3D:
		return node as RigidBody3D
	for child in node.get_children():
		var found := _find_rigid_body(child)
		if found != null:
			return found
	return null


func _constrain_vehicle(vehicle_root: Node3D, body: RigidBody3D) -> void:
	var body_id := body.get_instance_id()
	var footprint := _get_vehicle_footprint(body)
	var probes: Array = _array_value(footprint.get("probes", []))
	if probes.is_empty():
		return

	var valid_hit_count := 0
	var best_hit := {}
	var best_score := INF
	for probe_value in probes:
		if typeof(probe_value) != TYPE_DICTIONARY:
			continue
		var probe: Dictionary = probe_value
		var local_offset := probe.get("local_offset", Vector3.ZERO) as Vector3
		var probe_world_xz := _body_origin_xz(body) + _local_offset_world_xz(body, local_offset)
		var boundary_hit := _nearest_boundary_segment(probe_world_xz)
		if boundary_hit.is_empty():
			continue
		valid_hit_count += 1
		var probe_priority := int(probe.get("priority", 1))
		var signed_distance := float(boundary_hit.get("signed_distance", 0.0))
		var probe_score := signed_distance + float(probe_priority) * BOUNDARY_PROBE_FORWARD_BIAS
		boundary_hit["probe_name"] = String(probe.get("name", "probe"))
		boundary_hit["probe_local_offset"] = local_offset
		boundary_hit["probe_world_xz"] = probe_world_xz
		boundary_hit["probe_priority"] = probe_priority
		boundary_hit["probe_score"] = probe_score
		if probe_score >= best_score:
			continue
		best_score = probe_score
		best_hit = boundary_hit

	if valid_hit_count == 0:
		var missing_frames := int(_outside_missing_frames.get(body_id, 0)) + 1
		_outside_missing_frames[body_id] = missing_frames
		if missing_frames >= HARD_RECOVERY_MISSING_FRAMES:
			_recover_vehicle(vehicle_root, body)
			_outside_missing_frames[body_id] = 0
		return

	_outside_missing_frames[body_id] = 0
	var signed_distance := float(best_hit.get("signed_distance", 0.0))
	if signed_distance >= 0.0:
		return
	var outside_distance := -signed_distance
	if outside_distance >= HARD_RECOVERY_DISTANCE:
		_recover_vehicle(vehicle_root, body)
		return
	_soft_reentry(body, best_hit)


func _soft_reentry(body: RigidBody3D, boundary_hit: Dictionary) -> void:
	var closest_point_xz := boundary_hit.get("closest_point_xz", Vector2.ZERO) as Vector2
	var inward_normal_xz := boundary_hit.get("inward_normal_xz", Vector2.ZERO) as Vector2
	var probe_local_offset := boundary_hit.get("probe_local_offset", Vector3.ZERO) as Vector3
	var desired_probe_xz := closest_point_xz + inward_normal_xz * BOUNDARY_CONTACT_EPSILON
	var desired_xz := desired_probe_xz - _local_offset_world_xz(body, probe_local_offset)
	var current_origin := body.global_position
	var correction := desired_xz - Vector2(current_origin.x, current_origin.z)
	if correction.length() > SOFT_MAX_CORRECTION_PER_STEP:
		correction = correction.normalized() * SOFT_MAX_CORRECTION_PER_STEP
	current_origin.x += correction.x
	current_origin.z += correction.y
	body.global_transform = Transform3D(body.global_transform.basis, current_origin)

	var velocity := body.linear_velocity
	var outward_speed := velocity.x * inward_normal_xz.x + velocity.z * inward_normal_xz.y
	if outward_speed < 0.0:
		velocity.x -= inward_normal_xz.x * outward_speed
		velocity.z -= inward_normal_xz.y * outward_speed
		body.linear_velocity = velocity
	body.sleeping = false


func _get_vehicle_footprint(body: RigidBody3D) -> Dictionary:
	var body_id := body.get_instance_id()
	if _vehicle_footprints.has(body_id):
		return _vehicle_footprints[body_id]
	var footprint := _build_vehicle_footprint(body)
	_vehicle_footprints[body_id] = footprint
	return footprint


func _build_vehicle_footprint(body: RigidBody3D) -> Dictionary:
	var wheel_footprint := _build_wheel_footprint(body)
	if not wheel_footprint.is_empty():
		return wheel_footprint
	return _build_fallback_footprint(body)


func _build_wheel_footprint(body: RigidBody3D) -> Dictionary:
	var front_left := _resolve_wheel_node(body, "front_left_wheel", "WheelFrontLeft")
	var front_right := _resolve_wheel_node(body, "front_right_wheel", "WheelFrontRight")
	var rear_left := _resolve_wheel_node(body, "rear_left_wheel", "WheelRearLeft")
	var rear_right := _resolve_wheel_node(body, "rear_right_wheel", "WheelRearRight")
	if front_left == null or front_right == null or rear_left == null or rear_right == null:
		return {}

	var front_left_local := _node_local_position_in_body(body, front_left)
	var front_right_local := _node_local_position_in_body(body, front_right)
	var rear_left_local := _node_local_position_in_body(body, rear_left)
	var rear_right_local := _node_local_position_in_body(body, rear_right)

	var front_half_width := _tire_half_width_meters(body, "front_tire_width", 245.0)
	var rear_half_width := _tire_half_width_meters(body, "rear_tire_width", 245.0)

	var front_left_edge := Vector3(front_left_local.x - front_half_width, 0.0, front_left_local.z)
	var front_right_edge := Vector3(front_right_local.x + front_half_width, 0.0, front_right_local.z)
	var rear_left_edge := Vector3(rear_left_local.x - rear_half_width, 0.0, rear_left_local.z)
	var rear_right_edge := Vector3(rear_right_local.x + rear_half_width, 0.0, rear_right_local.z)

	var probes: Array = [
		{"name": "front_left", "priority": 0, "local_offset": front_left_edge},
		{"name": "mid_left", "priority": 1, "local_offset": front_left_edge.lerp(rear_left_edge, 0.5)},
		{"name": "rear_left", "priority": 2, "local_offset": rear_left_edge},
		{"name": "front_right", "priority": 0, "local_offset": front_right_edge},
		{"name": "mid_right", "priority": 1, "local_offset": front_right_edge.lerp(rear_right_edge, 0.5)},
		{"name": "rear_right", "priority": 2, "local_offset": rear_right_edge},
	]
	return {
		"source": "wheels",
		"probes": probes,
		"half_width": maxf(maxf(absf(front_left_edge.x), absf(front_right_edge.x)), maxf(absf(rear_left_edge.x), absf(rear_right_edge.x))),
		"half_length": maxf(maxf(absf(front_left_edge.z), absf(front_right_edge.z)), maxf(absf(rear_left_edge.z), absf(rear_right_edge.z))),
	}


func _build_fallback_footprint(body: RigidBody3D) -> Dictionary:
	var bounds := _estimate_body_local_bounds(body)
	var min_x := float(bounds.get("min_x", -DEFAULT_HALF_WIDTH))
	var max_x := float(bounds.get("max_x", DEFAULT_HALF_WIDTH))
	var min_z := float(bounds.get("min_z", -DEFAULT_HALF_LENGTH))
	var max_z := float(bounds.get("max_z", DEFAULT_HALF_LENGTH))

	var left_front := Vector3(min_x, 0.0, min_z)
	var left_rear := Vector3(min_x, 0.0, max_z)
	var right_front := Vector3(max_x, 0.0, min_z)
	var right_rear := Vector3(max_x, 0.0, max_z)

	var probes: Array = [
		{"name": "front_left", "priority": 0, "local_offset": left_front},
		{"name": "mid_left", "priority": 1, "local_offset": left_front.lerp(left_rear, 0.5)},
		{"name": "rear_left", "priority": 2, "local_offset": left_rear},
		{"name": "front_right", "priority": 0, "local_offset": right_front},
		{"name": "mid_right", "priority": 1, "local_offset": right_front.lerp(right_rear, 0.5)},
		{"name": "rear_right", "priority": 2, "local_offset": right_rear},
	]
	return {
		"source": "fallback",
		"probes": probes,
		"half_width": maxf(absf(min_x), absf(max_x)),
		"half_length": maxf(absf(min_z), absf(max_z)),
	}


func _resolve_wheel_node(body: RigidBody3D, property_name: String, fallback_path: String) -> Node3D:
	var value = body.get(property_name)
	if value is Node3D:
		return value as Node3D
	if value is NodePath:
		return body.get_node_or_null(value) as Node3D
	if typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME:
		return body.get_node_or_null(NodePath(String(value))) as Node3D
	return body.get_node_or_null(fallback_path) as Node3D


func _tire_half_width_meters(body: RigidBody3D, property_name: String, default_width_mm: float) -> float:
	var width_mm := default_width_mm
	var value = body.get(property_name)
	if value is float or value is int:
		width_mm = maxf(float(value), 1.0)
	return width_mm * 0.0005


func _node_local_position_in_body(body: RigidBody3D, node: Node3D) -> Vector3:
	if body.is_inside_tree() and node.is_inside_tree():
		return body.to_local(node.global_position)
	if node.get_parent() == body:
		return node.position
	return node.transform.origin


func _estimate_body_local_bounds(body: RigidBody3D) -> Dictionary:
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	var found := false

	for child in body.find_children("*", "CollisionShape3D", true, false):
		var collision_shape := child as CollisionShape3D
		if collision_shape == null or collision_shape.shape == null or collision_shape.disabled:
			continue
		var shape_bounds := _shape_local_bounds(collision_shape.shape)
		if not bool(shape_bounds.get("valid", false)):
			continue
		var shape_min := shape_bounds.get("min", Vector3.ZERO) as Vector3
		var shape_max := shape_bounds.get("max", Vector3.ZERO) as Vector3
		for corner in _bounds_corners(shape_min, shape_max):
			var world_corner := collision_shape.to_global(corner)
			var local_corner := body.to_local(world_corner)
			min_x = minf(min_x, local_corner.x)
			max_x = maxf(max_x, local_corner.x)
			min_z = minf(min_z, local_corner.z)
			max_z = maxf(max_z, local_corner.z)
			found = true

	if not found:
		return {
			"min_x": -DEFAULT_HALF_WIDTH,
			"max_x": DEFAULT_HALF_WIDTH,
			"min_z": -DEFAULT_HALF_LENGTH,
			"max_z": DEFAULT_HALF_LENGTH,
		}
	return {
		"min_x": min_x,
		"max_x": max_x,
		"min_z": min_z,
		"max_z": max_z,
	}


func _shape_local_bounds(shape: Shape3D) -> Dictionary:
	if shape is BoxShape3D:
		var size := (shape as BoxShape3D).size * 0.5
		return {"valid": true, "min": -size, "max": size}
	if shape is SphereShape3D:
		var radius := (shape as SphereShape3D).radius
		var extents := Vector3.ONE * radius
		return {"valid": true, "min": -extents, "max": extents}
	if shape is CapsuleShape3D:
		var capsule := shape as CapsuleShape3D
		var extents := Vector3(capsule.radius, capsule.height * 0.5 + capsule.radius, capsule.radius)
		return {"valid": true, "min": -extents, "max": extents}
	if shape is CylinderShape3D:
		var cylinder := shape as CylinderShape3D
		var extents := Vector3(cylinder.radius, cylinder.height * 0.5, cylinder.radius)
		return {"valid": true, "min": -extents, "max": extents}
	if shape is ConvexPolygonShape3D:
		return _points_bounds((shape as ConvexPolygonShape3D).points)
	return {"valid": false}


func _points_bounds(points: PackedVector3Array) -> Dictionary:
	if points.is_empty():
		return {"valid": false}
	var min_point := Vector3(INF, INF, INF)
	var max_point := Vector3(-INF, -INF, -INF)
	for point in points:
		min_point.x = minf(min_point.x, point.x)
		min_point.y = minf(min_point.y, point.y)
		min_point.z = minf(min_point.z, point.z)
		max_point.x = maxf(max_point.x, point.x)
		max_point.y = maxf(max_point.y, point.y)
		max_point.z = maxf(max_point.z, point.z)
	return {"valid": true, "min": min_point, "max": max_point}


func _bounds_corners(min_point: Vector3, max_point: Vector3) -> Array[Vector3]:
	return [
		Vector3(min_point.x, min_point.y, min_point.z),
		Vector3(min_point.x, min_point.y, max_point.z),
		Vector3(min_point.x, max_point.y, min_point.z),
		Vector3(min_point.x, max_point.y, max_point.z),
		Vector3(max_point.x, min_point.y, min_point.z),
		Vector3(max_point.x, min_point.y, max_point.z),
		Vector3(max_point.x, max_point.y, min_point.z),
		Vector3(max_point.x, max_point.y, max_point.z),
	]


func _body_origin_xz(body: RigidBody3D) -> Vector2:
	return Vector2(body.global_position.x, body.global_position.z)


func _local_offset_world_xz(body: RigidBody3D, local_offset: Vector3) -> Vector2:
	var basis := body.global_transform.basis
	var right_xz := Vector2(basis.x.x, basis.x.z)
	if right_xz.length_squared() <= 0.000001:
		right_xz = Vector2.RIGHT
	else:
		right_xz = right_xz.normalized()

	var back_xz := Vector2(basis.z.x, basis.z.z)
	if back_xz.length_squared() <= 0.000001:
		back_xz = Vector2(-right_xz.y, right_xz.x)
	else:
		back_xz = back_xz.normalized()
	return right_xz * local_offset.x + back_xz * local_offset.z


func _recover_vehicle(vehicle_root: Node3D, body: RigidBody3D) -> void:
	var local_position := _boundary_root.to_local(body.global_position)
	var nearest := TrackRouteBuilderScript.nearest_route_point(_route_points, local_position, true)
	if nearest.is_empty():
		return
	var route_local := nearest.get("position", local_position) as Vector3
	var route_world := _boundary_root.to_global(route_local)
	route_world.y += RECOVERY_VERTICAL_OFFSET

	var current_forward := -body.global_transform.basis.z
	current_forward.y = 0.0
	if current_forward.length_squared() <= 0.000001:
		current_forward = nearest.get("forward", Vector3.FORWARD) as Vector3
		current_forward.y = 0.0
	if current_forward.length_squared() <= 0.000001:
		current_forward = Vector3.FORWARD
	current_forward = current_forward.normalized()
	var right := Vector3.UP.cross(current_forward).normalized()
	if right.length_squared() <= 0.000001:
		right = Vector3.RIGHT
	var upright_basis := Basis(right, Vector3.UP, -current_forward).orthonormalized()

	body.global_transform = Transform3D(upright_basis, route_world)
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	body.sleeping = false
	_reset_motion_state_recursive(vehicle_root)


func _nearest_boundary_segment(position_xz: Vector2) -> Dictionary:
	if _boundary_segments.is_empty():
		return {}
	var cell_x := int(floor(position_xz.x / _boundary_cell_size))
	var cell_z := int(floor(position_xz.y / _boundary_cell_size))
	var candidate_indices := {}
	for offset_x in range(-1, 2):
		for offset_z in range(-1, 2):
			var key := _boundary_grid_key(cell_x + offset_x, cell_z + offset_z)
			var cell_indices: Array = _array_value(_boundary_grid.get(key, []))
			for index_value in cell_indices:
				candidate_indices[int(index_value)] = true
	if candidate_indices.is_empty():
		return {}

	var best := {}
	var best_distance_sq := INF
	for index_key in candidate_indices.keys():
		var index := int(index_key)
		if index < 0 or index >= _boundary_segments.size():
			continue
		var segment: Dictionary = _boundary_segments[index]
		var a_xz := segment.get("a_xz", Vector2.ZERO) as Vector2
		var b_xz := segment.get("b_xz", Vector2.ZERO) as Vector2
		var closest := _closest_point_on_segment_2d(position_xz, a_xz, b_xz)
		var delta := position_xz - closest
		var distance_sq := delta.length_squared()
		if distance_sq >= best_distance_sq:
			continue
		var inward_normal_xz := segment.get("inward_normal_xz", Vector2.ZERO) as Vector2
		best_distance_sq = distance_sq
		best = {
			"segment_index": int(segment.get("segment_index", index)),
			"closest_point_xz": closest,
			"inward_normal_xz": inward_normal_xz,
			"signed_distance": delta.dot(inward_normal_xz),
			"distance_sq": distance_sq,
		}
	return best


func _closest_point_on_segment_2d(point: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab := b - a
	var length_sq := ab.length_squared()
	if length_sq <= 0.000001:
		return a
	var t := clampf((point - a).dot(ab) / length_sq, 0.0, 1.0)
	return a + ab * t


func _find_boundary_root(root: Node3D) -> Node3D:
	if root == null:
		return null
	var track_content := root.get_node_or_null("TrackContent") as Node3D
	if track_content != null and bool(track_content.get_meta("eagl_boundary_root", false)):
		return track_content
	if bool(root.get_meta("eagl_boundary_root", false)):
		return root
	for child in root.find_children("*", "Node3D", true, false):
		if bool(child.get_meta("eagl_boundary_root", false)):
			return child as Node3D
	return null


func _log_disabled_once(boundary_enabled: bool, route_enabled: bool) -> void:
	if _disabled_logged or track_root == null:
		return
	_disabled_logged = true
	push_error(
		"TrackBoundaryLimiter disabled for %s: boundary_enabled=%s route_enabled=%s boundary_segments=%d route_points=%d" % [
			track_root.name,
			str(boundary_enabled),
			str(route_enabled),
			_boundary_segments.size(),
			_route_points.size(),
		]
	)


func _boundary_grid_key(cell_x: int, cell_z: int) -> String:
	return "%d:%d" % [cell_x, cell_z]


func _dictionary_array(value) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(value) != TYPE_ARRAY:
		return out
	for item in value:
		if typeof(item) == TYPE_DICTIONARY:
			out.append(item)
	return out


func _array_value(value) -> Array:
	if typeof(value) == TYPE_ARRAY:
		return value
	return []


func _reset_motion_state_recursive(node: Node) -> void:
	if node is Node3D and "previous_global_position" in node:
		node.set("previous_global_position", (node as Node3D).global_position)
	if "previous_velocity" in node:
		node.set("previous_velocity", Vector3.ZERO)
	if "local_velocity" in node:
		node.set("local_velocity", Vector3.ZERO)
	if "force_vector" in node:
		node.set("force_vector", Vector2.ZERO)
	if "slip_vector" in node:
		node.set("slip_vector", Vector2.ZERO)
	if "delta_time" in node:
		node.set("delta_time", 0.0)
	if "speed" in node:
		node.set("speed", 0.0)
	if "throttle_input" in node:
		node.set("throttle_input", 0.0)
	if "brake_input" in node:
		node.set("brake_input", 0.0)
	if "steering_input" in node:
		node.set("steering_input", 0.0)
	if "handbrake_input" in node:
		node.set("handbrake_input", 0.0)
	if "clutch_input" in node:
		node.set("clutch_input", 0.0)
	for child in node.get_children():
		_reset_motion_state_recursive(child)
